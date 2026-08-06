import AVFoundation
import Foundation
import XCTest
@testable import CalliopeiaAudioCapture
@testable import CalliopeiaAudioContracts

final class PairedRecordingProcessorTests: XCTestCase {
    func testOutputSafetyDistinguishesSilentInputAndAttenuatedOutput() {
        let configuration = PairedOutputSafetyConfiguration()
        XCTAssertEqual(
            PairedRecordingProcessor.assessOutputSafety(
                inputSamples: [0.1, -0.2, 0.3, -0.4],
                outputSamples: [0, 0, 0, 0],
                configuration: configuration
            ),
            .attenuated
        )
        XCTAssertEqual(
            PairedRecordingProcessor.assessOutputSafety(
                inputSamples: [0.1, -0.2, 0.3, -0.4],
                outputSamples: [0.05, -0.1, 0.15, -0.2],
                configuration: configuration
            ),
            .safe
        )
        XCTAssertEqual(
            PairedRecordingProcessor.assessOutputSafety(
                inputSamples: [0.0001, -0.0002, 0.0001, -0.0001],
                outputSamples: [0, 0, 0, 0],
                configuration: configuration
            ),
            .inputSilent
        )
    }

    func testSyntheticWAVReconstructionPreservesAlignmentAndCoalescesSpans() throws {
        let workspace = try TemporaryWorkspace()
        let raw = workspace.url.appendingPathComponent("raw.wav")
        let enhanced = workspace.url.appendingPathComponent("enhanced.wav")
        let manifest = workspace.url.appendingPathComponent("manifest.json")
        let samples = (0..<12).map { Float($0) / 12 }
        try writeWAV(samples: samples, channels: 1, sampleRate: 16_000, to: raw)

        let enhancer = TransformEnhancer { $0.map { $0 * 2 } }
        let processor = PairedRecordingProcessor(enhancer: enhancer)
        try processor.start(
            sampleRate: 16_000,
            spoolDirectory: workspace.url.appendingPathComponent("spool")
        )
        try processor.append(frame(Array(samples[0..<4])))
        try processor.append(frame(Array(samples[4..<8])))
        try processor.append(frame(Array(samples[8..<12])))
        let artifacts = try processor.stopAndFinalize(
            rawFileURL: raw,
            enhancedFileURL: enhanced,
            manifestURL: manifest
        )

        assertFloatArraysEqual(try readMonoWAV(enhanced), samples.map { $0 * 2 })
        let rawAudioFile = try AVAudioFile(forReading: raw)
        let enhancedAudioFile = try AVAudioFile(forReading: enhanced)
        XCTAssertEqual(rawAudioFile.length, enhancedAudioFile.length)
        XCTAssertEqual(artifacts.manifest.totalSamples, 12)
        XCTAssertEqual(artifacts.manifest.schemaVersion, 1)
        XCTAssertEqual(artifacts.manifest.enhancerIdentifier, enhancer.identifier)
        XCTAssertEqual(artifacts.manifest.sampleRate, 16_000)
        XCTAssertEqual(artifacts.manifest.rawChannelCount, 1)
        XCTAssertEqual(artifacts.manifest.enhancedChannelCount, 1)
        XCTAssertEqual(artifacts.manifest.samplesByDisposition["enhanced"], 12)
        XCTAssertEqual(
            artifacts.manifest.samplesByDisposition.values.reduce(0, +),
            artifacts.manifest.totalSamples
        )
        XCTAssertEqual(
            artifacts.manifest.spans,
            [.init(startSample: 0, sampleCount: 12, disposition: .enhanced)]
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                PairedRecordingManifest.self,
                from: Data(contentsOf: manifest)
            ),
            artifacts.manifest
        )
    }

    func testForcedOverflowFallsBackInChronologicalOrderBeforeEarlierCompletion() throws {
        let workspace = try TemporaryWorkspace()
        let raw = workspace.url.appendingPathComponent("raw.wav")
        let enhanced = workspace.url.appendingPathComponent("enhanced.wav")
        let manifest = workspace.url.appendingPathComponent("manifest.json")
        let first: [Float] = [0.1, 0.2, 0.3, 0.4]
        let second: [Float] = [0.5, 0.6, 0.7, 0.8]
        try writeWAV(samples: first + second, channels: 1, sampleRate: 16_000, to: raw)

        let gate = DispatchSemaphore(value: 0)
        let started = DispatchSemaphore(value: 0)
        let enhancer = TransformEnhancer { samples in
            started.signal()
            gate.wait()
            return samples.map { -$0 }
        }
        let processor = PairedRecordingProcessor(
            enhancer: enhancer,
            configuration: .init(maximumPendingFrames: 1)
        )
        let spool = workspace.url.appendingPathComponent("spool")
        try processor.start(
            sampleRate: 16_000,
            spoolDirectory: spool
        )
        XCTAssertTrue(try processor.append(frame(first)))
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        XCTAssertFalse(try processor.append(frame(second)))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: spool.path).count,
            2
        )
        gate.signal()
        let artifacts = try processor.stopAndFinalize(
            rawFileURL: raw,
            enhancedFileURL: enhanced,
            manifestURL: manifest
        )

        assertFloatArraysEqual(try readMonoWAV(enhanced), first.map { -$0 } + second)
        XCTAssertEqual(artifacts.manifest.overrunCount, 1)
        XCTAssertEqual(
            artifacts.manifest.spans,
            [
                .init(startSample: 0, sampleCount: 4, disposition: .enhanced),
                .init(startSample: 4, sampleCount: 4, disposition: .overloadFallback),
            ]
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: spool.path))
    }

    func testModelFailureAndMalformedOutputsUseExactRawSamples() throws {
        let workspace = try TemporaryWorkspace()
        let raw = workspace.url.appendingPathComponent("raw.wav")
        let enhanced = workspace.url.appendingPathComponent("enhanced.wav")
        let manifest = workspace.url.appendingPathComponent("manifest.json")
        let samples: [Float] = [0.1, 0.2, 0.3, 0.4, 0.5, 0.6]
        try writeWAV(samples: samples, channels: 1, sampleRate: 16_000, to: raw)

        let enhancer = SequencedEnhancer(results: [
            .failure(TestError.model),
            .success([0.9]),
            .success([.nan, 0.1]),
        ])
        let processor = PairedRecordingProcessor(enhancer: enhancer)
        try processor.start(
            sampleRate: 16_000,
            spoolDirectory: workspace.url.appendingPathComponent("spool")
        )
        try processor.append(frame(Array(samples[0..<2])))
        try processor.append(frame(Array(samples[2..<4])))
        try processor.append(frame(Array(samples[4..<6])))
        let artifacts = try processor.stopAndFinalize(
            rawFileURL: raw,
            enhancedFileURL: enhanced,
            manifestURL: manifest
        )

        assertFloatArraysEqual(try readMonoWAV(enhanced), samples)
        XCTAssertEqual(artifacts.manifest.modelErrorCount, 1)
        XCTAssertEqual(artifacts.manifest.malformedOutputCount, 2)
        XCTAssertEqual(artifacts.manifest.samplesByDisposition["modelErrorFallback"], 2)
        XCTAssertEqual(artifacts.manifest.samplesByDisposition["malformedOutputFallback"], 4)
    }

    func testExtremelyAttenuatedCandidateFallsBackToRawAndRecordsDisposition() throws {
        let workspace = try TemporaryWorkspace()
        let raw = workspace.url.appendingPathComponent("raw.wav")
        let enhanced = workspace.url.appendingPathComponent("enhanced.wav")
        let manifest = workspace.url.appendingPathComponent("manifest.json")
        let samples: [Float] = [0.2, -0.1, 0.3, -0.4]
        try writeWAV(samples: samples, channels: 1, sampleRate: 16_000, to: raw)

        let processor = PairedRecordingProcessor(
            enhancer: TransformEnhancer { _ in [0, 0, 0, 0] }
        )
        try processor.start(
            sampleRate: 16_000,
            spoolDirectory: workspace.url.appendingPathComponent("spool")
        )
        try processor.append(frame(samples))

        let artifacts = try processor.stopAndFinalize(
            rawFileURL: raw,
            enhancedFileURL: enhanced,
            manifestURL: manifest
        )

        assertFloatArraysEqual(try readMonoWAV(enhanced), samples)
        XCTAssertEqual(
            artifacts.manifest.spans,
            [
                .init(
                    startSample: 0,
                    sampleCount: Int64(samples.count),
                    disposition: .outputSafetyFallback
                ),
            ]
        )
        XCTAssertEqual(
            artifacts.manifest.samplesByDisposition["outputSafetyFallback"],
            Int64(samples.count)
        )
    }

    func testModelFailureResetsStateBeforeTheNextAcceptedFrame() throws {
        let workspace = try TemporaryWorkspace()
        let raw = workspace.url.appendingPathComponent("raw.wav")
        let enhanced = workspace.url.appendingPathComponent("enhanced.wav")
        let manifest = workspace.url.appendingPathComponent("manifest.json")
        let samples: [Float] = [0.1, 0.2, 0.3, 0.4]
        try writeWAV(samples: samples, channels: 1, sampleRate: 16_000, to: raw)

        let enhancer = SequencedEnhancer(results: [
            .failure(TestError.model),
            .success([-0.3, -0.4]),
        ])
        let processor = PairedRecordingProcessor(enhancer: enhancer)
        try processor.start(
            sampleRate: 16_000,
            spoolDirectory: workspace.url.appendingPathComponent("spool")
        )
        try processor.append(frame(Array(samples[0..<2])))
        try processor.append(frame(Array(samples[2..<4])))
        _ = try processor.stopAndFinalize(
            rawFileURL: raw,
            enhancedFileURL: enhanced,
            manifestURL: manifest
        )

        assertFloatArraysEqual(try readMonoWAV(enhanced), [0.1, 0.2, -0.3, -0.4])
        XCTAssertEqual(enhancer.resetCount, 2)
    }

    func testStereoRawFallbackIsExactlyAlignedMonoAndModelTailIsDiscarded() throws {
        let workspace = try TemporaryWorkspace()
        let raw = workspace.url.appendingPathComponent("raw.wav")
        let enhanced = workspace.url.appendingPathComponent("enhanced.wav")
        let manifest = workspace.url.appendingPathComponent("manifest.json")
        let left: [Float] = [0.2, 0.4, 0.6, 0.8]
        let right: [Float] = [-0.2, 0.2, 0.4, 0.6]
        try writeWAV(
            channelSamples: [left, right],
            sampleRate: 48_000,
            to: raw
        )

        let processor = PairedRecordingProcessor(
            enhancer: TransformEnhancer(
                requiredSampleRate: 48_000,
                flushResult: [0.1]
            ) { _ in throw TestError.model }
        )
        try processor.start(
            sampleRate: 48_000,
            spoolDirectory: workspace.url.appendingPathComponent("spool")
        )
        try processor.append(
            AudioFrame(
                samples: zip(left, right).map { ($0 + $1) / 2 },
                sampleRate: 48_000,
                timestampMilliseconds: 0
            )
        )
        let artifacts = try processor.stopAndFinalize(
            rawFileURL: raw,
            enhancedFileURL: enhanced,
            manifestURL: manifest
        )

        assertFloatArraysEqual(
            try readMonoWAV(enhanced),
            zip(left, right).map { ($0 + $1) / 2 }
        )
        XCTAssertEqual(artifacts.manifest.rawChannelCount, 2)
        XCTAssertTrue(artifacts.manifest.modelTailDiscarded)
    }

    func testRejectsRequiredSampleRateMismatchWithoutResampling() throws {
        let workspace = try TemporaryWorkspace()
        let processor = PairedRecordingProcessor(
            enhancer: TransformEnhancer(requiredSampleRate: 16_000) { $0 }
        )
        XCTAssertThrowsError(
            try processor.start(
                sampleRate: 48_000,
                spoolDirectory: workspace.url.appendingPathComponent("spool")
            )
        ) { error in
            XCTAssertEqual(
                error as? PairedRecordingProcessor.ProcessorError,
                .unsupportedSampleRate(expected: 16_000, actual: 48_000)
            )
        }
    }

    func testRawTailWithoutSubmittedFramesUsesStoppedFallback() throws {
        let workspace = try TemporaryWorkspace()
        let raw = workspace.url.appendingPathComponent("raw.wav")
        let enhanced = workspace.url.appendingPathComponent("enhanced.wav")
        let manifest = workspace.url.appendingPathComponent("manifest.json")
        let samples: [Float] = [0.1, 0.2, 0.3, 0.4, 0.5, 0.6]
        try writeWAV(samples: samples, channels: 1, sampleRate: 16_000, to: raw)

        let processor = PairedRecordingProcessor(
            enhancer: TransformEnhancer { $0.map { -$0 } }
        )
        try processor.start(
            sampleRate: 16_000,
            spoolDirectory: workspace.url.appendingPathComponent("spool")
        )
        try processor.append(frame(Array(samples[0..<2])))
        let artifacts = try processor.stopAndFinalize(
            rawFileURL: raw,
            enhancedFileURL: enhanced,
            manifestURL: manifest
        )

        assertFloatArraysEqual(
            try readMonoWAV(enhanced),
            samples[0..<2].map { -$0 } + Array(samples[2..<6])
        )
        XCTAssertEqual(
            artifacts.manifest.spans,
            [
                .init(startSample: 0, sampleCount: 2, disposition: .enhanced),
                .init(startSample: 2, sampleCount: 4, disposition: .stoppedFallback),
            ]
        )
        XCTAssertEqual(artifacts.manifest.samplesByDisposition["stoppedFallback"], 4)
    }

    private func frame(_ samples: [Float], sampleRate: Int = 16_000) -> AudioFrame {
        AudioFrame(samples: samples, sampleRate: sampleRate, timestampMilliseconds: 0)
    }

    private func writeWAV(
        samples: [Float],
        channels: AVAudioChannelCount,
        sampleRate: Double,
        to url: URL
    ) throws {
        try writeWAV(
            channelSamples: Array(repeating: samples, count: Int(channels)),
            sampleRate: sampleRate,
            to: url
        )
    }

    private func writeWAV(
        channelSamples: [[Float]],
        sampleRate: Double,
        to url: URL
    ) throws {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channelSamples.count),
            interleaved: false
        )!
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let count = channelSamples[0].count
        let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(count)
        )!
        buffer.frameLength = AVAudioFrameCount(count)
        for channel in channelSamples.indices {
            channelSamples[channel].withUnsafeBufferPointer {
                buffer.floatChannelData![channel].update(
                    from: $0.baseAddress!,
                    count: count
                )
            }
        }
        try file.write(from: buffer)
    }

    private func readMonoWAV(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let count = Int(file.length)
        let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(count)
        )!
        try file.read(into: buffer)
        return Array(
            UnsafeBufferPointer(
                start: buffer.floatChannelData![0],
                count: count
            )
        )
    }

    private func assertFloatArraysEqual(
        _ actual: [Float],
        _ expected: [Float],
        accuracy: Float = 0.000_001,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            actual.count == expected.count,
            "count \(actual.count) != \(expected.count)",
            file: file,
            line: line
        )
        for (actual, expected) in zip(actual, expected) {
            XCTAssertTrue(
                abs(actual - expected) <= accuracy,
                "\(actual) != \(expected) within \(accuracy)",
                file: file,
                line: line
            )
        }
    }
}

