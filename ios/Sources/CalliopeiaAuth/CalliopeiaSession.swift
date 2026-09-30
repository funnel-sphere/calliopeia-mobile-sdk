import Amplify
import AWSCognitoAuthPlugin
import AWSPluginsCore
import CalliopeiaSDK
import Foundation

public struct CalliopeiaAccount: Equatable, Sendable {
    public let userID: String
    public let email: String
}

public enum CalliopeiaLoginStep: Equatable, Sendable {
    case signedOut
    case emailCode
    case accountConfirmation
    case signedIn(CalliopeiaAccount)
}

/// Uses Amplify's Keychain persistence and token refresh. One instance per app.
/// Configure Amplify once before use; existing Amplify apps keep their setup.
@MainActor
public final class CalliopeiaSession: CalliopeiaCredentialProvider {
    public private(set) var step: CalliopeiaLoginStep = .signedOut
    private var email: String?

    public init() {}

    /// For apps which have not already configured Amplify.
    public static func configure() throws {
        try Amplify.add(plugin: AWSCognitoAuthPlugin())
        try Amplify.configure(with: .amplifyOutputs)
    }

    public func makeAPI(environment: CalliopeiaEnvironment) -> CalliopeiaAPIClient {
        .init(configuration: environment.api, credentialProvider: self)
    }

    @discardableResult
    public func restore() async throws -> CalliopeiaLoginStep {
        let session = try await Amplify.Auth.fetchAuthSession()
        guard session.isSignedIn else {
            step = .signedOut
            return step
        }
        return try await loadAccount()
    }

    /// Existing accounts only. Account creation is a separate explicit action.
    @discardableResult
    public func signIn(email value: String) async throws -> CalliopeiaLoginStep {
        let email = try Self.normalizedEmail(value)
        self.email = email
        step = .signedOut
        do {
            let result = try await Amplify.Auth.signIn(username: email, options: .init(
                pluginOptions: AWSAuthSignInOptions(authFlowType: .userAuth(preferredFirstFactor: .emailOTP))
            ))
            return try await handleSignIn(result)
        } catch {
            if Self.isUnconfirmed(error) {
                _ = try await Amplify.Auth.resendSignUpCode(for: email)
                step = .accountConfirmation
                return step
            }
            throw error
        }
    }

    @discardableResult
    public func signUp(email value: String) async throws -> CalliopeiaLoginStep {
        let email = try Self.normalizedEmail(value)
        self.email = email
        let result = try await Amplify.Auth.signUp(username: email, options: .init(
            userAttributes: [AuthUserAttribute(.email, value: email)]
        ))
        return try await handleSignUp(result, email: email)
    }

    @discardableResult
    public func confirm(code: String) async throws -> CalliopeiaLoginStep {
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty, let email else {
            throw CalliopeiaSDKError.invalidRequest("start email sign-in before confirming a code")
        }
        switch step {
        case .emailCode:
            return try await handleSignIn(Amplify.Auth.confirmSignIn(challengeResponse: code))
        case .accountConfirmation:
            let result = try await Amplify.Auth.confirmSignUp(for: email, confirmationCode: code)
            return try await handleSignUp(result, email: email)
        default:
            throw CalliopeiaSDKError.invalidRequest("no code confirmation is pending")
        }
    }

    @discardableResult
    public func resendCode() async throws -> CalliopeiaLoginStep {
        guard let email else { throw CalliopeiaSDKError.invalidRequest("no email sign-in is pending") }
        switch step {
        case .accountConfirmation:
            _ = try await Amplify.Auth.resendSignUpCode(for: email)
            return step
        case .emailCode:
            _ = await Amplify.Auth.signOut()
            return try await signIn(email: email)
        default:
            throw CalliopeiaSDKError.invalidRequest("no code confirmation is pending")
        }
    }

    public func signOut() async throws {
        _ = await Amplify.Auth.signOut()
        guard !(try await Amplify.Auth.fetchAuthSession()).isSignedIn else {
            throw CalliopeiaSDKError.service("local sign-out did not complete")
        }
        email = nil
        step = .signedOut
    }

    public func refreshCredentials() async throws {
        _ = try await Amplify.Auth.fetchAuthSession(options: .forceRefresh())
    }

    public func credential() async throws -> CalliopeiaCredential {
        let session = try await Amplify.Auth.fetchAuthSession()
        guard session.isSignedIn, let provider = session as? AuthCognitoTokensProvider else {
            throw CalliopeiaSDKError.service("sign in to Calliopeia before calling the API")
        }
        return .init(value: try provider.getCognitoTokens().get().idToken)
    }

    private func handleSignIn(_ result: AuthSignInResult) async throws -> CalliopeiaLoginStep {
        if result.isSignedIn { return try await loadAccount() }
        switch result.nextStep {
        case .confirmSignInWithOTP: step = .emailCode
        default: throw CalliopeiaSDKError.service("this account requires an unsupported sign-in step")
        }
        return step
    }

    private func handleSignUp(_ result: AuthSignUpResult, email: String) async throws -> CalliopeiaLoginStep {
        switch result.nextStep {
        case .confirmUser: step = .accountConfirmation; return step
        case .completeAutoSignIn:
            return try await handleSignIn(Amplify.Auth.autoSignIn())
        case .done: return try await signIn(email: email)
        }
    }

    private func loadAccount() async throws -> CalliopeiaLoginStep {
        let user = try await Amplify.Auth.getCurrentUser()
        let attributes = try await Amplify.Auth.fetchUserAttributes()
        guard let email = attributes.first(where: { $0.key == .email })?.value else {
            throw CalliopeiaSDKError.invalidResponse("signed-in account has no email")
        }
        self.email = email
        step = .signedIn(.init(userID: user.userId, email: email))
        return step
    }

    private static func normalizedEmail(_ value: String) throws -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard value.contains("@"), !value.contains(where: { $0.isWhitespace }) else {
            throw CalliopeiaSDKError.invalidRequest("enter an email address")
        }
        return value
    }

    private static func isUnconfirmed(_ error: Error) -> Bool {
        let underlying = (error as? AuthError)?.underlyingError
        return String(describing: underlying ?? error).contains("UserNotConfirmed")
    }
}
