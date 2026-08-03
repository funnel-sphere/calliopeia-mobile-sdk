package com.calliopeia.edgeaudio.contracts

enum class CaptureMode {
    RAW_MASTER,
    SYSTEM_VOICE,
}

enum class EnhancementProfile {
    BYPASS,
    ADAPTIVE_DSP,
    GTCRN_16K,
    DPDFNET_16K,
    DPDFNET_48K,
}

data class AudioFrame(
    val samples: FloatArray,
    val sampleRate: Int,
    val timestampMilliseconds: Long,
)

enum class QualityFlag {
    SILENCE,
    TOO_QUIET,
    CLIPPING,
    LOW_SNR,
}

data class QualitySnapshot(
    val rmsDbFS: Double,
    val peakDbFS: Double,
    val noiseFloorDbFS: Double,
    val estimatedSnrDb: Double,
    val clippingRatio: Double,
    val flags: Set<QualityFlag>,
)

interface AudioFrameInspector {
    fun reset()
    fun inspect(samples: FloatArray): QualitySnapshot
}

data class CaptureFormat(
    val requestedSampleRate: Int,
    val actualSampleRate: Int,
    val channelCount: Int,
    val isFloatPcm: Boolean,
    val mode: CaptureMode,
    val audioSource: Int,
)

interface StreamingAudioEnhancer : AutoCloseable {
    val requiredSampleRate: Int
    val preferredFrameSize: Int
    fun process(samples: FloatArray, sampleRate: Int): FloatArray
    fun flush(): FloatArray = floatArrayOf()
    fun reset()
    override fun close() = Unit
}

class UnsupportedSampleRateException(expected: Int, actual: Int) :
    IllegalArgumentException("Expected ${expected} Hz but received ${actual} Hz")
