// Derived from Calliopeia Recorder raw export at b12487526f227f50282849747634a06865a7bcd9.
import AVFoundation
import Foundation

public enum CalliopeiaAudioExporter {
    // kAudioFormatMPEG4AAC selects the interoperable AAC-LC encoder.
    public static let defaultAACBitRate = 64_000

    public struct AudioMetrics: Codable, Equatable, Sendable {
        public let sampleCount: Int64
        public let sampleRate: Double
        public let rms: Double
        public let peak: Double
        /// The level exceeded by only the loudest sliver of samples. Isolated
        /// knocks and bumps sit above it, so driving gain from this instead of the
        /// absolute peak stops one stray transient from holding down the level of
        /// an entire recording. Zero when no percentile was measured.
        public let headroomPeak: Double

        init(
            sampleCount: Int64,
            sampleRate: Double,
            rms: Double,
            peak: Double,
            headroomPeak: Double = 0
        ) {
            self.sampleCount = sampleCount
            self.sampleRate = sampleRate
            self.rms = rms
            self.peak = peak
            self.headroomPeak = headroomPeak
        }

        var gainReferencePeak: Double {
            headroomPeak > 0 && headroomPeak.isFinite ? headroomPeak : peak
        }

        public var duration: TimeInterval {
            sampleRate > 0 ? Double(sampleCount) / sampleRate : 0
        }
    }

