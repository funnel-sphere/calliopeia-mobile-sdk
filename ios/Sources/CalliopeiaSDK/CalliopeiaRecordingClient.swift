#if os(iOS)
import AVFoundation
#if canImport(CalliopeiaAudioCapture)
import CalliopeiaAudioCapture
#endif
#if canImport(CalliopeiaAudioContracts)
import CalliopeiaAudioContracts
#endif
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

public struct CalliopeiaPairedRecording: Sendable {
    public let rawAudio: CalliopeiaRecordedAudio
    public let enhancedFileURL: URL
    public let enhancedFileName: String
    public let manifestURL: URL
    public let manifest: PairedRecordingManifest
}

public final class CalliopeiaRecordingClient: @unchecked Sendable {
    public typealias QualityHandler = HighFidelityRecorder.FrameHandler

    private let apiClient: CalliopeiaAPIClient
    private let recorder: HighFidelityRecorder
    private let enhancer: (any StreamingAudioEnhancer)?
    private let pairedProcessorConfiguration: PairedRecordingProcessor.Configuration
    private let recordingsDirectory: URL
    private let lock = NSLock()
    private var activeRecording: ActiveRecording?
    private var activePairedRecording: ActivePairedRecording?
    private var pairedCallbackError: Error?
    private var observedFlags = Set<QualityFlag>()

    public init(
        apiClient: CalliopeiaAPIClient,
        recorderConfiguration: HighFidelityRecorder.Configuration = .init(),
        inspector: (any AudioFrameInspecting)? = nil,
        recordingsDirectory: URL? = nil
    ) {
        self.apiClient = apiClient
        self.enhancer = nil
        self.pairedProcessorConfiguration = .init()
        self.recorder = HighFidelityRecorder(
            configuration: recorderConfiguration,
            inspector: inspector
        )
        self.recordingsDirectory = recordingsDirectory
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("CalliopeiaRecordings", isDirectory: true)
    }

    public init(
        apiClient: CalliopeiaAPIClient,
        recorderConfiguration: HighFidelityRecorder.Configuration = .init(),
        inspector: (any AudioFrameInspecting)? = nil,
        enhancer: any StreamingAudioEnhancer,
        pairedProcessorConfiguration: PairedRecordingProcessor.Configuration = .init(),
        recordingsDirectory: URL? = nil
    ) {
        self.apiClient = apiClient
        self.enhancer = enhancer
        self.pairedProcessorConfiguration = pairedProcessorConfiguration
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
        guard lock.withLock({ activePairedRecording == nil }) else {
            throw CalliopeiaSDKError.invalidRequest("a paired recording is already active")
        }
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
        do {
            try lock.withLock {
                guard activeRecording == nil, activePairedRecording == nil else {
                    throw CalliopeiaSDKError.invalidRequest("a recording is already active")
                }
                activeRecording = ActiveRecording(
                    fileURL: outputURL,
                    fileName: fileName,
                    captureFormat: format
                )
            }
        } catch {
            try? recorder.stop()
            throw error
        }
        return format
    }

    @discardableResult
    public func startPairedRecording(
        baseFileName: String = "recording-\(UUID().uuidString)",
        mode: CaptureMode = .rawMaster,
        onFrame: QualityHandler? = nil
    ) throws -> CaptureFormat {
        guard !baseFileName.isEmpty, !baseFileName.contains("/") else {
            throw CalliopeiaSDKError.invalidRequest("baseFileName must be a non-empty file name")
        }
        guard let enhancer else {
            throw CalliopeiaSDKError.invalidRequest(
                "paired recording requires a StreamingAudioEnhancer"
            )
        }
        guard lock.withLock({ activeRecording == nil && activePairedRecording == nil }) else {
            throw CalliopeiaSDKError.invalidRequest("a recording is already active")
        }

        try FileManager.default.createDirectory(
            at: recordingsDirectory,
            withIntermediateDirectories: true
        )
        let rawFileName = "\(baseFileName)-raw.wav"
        let enhancedFileName = "\(baseFileName)-enhanced.wav"
        let manifestFileName = "\(baseFileName)-manifest.json"
        let rawFileURL = recordingsDirectory.appendingPathComponent(rawFileName)
        let enhancedFileURL = recordingsDirectory.appendingPathComponent(enhancedFileName)
        let manifestURL = recordingsDirectory.appendingPathComponent(manifestFileName)
        let spoolURL = recordingsDirectory.appendingPathComponent(
            ".\(baseFileName)-patches-\(UUID().uuidString)",
            isDirectory: true
        )
        let processor = PairedRecordingProcessor(
            enhancer: enhancer,
            configuration: pairedProcessorConfiguration
        )
        try processor.start(
            sampleRate: enhancer.requiredSampleRate,
            spoolDirectory: spoolURL
        )
        lock.withLock {
            observedFlags = []
            pairedCallbackError = nil
        }

        do {
            let format = try recorder.start(
                writingRawMasterTo: rawFileURL,
                mode: mode,
                requiredSampleRate: enhancer.requiredSampleRate
            ) { [weak self, weak processor] frame, quality in
                if let quality {
                    self?.lock.withLock {
                        self?.observedFlags.formUnion(quality.flags)
                    }
                }
                do {
                    try processor?.append(frame)
                } catch {
                    self?.lock.withLock {
                        self?.pairedCallbackError = error
                    }
                }
                onFrame?(frame, quality)
            }
            do {
                try lock.withLock {
                    guard activeRecording == nil, activePairedRecording == nil else {
                        throw CalliopeiaSDKError.invalidRequest("a recording is already active")
                    }
                    activePairedRecording = ActivePairedRecording(
                        rawFileURL: rawFileURL,
                        rawFileName: rawFileName,
                        enhancedFileURL: enhancedFileURL,
                        manifestURL: manifestURL,
                        captureFormat: format,
                        processor: processor
                    )
                }
            } catch {
                try? recorder.stop()
                throw error
            }
            return format
        } catch {
            processor.cancel()
            try? FileManager.default.removeItem(at: spoolURL)
            throw error
        }
    }

