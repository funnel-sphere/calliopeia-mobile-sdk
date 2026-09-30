package com.calliopeia.auth

import android.content.Context
import com.amplifyframework.auth.AuthFactorType
import com.amplifyframework.auth.AuthUserAttributeKey
import com.amplifyframework.auth.cognito.AWSCognitoAuthPlugin
import com.amplifyframework.auth.cognito.AWSCognitoAuthSession
import com.amplifyframework.auth.cognito.exceptions.service.UserNotConfirmedException
import com.amplifyframework.auth.cognito.options.AWSCognitoAuthSignInOptions
import com.amplifyframework.auth.cognito.options.AuthFlowType
import com.amplifyframework.auth.options.AuthFetchSessionOptions
import com.amplifyframework.auth.result.AuthSignInResult
import com.amplifyframework.auth.result.step.AuthSignInStep
import com.amplifyframework.core.configuration.AmplifyOutputs
import com.amplifyframework.kotlin.core.Amplify
import com.calliopeia.sdk.*
import java.util.Locale

data class CalliopeiaAccount(val userID: String, val email: String)
sealed interface CalliopeiaLoginStep {
    data object SignedOut : CalliopeiaLoginStep
    data object EmailCode : CalliopeiaLoginStep
    data object AccountConfirmation : CalliopeiaLoginStep
    data class SignedIn(val account: CalliopeiaAccount) : CalliopeiaLoginStep
}

/** One session per app. Amplify owns persistence and refresh; no token is exposed to the UI. */
class CalliopeiaSession : CalliopeiaCredentialProvider {
    var step: CalliopeiaLoginStep = CalliopeiaLoginStep.SignedOut
        private set
    private var email: String? = null

    fun makeAPI(environment: CalliopeiaEnvironment) = CalliopeiaAPIClient(environment.api, this)

    suspend fun restore(): CalliopeiaLoginStep {
        if (!Amplify.Auth.fetchAuthSession().isSignedIn) {
            step = CalliopeiaLoginStep.SignedOut
            return step
        }
        return loadAccount()
    }
    /** Existing accounts only. Never creates an account implicitly. */
    suspend fun signIn(email: String): CalliopeiaLoginStep {
        val normalized = email.trim().lowercase(Locale.ROOT)
        require(normalized.contains('@') && normalized.none(Char::isWhitespace)) { "Enter an email address" }
        this.email = normalized
        step = CalliopeiaLoginStep.SignedOut
        return try {
            handle(Amplify.Auth.signIn(normalized, null, AWSCognitoAuthSignInOptions.builder()
                .authFlowType(AuthFlowType.USER_AUTH).preferredFirstFactor(AuthFactorType.EMAIL_OTP).build()))
        } catch (error: UserNotConfirmedException) {
            Amplify.Auth.resendSignUpCode(normalized)
            step = CalliopeiaLoginStep.AccountConfirmation
            step
        }
    }
    suspend fun confirm(code: String): CalliopeiaLoginStep {
        val value = code.trim()
        require(value.isNotEmpty()) { "Enter the email code" }
        return when (step) {
            CalliopeiaLoginStep.EmailCode -> handle(Amplify.Auth.confirmSignIn(value))
            CalliopeiaLoginStep.AccountConfirmation -> {
                val address = checkNotNull(email)
                val result = Amplify.Auth.confirmSignUp(address, value)
                check(result.isSignUpComplete) { "Account confirmation is incomplete" }
                signIn(address)
            }
            else -> throw IllegalStateException("No code confirmation is pending")
        }
    }
    suspend fun resendCode(): CalliopeiaLoginStep {
        val address = checkNotNull(email) { "No email sign-in is pending" }
        return when (step) {
            CalliopeiaLoginStep.EmailCode -> { Amplify.Auth.signOut(); signIn(address) }
            CalliopeiaLoginStep.AccountConfirmation -> { Amplify.Auth.resendSignUpCode(address); step }
            else -> throw IllegalStateException("No code confirmation is pending")
        }
    }
    suspend fun signOut() {
        Amplify.Auth.signOut()
        check(!Amplify.Auth.fetchAuthSession().isSignedIn) { "Local sign-out did not complete" }
        email = null
        step = CalliopeiaLoginStep.SignedOut
    }
    suspend fun refreshCredentials() {
        Amplify.Auth.fetchAuthSession(AuthFetchSessionOptions.builder().forceRefresh(true).build())
    }
    override suspend fun credential(): CalliopeiaCredential {
        val session = Amplify.Auth.fetchAuthSession() as? AWSCognitoAuthSession
        check(session?.isSignedIn == true) { "Sign in before calling the API" }
        val token = session.userPoolTokensResult.value?.idToken
            ?: throw CalliopeiaSDKException.Service("Session tokens are unavailable")
        return CalliopeiaCredential(token)
    }
    private suspend fun handle(result: AuthSignInResult): CalliopeiaLoginStep {
        if (result.isSignedIn) return loadAccount()
        step = when (result.nextStep.signInStep) {
            AuthSignInStep.CONFIRM_SIGN_IN_WITH_OTP -> CalliopeiaLoginStep.EmailCode
            AuthSignInStep.CONFIRM_SIGN_UP -> {
                Amplify.Auth.resendSignUpCode(checkNotNull(email)); CalliopeiaLoginStep.AccountConfirmation
            }
            else -> throw CalliopeiaSDKException.Service("This account requires an unsupported sign-in step")
        }
        return step
    }
    private suspend fun loadAccount(): CalliopeiaLoginStep {
        val user = Amplify.Auth.getCurrentUser()
        val address = Amplify.Auth.fetchUserAttributes().firstOrNull { it.key == AuthUserAttributeKey.email() }?.value
            ?: throw CalliopeiaSDKException.InvalidResponse("Signed-in account has no email")
        email = address
        step = CalliopeiaLoginStep.SignedIn(CalliopeiaAccount(user.userId, address))
        return step
    }
    companion object {
        /** Call once from Application.onCreate only if the host has not configured Amplify. */
        fun configure(context: Context, amplifyOutputs: String) {
            com.amplifyframework.core.Amplify.addPlugin(AWSCognitoAuthPlugin())
            com.amplifyframework.core.Amplify.configure(AmplifyOutputs.fromString(amplifyOutputs), context.applicationContext)
        }
    }
}
