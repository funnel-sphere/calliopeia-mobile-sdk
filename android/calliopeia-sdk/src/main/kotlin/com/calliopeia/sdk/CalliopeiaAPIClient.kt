package com.calliopeia.sdk

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonObject
import java.io.File
import java.net.URI
import java.net.URLEncoder

class CalliopeiaAPIClient(
    private val configuration: CalliopeiaAPIConfiguration,
    private val credentialProvider: CalliopeiaCredentialProvider,
    private val transport: CalliopeiaTransport = URLConnectionCalliopeiaTransport(),
) {
    private val json = Json { ignoreUnknownKeys = true }

    suspend fun createAudioUpload(fileName: String, contentType: String): CalliopeiaUploadTicket {
        if (fileName.isBlank() || contentType.isBlank()) {
            throw CalliopeiaSDKException.InvalidRequest("fileName and contentType are required")
        }
        val credential = credentialProvider.credential()
        val data = graphQL(
            query = CREATE_AUDIO_UPLOAD_MUTATION,
            variables = mapOf(
                "credential" to JsonPrimitive(credential.value),
                "authType" to JsonPrimitive(credential.type.apiValue),
                "fileName" to JsonPrimitive(fileName),
                "contentType" to JsonPrimitive(contentType),
            ),
            credential = credential,
        )
        val result = data.requiredObject("externalCreateAudioUpload")
        if (result.boolean("success") != true) {
            throw CalliopeiaSDKException.Service(
                result.string("error") ?: "Calliopeia rejected the upload request",
            )
        }
        val upload = result.objectOrNull("upload")
            ?: throw CalliopeiaSDKException.InvalidResponse("Upload response did not contain a ticket")
        return CalliopeiaUploadTicket(
            objectKey = upload.requiredString("objectKey"),
            uploadURL = upload.requiredURI("uploadUrl"),
            method = upload.requiredString("method"),
            contentType = upload.requiredString("contentType"),
            expiresAt = upload.string("expiresAt"),
        )
    }

    suspend fun uploadAudio(file: File, ticket: CalliopeiaUploadTicket) {
        if (!file.isFile || file.length() <= 0) {
            throw CalliopeiaSDKException.InvalidRequest("audio file must exist and not be empty")
        }
        val response = transport.execute(
            CalliopeiaTransportRequest(
                uri = ticket.uploadURL,
                method = ticket.method,
                headers = mapOf("Content-Type" to ticket.contentType),
                body = CalliopeiaRequestBody.FileBody(file),
            ),
        )
        validateHTTP(response)
    }

    suspend fun invokeAudioJob(
        ticket: CalliopeiaUploadTicket,
        fileName: String,
        fileSizeBytes: Long,
        audioSeconds: Double?,
        request: CalliopeiaAudioJobRequest,
    ): CalliopeiaJobSubmission {
        if (fileSizeBytes !in 1..MAXIMUM_AUDIO_BYTES) {
            throw CalliopeiaSDKException.InvalidRequest("audio file must be between 1 byte and 2 GiB")
        }
        if (request.idempotencyKey.isEmpty() || request.idempotencyKey.length > 128) {
            throw CalliopeiaSDKException.InvalidRequest("idempotencyKey must be 1 to 128 characters")
        }
        if (audioSeconds != null && (!audioSeconds.isFinite() || audioSeconds < 0)) {
            throw CalliopeiaSDKException.InvalidRequest(
                "audioSeconds must be a finite non-negative number",
            )
        }
        if (request.auditBatchSize != null && request.auditBatchSize !in 1..16) {
            throw CalliopeiaSDKException.InvalidRequest("auditBatchSize must be between 1 and 16")
        }
        if (request.responseMode == CalliopeiaResponseMode.WEBHOOK && request.webhookEndpointID == null) {
            throw CalliopeiaSDKException.InvalidRequest(
                "webhookEndpointID is required for WEBHOOK mode",
            )
        }

        val variables = linkedMapOf<String, JsonElement>(
            "objectKey" to JsonPrimitive(ticket.objectKey),
            "fileName" to JsonPrimitive(fileName),
            "contentType" to JsonPrimitive(ticket.contentType),
            "fileSizeBytes" to JsonPrimitive(fileSizeBytes),
            "responseMode" to JsonPrimitive(request.responseMode.apiValue),
            "idempotencyKey" to JsonPrimitive(request.idempotencyKey),
        )
        variables.putOptional("audioSeconds", audioSeconds?.let(::JsonPrimitive))
        variables.putOptional("processingProfileId", request.processingProfileID?.let(::JsonPrimitive))
        variables.putOptional("extractionEffort", request.extractionEffort?.apiValue?.let(::JsonPrimitive))
        variables.putOptional("transcriptSupportAuditMode", request.auditMode?.apiValue?.let(::JsonPrimitive))
        variables.putOptional("auditEffort", request.auditEffort?.apiValue?.let(::JsonPrimitive))
        variables.putOptional("auditStrategy", request.auditStrategy?.apiValue?.let(::JsonPrimitive))
        variables.putOptional("auditBatchSize", request.auditBatchSize?.let(::JsonPrimitive))
        variables.putOptional("promptText", request.promptText?.let(::JsonPrimitive))
        variables.putOptional("promptTemplateId", request.promptTemplateID?.let(::JsonPrimitive))
        variables.putOptional("promptTitle", request.promptTitle?.let(::JsonPrimitive))
        variables.putOptional("webhookEndpointId", request.webhookEndpointID?.let(::JsonPrimitive))
        variables.putOptional("userId", request.userID?.let(::JsonPrimitive))
        variables.putOptional("shopId", request.shopID?.let(::JsonPrimitive))
        variables.putOptional("customerId", request.customerID?.let(::JsonPrimitive))
        variables.putOptional("expectedAddressee", request.expectedAddressee?.let(::JsonPrimitive))
        variables.putOptional("karteId", request.karteID?.let(::JsonPrimitive))
        variables.putOptional("summaryId", request.summaryID?.let(::JsonPrimitive))
        request.passthrough?.let {
            validatePassthrough(it)
            variables["passthrough"] = JsonPrimitive(it.toString())
        }

        val credential = credentialProvider.credential()
        variables["credential"] = JsonPrimitive(credential.value)
        variables["authType"] = JsonPrimitive(credential.type.apiValue)
        val data = graphQL(INVOKE_AUDIO_JOB_MUTATION, variables, credential)
        val result = data.requiredObject("externalInvokeAudioJob")
        if (result.boolean("success") != true) {
            throw CalliopeiaSDKException.Service(
                result.string("error") ?: "Calliopeia rejected the audio job",
            )
        }
        val job = result.objectOrNull("job")
            ?: throw CalliopeiaSDKException.InvalidResponse("Audio job response did not contain a job")
        return CalliopeiaJobSubmission(
            message = result.string("message"),
            idempotentReplay = result.boolean("idempotentReplay") ?: false,
            subscriptionToken = result.string("subscriptionToken"),
            statusURL = result.uri("statusUrl"),
            job = job.toAcceptedJob(),
        )
    }

    suspend fun submitAudio(
        file: File,
        fileName: String = file.name,
        contentType: String = "audio/wav",
        audioSeconds: Double? = null,
        request: CalliopeiaAudioJobRequest,
    ): CalliopeiaJobSubmission {
        if (!file.isFile) {
            throw CalliopeiaSDKException.InvalidRequest("audio file does not exist")
        }
        val ticket = createAudioUpload(fileName, contentType)
        uploadAudio(file, ticket)
        return invokeAudioJob(ticket, fileName, file.length(), audioSeconds, request)
    }

    suspend fun getJob(id: String): CalliopeiaJobSnapshot {
        if (id.isEmpty()) throw CalliopeiaSDKException.InvalidRequest("job id is required")
        val credential = credentialProvider.credential()
        val data = graphQL(
            query = GET_AUDIO_JOB_QUERY,
            variables = mapOf(
                "credential" to JsonPrimitive(credential.value),
                "authType" to JsonPrimitive(credential.type.apiValue),
                "id" to JsonPrimitive(id),
            ),
            credential = credential,
        )
        val result = data.requiredObject("externalGetJob")
        if (result.boolean("success") != true) {
            throw CalliopeiaSDKException.Service(
                result.string("error") ?: "Calliopeia could not retrieve the job",
            )
        }
        return result.objectOrNull("job")?.toJobSnapshot()
            ?: throw CalliopeiaSDKException.InvalidResponse("Job response did not contain a job")
    }

    suspend fun getPullJob(id: String): CalliopeiaPullJobResponse {
        if (id.isEmpty()) throw CalliopeiaSDKException.InvalidRequest("job id is required")
        val baseURL = configuration.pullAPIBaseURL
            ?: throw CalliopeiaSDKException.MissingPullAPIBaseURL()
        val credential = credentialProvider.credential()
        if (credential.type != CalliopeiaCredentialType.API_KEY) {
            throw CalliopeiaSDKException.InvalidRequest(
                "the pull API currently requires an API_KEY credential",
            )
        }
        @Suppress("DEPRECATION")
        val encodedID = URLEncoder.encode(id, "UTF-8").replace("+", "%20")
        val uri = URI.create("${baseURL.toString().trimEnd('/')}/v1/jobs/$encodedID")
        val response = transport.execute(
            CalliopeiaTransportRequest(
                uri = uri,
                method = "GET",
                headers = mapOf(
                    "Authorization" to "Bearer ${credential.value}",
                    "Accept" to "application/json",
                ),
            ),
        )
        validateHTTP(response)
        return response.parseObject().toPullJobResponse()
    }

    private suspend fun graphQL(
        query: String,
        variables: Map<String, JsonElement>,
        credential: CalliopeiaCredential,
    ): JsonObject {
        val body = JsonObject(
            mapOf(
                "query" to JsonPrimitive(query),
                "variables" to JsonObject(variables),
            ),
        ).toString().encodeToByteArray()
        val authorizationHeaders = when (configuration.graphQLAuthorization) {
            CalliopeiaGraphQLAuthorization.API_KEY -> mapOf(
                "x-api-key" to configuration.appSyncAPIKey,
            )
            CalliopeiaGraphQLAuthorization.COGNITO_USER_POOLS -> {
                if (credential.type != CalliopeiaCredentialType.JWT) {
                    throw CalliopeiaSDKException.InvalidRequest(
                        "Cognito User Pools GraphQL authorization requires a JWT credential",
                    )
                }
                mapOf("Authorization" to credential.value)
            }
        }
        val response = transport.execute(
            CalliopeiaTransportRequest(
                uri = configuration.graphQLEndpoint,
                method = "POST",
                headers = mapOf(
                    "Content-Type" to "application/json",
                ) + authorizationHeaders,
                body = CalliopeiaRequestBody.Bytes(body),
            ),
        )
        validateHTTP(response)
        val envelope = response.parseObject()
        val errors = envelope["errors"] as? JsonArray
        if (!errors.isNullOrEmpty()) {
            val messages = errors.mapNotNull { (it as? JsonObject)?.string("message") }
            throw CalliopeiaSDKException.Service(messages.joinToString("; ").ifEmpty { "GraphQL error" })
        }
        return envelope.objectOrNull("data")
            ?: throw CalliopeiaSDKException.InvalidResponse("GraphQL response did not contain data")
    }

    private fun CalliopeiaTransportResponse.parseObject(): JsonObject = try {
        json.parseToJsonElement(body.decodeToString()).jsonObject
    } catch (error: Exception) {
        throw CalliopeiaSDKException.InvalidResponse("Response was not a JSON object", error)
    }

    private fun validateHTTP(response: CalliopeiaTransportResponse) {
        if (response.statusCode !in 200..299) {
            throw CalliopeiaSDKException.HTTP(
                statusCode = response.statusCode,
                responseBody = response.body.takeIf(ByteArray::isNotEmpty)?.decodeToString(),
            )
        }
    }

    private fun validatePassthrough(value: JsonObject) {
        val counter = PropertyCounter()
        validatePassthroughValue(value, depth = 1, counter)
        val bytes = value.toString().encodeToByteArray().size
        if (bytes > PASSTHROUGH_MAXIMUM_BYTES) {
            throw CalliopeiaSDKException.InvalidRequest(
                "passthrough must be at most $PASSTHROUGH_MAXIMUM_BYTES UTF-8 bytes",
            )
        }
    }

    private fun validatePassthroughValue(value: JsonElement, depth: Int, counter: PropertyCounter) {
        if (depth > PASSTHROUGH_MAXIMUM_DEPTH) {
            throw CalliopeiaSDKException.InvalidRequest(
                "passthrough must be at most $PASSTHROUGH_MAXIMUM_DEPTH levels deep",
            )
        }
        when (value) {
            is JsonObject -> value.forEach { (key, child) ->
                if (key.isEmpty() || key.length > PASSTHROUGH_MAXIMUM_KEY_LENGTH) {
                    throw CalliopeiaSDKException.InvalidRequest(
                        "passthrough keys must be 1 to $PASSTHROUGH_MAXIMUM_KEY_LENGTH characters",
                    )
                }
                if (key in FORBIDDEN_PASSTHROUGH_KEYS) {
                    throw CalliopeiaSDKException.InvalidRequest("passthrough contains a forbidden key")
                }
                counter.value += 1
                if (counter.value > PASSTHROUGH_MAXIMUM_PROPERTIES) {
                    throw CalliopeiaSDKException.InvalidRequest(
                        "passthrough must contain at most $PASSTHROUGH_MAXIMUM_PROPERTIES properties",
                    )
                }
                validatePassthroughValue(child, depth + 1, counter)
            }
            is JsonArray -> value.forEach { validatePassthroughValue(it, depth + 1, counter) }
            JsonNull -> Unit
            is JsonPrimitive -> if (!value.isString && value.booleanOrNull == null) {
                val number = value.doubleOrNull
                if (number == null || !number.isFinite()) {
                    throw CalliopeiaSDKException.InvalidRequest("passthrough numbers must be finite")
                }
            }
        }
    }

    private class PropertyCounter(var value: Int = 0)

    companion object {
        private const val MAXIMUM_AUDIO_BYTES = 2L * 1_024 * 1_024 * 1_024
        private const val PASSTHROUGH_MAXIMUM_BYTES = 16 * 1_024
        private const val PASSTHROUGH_MAXIMUM_DEPTH = 6
        private const val PASSTHROUGH_MAXIMUM_PROPERTIES = 100
        private const val PASSTHROUGH_MAXIMUM_KEY_LENGTH = 128
        private val FORBIDDEN_PASSTHROUGH_KEYS = setOf("__proto__", "prototype", "constructor")

        private val CREATE_AUDIO_UPLOAD_MUTATION = """
            mutation CreateAudioUpload(${dollar}credential: String!, ${dollar}authType: String!, ${dollar}fileName: String!, ${dollar}contentType: String!) {
              externalCreateAudioUpload(credential: ${dollar}credential, authType: ${dollar}authType, fileName: ${dollar}fileName, contentType: ${dollar}contentType) {
                success
                error
                upload { objectKey uploadUrl method contentType expiresAt }
              }
            }
        """.trimIndent()

        private val INVOKE_AUDIO_JOB_MUTATION = """
            mutation InvokeAudioJob(
              ${dollar}credential: String!, ${dollar}authType: String!, ${dollar}objectKey: String!, ${dollar}fileName: String!,
              ${dollar}contentType: String, ${dollar}fileSizeBytes: Int, ${dollar}audioSeconds: Float,
              ${dollar}processingProfileId: String, ${dollar}extractionEffort: String,
              ${dollar}transcriptSupportAuditMode: String, ${dollar}auditEffort: String,
              ${dollar}auditStrategy: String, ${dollar}auditBatchSize: Int, ${dollar}promptText: String,
              ${dollar}promptTemplateId: String, ${dollar}promptTitle: String, ${dollar}responseMode: String,
              ${dollar}webhookEndpointId: String, ${dollar}idempotencyKey: String, ${dollar}userId: String,
              ${dollar}shopId: String, ${dollar}customerId: String, ${dollar}expectedAddressee: String,
              ${dollar}karteId: String, ${dollar}passthrough: AWSJSON, ${dollar}summaryId: String
            ) {
              externalInvokeAudioJob(
                credential: ${dollar}credential, authType: ${dollar}authType, objectKey: ${dollar}objectKey,
                fileName: ${dollar}fileName, contentType: ${dollar}contentType, fileSizeBytes: ${dollar}fileSizeBytes,
                audioSeconds: ${dollar}audioSeconds, processingProfileId: ${dollar}processingProfileId,
                extractionEffort: ${dollar}extractionEffort,
                transcriptSupportAuditMode: ${dollar}transcriptSupportAuditMode,
                auditEffort: ${dollar}auditEffort, auditStrategy: ${dollar}auditStrategy,
                auditBatchSize: ${dollar}auditBatchSize, promptText: ${dollar}promptText,
                promptTemplateId: ${dollar}promptTemplateId, promptTitle: ${dollar}promptTitle,
                responseMode: ${dollar}responseMode, webhookEndpointId: ${dollar}webhookEndpointId,
                idempotencyKey: ${dollar}idempotencyKey, userId: ${dollar}userId, shopId: ${dollar}shopId,
                customerId: ${dollar}customerId, expectedAddressee: ${dollar}expectedAddressee,
                karteId: ${dollar}karteId, passthrough: ${dollar}passthrough, summaryId: ${dollar}summaryId
              ) {
                success error message idempotentReplay subscriptionToken statusUrl
                job {
                  id status externalSummaryId externalIdempotencyKey
                  externalResponseMode externalCallbackStatus
                }
              }
            }
        """.trimIndent()

        private val GET_AUDIO_JOB_QUERY = """
            query GetAudioJob(${dollar}credential: String!, ${dollar}authType: String!, ${dollar}id: String!) {
              externalGetJob(credential: ${dollar}credential, authType: ${dollar}authType, id: ${dollar}id) {
                success
                error
                job {
                  id status operation inputKind fileName audioSeconds responseText responseJson
                  extractionEffort transcriptSupportAuditMode auditEffort auditStrategy auditBatchSize
                  transcriptSupportAuditState transcriptSupportAuditJson deliveryBlockedReason errorMessage
                  costUsd costJpy createdAt updatedAt completedAt externalShopId externalCustomerId
                  externalKarteId externalSummaryId externalPassthrough
                }
              }
            }
        """.trimIndent()

        private const val dollar = '$'
    }
}

