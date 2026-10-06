package com.calliopeia.sdk

import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.io.File

/** Retain this object when retrying an uncertain response; one instance per recording. */
class CalliopeiaPendingAudioSubmission(
    private val file: File,
    private val contentType: String,
    private val audioSeconds: Double,
    private val request: CalliopeiaAudioJobRequest = CalliopeiaAudioJobRequest.qualityBatch(),
) {
    private val mutex = Mutex()
    private var ticket: CalliopeiaUploadTicket? = null
    private var submission: CalliopeiaJobSubmission? = null
    suspend fun submit(api: CalliopeiaAPIClient): CalliopeiaJobSubmission = mutex.withLock {
        submission?.let { return@withLock it }
        val fileSizeBytes = file.length()
        val uploaded = ticket ?: api.createAudioUpload(file.name, contentType, fileSizeBytes).also {
            api.uploadAudio(file, it)
            ticket = it
        }
        api.invokeAudioJob(uploaded, file.name, fileSizeBytes, audioSeconds, request).also { submission = it }
    }
}
