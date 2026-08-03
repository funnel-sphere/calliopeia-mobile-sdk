package com.calliopeia.edgeaudio.capture

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.MediaRecorder
import android.media.audiofx.AcousticEchoCanceler
import android.media.audiofx.AutomaticGainControl
import android.media.audiofx.NoiseSuppressor
import android.os.Build
import androidx.annotation.RequiresPermission
import com.calliopeia.edgeaudio.contracts.AudioFrame
import com.calliopeia.edgeaudio.contracts.AudioFrameInspector
import com.calliopeia.edgeaudio.contracts.CaptureFormat
import com.calliopeia.edgeaudio.contracts.CaptureMode
import com.calliopeia.edgeaudio.contracts.QualitySnapshot
import java.io.File
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.concurrent.thread

class HighFidelityRecorder(
    context: Context,
    private val configuration: Configuration = Configuration(),
    private val inspector: AudioFrameInspector? = null,
) : AutoCloseable {
    data class Configuration(
        val preferredSampleRate: Int = 48_000,
        val frameDurationMilliseconds: Int = 20,
        val privacySensitive: Boolean = true,
    )

    fun interface FrameListener {
        fun onFrame(frame: AudioFrame, quality: QualitySnapshot?)
    }

    private val appContext = context.applicationContext
    private val running = AtomicBoolean(false)
    private var audioRecord: AudioRecord? = null
    private var worker: Thread? = null
    private var wavWriter: FloatWavWriter? = null
    private var noiseSuppressor: NoiseSuppressor? = null
    private var automaticGainControl: AutomaticGainControl? = null
    private var acousticEchoCanceler: AcousticEchoCanceler? = null

    @RequiresPermission(Manifest.permission.RECORD_AUDIO)
    @Synchronized
    fun start(
        rawMasterFile: File,
        mode: CaptureMode = CaptureMode.RAW_MASTER,
        listener: FrameListener? = null,
    ): CaptureFormat {
        check(!running.get()) { "Recorder is already running" }
        check(
            appContext.checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED,
        ) { "RECORD_AUDIO permission is required" }

        val source = selectAudioSource(mode)
        val (record, encoding) = createAudioRecord(source)

        if (mode == CaptureMode.SYSTEM_VOICE) attachVoiceEffects(record.audioSessionId)
        val actualRate = record.sampleRate
        val framesPerCallback = actualRate * configuration.frameDurationMilliseconds / 1_000
        wavWriter = FloatWavWriter(rawMasterFile, actualRate)
        inspector?.reset()
        audioRecord = record
        running.set(true)
        try {
            record.startRecording()
            check(record.recordingState == AudioRecord.RECORDSTATE_RECORDING) {
                "AudioRecord did not enter the recording state"
            }
        } catch (error: Throwable) {
            running.set(false)
            record.release()
            audioRecord = null
            releaseVoiceEffects()
            wavWriter?.close()
            wavWriter = null
            throw error
        }

        worker = thread(name = "calliopeia-audio-capture", isDaemon = true) {
            captureLoop(record, encoding, actualRate, framesPerCallback, listener)
        }

        return CaptureFormat(
            requestedSampleRate = configuration.preferredSampleRate,
            actualSampleRate = actualRate,
            channelCount = 1,
            isFloatPcm = encoding == AudioFormat.ENCODING_PCM_FLOAT,
            mode = mode,
            audioSource = source,
        )
    }

    @Synchronized
    fun stop() {
        if (!running.getAndSet(false)) return
        audioRecord?.stop()
        worker?.join(2_000)
        worker = null
        audioRecord?.release()
        audioRecord = null
        releaseVoiceEffects()
        wavWriter?.close()
        wavWriter = null
    }

    override fun close() = stop()

    private fun captureLoop(
        record: AudioRecord,
        encoding: Int,
        sampleRate: Int,
        framesPerCallback: Int,
        listener: FrameListener?,
    ) {
        val floatBuffer = FloatArray(framesPerCallback)
        val shortBuffer = ShortArray(framesPerCallback)
        var capturedFrames = 0L
        while (running.get()) {
            val count: Int
            val samples: FloatArray
            if (encoding == AudioFormat.ENCODING_PCM_FLOAT) {
                count = record.read(floatBuffer, 0, floatBuffer.size, AudioRecord.READ_BLOCKING)
                samples = if (count == floatBuffer.size) floatBuffer.copyOf() else floatBuffer.copyOf(maxOf(count, 0))
            } else {
                count = record.read(shortBuffer, 0, shortBuffer.size, AudioRecord.READ_BLOCKING)
                samples = if (count > 0) {
                    FloatArray(count) { shortBuffer[it] / 32_768f }
                } else {
                    floatArrayOf()
                }
            }
            if (count <= 0) continue
            wavWriter?.write(samples)
            val timestamp = capturedFrames * 1_000 / sampleRate
            capturedFrames += count
            listener?.onFrame(
                AudioFrame(samples, sampleRate, timestamp),
                inspector?.inspect(samples),
            )
        }
    }

    @RequiresPermission(Manifest.permission.RECORD_AUDIO)
    private fun createAudioRecord(source: Int): Pair<AudioRecord, Int> {
        val encodings = listOf(AudioFormat.ENCODING_PCM_FLOAT, AudioFormat.ENCODING_PCM_16BIT)
        for (encoding in encodings) {
            val minimumBytes = AudioRecord.getMinBufferSize(
                configuration.preferredSampleRate,
                AudioFormat.CHANNEL_IN_MONO,
                encoding,
            )
            if (minimumBytes <= 0) continue
            val bytesPerSample = if (encoding == AudioFormat.ENCODING_PCM_FLOAT) 4 else 2
            val requestedFrames = configuration.preferredSampleRate * configuration.frameDurationMilliseconds / 1_000
            val bufferBytes = maxOf(minimumBytes * 2, requestedFrames * bytesPerSample * 4)
            val format = AudioFormat.Builder()
                .setSampleRate(configuration.preferredSampleRate)
                .setEncoding(encoding)
                .setChannelMask(AudioFormat.CHANNEL_IN_MONO)
                .build()
            val record = runCatching {
                AudioRecord.Builder()
                    .setAudioSource(source)
                    .setAudioFormat(format)
                    .setBufferSizeInBytes(bufferBytes)
                    .also {
                        if (Build.VERSION.SDK_INT >= 30) {
                            it.setPrivacySensitive(configuration.privacySensitive)
                        }
                    }
                    .build()
            }.getOrNull() ?: continue
            if (record.state == AudioRecord.STATE_INITIALIZED) return record to encoding
            record.release()
        }
        error("48 kHz PCM capture is not supported by this device")
    }

    private fun selectAudioSource(mode: CaptureMode): Int {
        if (mode == CaptureMode.SYSTEM_VOICE) return MediaRecorder.AudioSource.VOICE_COMMUNICATION
        val manager = appContext.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val supportsUnprocessed = manager.getProperty(AudioManager.PROPERTY_SUPPORT_AUDIO_SOURCE_UNPROCESSED)
            ?.toBooleanStrictOrNull() == true
        return if (supportsUnprocessed) {
            MediaRecorder.AudioSource.UNPROCESSED
        } else {
            MediaRecorder.AudioSource.VOICE_RECOGNITION
        }
    }

    private fun attachVoiceEffects(audioSessionId: Int) {
        if (NoiseSuppressor.isAvailable()) {
            noiseSuppressor = NoiseSuppressor.create(audioSessionId)?.apply { enabled = true }
        }
        if (AutomaticGainControl.isAvailable()) {
            automaticGainControl = AutomaticGainControl.create(audioSessionId)?.apply { enabled = true }
        }
        if (AcousticEchoCanceler.isAvailable()) {
            acousticEchoCanceler = AcousticEchoCanceler.create(audioSessionId)?.apply { enabled = true }
        }
    }

    private fun releaseVoiceEffects() {
        noiseSuppressor?.release()
        automaticGainControl?.release()
        acousticEchoCanceler?.release()
        noiseSuppressor = null
        automaticGainControl = null
        acousticEchoCanceler = null
    }
}
