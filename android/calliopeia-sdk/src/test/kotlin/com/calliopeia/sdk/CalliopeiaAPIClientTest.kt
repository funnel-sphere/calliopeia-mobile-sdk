package com.calliopeia.sdk

import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.File
import java.net.URI

class CalliopeiaAPIClientTest {
    @Test
    fun processingOptionValuesMatchExternalContract() {
        assertEquals("LOW", CalliopeiaExtractionEffort.LOW.apiValue)
        assertEquals("STANDARD", CalliopeiaExtractionEffort.STANDARD.apiValue)
        assertEquals("MAX", CalliopeiaExtractionEffort.MAXIMUM.apiValue)
        assertEquals("OBSERVE", CalliopeiaAuditMode.OBSERVE.apiValue)
        assertEquals("ENFORCE", CalliopeiaAuditMode.ENFORCE.apiValue)
        assertEquals("ATOMIC_BATCH", CalliopeiaAuditStrategy.ATOMIC_BATCH.apiValue)
    }

    @Test
    fun submitUploadsThenInvokesWithPassthrough() = runBlocking {
        val transport = QueueTransport(
            jsonResponse(
                """{"data":{"externalCreateAudioUpload":{"success":true,"error":null,"upload":{"objectKey":"tenant/audio.wav","uploadUrl":"https://upload.example.com/audio.wav","method":"PUT","contentType":"audio/wav","expiresAt":"2026-08-03T00:00:00Z"}}}}""",
            ),
            CalliopeiaTransportResponse(200, emptyMap(), byteArrayOf()),
            jsonResponse(
                """{"data":{"externalInvokeAudioJob":{"success":true,"error":null,"message":"queued","idempotentReplay":false,"subscriptionToken":null,"statusUrl":"https://pull.example.com/v1/jobs/abc","job":{"id":"abc","status":"QUEUED","externalSummaryId":null,"externalIdempotencyKey":"idem-1","externalResponseMode":"WEBHOOK","externalCallbackStatus":null}}}}""",
            ),
        )
        val client = client(transport)
        val audio = File.createTempFile("calliopeia-sdk-test", ".wav").apply {
            writeBytes(ByteArray(128) { 0x5a })
            deleteOnExit()
        }

        val result = client.submitAudio(
            file = audio,
            request = CalliopeiaAudioJobRequest(
                idempotencyKey = "idem-1",
                extractionEffort = CalliopeiaExtractionEffort.MAXIMUM,
                responseMode = CalliopeiaResponseMode.WEBHOOK,
                webhookEndpointID = "endpoint-1",
                passthrough = buildJsonObject { put("crm_record_id", "C-123") },
            ),
        )

        assertEquals("abc", result.job.id)
        assertEquals(3, transport.requests.size)
        val upload = transport.requests[1]
        assertEquals("PUT", upload.method)
        assertEquals("audio/wav", upload.headers["Content-Type"])
        assertTrue(upload.body is CalliopeiaRequestBody.FileBody)
        val invokeBody = (transport.requests[2].body as CalliopeiaRequestBody.Bytes).value
        val variables = Json.parseToJsonElement(invokeBody.decodeToString())
            .jsonObject.getValue("variables").jsonObject
        assertEquals("MAX", variables.getValue("extractionEffort").jsonPrimitive.content)
        assertEquals("JWT", variables.getValue("authType").jsonPrimitive.content)
        assertEquals(
            "{\"crm_record_id\":\"C-123\"}",
            variables.getValue("passthrough").jsonPrimitive.content,
        )
    }

    @Test
    fun rejectsOversizedPassthroughBeforeNetwork() = runBlocking {
        val transport = QueueTransport()
        val ticket = CalliopeiaUploadTicket(
            objectKey = "tenant/audio.wav",
            uploadURL = URI.create("https://upload.example.com/audio.wav"),
            method = "PUT",
            contentType = "audio/wav",
            expiresAt = null,
        )

        try {
            client(transport).invokeAudioJob(
                ticket = ticket,
                fileName = "audio.wav",
                fileSizeBytes = 100,
                audioSeconds = 1.0,
                request = CalliopeiaAudioJobRequest(
                    idempotencyKey = "idem",
                    passthrough = buildJsonObject { put("payload", "x".repeat(17_000)) },
                ),
            )
            fail("Expected passthrough validation to fail")
        } catch (error: CalliopeiaSDKException.InvalidRequest) {
            assertTrue(error.message!!.contains("16384"))
        }
        assertTrue(transport.requests.isEmpty())
    }