private enum TestError: Error {
    case model
}

private final class TransformEnhancer: StreamingAudioEnhancer, @unchecked Sendable {
    let requiredSampleRate: Int
    let preferredFrameSize: Int
    private let transform: ([Float]) throws -> [Float]
    private let flushResult: [Float]

    init(
        requiredSampleRate: Int = 16_000,
        preferredFrameSize: Int = 2,
        flushResult: [Float] = [],
        transform: @escaping ([Float]) throws -> [Float]
    ) {
        self.requiredSampleRate = requiredSampleRate
        self.preferredFrameSize = preferredFrameSize
        self.flushResult = flushResult
        self.transform = transform
    }

    func process(samples: [Float], sampleRate: Int) throws -> [Float] {
        try transform(samples)
    }

    func flush() throws -> [Float] { flushResult }
    func reset() {}
}

private final class SequencedEnhancer: StreamingAudioEnhancer, @unchecked Sendable {
    let requiredSampleRate = 16_000
    let preferredFrameSize = 2
    private let lock = NSLock()
    private var results: [Result<[Float], Error>]
    private var resets = 0

    var resetCount: Int { lock.withLock { resets } }

    init(results: [Result<[Float], Error>]) {
        self.results = results
    }

    func process(samples: [Float], sampleRate: Int) throws -> [Float] {
        try lock.withLock {
            try results.removeFirst().get()
        }
    }

    func flush() throws -> [Float] { [] }
    func reset() { lock.withLock { resets += 1 } }
}

private final class TemporaryWorkspace {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("calliopeia-paired-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}
