import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(CalliopeiaAudioContracts)
import CalliopeiaAudioContracts
#endif

public struct PairedOutputSafetyConfiguration: Equatable, Sendable {
    public var minimumMeaningfulInputRMS: Float
    public var minimumOutputRMS: Float
    public var minimumOutputToInputRMSRatio: Float

    public init(
        minimumMeaningfulInputRMS: Float = 0.005,
        minimumOutputRMS: Float = 0.0005,
        minimumOutputToInputRMSRatio: Float = 0.08
    ) {
        self.minimumMeaningfulInputRMS = minimumMeaningfulInputRMS
        self.minimumOutputRMS = minimumOutputRMS
        self.minimumOutputToInputRMSRatio = minimumOutputToInputRMSRatio
    }

    fileprivate var isValid: Bool {
        minimumMeaningfulInputRMS.isFinite &&
            minimumMeaningfulInputRMS >= 0 &&
            minimumOutputRMS.isFinite &&
            minimumOutputRMS >= 0 &&
            minimumOutputToInputRMSRatio.isFinite &&
            minimumOutputToInputRMSRatio > 0 &&
            minimumOutputToInputRMSRatio <= 1
    }
}

public enum PairedOutputSafetyResult: String, Codable, Sendable {
    case safe
    case inputSilent
    case attenuated
    case invalid

    public var acceptsOutput: Bool {
        switch self {
        case .safe, .inputSilent:
            true
        case .attenuated, .invalid:
            false
        }
    }
}

public enum PairedSampleDisposition: String, Codable, Sendable {
    case enhanced
    case overloadFallback
    case modelErrorFallback
    case malformedOutputFallback
    case stoppedFallback
    case outputSafetyFallback
}

public struct PairedRecordingSpan: Codable, Equatable, Sendable {
    public let startSample: Int64
    public let sampleCount: Int64
    public let disposition: PairedSampleDisposition

    public init(
        startSample: Int64,
        sampleCount: Int64,
        disposition: PairedSampleDisposition
    ) {
        self.startSample = startSample
        self.sampleCount = sampleCount
        self.disposition = disposition
    }
}

public struct PairedRecordingManifest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let enhancerIdentifier: String
    public let rawFileName: String
    public let enhancedFileName: String
    public let sampleRate: Int
    public let rawChannelCount: Int
    public let enhancedChannelCount: Int
    public let totalSamples: Int64
    public let samplesByDisposition: [String: Int64]
    public let overrunCount: Int
    public let modelErrorCount: Int
    public let malformedOutputCount: Int
    public let modelTailDiscarded: Bool
    public let spans: [PairedRecordingSpan]

    public init(
        schemaVersion: Int = 1,
        enhancerIdentifier: String,
        rawFileName: String,
        enhancedFileName: String,
        sampleRate: Int,
        rawChannelCount: Int,
        enhancedChannelCount: Int,
        totalSamples: Int64,
        samplesByDisposition: [String: Int64],
        overrunCount: Int,
        modelErrorCount: Int,
        malformedOutputCount: Int,
        modelTailDiscarded: Bool,
        spans: [PairedRecordingSpan]
    ) {
        self.schemaVersion = schemaVersion
        self.enhancerIdentifier = enhancerIdentifier
        self.rawFileName = rawFileName
        self.enhancedFileName = enhancedFileName
        self.sampleRate = sampleRate
        self.rawChannelCount = rawChannelCount
        self.enhancedChannelCount = enhancedChannelCount
        self.totalSamples = totalSamples
        self.samplesByDisposition = samplesByDisposition
        self.overrunCount = overrunCount
        self.modelErrorCount = modelErrorCount
        self.malformedOutputCount = malformedOutputCount
        self.modelTailDiscarded = modelTailDiscarded
        self.spans = spans
    }
}

public struct PairedRecordingArtifacts: Sendable {
    public let rawFileURL: URL
    public let enhancedFileURL: URL
    public let manifestURL: URL
    public let manifest: PairedRecordingManifest

    public init(
        rawFileURL: URL,
        enhancedFileURL: URL,
        manifestURL: URL,
        manifest: PairedRecordingManifest
    ) {
        self.rawFileURL = rawFileURL
        self.enhancedFileURL = enhancedFileURL
        self.manifestURL = manifestURL
        self.manifest = manifest
    }
}

