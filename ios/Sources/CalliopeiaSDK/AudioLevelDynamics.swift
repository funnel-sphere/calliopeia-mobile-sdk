import Foundation

/// A bounded-memory amplitude distribution.
///
/// Percentile levels are needed to tell an isolated knock apart from the sustained
/// loudness of a take, but sorting every sample of a long recording is not
/// affordable. Counting samples into decibel-spaced bins answers the same question
/// in a fixed 481-entry table.
enum AudioLevelHistogram {
    static let minimumDBFS = -120.0
    static let binWidthDB = 0.25
    /// One bin per 0.25 dB from -120 dBFS up to 0 dBFS, plus a final bin holding
    /// everything at or above full scale.
    static let binCount = Int(-minimumDBFS / binWidthDB) + 1

    static func binIndex(for magnitude: Double) -> Int {
        guard magnitude > 0, magnitude.isFinite else { return 0 }
        let dbfs = 20 * log10(magnitude)
        guard dbfs > minimumDBFS else { return 0 }
        guard dbfs < 0 else { return binCount - 1 }
        let index = Int((dbfs - minimumDBFS) / binWidthDB)
        return min(max(index, 0), binCount - 1)
    }

    /// The amplitude below which `percentile` of samples fall, reported as the top
    /// edge of the containing bin so the result never understates the level.
    static func amplitude(
        atPercentile percentile: Double,
        histogram: [Int64],
        sampleCount: Int64,
        peak: Double
    ) -> Double {
        guard sampleCount > 0, (0...1).contains(percentile), !histogram.isEmpty else {
            return 0
        }
        let target = Int64((Double(sampleCount) * percentile).rounded(.up))
        var cumulative: Int64 = 0
        for (index, count) in histogram.enumerated() {
            cumulative += count
            guard cumulative >= target else { continue }
            let upperEdgeDBFS = minimumDBFS + Double(index + 1) * binWidthDB
            let amplitude = pow(10.0, upperEdgeDBFS / 20.0)
            // The true peak is the hard ceiling; a bin edge must never exceed it.
            return min(amplitude, peak)
        }
        return peak
    }
}

/// Holds output below a ceiling by ducking gain around transients, instead of
/// paying for those transients with level across the whole recording.
///
/// Attack is immediate and release is exponential. There is no look-ahead, so the
/// leading sample of a very sharp transient can still reach the safety clamp — that
/// costs a single sample, where the previous absolute-peak gain policy gave up
/// several decibels across the entire take.
struct PeakLimiter {
    /// Kept below full scale so lossy-codec overshoot on decode still lands under 0 dBFS.
    static let defaultCeiling: Float = 0.89

    private let ceiling: Float
    private let releaseCoefficient: Float
    private(set) var currentGain: Float = 1

    init(
        ceiling: Float = PeakLimiter.defaultCeiling,
        releaseSeconds: Double = 0.03,
        sampleRate: Double = 48_000
    ) {
        self.ceiling = ceiling
        let releaseSamples = max(1.0, releaseSeconds * max(sampleRate, 1))
        self.releaseCoefficient = Float(exp(-1.0 / releaseSamples))
    }

    mutating func process(_ samples: UnsafeMutablePointer<Float>, count: Int) {
        guard count > 0 else { return }
        for index in 0..<count {
            let magnitude = abs(samples[index])
            if magnitude * currentGain > ceiling {
                currentGain = ceiling / magnitude
            } else {
                currentGain += (1 - currentGain) * (1 - releaseCoefficient)
            }
            samples[index] = min(max(samples[index] * currentGain, -0.98), 0.98)
        }
    }
}
