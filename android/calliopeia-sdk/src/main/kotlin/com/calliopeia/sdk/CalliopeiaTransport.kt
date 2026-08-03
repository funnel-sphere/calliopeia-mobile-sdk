package com.calliopeia.sdk

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.net.HttpURLConnection
import java.net.URI

sealed interface CalliopeiaRequestBody {
    data class Bytes(val value: ByteArray) : CalliopeiaRequestBody
    data class FileBody(val value: File) : CalliopeiaRequestBody
}

data class CalliopeiaTransportRequest(
    val uri: URI,
    val method: String,
    val headers: Map<String, String> = emptyMap(),
    val body: CalliopeiaRequestBody? = null,
)

data class CalliopeiaTransportResponse(
    val statusCode: Int,
    val headers: Map<String, List<String>>,
    val body: ByteArray,
)

fun interface CalliopeiaTransport {
    suspend fun execute(request: CalliopeiaTransportRequest): CalliopeiaTransportResponse
}

class URLConnectionCalliopeiaTransport(
    private val connectTimeoutMilliseconds: Int = 30_000,
    private val readTimeoutMilliseconds: Int = 120_000,
) : CalliopeiaTransport {
    override suspend fun execute(request: CalliopeiaTransportRequest): CalliopeiaTransportResponse =
        withContext(Dispatchers.IO) {
            val connection = request.uri.toURL().openConnection() as HttpURLConnection
            try {
                connection.requestMethod = request.method
                connection.connectTimeout = connectTimeoutMilliseconds
                connection.readTimeout = readTimeoutMilliseconds
                connection.instanceFollowRedirects = true
                request.headers.forEach(connection::setRequestProperty)
                when (val body = request.body) {
                    is CalliopeiaRequestBody.Bytes -> {
                        connection.doOutput = true
                        connection.setFixedLengthStreamingMode(body.value.size)
                        connection.outputStream.use { it.write(body.value) }
                    }
                    is CalliopeiaRequestBody.FileBody -> {
                        require(body.value.isFile) { "Upload body must be a readable file" }
                        connection.doOutput = true
                        connection.setFixedLengthStreamingMode(body.value.length())
                        body.value.inputStream().buffered().use { input ->
                            connection.outputStream.buffered().use(input::copyTo)
                        }
                    }
                    null -> Unit
                }
                val statusCode = connection.responseCode
                val responseStream = if (statusCode in 200..299) {
                    connection.inputStream
                } else {
                    connection.errorStream
                }
                CalliopeiaTransportResponse(
                    statusCode = statusCode,
                    headers = connection.headerFields
                        .filterKeys { it != null }
                        .mapKeys { it.key!! },
                    body = responseStream?.use { it.readBytes() } ?: byteArrayOf(),
                )
            } finally {
                connection.disconnect()
            }
        }
}