private fun MutableMap<String, JsonElement>.putOptional(key: String, value: JsonElement?) {
    if (value != null) put(key, value)
}

private fun JsonObject.element(name: String): JsonElement? = get(name)?.takeUnless { it is JsonNull }

private fun JsonObject.primitive(name: String): JsonPrimitive? = element(name) as? JsonPrimitive

private fun JsonObject.string(name: String): String? = primitive(name)?.contentOrNull

private fun JsonObject.requiredString(name: String): String = string(name)
    ?: throw CalliopeiaSDKException.InvalidResponse("Response field '$name' was missing or invalid")

private fun JsonObject.boolean(name: String): Boolean? = primitive(name)?.booleanOrNull

private fun JsonObject.double(name: String): Double? = primitive(name)?.doubleOrNull

private fun JsonObject.int(name: String): Int? = primitive(name)?.intOrNull

private fun JsonObject.objectOrNull(name: String): JsonObject? = element(name) as? JsonObject

private fun JsonObject.requiredObject(name: String): JsonObject = objectOrNull(name)
    ?: throw CalliopeiaSDKException.InvalidResponse("Response field '$name' was missing or invalid")

private fun JsonObject.uri(name: String): URI? = string(name)?.let {
    runCatching { URI.create(it) }.getOrElse { error ->
        throw CalliopeiaSDKException.InvalidResponse("Response field '$name' was not a valid URI", error)
    }
}