    @Test
    fun getJobParsesAuditAndExternalMetadata() = runBlocking {
        val transport = QueueTransport(
            jsonResponse(
                """{"data":{"externalGetJob":{"success":true,"error":null,"job":{"id":"job-123","status":"SUCCEEDED","operation":"ANALYZE","inputKind":"AUDIO","fileName":"audio.wav","audioSeconds":10,"responseText":"ok","responseJson":{"summary":"ok"},"extractionEffort":"MAX","transcriptSupportAuditMode":"OBSERVE","auditEffort":"MAX","auditStrategy":"ATOMIC_BATCH","auditBatchSize":4,"transcriptSupportAuditState":"PASSED","transcriptSupportAuditJson":null,"deliveryBlockedReason":null,"errorMessage":null,"costUsd":0.1,"costJpy":15,"createdAt":null,"updatedAt":null,"completedAt":null,"externalShopId":null,"externalCustomerId":null,"externalKarteId":null,"externalSummaryId":null,"externalPassthrough":{"crm_id":"C-123"}}}}}""",
            ),
        )

        val job = client(transport).getJob("job-123")

        assertEquals("job-123", job.id)
        assertEquals("OBSERVE", job.auditMode)
        assertEquals("C-123", job.passthrough!!.jsonObject["crm_id"]!!.jsonPrimitive.content)
        val variables = requestVariables(transport.requests.single())
        assertEquals("short-lived-jwt", variables["credential"]!!.jsonPrimitive.content)
    }

    @Test
    fun getPullJobUsesAPIKeyAuthorization() = runBlocking {
        val transport = QueueTransport(
            jsonResponse(
                """{"success":true,"job":{"version":"1","jobId":"job-123","status":"SUCCEEDED","shopId":null,"customerId":null,"karteId":null,"summaryId":null,"passthrough":{"crm_id":"C-123"},"error":null,"delivery":{},"createdAt":null,"updatedAt":null,"completedAt":null,"result":{"summary":"ok"}},"requestId":"request-1"}""",
            ),
        )
        val client = CalliopeiaAPIClient(
            configuration = configuration(),
            credentialProvider = StaticCalliopeiaCredentialProvider(
                CalliopeiaCredential("refreshed-api-key", CalliopeiaCredentialType.API_KEY),
            ),
            transport = transport,
        )

        val response = client.getPullJob("job-123")

        assertEquals("job-123", response.job.jobID)
        val request = transport.requests.single()
        assertEquals("https://pull.example.com/v1/jobs/job-123", request.uri.toString())
        assertEquals("Bearer refreshed-api-key", request.headers["Authorization"])
    }

    private fun client(transport: CalliopeiaTransport) = CalliopeiaAPIClient(
        configuration = configuration(),
        credentialProvider = StaticCalliopeiaCredentialProvider(
            CalliopeiaCredential("short-lived-jwt"),
        ),
        transport = transport,
    )

    private fun configuration() = CalliopeiaAPIConfiguration(
        graphQLEndpoint = URI.create("https://graphql.example.com/graphql"),
        appSyncAPIKey = "public-appsync-key",
        pullAPIBaseURL = URI.create("https://pull.example.com"),
    )

    private fun requestVariables(request: CalliopeiaTransportRequest) =
        Json.parseToJsonElement((request.body as CalliopeiaRequestBody.Bytes).value.decodeToString())
            .jsonObject.getValue("variables").jsonObject

    private fun jsonResponse(body: String) = CalliopeiaTransportResponse(
        statusCode = 200,
        headers = mapOf("Content-Type" to listOf("application/json")),
        body = body.encodeToByteArray(),
    )

    private class QueueTransport(
        vararg responses: CalliopeiaTransportResponse,
    ) : CalliopeiaTransport {
        private val responses = ArrayDeque(responses.toList())
        val requests = mutableListOf<CalliopeiaTransportRequest>()

        override suspend fun execute(request: CalliopeiaTransportRequest): CalliopeiaTransportResponse {
            requests += request
            return responses.removeFirst()
        }
    }
}