public final class PairedRecordingProcessor: @unchecked Sendable {
    public struct Configuration: Sendable {
        public var maximumPendingFrames: Int
        public var outputSafety: PairedOutputSafetyConfiguration

        public init(
            maximumPendingFrames: Int = 4,
            outputSafety: PairedOutputSafetyConfiguration = .init()
        ) {
            self.maximumPendingFrames = maximumPendingFrames
            self.outputSafety = outputSafety
        }
    }

    public enum ProcessorError: Error, Equatable {
        case invalidMaximumPendingFrames
        case invalidEnhancerFrameSize
        case unsupportedSampleRate(expected: Int, actual: Int)
        case alreadyStarted
        case notStarted
        case alreadyFinished
        case invalidFrameSampleRate(expected: Int, actual: Int)
        case invalidFrameSamples
        case spoolUnavailable
        case rawMasterUnavailable
        case rawMasterFormatMismatch
        case invalidOutputSafetyConfiguration
    }

    private let enhancer: any StreamingAudioEnhancer
    private let configuration: Configuration
    private let fileManager: FileManager
    private let processingQueue: DispatchQueue
    private let stateLock = NSLock()
    private let spoolLock = NSLock()
    private let completionGroup = DispatchGroup()

    private var started = false
    private var stopping = false
    private var finished = false
    private var sampleRate = 0
    private var nextStartSample: Int64 = 0
    private var nextRecordIndex: Int64 = 0
    private var acceptedWork = 0
    private var spoolDirectoryURL: URL?
    private var spoolRecordHandle: FileHandle?
    private var spoolAudioHandle: FileHandle?
    private var spoolAudioOffset: UInt64 = 0
    private var terminalError: Error?
    private var overrunCount = 0
    private var modelErrorCount = 0
    private var malformedOutputCount = 0
    private var modelTailDiscarded = false
    private var enhancerNeedsReset = false

    public init(
        enhancer: any StreamingAudioEnhancer,
        configuration: Configuration = .init(),
        fileManager: FileManager = .default
    ) {
        self.enhancer = enhancer
        self.configuration = configuration
        self.fileManager = fileManager
        self.processingQueue = DispatchQueue(
            label: "com.calliopeia.edge-audio.paired-enhancement",
            qos: .userInitiated
        )
    }

    public static func assessOutputSafety(
        inputSamples: [Float],
        outputSamples: [Float],
        configuration: PairedOutputSafetyConfiguration = .init()
    ) -> PairedOutputSafetyResult {
        guard configuration.isValid,
              !inputSamples.isEmpty,
              inputSamples.count == outputSamples.count,
              inputSamples.allSatisfy(\.isFinite),
              outputSamples.allSatisfy(\.isFinite) else {
            return .invalid
        }

        let inputRMS = rms(of: inputSamples)
        guard inputRMS >= Double(configuration.minimumMeaningfulInputRMS) else {
            return .inputSilent
        }

        let outputRMS = rms(of: outputSamples)
        if outputRMS <= Double(configuration.minimumOutputRMS) {
            return .attenuated
        }

        let rmsRatio = outputRMS / inputRMS
        guard rmsRatio < Double(configuration.minimumOutputToInputRMSRatio) else {
            return .safe
        }

        let inputPeak = peak(of: inputSamples)
        let outputPeak = peak(of: outputSamples)
        let peakRatio = inputPeak > 0 ? outputPeak / inputPeak : 0
        return peakRatio < Double(configuration.minimumOutputToInputRMSRatio)
            ? .attenuated
            : .safe
    }