private fun JsonObject.requiredURI(name: String): URI = uri(name)
    ?: throw CalliopeiaSDKException.InvalidResponse("Response field '$name' was missing or invalid")

private fun JsonObject.toAcceptedJob() = CalliopeiaAcceptedJob(
    id = requiredString("id"),
    status = requiredString("status"),
    externalSummaryID = string("externalSummaryId"),
    externalIdempotencyKey = string("externalIdempotencyKey"),
    externalResponseMode = string("externalResponseMode"),
    externalCallbackStatus = string("externalCallbackStatus"),
)

private fun JsonObject.toJobSnapshot() = CalliopeiaJobSnapshot(
    id = requiredString("id"),
    status = requiredString("status"),
    operation = string("operation"),
    inputKind = string("inputKind"),
    fileName = string("fileName"),
    audioSeconds = double("audioSeconds"),
    responseText = string("responseText"),
    responseJSON = element("responseJson"),
    extractionEffort = string("extractionEffort"),
    auditMode = string("transcriptSupportAuditMode"),
    auditEffort = string("auditEffort"),
    auditStrategy = string("auditStrategy"),
    auditBatchSize = int("auditBatchSize"),
    auditState = string("transcriptSupportAuditState"),
    auditJSON = element("transcriptSupportAuditJson"),
    deliveryBlockedReason = string("deliveryBlockedReason"),
    errorMessage = string("errorMessage"),
    costUSD = double("costUsd"),
    costJPY = double("costJpy"),
    createdAt = string("createdAt"),
    updatedAt = string("updatedAt"),
    completedAt = string("completedAt"),
    externalShopID = string("externalShopId"),
    externalCustomerID = string("externalCustomerId"),
    externalKarteID = string("externalKarteId"),
    externalSummaryID = string("externalSummaryId"),
    passthrough = element("externalPassthrough"),
)

private fun JsonObject.toPullJobResponse(): CalliopeiaPullJobResponse {
    val job = requiredObject("job")
    return CalliopeiaPullJobResponse(
        success = boolean("success")
            ?: throw CalliopeiaSDKException.InvalidResponse("Response field 'success' was missing"),
        job = CalliopeiaPullJob(
            version = job.requiredString("version"),
            jobID = job.requiredString("jobId"),
            status = job.requiredString("status"),
            shopID = job.string("shopId"),
            customerID = job.string("customerId"),
            karteID = job.string("karteId"),
            summaryID = job.string("summaryId"),
            passthrough = job.element("passthrough"),
            error = job.element("error"),
            delivery = job["delivery"]
                ?: throw CalliopeiaSDKException.InvalidResponse("Response field 'delivery' was missing"),
            createdAt = job.string("createdAt"),
            updatedAt = job.string("updatedAt"),
            completedAt = job.string("completedAt"),
            result = job.element("result"),
        ),
        requestID = requiredString("requestId"),
    )
}