    enum ExportError: LocalizedError {
        case unavailable
        case invalidInput
        case invalidBitRate
        case invalidGain
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .unavailable: "AAC変換を開始できませんでした"
            case .invalidInput: "音声入力を読み込めませんでした"
            case .invalidBitRate: "AACビットレートが対応範囲外です"
            case .invalidGain: "音量補正値が不正です"
            case .failed(let message): "M4A変換に失敗しました: \(message)"
            }
        }
    }

    public static func exportM4A(
        from inputURL: URL,
        to outputURL: URL,
        gain: Float = 1,
        levelQuietSpeech: Bool = false,
        bitRate: Int = defaultAACBitRate
    ) async throws {
        try await Task.detached(priority: .userInitiated) {
            try exportM4ASynchronously(
                from: inputURL,
                to: outputURL,
                gain: gain,
                levelQuietSpeech: levelQuietSpeech,
                bitRate: bitRate
            )
        }.value
    }

    public static func analyze(_ url: URL) async throws -> AudioMetrics {
        try await Task.detached(priority: .userInitiated) {
            try analyzeSynchronously(url)
        }.value
    }

    public static func validateM4A(
        at url: URL,
        expectedDuration: TimeInterval? = nil,
        bitRate: Int = defaultAACBitRate
    ) async throws {
        try await Task.detached(priority: .userInitiated) {
            try validateM4ASynchronously(
                at: url,
                expectedDuration: expectedDuration,
                bitRate: bitRate
            )
        }.value
    }

    public static func maximumExpectedFileSize(
        duration: TimeInterval,
        bitRate: Int = defaultAACBitRate
    ) -> Int64 {
        let encodedBytes = max(0, duration) * Double(bitRate) / 8
        return max(
            1_048_576,
            Int64(ceil(encodedBytes * 1.5 + 1_048_576))
        )
    }

    private static let conversionChunkFrameCount = 4_096

    private static func exportM4ASynchronously(
        from inputURL: URL,
        to outputURL: URL,
        gain: Float,
        levelQuietSpeech: Bool,
        bitRate: Int
    ) throws {
        guard inputURL.standardizedFileURL != outputURL.standardizedFileURL,
              FileManager.default.fileExists(atPath: inputURL.path) else {
            throw ExportError.invalidInput
        }
        guard (64_000...96_000).contains(bitRate) else {
            throw ExportError.invalidBitRate
        }
        guard gain.isFinite, gain > 0 else {
            throw ExportError.invalidGain
        }

        let inputFile: AVAudioFile
        do {
            inputFile = try AVAudioFile(forReading: inputURL)
        } catch {
            throw ExportError.failed(error.localizedDescription)
        }
        let inputFormat = inputFile.processingFormat
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw ExportError.invalidInput
        }

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: inputFormat.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: bitRate,
        ]
        let temporaryURL = outputURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).m4a")
        var moved = false
        defer {
            if !moved {
                try? FileManager.default.removeItem(at: temporaryURL)
            }
        }

        let sourceDuration = inputFormat.sampleRate > 0
            ? Double(inputFile.length) / inputFormat.sampleRate
            : 0
        do {
            let outputFile = try AVAudioFile(
                forWriting: temporaryURL,
                settings: outputSettings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            let outputFormat = outputFile.processingFormat
            guard outputFormat.channelCount == 1,
                  outputFormat.sampleRate > 0,
                  outputFormat.commonFormat == .pcmFormatFloat32 else {
                throw ExportError.unavailable
            }
            var speechLeveler = QuietSpeechLeveler()
            var limiter = PeakLimiter(sampleRate: outputFormat.sampleRate)

            while inputFile.framePosition < inputFile.length {
                let remaining = inputFile.length - inputFile.framePosition
                let capacity = AVAudioFrameCount(
                    min(Int64(conversionChunkFrameCount), remaining)
                )
                guard capacity > 0,
                      let inputBuffer = AVAudioPCMBuffer(
                        pcmFormat: inputFormat,
                        frameCapacity: capacity
                      ) else {
                    throw ExportError.unavailable
                }
                try inputFile.read(into: inputBuffer, frameCount: capacity)
                let frameLength = Int(inputBuffer.frameLength)
                guard frameLength > 0 else { break }
                guard let inputChannels = inputBuffer.floatChannelData,
                      let outputBuffer = AVAudioPCMBuffer(
                        pcmFormat: outputFormat,
                        frameCapacity: AVAudioFrameCount(frameLength)
                      ),
                      let outputChannel = outputBuffer.floatChannelData?[0] else {
                    throw ExportError.unavailable
                }

                let channelCount = Int(inputFormat.channelCount)
                for frame in 0..<frameLength {
                    var mono = 0.0
                    for channel in 0..<channelCount {
                        mono += Double(inputChannels[channel][frame])
                    }
                    let scaled = Float(mono / Double(channelCount)) * gain
                    outputChannel[frame] = scaled
                }
                if levelQuietSpeech {
                    speechLeveler.process(outputChannel, count: frameLength)
                }
                // Runs last so it bounds whatever the gain and leveller produced.
                limiter.process(outputChannel, count: frameLength)
                outputBuffer.frameLength = AVAudioFrameCount(frameLength)
                try outputFile.write(from: outputBuffer)
            }
        } catch let error as ExportError {
            throw error
        } catch {
            throw ExportError.failed(error.localizedDescription)
        }

        try validateM4ASynchronously(
            at: temporaryURL,
            expectedDuration: sourceDuration,
            bitRate: bitRate
        )
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: outputURL.path) {
            try fileManager.removeItem(at: outputURL)
        }
        try fileManager.moveItem(at: temporaryURL, to: outputURL)
        moved = true
    }

    private static func analyzeSynchronously(_ url: URL) throws -> AudioMetrics {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw ExportError.failed(error.localizedDescription)
        }
        let format = file.processingFormat
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw ExportError.invalidInput
        }

        var sampleCount: Int64 = 0
        var sumSquares = 0.0
        var peak = 0.0
        // A decibel-spaced histogram keeps the percentile bounded in memory: a
        // long take would otherwise need every sample retained to sort.
        var amplitudeHistogram = [Int64](
            repeating: 0,
            count: AudioLevelHistogram.binCount
        )
        while file.framePosition < file.length {
            let remaining = file.length - file.framePosition
            let capacity = AVAudioFrameCount(
                min(Int64(conversionChunkFrameCount), remaining)
            )
            guard capacity > 0,
                  let buffer = AVAudioPCMBuffer(
                    pcmFormat: format,
                    frameCapacity: capacity
                  ),
                  let channels = buffer.floatChannelData else {
                throw ExportError.unavailable
            }
            try file.read(into: buffer, frameCount: capacity)
            let frameLength = Int(buffer.frameLength)
            guard frameLength > 0 else { break }
            let channelCount = Int(format.channelCount)
            for frame in 0..<frameLength {
                var mono = 0.0
                for channel in 0..<channelCount {
                    mono += Double(channels[channel][frame])
                }
                mono /= Double(channelCount)
                sumSquares += mono * mono
                let magnitude = abs(mono)
                peak = max(peak, magnitude)
                amplitudeHistogram[AudioLevelHistogram.binIndex(for: magnitude)] += 1
            }
            sampleCount += Int64(frameLength)
        }

        let rms = sampleCount > 0
            ? (sumSquares / Double(sampleCount)).squareRoot()
            : 0
        return AudioMetrics(
            sampleCount: sampleCount,
            sampleRate: format.sampleRate,
            rms: rms,
            peak: peak,
            headroomPeak: AudioLevelHistogram.amplitude(
                atPercentile: AudioGainPolicy.headroomPercentile,
                histogram: amplitudeHistogram,
                sampleCount: sampleCount,
                peak: peak
            )
        )
    }

    private static func validateM4ASynchronously(
        at url: URL,
        expectedDuration: TimeInterval?,
        bitRate: Int
    ) throws {
        guard (64_000...96_000).contains(bitRate),
              FileManager.default.fileExists(atPath: url.path) else {
            throw ExportError.invalidInput
        }
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw ExportError.failed(error.localizedDescription)
        }
        let format = file.processingFormat
        let formatID = file.fileFormat.settings[AVFormatIDKey] as? NSNumber
        guard file.length > 0,
              format.sampleRate > 0,
              format.channelCount == 1,
              formatID?.uint32Value == kAudioFormatMPEG4AAC else {
            throw ExportError.failed("出力音声が空、またはmono AACではありません")
        }
        try verifyDecodablePCM(at: file)
        let size = Int64(
            (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?
                .int64Value ?? 0
        )
        guard size > 0 else {
            throw ExportError.failed("出力ファイルが空です")
        }
        let duration = Double(file.length) / format.sampleRate
        if let expectedDuration {
            let tolerance = max(0.25, expectedDuration * 0.02)
            guard abs(duration - expectedDuration) <= tolerance else {
                throw ExportError.failed("出力音声の長さを検証できませんでした")
            }
        }
        guard size <= maximumExpectedFileSize(duration: expectedDuration ?? duration, bitRate: bitRate) else {
            throw ExportError.failed("AAC出力サイズが上限を超えました")
        }
    }

    private static func verifyDecodablePCM(at file: AVAudioFile) throws {
        let probeFrameCount = min(Int64(conversionChunkFrameCount), file.length)
        guard probeFrameCount > 0 else {
            throw ExportError.failed("出力音声をデコードできませんでした")
        }

        func readProbe(startFrame: Int64) throws {
            file.framePosition = max(0, min(startFrame, file.length - probeFrameCount))
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(probeFrameCount)
            ) else {
                throw ExportError.failed("出力音声のPCMバッファを作成できませんでした")
            }
            try file.read(
                into: buffer,
                frameCount: AVAudioFrameCount(probeFrameCount)
            )
            guard buffer.frameLength > 0,
                  buffer.floatChannelData != nil else {
                throw ExportError.failed("出力音声をデコードできませんでした")
            }
        }

        try readProbe(startFrame: 0)
        try readProbe(startFrame: file.length - probeFrameCount)
    }
}

