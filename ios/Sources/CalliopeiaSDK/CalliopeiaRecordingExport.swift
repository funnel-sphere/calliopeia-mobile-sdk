import Foundation

/// The Recorder app's raw-audio export policy. No denoiser or speech gate runs.
public enum CalliopeiaRecordingExport {
    public static let profileID = "recorder-raw-m4a-v1"

    public struct Result: Codable, Sendable {
        public let profileID: String
        public let audioURL: URL
        public let sourceMetrics: CalliopeiaAudioExporter.AudioMetrics
        public let appliedGain: Float
        public let bitRate: Int
    }

    /// Preserves the source file. Conversion validates mono AAC-LC, duration,
    /// bounded size, and decodable frames at both ends before returning.
    public static func export(
        rawMasterURL: URL,
        outputURL: URL,
        bitRate: Int = 64_000
    ) async throws -> Result {
        guard !FileManager.default.fileExists(atPath: outputURL.path) else {
            throw CalliopeiaSDKError.invalidRequest("outputURL already exists")
        }
        let metrics = try await CalliopeiaAudioExporter.analyze(rawMasterURL)
        guard metrics.sampleCount > 0, metrics.rms.isFinite, metrics.peak.isFinite else {
            throw CalliopeiaSDKError.invalidRequest("raw master has no finite audio samples")
        }
        let gain = AudioGainPolicy.playbackGain(for: metrics, referenceInput: metrics)
        try await CalliopeiaAudioExporter.exportM4A(
            from: rawMasterURL, to: outputURL, gain: gain, bitRate: bitRate
        )
        return Result(profileID: profileID, audioURL: outputURL,
                      sourceMetrics: metrics, appliedGain: gain, bitRate: bitRate)
    }
}
