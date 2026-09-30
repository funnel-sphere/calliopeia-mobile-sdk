package com.calliopeia.sdk

import kotlinx.serialization.json.*

data class CalliopeiaAccess(val tenantID: String?, val tenantName: String?, val email: String,
    val role: String, val status: String, val canRunJobs: Boolean, val canViewRuns: Boolean)
data class CalliopeiaTranscript(val state: String?, val quoteToken: String?, val priceJPY: Int?,
    val purchasedAt: String?, val transcript: JsonElement?)
data class CalliopeiaCitation(val sourceID: String, val startSeconds: Double, val endSeconds: Double, val quote: String)
data class CalliopeiaQuestion(val questionID: String, val jobID: String, val question: String,
    val parentQuestionID: String?, val sectionIndex: Int?, val status: String, val answer: String?,
    val citations: List<CalliopeiaCitation>, val error: String?)
data class CalliopeiaQuestions(val question: CalliopeiaQuestion?, val questions: List<CalliopeiaQuestion>, val nextToken: String?)

suspend fun CalliopeiaAPIClient.currentAccess(): CalliopeiaAccess {
    val credential = credentialProvider.credential()
    require(credential.type == CalliopeiaCredentialType.JWT) { "currentAccess requires a signed-in Cognito session" }
    val result = graphQL("""query CurrentAccess { getCurrentAccess { success error access {
        tenantId tenantName email role status canRunJobs canViewRuns
    } } }""", emptyMap(), credential).getValue("getCurrentAccess").jsonObject.checked()
    val a = result.getValue("access").jsonObject
    return CalliopeiaAccess(a.text("tenantId"), a.text("tenantName"), a.required("email"),
        a.required("role"), a.required("status"), a.getValue("canRunJobs").jsonPrimitive.boolean,
        a.getValue("canViewRuns").jsonPrimitive.boolean)
}
suspend fun CalliopeiaAPIClient.getProvisionalTranscript(jobID: String) = transcript("externalGetJobProvisionalTranscript", jobID)
suspend fun CalliopeiaAPIClient.getFormattedTranscript(jobID: String) = transcript("externalGetJobTranscript", jobID)
suspend fun CalliopeiaAPIClient.purchaseFormattedTranscript(jobID: String, quoteToken: String, acceptCharge: Boolean): CalliopeiaTranscript {
    require(acceptCharge && quoteToken.isNotBlank()) { "A quote and explicit charge consent are required" }
    return transcript("externalPurchaseJobTranscript", jobID, quoteToken)
}
private suspend fun CalliopeiaAPIClient.transcript(field: String, jobID: String, quoteToken: String? = null): CalliopeiaTranscript {
    val r = followUp(field, quoteToken != null, jobID,
        if (quoteToken == null) emptyMap() else mapOf("quoteToken" to JsonPrimitive(quoteToken), "acceptCharge" to JsonPrimitive(true)),
        if (quoteToken == null) "" else "\$quoteToken: String!, \$acceptCharge: Boolean!",
        if (quoteToken == null) "" else "quoteToken: \$quoteToken, acceptCharge: \$acceptCharge",
        "success error state quoteToken priceJpy purchasedAt transcriptJson")
    return CalliopeiaTranscript(r.text("state"), r.text("quoteToken"), r["priceJpy"]?.jsonPrimitive?.intOrNull,
        r.text("purchasedAt"), r.embedded("transcriptJson"))
}
suspend fun CalliopeiaAPIClient.getQuestions(jobID: String, questionID: String? = null, nextToken: String? = null): CalliopeiaQuestions =
    followUp("externalGetJobQuestions", false, jobID,
        mapOf("questionId" to questionID?.let(::JsonPrimitive), "nextToken" to nextToken?.let(::JsonPrimitive)),
        "\$questionId: String, \$nextToken: String", "questionId: \$questionId, nextToken: \$nextToken",
        "success error questionJson questionsJson nextToken").questions()
suspend fun CalliopeiaAPIClient.askQuestion(jobID: String, question: String, requestID: String,
    parentQuestionID: String? = null, sectionIndex: Int? = null): CalliopeiaQuestions {
    require(question.isNotBlank() && question.length <= 4000 && requestID.length in 8..128 && (sectionIndex == null || sectionIndex >= 0)) { "Invalid question, requestID or sectionIndex" }
    return followUp("externalAskJobQuestion", true, jobID,
        mapOf("question" to JsonPrimitive(question), "requestId" to JsonPrimitive(requestID),
            "parentQuestionId" to parentQuestionID?.let(::JsonPrimitive), "sectionIndex" to sectionIndex?.let(::JsonPrimitive)),
        "\$question: String!, \$requestId: String!, \$parentQuestionId: String, \$sectionIndex: Int",
        "question: \$question, requestId: \$requestId, parentQuestionId: \$parentQuestionId, sectionIndex: \$sectionIndex",
        "success error questionJson questionsJson nextToken").questions()
}
private suspend fun CalliopeiaAPIClient.followUp(field: String, mutation: Boolean, jobID: String,
    parameters: Map<String, JsonElement?>, definitions: String, arguments: String, selection: String): JsonObject {
    require(jobID.isNotBlank()) { "jobID is required" }
    val credential = credentialProvider.credential()
    val variables = parameters.filterValues { it != null }.mapValues { it.value!! } + mapOf(
        "jobId" to JsonPrimitive(jobID), "credential" to JsonPrimitive(credential.value), "authType" to JsonPrimitive(credential.type.apiValue))
    val query = """${if (mutation) "mutation" else "query"} FollowUp(${'$'}credential: String!, ${'$'}authType: String!, ${'$'}jobId: ID!${if (definitions.isEmpty()) "" else ", $definitions"}) {
        $field(credential: ${'$'}credential, authType: ${'$'}authType, jobId: ${'$'}jobId${if (arguments.isEmpty()) "" else ", $arguments"}) { $selection }
    }"""
    return graphQL(query, variables, credential).getValue(field).jsonObject.checked()
}
private fun JsonObject.checked(): JsonObject {
    if (get("success")?.jsonPrimitive?.booleanOrNull != true) throw CalliopeiaSDKException.Service(text("error") ?: "Operation failed")
    return this
}
private fun JsonObject.text(name: String): String? = (get(name) as? JsonPrimitive)?.contentOrNull
private fun JsonObject.required(name: String): String = text(name) ?: throw CalliopeiaSDKException.InvalidResponse("Missing $name")
private fun JsonObject.embedded(name: String): JsonElement? = text(name)?.let { Json.parseToJsonElement(it) }
private fun JsonObject.questions() = CalliopeiaQuestions(
    embedded("questionJson")?.jsonObject?.question(),
    (embedded("questionsJson") as? JsonArray)?.map { it.jsonObject.question() } ?: emptyList(), text("nextToken"))
private fun JsonObject.question() = CalliopeiaQuestion(required("questionId"), required("jobId"), required("question"),
    text("parentQuestionId"), get("sectionIndex")?.jsonPrimitive?.intOrNull, required("status"), text("answer"),
    (get("citations") as? JsonArray)?.map { value -> value.jsonObject.let {
        CalliopeiaCitation(it.required("sourceId"), it.getValue("startSeconds").jsonPrimitive.double,
            it.getValue("endSeconds").jsonPrimitive.double, it.required("quote"))
    } } ?: emptyList(), text("error"))