    public func start(sampleRate: Int, spoolDirectory: URL) throws {
        guard configuration.maximumPendingFrames > 0 else {
            throw ProcessorError.invalidMaximumPendingFrames
        }
        guard configuration.outputSafety.isValid else {
            throw ProcessorError.invalidOutputSafetyConfiguration
        }
        guard enhancer.preferredFrameSize > 0 else {
            throw ProcessorError.invalidEnhancerFrameSize
        }
        guard enhancer.requiredSampleRate == sampleRate else {
            throw ProcessorError.unsupportedSampleRate(
                expected: enhancer.requiredSampleRate,
                actual: sampleRate
            )
        }
        try stateLock.withLock {
            guard !started else { throw ProcessorError.alreadyStarted }
            var openedHandles = [FileHandle]()
            do {
                if fileManager.fileExists(atPath: spoolDirectory.path) {
                    try fileManager.removeItem(at: spoolDirectory)
                }
                try fileManager.createDirectory(
                    at: spoolDirectory,
                    withIntermediateDirectories: true
                )
                let recordURL = spoolDirectory.appendingPathComponent(Self.recordFileName)
                let audioURL = spoolDirectory.appendingPathComponent(Self.audioFileName)
                guard fileManager.createFile(atPath: recordURL.path, contents: nil),
                      fileManager.createFile(atPath: audioURL.path, contents: nil) else {
                    throw ProcessorError.spoolUnavailable
                }
                let recordHandle = try FileHandle(forUpdating: recordURL)
                openedHandles.append(recordHandle)
                let audioHandle = try FileHandle(forUpdating: audioURL)
                openedHandles.append(audioHandle)

                enhancer.reset()
                enhancerNeedsReset = false
                started = true
                self.sampleRate = sampleRate
                nextStartSample = 0
                nextRecordIndex = 0
                spoolDirectoryURL = spoolDirectory
                spoolLock.withLock {
                    spoolRecordHandle = recordHandle
                    spoolAudioHandle = audioHandle
                    spoolAudioOffset = 0
                }
            } catch {
                for handle in openedHandles {
                    try? handle.close()
                }
                try? fileManager.removeItem(at: spoolDirectory)
                throw error
            }
        }
    }

    @discardableResult
    public func append(_ frame: AudioFrame) throws -> Bool {
        var acceptedPatch: PendingPatch?
        var rejectedForStop = false

        try stateLock.withLock {
            guard started else { throw ProcessorError.notStarted }
            guard !finished else { throw ProcessorError.alreadyFinished }
            guard frame.sampleRate == sampleRate else {
                throw ProcessorError.invalidFrameSampleRate(
                    expected: sampleRate,
                    actual: frame.sampleRate
                )
            }
            guard !frame.samples.isEmpty, frame.samples.allSatisfy(\.isFinite) else {
                throw ProcessorError.invalidFrameSamples
            }
            guard !stopping else {
                rejectedForStop = true
                return
            }

            let pending = PendingPatch(
                recordIndex: nextRecordIndex,
                startSample: nextStartSample,
                samples: frame.samples
            )
            nextRecordIndex += 1
            nextStartSample += Int64(frame.samples.count)

            if acceptedWork >= configuration.maximumPendingFrames {
                overrunCount += 1
                enhancerNeedsReset = true
                try writePatchRecord(
                    PatchRecord(
                        recordIndex: pending.recordIndex,
                        startSample: pending.startSample,
                        sampleCount: Int64(pending.samples.count),
                        disposition: .overloadFallback,
                        enhancedDataOffset: nil
                    )
                )
            } else {
                acceptedWork += 1
                completionGroup.enter()
                acceptedPatch = pending
            }
        }

        if rejectedForStop { return false }
        guard let acceptedPatch else { return false }

        processingQueue.async { [weak self] in
            defer { self?.completionGroup.leave() }
            self?.process(acceptedPatch)
        }
        return true
    }

