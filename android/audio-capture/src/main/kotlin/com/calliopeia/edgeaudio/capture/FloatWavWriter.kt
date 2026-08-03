package com.calliopeia.edgeaudio.capture

import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder

internal class FloatWavWriter(
    file: File,
    private val sampleRate: Int,
    private val channelCount: Int = 1,
) : AutoCloseable {
    private val output = RandomAccessFile(file, "rw")
    private var dataBytes = 0L

    init {
        output.setLength(0)
        output.write(ByteArray(44))
    }

    @Synchronized
    fun write(samples: FloatArray, count: Int = samples.size) {
        val bytes = ByteBuffer.allocate(count * Float.SIZE_BYTES).order(ByteOrder.LITTLE_ENDIAN)
        for (index in 0 until count) bytes.putFloat(samples[index].coerceIn(-1f, 1f))
        output.write(bytes.array())
        dataBytes += bytes.capacity()
    }

    @Synchronized
    override fun close() {
        val byteRate = sampleRate * channelCount * Float.SIZE_BYTES
        val blockAlign = channelCount * Float.SIZE_BYTES
        output.seek(0)
        output.writeAscii("RIFF")
        output.writeLittleEndianInt((36L + dataBytes).coerceAtMost(0xffff_ffffL).toInt())
        output.writeAscii("WAVE")
        output.writeAscii("fmt ")
        output.writeLittleEndianInt(16)
        output.writeLittleEndianShort(3) // IEEE Float
        output.writeLittleEndianShort(channelCount)
        output.writeLittleEndianInt(sampleRate)
        output.writeLittleEndianInt(byteRate)
        output.writeLittleEndianShort(blockAlign)
        output.writeLittleEndianShort(32)
        output.writeAscii("data")
        output.writeLittleEndianInt(dataBytes.coerceAtMost(0xffff_ffffL).toInt())
        output.close()
    }

    private fun RandomAccessFile.writeAscii(value: String) = write(value.toByteArray(Charsets.US_ASCII))

    private fun RandomAccessFile.writeLittleEndianInt(value: Int) {
        write(ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN).putInt(value).array())
    }

    private fun RandomAccessFile.writeLittleEndianShort(value: Int) {
        write(ByteBuffer.allocate(2).order(ByteOrder.LITTLE_ENDIAN).putShort(value.toShort()).array())
    }
}