enum AudioGainPolicy {
    // Keep the floor above the measured device noise, while allowing ordinary
    // speech recorded around -53 dBFS to be normalized instead of rejected.
    static let minimumMeaningfulRMS = 0.0005
    static let targetRMS = 0.12
    // AAC decoding reconstructs inter-sample peaks above what was encoded, so a
    // track mastered close to full scale plays back clipped. Measured overshoot on
    // device reached +1.39 dBFS, hence roughly 1.4 dB of reserved headroom.
    static let maximumPeak = 0.85
    static let maximumGainDB = 30.0
    /// Gain is set so this share of samples fits under `maximumPeak`; the louder
    /// remainder is caught by the limiter during export.
    static let headroomPercentile = 0.999

    static func playbackGain(
        for metrics: CalliopeiaAudioExporter.AudioMetrics,
        referenceInput: CalliopeiaAudioExporter.AudioMetrics? = nil
    ) -> Float {
        if let referenceInput,
           referenceInput.rms < minimumMeaningfulRMS {
            return 1
        }
        guard metrics.sampleCount > 0,
              metrics.rms.isFinite,
              metrics.peak.isFinite,
              metrics.rms >= minimumMeaningfulRMS,
              metrics.peak > 0 else {
            return 1
        }
        let maximumGain = pow(10.0, maximumGainDB / 20.0)
        let rmsGain = targetRMS / metrics.rms
        // Samples above this reference are brought back down by the limiter during
        // export rather than being paid for with level across the whole take.
        let peakGain = maximumPeak / metrics.gainReferencePeak
        return Float(max(0.05, min(maximumGain, rmsGain, peakGain)))
    }
}

