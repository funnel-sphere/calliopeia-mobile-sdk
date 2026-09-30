import AVFoundation
import Foundation
import Testing
@testable import CalliopeiaSDK
private typealias AudioExporter = CalliopeiaAudioExporter

struct RecorderExportRegressionTests {
    @Test func rawMasterCanBeConvertedToUploadM4A() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let input = directory.appendingPathComponent("input.wav")
        let output = directory.appendingPathComponent("output.m4a")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 12_000))
        buffer.frameLength = 12_000
        let samples = try #require(buffer.floatChannelData?[0])
        for index in 0..<Int(buffer.frameLength) {
            samples[index] = 0.15 * sin(2 * .pi * 440 * Float(index) / 48_000)
        }
        var file: AVAudioFile? = try AVAudioFile(forWriting: input, settings: format.settings)
        try file?.write(from: buffer)
        file = nil

        try await AudioExporter.exportM4A(from: input, to: output)

        let encoded = try AVAudioFile(forReading: output)
        #expect(encoded.length > 0)
        #expect(encoded.processingFormat.channelCount == 1)
        let encodedFormatID = encoded.fileFormat.settings[AVFormatIDKey] as? NSNumber
        #expect(encodedFormatID?.uint32Value == kAudioFormatMPEG4AAC)
        #expect((try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) > 0)
        #expect(
            Int64(try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
                <= AudioExporter.maximumExpectedFileSize(
                    duration: 12_000.0 / 48_000.0
                )
        )
        #expect(FileManager.default.fileExists(atPath: input.path))
    }

    @Test func truncatedM4AIsRejectedByPCMPlaybackValidation() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let input = directory.appendingPathComponent("input.wav")
        let output = directory.appendingPathComponent("output.m4a")
        try writeTestWAV(to: input)
        try await AudioExporter.exportM4A(from: input, to: output)

        let size = try #require(
            output.resourceValues(forKeys: [.fileSizeKey]).fileSize
        )
        let handle = try FileHandle(forUpdating: output)
        try handle.truncate(atOffset: UInt64(max(1, size / 2)))
        try handle.close()

        var rejected = false
        do {
            try await AudioExporter.validateM4A(
                at: output,
                expectedDuration: 12_000.0 / 48_000.0
            )
        } catch {
            rejected = true
        }
        #expect(rejected)
    }

    @Test func playbackGainRespectsSilenceAndClipBoundaries() {
        let quiet = AudioExporter.AudioMetrics(
            sampleCount: 48_000,
            sampleRate: 48_000,
            rms: 0.02,
            peak: 0.08
        )
        let silent = AudioExporter.AudioMetrics(
            sampleCount: 48_000,
            sampleRate: 48_000,
            rms: 0,
            peak: 0
        )
        let loud = AudioExporter.AudioMetrics(
            sampleCount: 48_000,
            sampleRate: 48_000,
            rms: 0.45,
            peak: 0.98
        )

        let quietGain = AudioGainPolicy.playbackGain(for: quiet)
        let loudGain = AudioGainPolicy.playbackGain(for: loud)
        #expect(quietGain > 1)
        #expect(Double(quietGain) <= pow(10.0, AudioGainPolicy.maximumGainDB / 20.0))
        #expect(AudioGainPolicy.playbackGain(for: silent) == 1)
        #expect(AudioGainPolicy.playbackGain(for: quiet, referenceInput: silent) == 1)
        #expect(loudGain < 1)
        #expect(Double(loudGain) * loud.peak <= AudioGainPolicy.maximumPeak + 0.000_001)
    }

    @Test func realDeviceConversationLevelIsNotTreatedAsSilence() {
        // Measured from a normal spoken recording on the target iPhone:
        // RMS -52.63 dBFS and peak -35.84 dBFS.
        let measuredConversation = AudioExporter.AudioMetrics(
            sampleCount: 883_200,
            sampleRate: 48_000,
            rms: pow(10.0, -52.629872 / 20.0),
            peak: pow(10.0, -35.839815 / 20.0)
        )

        let gain = AudioGainPolicy.playbackGain(
            for: measuredConversation,
            referenceInput: measuredConversation
        )

        #expect(gain > 1)
        #expect(Double(gain) * measuredConversation.rms >= 0.05)
        #expect(Double(gain) * measuredConversation.peak <= AudioGainPolicy.maximumPeak)
    }

    @Test func quietSpeechLevelerBoostsSpeechButKeepsNoiseBelowGate() {
        let noiseGain = QuietSpeechLevelingPolicy.additionalGain(
            rms: 0.002,
            peak: 0.008
        )
        let quietSpeechGain = QuietSpeechLevelingPolicy.additionalGain(
            rms: 0.03,
            peak: 0.18
        )
        let normalSpeechGain = QuietSpeechLevelingPolicy.additionalGain(
            rms: 0.08,
            peak: 0.40
        )

        #expect(noiseGain == 1)
        #expect(quietSpeechGain > normalSpeechGain)
        #expect(quietSpeechGain > 1)
        #expect(Double(quietSpeechGain) * 0.18 <= QuietSpeechLevelingPolicy.maximumPeak)
    }

    @Test func quietSpeechLevelerRaisesAQuietFrameWithoutRaisingSilence() {
        var leveler = QuietSpeechLeveler()
        var silence = Array(repeating: Float(0.002), count: 4_096)
        let silenceBefore = rms(silence)
        silence.withUnsafeMutableBufferPointer { buffer in
            leveler.process(buffer.baseAddress!, count: buffer.count)
        }
        let silenceAfter = rms(silence)

        let frameCount = 4_096
        let angularStep = 2.0 * Double.pi * 220.0 / 48_000.0
        var quietSpeech = [Float]()
        quietSpeech.reserveCapacity(frameCount)
        for index in 0..<frameCount {
            quietSpeech.append(Float(0.04 * sin(angularStep * Double(index))))
        }
        let speechBefore = rms(quietSpeech)
        quietSpeech.withUnsafeMutableBufferPointer { buffer in
            leveler.process(buffer.baseAddress!, count: buffer.count)
        }
        let speechAfter = rms(quietSpeech)

        #expect(abs(silenceAfter - silenceBefore) < 0.000_001)
        #expect(speechAfter > speechBefore * 1.2)
        #expect((quietSpeech.map(abs).max() ?? 0) <= 0.98)

        var trailingSilence = Array(repeating: Float(0.002), count: 4_096)
        let trailingSilenceBefore = rms(trailingSilence)
        trailingSilence.withUnsafeMutableBufferPointer { buffer in
            leveler.process(buffer.baseAddress!, count: buffer.count)
        }
        #expect(abs(rms(trailingSilence) - trailingSilenceBefore) < 0.000_001)
    }

    private func writeTestWAV(to url: URL) throws {
        let format = try #require(
            AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)
        )
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 12_000)
        )
        buffer.frameLength = 12_000
        let samples = try #require(buffer.floatChannelData?[0])
        for index in 0..<Int(buffer.frameLength) {
            samples[index] = 0.15 * sin(2 * .pi * 440 * Float(index) / 48_000)
        }
        var file: AVAudioFile? = try AVAudioFile(
            forWriting: url,
            settings: format.settings
        )
        try file?.write(from: buffer)
        file = nil
    }

    private func readSamples(from url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let buffer = try #require(
            AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(file.length)
            )
        )
        try file.read(into: buffer)
        let channel = try #require(buffer.floatChannelData?[0])
        return Array(
            UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))
        )
    }

    private func rms(_ samples: [Float]) -> Double {
        guard !samples.isEmpty else { return 0 }
        return sqrt(samples.reduce(0.0) { $0 + Double($1 * $1) } / Double(samples.count))
    }
}
