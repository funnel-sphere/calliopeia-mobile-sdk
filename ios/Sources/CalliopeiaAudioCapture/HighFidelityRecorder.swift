#if os(iOS)
import AVFoundation
#if canImport(CalliopeiaAudioContracts)
import CalliopeiaAudioContracts
#endif
import Foundation

public final class HighFidelityRecorder: @unchecked Sendable {
    public struct Configuration: Sendable {
        public var preferredSampleRate: Double
        public var preferredBufferDuration: TimeInterval
        public var frameBufferSize: AVAudioFrameCount

        public init(
            preferredSampleRate: Double = 48_000,
            preferredBufferDuration: TimeInterval = 0.02,
            frameBufferSize: AVAudioFrameCount = 960
        ) {
            self.preferredSampleRate = preferredSampleRate
            self.preferredBufferDuration = preferredBufferDuration
            self.frameBufferSize = frameBufferSize
        }
    }

    public enum RecorderError: Error {
        case alreadyRecording
        case unsupportedInputFormat
        case bufferCopyFailed
        case writeFailed(Error)
    }

    public typealias FrameHandler = @Sendable (AudioFrame, QualitySnapshot?) -> Void

    private let configuration: Configuration
    private let inspector: (any AudioFrameInspecting)?
    private let engine = AVAudioEngine()
    private let fileQueue = DispatchQueue(label: "com.calliopeia.edge-audio.file-writer")
    private let stateLock = NSLock()
    private let writeErrorLock = NSLock()
    private var audioFile: AVAudioFile?
    private var recording = false
    private var capturedFrameCount: Int64 = 0
    private var asynchronousWriteError: Error?

    public init(
        configuration: Configuration = .init(),
        inspector: (any AudioFrameInspecting)? = nil
    ) {
        self.configuration = configuration
        self.inspector = inspector
    }

    @discardableResult
    public func start(
        writingRawMasterTo outputURL: URL,
        mode: CaptureMode = .rawMaster,
        onFrame: FrameHandler? = nil
    ) throws -> CaptureFormat {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !recording else { throw RecorderError.alreadyRecording }

        let session = AVAudioSession.sharedInstance()
        try session.setActive(false)
        switch mode {
        case .rawMaster:
            try session.setCategory(.record, mode: .measurement, options: [])
        case .systemVoice:
            try session.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: [.defaultToSpeaker, .allowBluetoothHFP]
            )
        }
        try session.setPreferredSampleRate(configuration.preferredSampleRate)
        try session.setPreferredIOBufferDuration(configuration.preferredBufferDuration)
        try session.setActive(true)

        let input = engine.inputNode
        try input.setVoiceProcessingEnabled(mode == .systemVoice)
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0, format.floatChannelDataCompatible else {
            throw RecorderError.unsupportedInputFormat
        }

        audioFile = try AVAudioFile(
            forWriting: outputURL,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        capturedFrameCount = 0
        writeErrorLock.withLock { asynchronousWriteError = nil }
        inspector?.reset()

        var tapInstalled = false
        do {
            input.installTap(
                onBus: 0,
                bufferSize: configuration.frameBufferSize,
                format: format
            ) { [weak self] buffer, _ in
                self?.handle(buffer: buffer, format: format, onFrame: onFrame)
            }
            tapInstalled = true
            engine.prepare()
            try engine.start()
        } catch {
            engine.stop()
            if tapInstalled {
                input.removeTap(onBus: 0)
            }
            audioFile = nil
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw error
        }
        recording = true

        return CaptureFormat(
            requestedSampleRate: Int(configuration.preferredSampleRate),
            actualSampleRate: Int(format.sampleRate),
            channelCount: Int(format.channelCount),
            isFloatPCM: format.commonFormat == .pcmFormatFloat32,
            mode: mode
        )
    }

    public func stop() throws {
        stateLock.lock()
        guard recording else {
            stateLock.unlock()
            return
        }
        recording = false
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        stateLock.unlock()

        fileQueue.sync {}
        audioFile = nil
        try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        if let asynchronousWriteError = writeErrorLock.withLock({ asynchronousWriteError }) {
            throw RecorderError.writeFailed(asynchronousWriteError)
        }
    }

    private func handle(
        buffer: AVAudioPCMBuffer,
        format: AVAudioFormat,
        onFrame: FrameHandler?
    ) {
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0, let channelData = buffer.floatChannelData else { return }

        var mono = Array(repeating: Float(0), count: frameLength)
        for channel in 0..<Int(format.channelCount) {
            for frame in 0..<frameLength {
                mono[frame] += channelData[channel][frame] / Float(format.channelCount)
            }
        }

        let timestamp = capturedFrameCount * 1_000 / Int64(format.sampleRate)
        capturedFrameCount += Int64(frameLength)
        let snapshot = inspector?.inspect(samples: mono)
        onFrame?(AudioFrame(samples: mono, sampleRate: Int(format.sampleRate), timestampMilliseconds: timestamp), snapshot)

        guard let copy = Self.copy(buffer: buffer) else {
            writeErrorLock.withLock {
                asynchronousWriteError = RecorderError.bufferCopyFailed
            }
            return
        }
        fileQueue.async { [weak self] in
            guard let self, let audioFile = self.audioFile else { return }
            do {
                try audioFile.write(from: copy)
            } catch {
                self.writeErrorLock.withLock {
                    self.asynchronousWriteError = error
                }
            }
        }
    }

    private static func copy(buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(
            pcmFormat: buffer.format,
            frameCapacity: buffer.frameLength
        ) else { return nil }
        copy.frameLength = buffer.frameLength

        let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard source.count == destination.count else { return nil }
        for index in source.indices {
            guard let sourceData = source[index].mData, let destinationData = destination[index].mData else {
                return nil
            }
            memcpy(destinationData, sourceData, Int(source[index].mDataByteSize))
            destination[index].mDataByteSize = source[index].mDataByteSize
        }
        return copy
    }
}

private extension AVAudioFormat {
    var floatChannelDataCompatible: Bool {
        isStandard && !isInterleaved && commonFormat == .pcmFormatFloat32
    }
}
#endif