    public func stopAndFinalize(
        rawFileURL: URL,
        enhancedFileURL: URL,
        manifestURL: URL
    ) throws -> PairedRecordingArtifacts {
        try stateLock.withLock {
            guard started else { throw ProcessorError.notStarted }
            guard !finished else { throw ProcessorError.alreadyFinished }
            stopping = true
        }
        defer {
            stateLock.withLock { finished = true }
            cleanupSpool()
        }

        completionGroup.wait()
        processingQueue.sync {}
        try closeSpoolHandles()
        let completionState = stateLock.withLock { terminalError }
        if let terminalError = completionState {
            throw terminalError
        }

        do {
            let tail = try enhancer.flush()
            if !tail.isEmpty {
                stateLock.withLock { modelTailDiscarded = true }
            }
        } catch {
            stateLock.withLock { modelErrorCount += 1 }
        }

        do {
            let manifest = try reconstruct(
                rawFileURL: rawFileURL,
                enhancedFileURL: enhancedFileURL
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(manifest).write(to: manifestURL, options: .atomic)
            return PairedRecordingArtifacts(
                rawFileURL: rawFileURL,
                enhancedFileURL: enhancedFileURL,
                manifestURL: manifestURL,
                manifest: manifest
            )
        } catch {
            try? fileManager.removeItem(at: enhancedFileURL)
            try? fileManager.removeItem(at: manifestURL)
            throw error
        }
    }

    public func cancel() {
        stateLock.withLock { stopping = true }
        completionGroup.wait()
        processingQueue.sync {}
        try? closeSpoolHandles()
        cleanupSpool()
        stateLock.withLock { finished = true }
    }

    private func process(_ pending: PendingPatch) {
        let disposition: PairedSampleDisposition
        var enhancedSamples: [Float]?
        do {
            let shouldReset = stateLock.withLock { () -> Bool in
                let value = enhancerNeedsReset
                enhancerNeedsReset = false
                return value
            }
            if shouldReset {
                enhancer.reset()
            }
            let output = try enhancer.process(
                samples: pending.samples,
                sampleRate: sampleRate
            )
            if output.count != pending.samples.count || !output.allSatisfy(\.isFinite) {
                disposition = .malformedOutputFallback
                stateLock.withLock {
                    malformedOutputCount += 1
                    enhancerNeedsReset = true
                }
            } else {
                switch Self.assessOutputSafety(
                    inputSamples: pending.samples,
                    outputSamples: output,
                    configuration: configuration.outputSafety
                ) {
                case .safe, .inputSilent:
                    disposition = .enhanced
                    enhancedSamples = output
                case .attenuated:
                    disposition = .outputSafetyFallback
                    stateLock.withLock { enhancerNeedsReset = true }
                case .invalid:
                    disposition = .malformedOutputFallback
                    stateLock.withLock {
                        malformedOutputCount += 1
                        enhancerNeedsReset = true
                    }
                }
            }
        } catch {
            disposition = .modelErrorFallback
            stateLock.withLock {
                modelErrorCount += 1
                enhancerNeedsReset = true
            }
        }

        do {
            try writePatchRecord(
                PatchRecord(
                    recordIndex: pending.recordIndex,
                    startSample: pending.startSample,
                    sampleCount: Int64(pending.samples.count),
                    disposition: disposition,
                    enhancedDataOffset: nil
                ),
                enhancedSamples: enhancedSamples
            )
        } catch {
            stateLock.withLock { terminalError = error }
        }
        stateLock.withLock {
            acceptedWork -= 1
        }
    }

    private func reconstruct(
        rawFileURL: URL,
        enhancedFileURL: URL
    ) throws -> PairedRecordingManifest {
#if canImport(AVFoundation)
        let rawFile: AVAudioFile
        do {
            rawFile = try AVAudioFile(forReading: rawFileURL)
        } catch {
            throw ProcessorError.rawMasterUnavailable
        }
        let rawFormat = rawFile.processingFormat
        guard Int(rawFormat.sampleRate.rounded()) == sampleRate,
              rawFormat.channelCount > 0 else {
            throw ProcessorError.rawMasterFormatMismatch
        }
        let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: rawFormat.sampleRate,
            channels: 1,
            interleaved: false
        )!
        let outputFile = try AVAudioFile(
            forWriting: enhancedFileURL,
            settings: outputFormat.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let expectedSamples = rawFile.length
        let snapshot = stateLock.withLock {
            Snapshot(
                overrunCount: overrunCount,
                modelErrorCount: modelErrorCount,
                malformedOutputCount: malformedOutputCount,
                modelTailDiscarded: modelTailDiscarded
            )
        }
        guard nextStartSample <= expectedSamples else {
            throw ProcessorError.rawMasterFormatMismatch
        }
        guard let spoolDirectoryURL = stateLock.withLock({ spoolDirectoryURL }) else {
            throw ProcessorError.spoolUnavailable
        }
        let recordReader = try FileHandle(
            forReadingFrom: spoolDirectoryURL.appendingPathComponent(Self.recordFileName)
        )
        let audioReader = try FileHandle(
            forReadingFrom: spoolDirectoryURL.appendingPathComponent(Self.audioFileName)
        )
        defer {
            try? recordReader.close()
            try? audioReader.close()
        }
        let recordCount = stateLock.withLock { nextRecordIndex }
        var rawPosition: Int64 = 0
        var recordIndex: Int64 = 0
        var spans = [PairedRecordingSpan]()
        var counts = [PairedSampleDisposition: Int64]()
        var reconstructedModelErrorCount = snapshot.modelErrorCount

        while rawPosition < expectedSamples, recordIndex < recordCount {
            let patch = try loadPatchRecord(
                recordIndex: recordIndex,
                from: recordReader
            )
            guard patch.startSample == rawPosition else {
                throw ProcessorError.rawMasterFormatMismatch
            }
            let available = expectedSamples - rawPosition
            let count = min(patch.sampleCount, available)
            let rawMono = try Self.readMono(
                from: rawFile,
                frameCount: Int(count),
                channelCount: Int(rawFormat.channelCount)
            )
            guard rawMono.count == Int(count) else {
                throw ProcessorError.rawMasterFormatMismatch
            }
            let output: [Float]
            var appliedDisposition = patch.disposition
            if patch.disposition == .enhanced, count == patch.sampleCount {
                do {
                    output = try readPatch(
                        patch,
                        expectedCount: Int(count),
                        from: audioReader
                    )
                } catch {
                    output = rawMono
                    appliedDisposition = .modelErrorFallback
                    reconstructedModelErrorCount += 1
                }
            } else {
                output = rawMono
            }
            try Self.writeMono(output, to: outputFile, format: outputFormat)
            Self.appendSpan(
                startSample: rawPosition,
                sampleCount: count,
                disposition: appliedDisposition,
                spans: &spans,
                counts: &counts
            )
            rawPosition += count
            recordIndex += 1
        }

        if rawPosition < expectedSamples {
            let remaining = Int(expectedSamples - rawPosition)
            let rawMono = try Self.readMono(
                from: rawFile,
                frameCount: remaining,
                channelCount: Int(rawFormat.channelCount)
            )
            guard rawMono.count == remaining else {
                throw ProcessorError.rawMasterFormatMismatch
            }
            try Self.writeMono(rawMono, to: outputFile, format: outputFormat)
            Self.appendSpan(
                startSample: rawPosition,
                sampleCount: Int64(remaining),
                disposition: .stoppedFallback,
                spans: &spans,
                counts: &counts
            )
            rawPosition += Int64(remaining)
        }
        guard rawPosition == expectedSamples else {
            throw ProcessorError.rawMasterFormatMismatch
        }
        guard recordIndex == recordCount else {
            throw ProcessorError.rawMasterFormatMismatch
        }

        return PairedRecordingManifest(
            enhancerIdentifier: enhancer.identifier,
            rawFileName: rawFileURL.lastPathComponent,
            enhancedFileName: enhancedFileURL.lastPathComponent,
            sampleRate: sampleRate,
            rawChannelCount: Int(rawFormat.channelCount),
            enhancedChannelCount: 1,
            totalSamples: expectedSamples,
            samplesByDisposition: Dictionary(
                uniqueKeysWithValues: PairedSampleDisposition.allCases.map {
                    ($0.rawValue, counts[$0, default: 0])
                }
            ),
            overrunCount: snapshot.overrunCount,
            modelErrorCount: reconstructedModelErrorCount,
            malformedOutputCount: snapshot.malformedOutputCount,
            modelTailDiscarded: snapshot.modelTailDiscarded,
            spans: spans
        )
#else
        throw ProcessorError.rawMasterUnavailable
#endif
    }

    private func cleanupSpool() {
        try? closeSpoolHandles()
        if let directory = stateLock.withLock({ spoolDirectoryURL }) {
            try? fileManager.removeItem(at: directory)
        }
    }

    private func closeSpoolHandles() throws {
        var firstError: Error?
        spoolLock.withLock {
            let handles = [spoolRecordHandle, spoolAudioHandle].compactMap { $0 }
            spoolRecordHandle = nil
            spoolAudioHandle = nil
            for handle in handles {
                do {
                    try handle.synchronize()
                } catch {
                    if firstError == nil { firstError = error }
                }
                do {
                    try handle.close()
                } catch {
                    if firstError == nil { firstError = error }
                }
            }
        }
        if let firstError { throw firstError }
    }

    private func writePatchRecord(
        _ record: PatchRecord,
        enhancedSamples: [Float]? = nil
    ) throws {
        try spoolLock.withLock {
            guard let recordHandle = spoolRecordHandle,
                  let audioHandle = spoolAudioHandle else {
                throw ProcessorError.spoolUnavailable
            }
            var storedRecord = record
            if let enhancedSamples {
                let data = Self.data(from: enhancedSamples)
                let offset = spoolAudioOffset
                try audioHandle.seek(toOffset: offset)
                try audioHandle.write(contentsOf: data)
                spoolAudioOffset += UInt64(data.count)
                storedRecord = PatchRecord(
                    recordIndex: record.recordIndex,
                    startSample: record.startSample,
                    sampleCount: record.sampleCount,
                    disposition: record.disposition,
                    enhancedDataOffset: offset
                )
            }
            try recordHandle.seek(
                toOffset: UInt64(record.recordIndex) * UInt64(Self.patchRecordSize)
            )
            try recordHandle.write(contentsOf: Self.encode(storedRecord))
        }
    }

    private func loadPatchRecord(
        recordIndex: Int64,
        from handle: FileHandle
    ) throws -> PatchRecord {
        try handle.seek(
            toOffset: UInt64(recordIndex) * UInt64(Self.patchRecordSize)
        )
        guard let data = try handle.read(upToCount: Self.patchRecordSize),
              data.count == Self.patchRecordSize else {
            throw ProcessorError.spoolUnavailable
        }
        return try Self.decode(data, recordIndex: recordIndex)
    }

    private static func data(from samples: [Float]) -> Data {
        samples.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private static func rms(of samples: [Float]) -> Double {
        let sum = samples.reduce(into: 0.0) { partialResult, sample in
            let value = Double(sample)
            partialResult += value * value
        }
        return (sum / Double(samples.count)).squareRoot()
    }

    private static func peak(of samples: [Float]) -> Double {
        samples.reduce(0) { max($0, abs(Double($1))) }
    }

    private static let recordFileName = "patch-records.bin"
    private static let audioFileName = "enhanced-samples.f32"
    private static let patchRecordSize = 32

    private static func encode(_ record: PatchRecord) -> Data {
        var data = Data(capacity: patchRecordSize)
        appendInteger(record.startSample, to: &data)
        appendInteger(record.sampleCount, to: &data)
        appendInteger(record.disposition.binaryCode, to: &data)
        data.append(Data(repeating: 0, count: 7))
        appendInteger(record.enhancedDataOffset ?? UInt64.max, to: &data)
        return data
    }

    private static func decode(_ data: Data, recordIndex: Int64) throws -> PatchRecord {
        guard data.count == patchRecordSize else {
            throw ProcessorError.spoolUnavailable
        }
        let startSample: Int64 = integer(from: data, at: 0)
        let sampleCount: Int64 = integer(from: data, at: 8)
        let dispositionCode: UInt8 = integer(from: data, at: 16)
        let storedOffset: UInt64 = integer(from: data, at: 24)
        guard sampleCount > 0,
              let disposition = PairedSampleDisposition(binaryCode: dispositionCode) else {
            throw ProcessorError.spoolUnavailable
        }
        return PatchRecord(
            recordIndex: recordIndex,
            startSample: startSample,
            sampleCount: sampleCount,
            disposition: disposition,
            enhancedDataOffset: storedOffset == UInt64.max ? nil : storedOffset
        )
    }

    private static func appendInteger<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    private static func integer<T: FixedWidthInteger>(
        from data: Data,
        at offset: Int
    ) -> T {
        var value: T = 0
        withUnsafeMutableBytes(of: &value) { destination in
            _ = data.copyBytes(
                to: destination,
                from: offset..<(offset + MemoryLayout<T>.size)
            )
        }
        return T(littleEndian: value)
    }

    private static func appendSpan(
        startSample: Int64,
        sampleCount: Int64,
        disposition: PairedSampleDisposition,
        spans: inout [PairedRecordingSpan],
        counts: inout [PairedSampleDisposition: Int64]
    ) {
        guard sampleCount > 0 else { return }
        counts[disposition, default: 0] += sampleCount
        if let last = spans.last,
           last.disposition == disposition,
           last.startSample + last.sampleCount == startSample {
            spans[spans.count - 1] = PairedRecordingSpan(
                startSample: last.startSample,
                sampleCount: last.sampleCount + sampleCount,
                disposition: disposition
            )
        } else {
            spans.append(
                PairedRecordingSpan(
                    startSample: startSample,
                    sampleCount: sampleCount,
                    disposition: disposition
                )
            )
        }
    }

#if canImport(AVFoundation)
    private static func readMono(
        from file: AVAudioFile,
        frameCount: Int,
        channelCount: Int
    ) throws -> [Float] {
        guard frameCount > 0 else { return [] }
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(frameCount)
        ) else {
            throw ProcessorError.rawMasterFormatMismatch
        }
        try file.read(into: buffer, frameCount: AVAudioFrameCount(frameCount))
        guard Int(buffer.frameLength) == frameCount,
              let channels = buffer.floatChannelData else {
            throw ProcessorError.rawMasterFormatMismatch
        }
        var mono = [Float](repeating: 0, count: frameCount)
        for channel in 0..<channelCount {
            for sample in 0..<frameCount {
                mono[sample] += channels[channel][sample] / Float(channelCount)
            }
        }
        return mono
    }

    private func readPatch(
        _ patch: PatchRecord,
        expectedCount: Int,
        from handle: FileHandle
    ) throws -> [Float] {
        guard let offset = patch.enhancedDataOffset else {
            throw ProcessorError.spoolUnavailable
        }
        try handle.seek(toOffset: offset)
        let expectedBytes = expectedCount * MemoryLayout<Float>.size
        guard let data = try handle.read(upToCount: expectedBytes) else {
            throw ProcessorError.spoolUnavailable
        }
        guard data.count == expectedBytes else {
            throw ProcessorError.rawMasterFormatMismatch
        }
        var samples = [Float](repeating: 0, count: expectedCount)
        samples.withUnsafeMutableBytes { destination in
            _ = data.copyBytes(to: destination)
        }
        return samples
    }

    private static func writeMono(
        _ samples: [Float],
        to file: AVAudioFile,
        format: AVAudioFormat
    ) throws {
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ), let channel = buffer.floatChannelData?[0] else {
            throw ProcessorError.rawMasterFormatMismatch
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer {
            channel.update(from: $0.baseAddress!, count: samples.count)
        }
        try file.write(from: buffer)
    }
#endif
}

private struct PendingPatch: Sendable {
    let recordIndex: Int64
    let startSample: Int64
    let samples: [Float]
}

private struct PatchRecord: Sendable {
    let recordIndex: Int64
    let startSample: Int64
    let sampleCount: Int64
    let disposition: PairedSampleDisposition
    let enhancedDataOffset: UInt64?
}

private struct Snapshot {
    let overrunCount: Int
    let modelErrorCount: Int
    let malformedOutputCount: Int
    let modelTailDiscarded: Bool
}

private extension PairedSampleDisposition {
    static let allCases: [Self] = [
        .enhanced,
        .overloadFallback,
        .modelErrorFallback,
        .malformedOutputFallback,
        .stoppedFallback,
        .outputSafetyFallback,
    ]

    var binaryCode: UInt8 {
        switch self {
        case .enhanced: 0
        case .overloadFallback: 1
        case .modelErrorFallback: 2
        case .malformedOutputFallback: 3
        case .stoppedFallback: 4
        case .outputSafetyFallback: 5
        }
    }

    init?(binaryCode: UInt8) {
        switch binaryCode {
        case 0: self = .enhanced
        case 1: self = .overloadFallback
        case 2: self = .modelErrorFallback
        case 3: self = .malformedOutputFallback
        case 4: self = .stoppedFallback
        case 5: self = .outputSafetyFallback
        default: return nil
        }
    }
}
