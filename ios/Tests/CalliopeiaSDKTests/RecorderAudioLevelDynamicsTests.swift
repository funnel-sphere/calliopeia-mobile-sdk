import Foundation
import Testing
@testable import CalliopeiaSDK
private typealias AudioExporter = CalliopeiaAudioExporter

@Suite struct AudioLevelDynamicsTests {
    private func histogram(of magnitudes: [Double]) -> [Int64] {
        var bins = [Int64](repeating: 0, count: AudioLevelHistogram.binCount)
        for magnitude in magnitudes {
            bins[AudioLevelHistogram.binIndex(for: magnitude)] += 1
        }
        return bins
    }

    @Test func histogramPercentileIgnoresAnIsolatedTransient() {
        // 999 samples of speech-level material plus one full-scale knock.
        var magnitudes = [Double](repeating: 0.05, count: 999)
        magnitudes.append(0.98)

        let headroom = AudioLevelHistogram.amplitude(
            atPercentile: 0.999,
            histogram: histogram(of: magnitudes),
            sampleCount: Int64(magnitudes.count),
            peak: 0.98
        )

        // Within one bin (0.25 dB) of the sustained level, not the transient.
        #expect(headroom > 0.05 * pow(10.0, -0.25 / 20.0))
        #expect(headroom < 0.05 * pow(10.0, 0.25 / 20.0))
    }

    @Test func histogramPercentileNeverExceedsTheTruePeak() {
        let magnitudes = [Double](repeating: 0.4, count: 100)
        let headroom = AudioLevelHistogram.amplitude(
            atPercentile: 0.999,
            histogram: histogram(of: magnitudes),
            sampleCount: 100,
            peak: 0.4
        )
        #expect(headroom <= 0.4)
    }

    @Test func histogramHandlesSilenceAndEmptyInput() {
        #expect(
            AudioLevelHistogram.amplitude(
                atPercentile: 0.999,
                histogram: histogram(of: [0, 0, 0]),
                sampleCount: 3,
                peak: 0
            ) == 0
        )
        #expect(
            AudioLevelHistogram.amplitude(
                atPercentile: 0.999,
                histogram: [],
                sampleCount: 0,
                peak: 0.5
            ) == 0
        )
    }

    @Test func transientNoLongerHoldsDownTheGainOfAQuietTake() {
        // Measured from recording C on the target iPhone: speech near -37 dBFS with
        // a single -1.13 dBFS knock that previously pinned the gain at unity.
        let quietSpeech = pow(10.0, -36.06 / 20.0)
        let knock = pow(10.0, -1.13 / 20.0)
        let headroom = pow(10.0, -13.22 / 20.0)

        let beforeFix = AudioExporter.AudioMetrics(
            sampleCount: 513_600,
            sampleRate: 48_000,
            rms: quietSpeech,
            peak: knock
        )
        let afterFix = AudioExporter.AudioMetrics(
            sampleCount: 513_600,
            sampleRate: 48_000,
            rms: quietSpeech,
            peak: knock,
            headroomPeak: headroom
        )

        let gainBefore = AudioGainPolicy.playbackGain(for: beforeFix, referenceInput: beforeFix)
        let gainAfter = AudioGainPolicy.playbackGain(for: afterFix, referenceInput: afterFix)
        let improvementDB = 20 * log10(Double(gainAfter) / Double(gainBefore))

        #expect(gainAfter > gainBefore)
        #expect(improvementDB > 10)
    }

    @Test func metricsFallBackToAbsolutePeakWhenNoPercentileMeasured() {
        let metrics = AudioExporter.AudioMetrics(
            sampleCount: 100,
            sampleRate: 48_000,
            rms: 0.05,
            peak: 0.5
        )
        #expect(metrics.gainReferencePeak == 0.5)
    }

    @Test func limiterHoldsOutputUnderTheCeiling() {
        var limiter = PeakLimiter(sampleRate: 48_000)
        var samples = [Float](repeating: 0.2, count: 4_096)
        // A burst that would clip hard without limiting.
        for index in 1_000..<1_050 {
            samples[index] = 3.5
        }
        samples.withUnsafeMutableBufferPointer { buffer in
            limiter.process(buffer.baseAddress!, count: buffer.count)
        }

        #expect((samples.map(abs).max() ?? 0) <= 0.98)
        // Only the leading sample of the burst may reach the safety clamp.
        #expect(samples[1_010] <= PeakLimiter.defaultCeiling + 0.000_01)
    }

    @Test func limiterLeavesQuietMaterialUntouched() {
        var limiter = PeakLimiter(sampleRate: 48_000)
        let original = (0..<2_048).map { Float(0.1 * sin(Double($0) * 0.01)) }
        var samples = original
        samples.withUnsafeMutableBufferPointer { buffer in
            limiter.process(buffer.baseAddress!, count: buffer.count)
        }
        for (before, after) in zip(original, samples) {
            #expect(abs(before - after) < 0.000_01)
        }
    }

    @Test func exportLeavesHeadroomForLossyCodecOvershoot() {
        // Measured on device: a track mastered to the old 0.92 ceiling decoded back
        // at +1.39 dBFS, i.e. clipped on playback.
        #expect(AudioGainPolicy.maximumPeak <= 0.86)
        #expect(PeakLimiter.defaultCeiling < 1.0)
        let ceilingDB = 20 * log10(Double(PeakLimiter.defaultCeiling))
        #expect(ceilingDB <= -1.0)
    }

    @Test func limiterRecoversGainAfterATransient() {
        var limiter = PeakLimiter(sampleRate: 48_000)
        var burst: [Float] = [3.0]
        burst.withUnsafeMutableBufferPointer { buffer in
            limiter.process(buffer.baseAddress!, count: buffer.count)
        }
        let duckedGain = limiter.currentGain
        #expect(duckedGain < 1)

        // 300 ms of quiet material at a 30 ms release must restore unity.
        var tail = [Float](repeating: 0.05, count: 14_400)
        tail.withUnsafeMutableBufferPointer { buffer in
            limiter.process(buffer.baseAddress!, count: buffer.count)
        }
        #expect(limiter.currentGain > 0.99)
    }
}
