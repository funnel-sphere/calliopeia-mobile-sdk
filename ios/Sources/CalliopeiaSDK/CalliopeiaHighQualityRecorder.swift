#if os(iOS)
import AVFoundation
#if canImport(CalliopeiaAudioCapture)
import CalliopeiaAudioCapture
#endif
#if canImport(CalliopeiaAudioContracts)
import CalliopeiaAudioContracts
#endif
import Foundation

public struct CalliopeiaHighQualityRecording: Codable, Sendable {
    public let id: String
    public let rawMasterURL: URL
    public let manifestURL: URL
    public let startedAt: Date
    public let captureFormat: CaptureFormat
    public let captureRoute: CaptureRouteReport
    public let export: CalliopeiaRecordingExport.Result

    public var audioURL: URL { export.audioURL }
    public var durationSeconds: Double { export.sourceMetrics.duration }
}

/// High-quality raw capture using the system audio APIs.
/// Own this object for the entire recording. Stop explicitly on interruption.
@MainActor
public final class CalliopeiaHighQualityRecorder {
    private let recorder: HighFidelityRecorder
    private let directory: URL
    private let bitRate: Int
    private var active: (id: String, url: URL, startedAt: Date, format: CaptureFormat)?
    private var exporting = false
    private var lastRawMasterURL: URL?

    public init(directory: URL? = nil, bitRate: Int = 64_000) {
        self.directory = directory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CalliopeiaRecordings", isDirectory: true)
        self.bitRate = bitRate
        recorder = HighFidelityRecorder(configuration: .init(preferDirectionalPickup: true))
    }

    public static func requestPermission() async -> Bool {
        await CalliopeiaRecordingClient.requestRecordPermission()
    }

    @discardableResult
    public func start(onFrame: HighFidelityRecorder.FrameHandler? = nil) throws -> CaptureFormat {
        guard active == nil, !exporting else {
            throw CalliopeiaSDKError.invalidRequest("a recording or export is already active")
        }
        guard (64_000...96_000).contains(bitRate) else {
            throw CalliopeiaSDKError.invalidRequest("AAC bit rate must be 64000...96000")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID().uuidString
        let url = directory.appendingPathComponent("\(id)-raw.wav")
        let format = try recorder.start(writingRawMasterTo: url, mode: .rawMaster, onFrame: onFrame)
        active = (id, url, Date(), format)
        lastRawMasterURL = url
        return format
    }

    /// On failure, the raw WAV is retained at `rawMasterURL` for recovery.
    public var rawMasterURL: URL? { active?.url ?? lastRawMasterURL }

    public func stop() async throws -> CalliopeiaHighQualityRecording {
        guard let take = active, !exporting else {
            throw CalliopeiaSDKError.invalidRequest("no recording is active")
        }
        exporting = true
        defer { exporting = false; active = nil }
        try recorder.stop()
        let exported = try await CalliopeiaRecordingExport.export(
            rawMasterURL: take.url,
            outputURL: directory.appendingPathComponent("\(take.id).m4a"), bitRate: bitRate
        )
        let manifestURL = directory.appendingPathComponent("\(take.id).json")
        let result = CalliopeiaHighQualityRecording(
            id: take.id, rawMasterURL: take.url, manifestURL: manifestURL,
            startedAt: take.startedAt, captureFormat: take.format,
            captureRoute: recorder.captureRouteReport, export: exported
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(result).write(to: manifestURL, options: .atomic)
        active = nil
        return result
    }
}

public extension CalliopeiaAPIClient {
    func submit(
        _ recording: CalliopeiaHighQualityRecording,
        request: CalliopeiaAudioJobRequest = .qualityBatch()
    ) async throws -> CalliopeiaJobSubmission {
        try await submitAudio(fileURL: recording.audioURL, contentType: "audio/mp4",
                              audioSeconds: recording.durationSeconds, request: request)
    }
}
#endif
