package com.calliopeia.sdk

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.net.URI

/** Public deployment configuration only; contains no user session or tenant API key. */
class CalliopeiaEnvironment(amplifyOutputs: String) {
    val api: CalliopeiaAPIConfiguration
    init {
        val data = Json.parseToJsonElement(amplifyOutputs).jsonObject.getValue("data").jsonObject
        val endpoint = URI.create(data.getValue("url").jsonPrimitive.content)
        require(endpoint.scheme == "https") { "GraphQL endpoint must use HTTPS" }
        api = CalliopeiaAPIConfiguration(endpoint, data["api_key"]?.jsonPrimitive?.content ?: "",
            graphQLAuthorization = CalliopeiaGraphQLAuthorization.COGNITO_USER_POOLS)
    }
}