enum QuietSpeechLevelingPolicy {
    // Thresholds are evaluated after recording-level normalization. The
    // enhanced track's measured noise floor remains well below this gate.
    static let minimumSpeechRMS = 0.008
    static let minimumSpeechPeak = 0.02
    static let targetSpeechRMS = 0.10
    static let maximumAdditionalGainDB = 8.0
    static let maximumPeak = 0.95

    static func additionalGain(rms: Double, peak: Double) -> Float {
        guard rms.isFinite,
              peak.isFinite,
              rms >= minimumSpeechRMS,
              peak >= minimumSpeechPeak else {
            return 1
        }

        let maximumGain = pow(10.0, maximumAdditionalGainDB / 20.0)
        let rmsGain = targetSpeechRMS / rms
        let peakGain = maximumPeak / peak
        return Float(max(1, min(maximumGain, rmsGain, peakGain)))
    }
}

struct QuietSpeechLeveler {
    private(set) var currentGain: Float = 1

    mutating func process(_ samples: UnsafeMutablePointer<Float>, count: Int) {
        guard count > 0 else { return }

        var sumSquares = 0.0
        var peak = 0.0
        for index in 0..<count {
            let sample = Double(samples[index])
            sumSquares += sample * sample
            peak = max(peak, abs(sample))
        }
        let rms = sqrt(sumSquares / Double(count))
        let desiredGain = QuietSpeechLevelingPolicy.additionalGain(rms: rms, peak: peak)

        if desiredGain <= 1 {
            // Bounding is left to the limiter downstream. Clamping here would hard
            // clip transients that the limiter is able to duck smoothly.
            currentGain = 1
            return
        }

        // Reduce gain quickly when a louder frame arrives, then raise it more
        // gradually for quieter speech so level changes do not pump between words.
        let smoothing: Float = desiredGain < currentGain ? 0.85 : 0.55
        let safeStartGain = peak > 0
            ? min(currentGain, Float(QuietSpeechLevelingPolicy.maximumPeak / peak))
            : 1
        let endGain = safeStartGain + (desiredGain - safeStartGain) * smoothing
        let divisor = Float(max(1, count - 1))

        for index in 0..<count {
            let progress = Float(index) / divisor
            let frameGain = safeStartGain + (endGain - safeStartGain) * progress
            samples[index] *= frameGain
        }
        currentGain = endGain
    }
}