    public func stopRecording() throws -> CalliopeiaRecordedAudio {
        guard let active = lock.withLock({ activeRecording }) else {
            throw CalliopeiaSDKError.invalidRequest("no recording is active")
        }
        defer { lock.withLock { activeRecording = nil } }
        try recorder.stop()
        let audioFile = try AVAudioFile(forReading: active.fileURL)
        let duration = audioFile.processingFormat.sampleRate > 0
            ? Double(audioFile.length) / audioFile.processingFormat.sampleRate
            : 0
        let attributes = try FileManager.default.attributesOfItem(atPath: active.fileURL.path)
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        let flags = lock.withLock { () -> Set<QualityFlag> in
            let value = observedFlags
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

    public func stopPairedRecording() throws -> CalliopeiaPairedRecording {
        guard let active = lock.withLock({ activePairedRecording }) else {
            throw CalliopeiaSDKError.invalidRequest("no paired recording is active")
        }
        defer {
            lock.withLock {
                activePairedRecording = nil
                pairedCallbackError = nil
            }
        }
        do {
            try recorder.stop()
        } catch {
            active.processor.cancel()
            throw error
        }
        if let callbackError = lock.withLock({ pairedCallbackError }) {
            active.processor.cancel()
            throw callbackError
        }
        let artifacts: PairedRecordingArtifacts
        do {
            artifacts = try active.processor.stopAndFinalize(
                rawFileURL: active.rawFileURL,
                enhancedFileURL: active.enhancedFileURL,
                manifestURL: active.manifestURL
            )
        } catch {
            active.processor.cancel()
            throw error
        }
        let rawAudio = try recordedAudio(
            fileURL: active.rawFileURL,
            fileName: active.rawFileName,
            captureFormat: active.captureFormat
        )
        return CalliopeiaPairedRecording(
            rawAudio: rawAudio,
            enhancedFileURL: artifacts.enhancedFileURL,
            enhancedFileName: artifacts.enhancedFileURL.lastPathComponent,
            manifestURL: artifacts.manifestURL,
            manifest: artifacts.manifest
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

    private func recordedAudio(
        fileURL: URL,
        fileName: String,
        captureFormat: CaptureFormat
    ) throws -> CalliopeiaRecordedAudio {
        let audioFile = try AVAudioFile(forReading: fileURL)
        let duration = audioFile.processingFormat.sampleRate > 0
            ? Double(audioFile.length) / audioFile.processingFormat.sampleRate
            : 0
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        let flags = lock.withLock { observedFlags }
        return CalliopeiaRecordedAudio(
            fileURL: fileURL,
            fileName: fileName,
            contentType: "audio/wav",
            fileSizeBytes: size,
            durationSeconds: duration,
            captureFormat: captureFormat,
            observedQualityFlags: flags
        )
    }
}

private struct ActiveRecording {
    let fileURL: URL
    let fileName: String
    let captureFormat: CaptureFormat
}

private struct ActivePairedRecording {
    let rawFileURL: URL
    let rawFileName: String
    let enhancedFileURL: URL
    let manifestURL: URL
    let captureFormat: CaptureFormat
    let processor: PairedRecordingProcessor
}
#endif
