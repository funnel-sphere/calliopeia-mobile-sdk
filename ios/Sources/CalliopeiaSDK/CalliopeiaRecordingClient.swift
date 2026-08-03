#if os(iOS)
import AVFoundation
import CalliopeiaAudioCapture
import CalliopeiaAudioContracts
import Foundation

public struct CalliopeiaRecordedAudio: Sendable {
    public let fileURL: URL
    public let fileName: String
    public let contentType: String
    public let fileSizeBytes: Int
    public let durationSeconds: Double
    public let captureFormat: CaptureFormat
    public let observedQualityFlags: Set<QualityFlag>
}

public final class CalliopeiaRecordingClient: @unchecked Sendable {
    public typealias QualityHandler = HighFidelityRecorder.FrameHandler

    private let apiClient: CalliopeiaAPIClient
    private let recorder: HighFidelityRecorder
    private let recordingsDirectory: URL
    private let lock = NSLock()
    private var activeRecording: ActiveRecording?
    private var observedFlags = Set<QualityFlag>()

    public init(
        apiClient: CalliopeiaAPIClient,
        recorderConfiguration: HighFidelityRecorder.Configuration = .init(),
        inspector: (any AudioFrameInspecting)? = nil,
        recordingsDirectory: URL? = nil
    ) {
        self.apiClient = apiClient
        self.recorder = HighFidelityRecorder(
            configuration: recorderConfiguration,
            inspector: inspector
        )
        self.recordingsDirectory = recordingsDirectory
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("CalliopeiaRecordings", isDirectory: true)
    }

    public static func requestRecordPermission() async -> Bool {
        if #available(iOS 17.0, *) {
            return await AVAudioApplication.requestRecordPermission()
        }
        return await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    @discardableResult
    public func startRecording(
        fileName: String = "recording-\(UUID().uuidString).wav",
        mode: CaptureMode = .rawMaster,
        onFrame: QualityHandler? = nil
    ) throws -> CaptureFormat {
        try FileManager.default.createDirectory(
            at: recordingsDirectory,
            withIntermediateDirectories: true
        )
        let outputURL = recordingsDirectory.appendingPathComponent(fileName)
        lock.withLock {
            observedFlags = []
        }
        let format = try recorder.start(
            writingRawMasterTo: outputURL,
            mode: mode
        ) { [weak self] frame, quality in
            if let quality {
                self?.lock.withLock {
                    self?.observedFlags.formUnion(quality.flags)
                }
            }
            onFrame?(frame, quality)
        }
        lock.withLock {
            activeRecording = ActiveRecording(
                fileURL: outputURL,
                fileName: fileName,
                captureFormat: format
            )
        }
        return format
    }

    public func stopRecording() throws -> CalliopeiaRecordedAudio {
        guard let active = lock.withLock({ activeRecording }) else {
            throw CalliopeiaSDKError.invalidRequest("no recording is active")
        }
        try recorder.stop()
        let audioFile = try AVAudioFile(forReading: active.fileURL)
        let duration = audioFile.processingFormat.sampleRate > 0
            ? Double(audioFile.length) / audioFile.processingFormat.sampleRate
            : 0
        let attributes = try FileManager.default.attributesOfItem(atPath: active.fileURL.path)
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        let flags = lock.withLock { () -> Set<QualityFlag> in
            let value = observedFlags
            activeRecording = nil
            return value
        }
        return CalliopeiaRecordedAudio(
            fileURL: active.fileURL,
            fileName: active.fileName,
            contentType: "audio/wav",
            fileSizeBytes: size,
            durationSeconds: duration,
            captureFormat: active.captureFormat,
            observedQualityFlags: flags
        )
    }

    public func submit(
        _ audio: CalliopeiaRecordedAudio,
        request: CalliopeiaAudioJobRequest
    ) async throws -> CalliopeiaJobSubmission {
        try await apiClient.submitAudio(
            fileURL: audio.fileURL,
            fileName: audio.fileName,
            contentType: audio.contentType,
            audioSeconds: audio.durationSeconds,
            request: request
        )
    }

    public func stopAndSubmit(
        request: CalliopeiaAudioJobRequest
    ) async throws -> (audio: CalliopeiaRecordedAudio, submission: CalliopeiaJobSubmission) {
        let audio = try stopRecording()
        let submission = try await submit(audio, request: request)
        return (audio, submission)
    }
}

private struct ActiveRecording {
    let fileURL: URL
    let fileName: String
    let captureFormat: CaptureFormat
}
#endif
