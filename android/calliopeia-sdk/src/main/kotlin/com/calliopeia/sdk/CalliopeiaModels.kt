package com.calliopeia.sdk

import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import java.net.URI
import java.util.UUID

enum class CalliopeiaCredentialType(val apiValue: String) {
    JWT("JWT"),
    API_KEY("API_KEY"),
}

data class CalliopeiaCredential(
    val value: String,
    val type: CalliopeiaCredentialType = CalliopeiaCredentialType.JWT,
)

fun interface CalliopeiaCredentialProvider {
    suspend fun credential(): CalliopeiaCredential
}

class StaticCalliopeiaCredentialProvider(
    private val storedCredential: CalliopeiaCredential,
) : CalliopeiaCredentialProvider {
    override suspend fun credential(): CalliopeiaCredential = storedCredential
}

data class CalliopeiaAPIConfiguration(
    val graphQLEndpoint: URI,
    val appSyncAPIKey: String,
    val pullAPIBaseURL: URI? = null,
)

enum class CalliopeiaResponseMode(val apiValue: String) {
    ASYNC("ASYNC"),
    SUBSCRIPTION("SUBSCRIPTION"),
    WEBHOOK("WEBHOOK"),
}

enum class CalliopeiaExtractionEffort(val apiValue: String) {
    LOW("LOW"),
    STANDARD("STANDARD"),
    MAXIMUM("MAX"),
}

enum class CalliopeiaAuditMode(val apiValue: String) {
    OFF("OFF"),
    OBSERVE("OBSERVE"),
    ENFORCE("ENFORCE"),
}

enum class CalliopeiaAuditEffort(val apiValue: String) {
    STANDARD("STANDARD"),
    MAXIMUM("MAX"),
}

enum class CalliopeiaAuditStrategy(val apiValue: String) {
    COMBINED("COMBINED"),
    ATOMIC_BATCH("ATOMIC_BATCH"),
}

data class CalliopeiaAudioJobRequest(
    val idempotencyKey: String = UUID.randomUUID().toString(),
    val processingProfileID: String? = null,
    val extractionEffort: CalliopeiaExtractionEffort? = null,
    val auditMode: CalliopeiaAuditMode? = null,
    val auditEffort: CalliopeiaAuditEffort? = null,
    val auditStrategy: CalliopeiaAuditStrategy? = null,
    val auditBatchSize: Int? = null,
    val promptText: String? = null,
    val promptTemplateID: String? = null,
    val promptTitle: String? = null,
    val responseMode: CalliopeiaResponseMode = CalliopeiaResponseMode.ASYNC,
    val webhookEndpointID: String? = null,
    val userID: String? = null,
    val shopID: String? = null,
    val customerID: String? = null,
    val expectedAddressee: String? = null,
    val karteID: String? = null,
    val summaryID: String? = null,
    val passthrough: JsonObject? = null,
)

data class CalliopeiaUploadTicket(
    val objectKey: String,
    val uploadURL: URI,
    val method: String,
    val contentType: String,
    val expiresAt: String?,
)

data class CalliopeiaAcceptedJob(
    val id: String,
    val status: String,
    val externalSummaryID: String?,
    val externalIdempotencyKey: String?,
    val externalResponseMode: String?,
    val externalCallbackStatus: String?,
)

data class CalliopeiaJobSubmission(
    val message: String?,
    val idempotentReplay: Boolean,
    val subscriptionToken: String?,
    val statusURL: URI?,
    val job: CalliopeiaAcceptedJob,
)

data class CalliopeiaJobSnapshot(
    val id: String,
    val status: String,
    val operation: String?,
    val inputKind: String?,
    val fileName: String?,
    val audioSeconds: Double?,
    val responseText: String?,
    val responseJSON: JsonElement?,
    val extractionEffort: String?,
    val auditMode: String?,
    val auditEffort: String?,
    val auditStrategy: String?,
    val auditBatchSize: Int?,
    val auditState: String?,
    val auditJSON: JsonElement?,
    val deliveryBlockedReason: String?,
    val errorMessage: String?,
    val costUSD: Double?,
    val costJPY: Double?,
    val createdAt: String?,
    val updatedAt: String?,
    val completedAt: String?,
    val externalShopID: String?,
    val externalCustomerID: String?,
    val externalKarteID: String?,
    val externalSummaryID: String?,
    val passthrough: JsonElement?,
)

data class CalliopeiaPullJob(
    val version: String,
    val jobID: String,
    val status: String,
    val shopID: String?,
    val customerID: String?,
    val karteID: String?,
    val summaryID: String?,
    val passthrough: JsonElement?,
    val error: JsonElement?,
    val delivery: JsonElement,
    val createdAt: String?,
    val updatedAt: String?,
    val completedAt: String?,
    val result: JsonElement?,
)

data class CalliopeiaPullJobResponse(
    val success: Boolean,
    val job: CalliopeiaPullJob,
    val requestID: String,
)

sealed class CalliopeiaSDKException(message: String, cause: Throwable? = null) : Exception(message, cause) {
    class InvalidRequest(message: String) : CalliopeiaSDKException(message)
    class InvalidResponse(message: String, cause: Throwable? = null) : CalliopeiaSDKException(message, cause)
    class Service(message: String) : CalliopeiaSDKException(message)
    class HTTP(val statusCode: Int, val responseBody: String?) : CalliopeiaSDKException(
        responseBody?.let { "Calliopeia returned HTTP $statusCode: $it" }
            ?: "Calliopeia returned HTTP $statusCode",
    )
    class MissingPullAPIBaseURL : CalliopeiaSDKException(
        "pullAPIBaseURL is required to retrieve job results",
    )
}
