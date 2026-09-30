package com.calliopeia.sdk

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMuxer
import android.os.SystemClock
import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** Exports this SDK's mono IEEE-float WAV master via Android's AAC encoder; does not alter the master. */
object CalliopeiaRecordingExport {
    fun export(rawMaster: File, output: File) {
        require(rawMaster.canonicalFile != output.canonicalFile) { "Output must differ from raw master" }
        require(!output.exists()) { "Output already exists" }
        RandomAccessFile(rawMaster, "r").use { input ->
            val header = ByteArray(44).also(input::readFully)
            val fields = ByteBuffer.wrap(header).order(ByteOrder.LITTLE_ENDIAN)
            require(String(header, 0, 4, Charsets.US_ASCII) == "RIFF" &&
                String(header, 8, 4, Charsets.US_ASCII) == "WAVE" &&
                String(header, 12, 4, Charsets.US_ASCII) == "fmt " && fields.getInt(16) == 16 &&
                fields.getShort(20).toInt() == 3 && fields.getShort(22).toInt() == 1 &&
                fields.getShort(34).toInt() == 32 && String(header, 36, 4, Charsets.US_ASCII) == "data") {
                "Expected an SDK mono float WAV master"
            }
            val rate = fields.getInt(24)
            val audioBytes = fields.getInt(40).toLong() and 0xffffffffL
            require(rate > 0 && audioBytes > 0 && audioBytes % 4 == 0L && input.length() == 44 + audioBytes) { "Invalid or empty WAV" }
            val codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC)
            var muxer: MediaMuxer? = null
            var codecStarted = false
            var muxerStarted = false
            var completed = false
            try {
                val format = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AAC, rate, 1).apply {
                    setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
                    setInteger(MediaFormat.KEY_BIT_RATE, 64_000)
                    setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 8192)
                }
                codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
                codec.start(); codecStarted = true
                muxer = MediaMuxer(output.absolutePath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
                val info = MediaCodec.BufferInfo()
                var inputEnded = false
                var outputEnded = false
                var samplesSent = 0L
                var track = -1
                var lastProgress = SystemClock.elapsedRealtime()
                while (!outputEnded) {
                    check(SystemClock.elapsedRealtime() - lastProgress < 30_000) { "AAC encoder stalled" }
                    if (!inputEnded) {
                        val index = codec.dequeueInputBuffer(10_000)
                        if (index >= 0) {
                            val buffer = checkNotNull(codec.getInputBuffer(index)).order(ByteOrder.LITTLE_ENDIAN)
                            buffer.clear()
                            val count = minOf(buffer.remaining() / 2, ((audioBytes / 4) - samplesSent).toInt())
                            repeat(count) {
                                val sample = Float.fromBits(Integer.reverseBytes(input.readInt()))
                                require(sample.isFinite()) { "Raw master contains a non-finite sample" }
                                buffer.putShort((sample.coerceIn(-1f, 1f) * 32767f).toInt().toShort())
                            }
                            codec.queueInputBuffer(index, 0, count * 2, samplesSent * 1_000_000 / rate,
                                if (count == 0) MediaCodec.BUFFER_FLAG_END_OF_STREAM else 0)
                            samplesSent += count
                            inputEnded = count == 0
                            lastProgress = SystemClock.elapsedRealtime()
                        }
                    }
                    val index = codec.dequeueOutputBuffer(info, 10_000)
                    if (index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                        check(!muxerStarted) { "Encoder format changed twice" }
                        track = muxer.addTrack(codec.outputFormat); muxer.start(); muxerStarted = true
                        lastProgress = SystemClock.elapsedRealtime()
                    } else if (index >= 0) {
                        try {
                            if (info.size > 0 && info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0) {
                                check(muxerStarted)
                                val encoded = checkNotNull(codec.getOutputBuffer(index))
                                encoded.position(info.offset); encoded.limit(info.offset + info.size)
                                muxer.writeSampleData(track, encoded, info)
                            }
                            outputEnded = info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
                        } finally { codec.releaseOutputBuffer(index, false) }
                        lastProgress = SystemClock.elapsedRealtime()
                    }
                }
                check(muxerStarted)
                muxer.stop(); muxerStarted = false
                completed = true
            } finally {
                if (codecStarted) runCatching { codec.stop() }
                codec.release()
                if (muxerStarted) runCatching { muxer?.stop() }
                muxer?.release()
                if (!completed) output.delete()
            }
        }
    }
}
