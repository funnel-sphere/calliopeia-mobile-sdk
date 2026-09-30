package com.calliopeia.sdk

import android.Manifest
import android.content.Context
import androidx.annotation.RequiresPermission
import com.calliopeia.edgeaudio.capture.HighFidelityRecorder
import com.calliopeia.edgeaudio.contracts.CaptureFormat
import com.calliopeia.edgeaudio.contracts.CaptureMode
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.*
import java.io.File
import java.util.UUID

data class CalliopeiaHighQualityRecording(val audio: CalliopeiaRecordedAudio, val rawMasterFile: File, val manifestFile: File)

/** Raw mono PCM master plus AAC delivery copy. Recording does not require authentication. */
class CalliopeiaHighQualityRecorder(
    context: Context,
    private val directory: File = File(context.filesDir, "CalliopeiaRecordings"),
) : AutoCloseable {
    private val recorder = HighFidelityRecorder(context)
    private var active: Pair<File, CaptureFormat>? = null
    var isRecording: Boolean = false
        private set

    @RequiresPermission(Manifest.permission.RECORD_AUDIO)
    fun start(): CaptureFormat {
        check(active == null) { "A recording is already active" }
        check(directory.isDirectory || directory.mkdirs()) { "Cannot create recordings directory" }
        val raw = File(directory, "recording-${UUID.randomUUID()}.wav")
        val format = recorder.start(raw, CaptureMode.RAW_MASTER)
        active = raw to format
        isRecording = true
        return format
    }

    suspend fun stop(): CalliopeiaHighQualityRecording {
        val (raw, format) = checkNotNull(active) { "No recording is active" }
        recorder.stop()
        active = null
        isRecording = false
        return withContext(Dispatchers.IO) {
            val output = File(directory, raw.nameWithoutExtension + ".m4a")
            CalliopeiaRecordingExport.export(raw, output)
            val duration = (raw.length() - 44).coerceAtLeast(0).toDouble() / (format.actualSampleRate * 4)
            val manifest = File(directory, raw.nameWithoutExtension + ".json")
            manifest.writeText(buildJsonObject {
                put("schemaVersion", 1); put("rawMaster", raw.name); put("deliveryAudio", output.name)
                put("requestedSampleRate", format.requestedSampleRate); put("actualSampleRate", format.actualSampleRate)
                put("channelCount", format.channelCount); put("audioSource", format.audioSource)
                put("mode", "rawMaster"); put("durationSeconds", duration)
                put("deliveryCodec", "AAC-LC"); put("deliveryBitRate", 64000)
                put("softwareNoiseSuppression", false); put("gain", 1.0)
            }.toString())
            CalliopeiaHighQualityRecording(CalliopeiaRecordedAudio(output, output.name, "audio/mp4", output.length(),
                duration, format, emptySet()), raw, manifest)
        }
    }

    /** Finalizes the raw WAV when the host is destroyed; never submits audio automatically. */
    override fun close() {
        recorder.close()
        active = null
        isRecording = false
    }
}
