package com.calliopeia.sdk

import android.Manifest
import android.content.Context
import androidx.annotation.RequiresPermission
import com.calliopeia.edgeaudio.capture.HighFidelityRecorder
import com.calliopeia.edgeaudio.contracts.AudioFrame
import com.calliopeia.edgeaudio.contracts.AudioFrameInspector
import com.calliopeia.edgeaudio.contracts.CaptureFormat
import com.calliopeia.edgeaudio.contracts.CaptureMode
import com.calliopeia.edgeaudio.contracts.QualityFlag
import com.calliopeia.edgeaudio.contracts.QualitySnapshot
import java.io.File
import java.util.UUID

data class CalliopeiaRecordedAudio(
    val file: File,
    val fileName: String,
    val contentType: String,
    val fileSizeBytes: Long,
    val durationSeconds: Double,
    val captureFormat: CaptureFormat,
    val observedQualityFlags: Set<QualityFlag>,
)

class CalliopeiaRecordingClient(
    context: Context,
    private val apiClient: CalliopeiaAPIClient,
    recorderConfiguration: HighFidelityRecorder.Configuration = HighFidelityRecorder.Configuration(),
    inspector: AudioFrameInspector? = null,
    private val recordingsDirectory: File = File(context.cacheDir, "CalliopeiaRecordings"),
) : AutoCloseable {
    fun interface FrameListener {
        fun onFrame(frame: AudioFrame, quality: QualitySnapshot?)
    }

    private val recorder = HighFidelityRecorder(context, recorderConfiguration, inspector)
    private val lock = Any()
    private var activeRecording: ActiveRecording? = null
    private val observedFlags = mutableSetOf<QualityFlag>()

    @RequiresPermission(Manifest.permission.RECORD_AUDIO)
    fun startRecording(
        fileName: String = "recording-${UUID.randomUUID()}.wav",
        mode: CaptureMode = CaptureMode.RAW_MASTER,
        listener: FrameListener? = null,
    ): CaptureFormat {
        if (!recordingsDirectory.exists() && !recordingsDirectory.mkdirs()) {
            throw CalliopeiaSDKException.InvalidRequest("unable to create recordings directory")
        }
        val outputFile = File(recordingsDirectory, fileName)
        synchronized(lock) {
            if (activeRecording != null) {
                throw CalliopeiaSDKException.InvalidRequest("a recording is already active")
            }
            observedFlags.clear()
        }
        val format = recorder.start(outputFile, mode) { frame, quality ->
            if (quality != null) synchronized(lock) { observedFlags.addAll(quality.flags) }
            listener?.onFrame(frame, quality)
        }
        synchronized(lock) {
            activeRecording = ActiveRecording(outputFile, fileName, format)
        }
        return format
    }

    fun stopRecording(): CalliopeiaRecordedAudio {
        val active = synchronized(lock) { activeRecording }
            ?: throw CalliopeiaSDKException.InvalidRequest("no recording is active")
        recorder.stop()
        val bytesPerSecond = active.captureFormat.actualSampleRate.toLong() *
            active.captureFormat.channelCount * Float.SIZE_BYTES
        val audioBytes = (active.file.length() - WAV_HEADER_BYTES).coerceAtLeast(0)
        val duration = if (bytesPerSecond > 0) audioBytes.toDouble() / bytesPerSecond else 0.0
        val flags = synchronized(lock) {
            activeRecording = null
            observedFlags.toSet()
        }
        return CalliopeiaRecordedAudio(
            file = active.file,
            fileName = active.fileName,
            contentType = "audio/wav",
            fileSizeBytes = active.file.length(),
            durationSeconds = duration,
            captureFormat = active.captureFormat,
            observedQualityFlags = flags,
        )
    }

    suspend fun submit(
        audio: CalliopeiaRecordedAudio,
        request: CalliopeiaAudioJobRequest,
    ): CalliopeiaJobSubmission = apiClient.submitAudio(
        file = audio.file,
        fileName = audio.fileName,
        contentType = audio.contentType,
        audioSeconds = audio.durationSeconds,
        request = request,
    )

    suspend fun stopAndSubmit(
        request: CalliopeiaAudioJobRequest,
    ): Pair<CalliopeiaRecordedAudio, CalliopeiaJobSubmission> {
        val audio = stopRecording()
        return audio to submit(audio, request)
    }

    override fun close() {
        recorder.close()
        synchronized(lock) { activeRecording = null }
    }

    private data class ActiveRecording(
        val file: File,
        val fileName: String,
        val captureFormat: CaptureFormat,
    )

    private companion object {
        const val WAV_HEADER_BYTES = 44L
    }
}
