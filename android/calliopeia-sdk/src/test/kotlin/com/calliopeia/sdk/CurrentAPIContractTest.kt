package com.calliopeia.sdk

import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.io.IOException
import java.net.URI

class CurrentAPIContractTest {
    private fun client(transport: CalliopeiaTransport) = CalliopeiaAPIClient(
        CalliopeiaAPIConfiguration(URI("https://api.example/graphql"), "public-key"),
        StaticCalliopeiaCredentialProvider(CalliopeiaCredential("test-credential")), transport)
    private fun response(value: String) = CalliopeiaTransportResponse(200, emptyMap(), value.toByteArray())

    @Test fun qualityBatchExplicitlySendsOffOptionsAndValidatesSize() = runBlocking {
        val requests = mutableListOf<JsonObject>()
        val api = client { request ->
            requests += Json.parseToJsonElement((request.body as CalliopeiaRequestBody.Bytes).value.decodeToString()).jsonObject
            response("""{"data":{"externalInvokeAudioJob":{"success":true,"job":{"id":"job-1","status":"QUEUED"}}}}""")
        }
        val ticket = CalliopeiaUploadTicket("audio.wav", URI("https://upload.example/audio.wav"), "PUT", "audio/wav", null)
        api.invokeAudioJob(ticket, "audio.wav", 100, 1.0, CalliopeiaAudioJobRequest.qualityBatch())
        val variables = requests.single().getValue("variables").jsonObject
        assertEquals("quality_batch", variables.getValue("processingProfileId").jsonPrimitive.content)
        assertEquals(false, variables.getValue("generateIndividualKartes").jsonPrimitive.boolean)
        assertEquals("off", variables.getValue("bgmSeparation").jsonPrimitive.content)
        assertEquals("OFF", variables.getValue("transcriptSupportAuditMode").jsonPrimitive.content)
        try {
            api.invokeAudioJob(ticket, "audio.wav", 2147483648L, 1.0, CalliopeiaAudioJobRequest.qualityBatch())
            fail("Expected the GraphQL signed Int limit")
        } catch (_: CalliopeiaSDKException.InvalidRequest) { assertEquals(1, requests.size) }
    }

    @Test fun questionsDecodeNumericSourcesAndKeepGraphQLVariableNames() = runBlocking {
        var sent: JsonObject? = null
        val question = buildJsonObject {
            put("questionId", "q1"); put("jobId", "j1"); put("question", "When?"); put("status", "COMPLETED")
            put("answer", "Tomorrow")
            put("citations", buildJsonArray { add(buildJsonObject {
                put("sourceId", 0); put("startSeconds", 1.0); put("endSeconds", 2.0); put("quote", "Tomorrow")
            }) })
        }
        val api = client { request ->
            sent = Json.parseToJsonElement((request.body as CalliopeiaRequestBody.Bytes).value.decodeToString()).jsonObject
            response(buildJsonObject { put("data", buildJsonObject { put("externalGetJobQuestions", buildJsonObject {
                put("success", true); put("questionJson", question.toString())
            }) }) }.toString())
        }
        val answer = api.getQuestions("j1", "q1").question!!
        assertEquals("0", answer.citations.single().sourceID)
        assertTrue(sent!!.getValue("query").jsonPrimitive.content.contains("\$jobId: ID!"))
        assertEquals("q1", sent!!.getValue("variables").jsonObject.getValue("questionId").jsonPrimitive.content)
    }

    @Test fun failedInvokeReusesUploadAndRequest() = runBlocking {
        val audio = File.createTempFile("recording", ".wav").apply { writeBytes(ByteArray(100)) }
        try {
            var creates = 0; var uploads = 0
            val invokes = mutableListOf<JsonObject>()
            val api = client { request ->
                if (request.body is CalliopeiaRequestBody.FileBody) {
                    uploads++; response("")
                } else {
                    val body = Json.parseToJsonElement((request.body as CalliopeiaRequestBody.Bytes).value.decodeToString()).jsonObject
                    if (body.getValue("query").jsonPrimitive.content.contains("externalCreateAudioUpload")) {
                        creates++
                        response("""{"data":{"externalCreateAudioUpload":{"success":true,"upload":{"objectKey":"same.wav","uploadUrl":"https://upload.example/same.wav","method":"PUT","contentType":"audio/wav"}}}}""")
                    } else {
                        invokes += body.getValue("variables").jsonObject
                        if (invokes.size == 1) throw IOException("Response lost")
                        response("""{"data":{"externalInvokeAudioJob":{"success":true,"idempotentReplay":true,"job":{"id":"same-job","status":"QUEUED"}}}}""")
                    }
                }
            }
            val pending = CalliopeiaPendingAudioSubmission(audio, "audio/wav", 1.0)
            try { pending.submit(api); fail("Expected response loss") } catch (_: IOException) { }
            assertTrue(pending.submit(api).idempotentReplay)
            assertEquals("same-job", pending.submit(api).job.id)
            assertEquals(1, creates); assertEquals(1, uploads); assertEquals(2, invokes.size)
            assertEquals(invokes[0], invokes[1])
        } finally { audio.delete() }
    }
}
