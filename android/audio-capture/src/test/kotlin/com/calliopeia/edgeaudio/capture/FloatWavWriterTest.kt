package com.calliopeia.edgeaudio.capture

import java.io.File
import java.nio.charset.StandardCharsets
import kotlin.io.path.createTempDirectory
import org.junit.Assert.assertEquals
import org.junit.Test

class FloatWavWriterTest {
    @Test
    fun writesFloatWavHeaderAndPayload() {
        val directory = createTempDirectory("calliopeia-wav-test").toFile()
        val output = File(directory, "capture.wav")
        try {
            FloatWavWriter(output, sampleRate = 48_000).use { writer ->
                writer.write(floatArrayOf(-1f, -0.5f, 0f, 0.5f, 1f))
            }

            val bytes = output.readBytes()
            assertEquals("RIFF", String(bytes, 0, 4, StandardCharsets.US_ASCII))
            assertEquals("WAVE", String(bytes, 8, 4, StandardCharsets.US_ASCII))
            assertEquals("data", String(bytes, 36, 4, StandardCharsets.US_ASCII))
            assertEquals(44 + 5 * Float.SIZE_BYTES, bytes.size)
        } finally {
            directory.deleteRecursively()
        }
    }
}
