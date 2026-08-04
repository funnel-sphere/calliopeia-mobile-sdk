import Foundation

public enum CaptureMode: String, Codable, Sendable {
    case rawMaster
    case systemVoice
}

public enum EnhancementProfile: String, Codable, Sendable {
    case bypass
    case adaptiveDsp
    case gtcrn16k
    case dpdfnet16k
    case dpdfnet48k
}

public struct AudioFrame: Sendable {
    public let samples: [Float]
    public let sampleRate: Int
    public let timestampMilliseconds: Int64

    public init(samples: [Float], sampleRate: Int, timestampMilliseconds: Int64) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.timestampMilliseconds = timestampMilliseconds
    }
}

public enum QualityFlag: String, Codable, Hashable, Sendable {
    case silence
    case tooQuiet
    case clipping
    case lowSnr
}

public struct QualitySnapshot: Codable, Equatable, Sendable {
    public let rmsDbFS: Double
    public let peakDbFS: Double
    public let noiseFloorDbFS: Double
    public let estimatedSnrDb: Double
    public let clippingRatio: Double
    public let flags: Set<QualityFlag>

    public init(
        rmsDbFS: Double,
        peakDbFS: Double,
        noiseFloorDbFS: Double,
        estimatedSnrDb: Double,
        clippingRatio: Double,
        flags: Set<QualityFlag>
    ) {
        self.rmsDbFS = rmsDbFS
        self.peakDbFS = peakDbFS
        self.noiseFloorDbFS = noiseFloorDbFS
        self.estimatedSnrDb = estimatedSnrDb
        self.clippingRatio = clippingRatio
        self.flags = flags
    }
}

public protocol AudioFrameInspecting: AnyObject, Sendable {
    func reset()
    func inspect(samples: [Float]) -> QualitySnapshot
}

public struct CaptureFormat: Codable, Equatable, Sendable {
    public let requestedSampleRate: Int
    public let actualSampleRate: Int
    public let channelCount: Int
    public let isFloatPCM: Bool
    public let mode: CaptureMode

    public init(
        requestedSampleRate: Int,
        actualSampleRate: Int,
        channelCount: Int,
        isFloatPCM: Bool,
        mode: CaptureMode
    ) {
        self.requestedSampleRate = requestedSampleRate
        self.actualSampleRate = actualSampleRate
        self.channelCount = channelCount
        self.isFloatPCM = isFloatPCM
        self.mode = mode
    }
}

public protocol StreamingAudioEnhancer: AnyObject {
    var identifier: String { get }
    var requiredSampleRate: Int { get }
    var preferredFrameSize: Int { get }
    func process(samples: [Float], sampleRate: Int) throws -> [Float]
    func flush() throws -> [Float]
    func reset()
}

public extension StreamingAudioEnhancer {
    var identifier: String { String(reflecting: type(of: self)) }
}

public enum AudioEnhancerError: Error, Equatable {
    case unsupportedSampleRate(expected: Int, actual: Int)
    case invalidModel(String)
    case processingFailed
}
