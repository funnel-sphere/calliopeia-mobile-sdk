#if os(iOS)
import AVFoundation
import Foundation

/// Microphone directionality, ordered by how much off-axis sound it rejects.
///
/// A directional pickup raises the *acoustic* signal-to-noise ratio before any
/// enhancement runs, so it improves both listening clarity and downstream
/// transcription. Neural denoising, by contrast, can only reshape a signal that
/// already contains the noise.
enum MicrophonePolarPattern: String, CaseIterable, Equatable {
    case cardioid
    case subcardioid
    case omnidirectional
    case stereo

    /// Higher rejects more off-axis noise. `stereo` ranks lowest because the
    /// recorder downmixes to mono, which discards its spatial advantage.
    var offAxisRejectionRank: Int {
        switch self {
        case .cardioid: return 3
        case .subcardioid: return 2
        case .omnidirectional: return 1
        case .stereo: return 0
        }
    }

    init?(platformRawValue: String) {
        switch platformRawValue {
        case AVAudioSession.PolarPattern.cardioid.rawValue: self = .cardioid
        case AVAudioSession.PolarPattern.subcardioid.rawValue: self = .subcardioid
        case AVAudioSession.PolarPattern.omnidirectional.rawValue: self = .omnidirectional
        case AVAudioSession.PolarPattern.stereo.rawValue: self = .stereo
        default: return nil
        }
    }

    var platformPattern: AVAudioSession.PolarPattern {
        switch self {
        case .cardioid: return .cardioid
        case .subcardioid: return .subcardioid
        case .omnidirectional: return .omnidirectional
        case .stereo: return .stereo
        }
    }
}

/// One selectable built-in microphone and the patterns it offers.
struct CaptureRouteOption: Equatable {
    let dataSourceID: Int
    let name: String
    let supportedPatterns: [MicrophonePolarPattern]
}

/// The microphone configuration the policy wants to apply.
struct CaptureRouteChoice: Equatable {
    let dataSourceID: Int
    let name: String
    let pattern: MicrophonePolarPattern
}

/// Picks the most directional microphone configuration the hardware offers.
enum CaptureRoutePolicy {
    /// Returns `nil` when no option exposes a selectable pattern, which means the
    /// current route is already the only choice and must be left untouched.
    static func choose(from options: [CaptureRouteOption]) -> CaptureRouteChoice? {
        var best: CaptureRouteChoice?
        var bestRank = Int.min

        // Iterating in the order iOS reports keeps the choice stable and lets the
        // system's own ordering break ties between equally directional options.
        for option in options {
            for pattern in option.supportedPatterns
            where pattern.offAxisRejectionRank > bestRank {
                bestRank = pattern.offAxisRejectionRank
                best = CaptureRouteChoice(
                    dataSourceID: option.dataSourceID,
                    name: option.name,
                    pattern: pattern
                )
            }
        }

        // Omnidirectional is what the route already defaults to, so selecting it
        // would churn the route without improving rejection.
        guard let best, best.pattern.offAxisRejectionRank > MicrophonePolarPattern.omnidirectional.offAxisRejectionRank else {
            return nil
        }
        return best
    }
}

/// What the device actually offered and what was applied, recorded alongside each
/// take so route behaviour can be audited from a real recording afterwards.
public struct CaptureRouteReport: Codable, Equatable, Sendable {
    public var availableDataSources: [String]
    public var supportedPatternsByDataSource: [String: [String]]
    public var appliedDataSource: String?
    public var appliedPattern: String?
    public var failureDescription: String?
    /// True when the route already matched the policy and was left untouched.
    public var alreadySelected: Bool = false

    public var didApplyDirectionalPickup: Bool { appliedPattern != nil }

    public static let unavailable = CaptureRouteReport(
        availableDataSources: [],
        supportedPatternsByDataSource: [:],
        appliedDataSource: nil,
        appliedPattern: nil,
        failureDescription: nil,
        alreadySelected: false
    )
}

/// Applies the directional-pickup policy to the shared audio session.
///
/// Must be called while the session is active and configured for recording:
/// `supportedPolarPatterns` is only populated once a route is established, and it
/// varies by device *and* session mode, so the outcome is always probed at runtime
/// rather than assumed.
enum CaptureRouteOptimizer {
    @discardableResult
    static func applyDirectionalPickup(
        session: AVAudioSession = .sharedInstance()
    ) -> CaptureRouteReport {
        guard let port = session.currentRoute.inputs.first ?? session.availableInputs?.first else {
            return .unavailable
        }
        guard let dataSources = port.dataSources, !dataSources.isEmpty else {
            return .unavailable
        }

        var options: [CaptureRouteOption] = []
        var patternsByName: [String: [String]] = [:]
        for source in dataSources {
            let patterns = (source.supportedPolarPatterns ?? []).compactMap {
                MicrophonePolarPattern(platformRawValue: $0.rawValue)
            }
            patternsByName[source.dataSourceName] = patterns.map(\.rawValue)
            options.append(
                CaptureRouteOption(
                    dataSourceID: source.dataSourceID.intValue,
                    name: source.dataSourceName,
                    supportedPatterns: patterns
                )
            )
        }

        var report = CaptureRouteReport(
            availableDataSources: dataSources.map(\.dataSourceName),
            supportedPatternsByDataSource: patternsByName,
            appliedDataSource: nil,
            appliedPattern: nil,
            failureDescription: nil,
            alreadySelected: false
        )

        guard let choice = CaptureRoutePolicy.choose(from: options) else {
            return report
        }
        guard let source = dataSources.first(where: {
            $0.dataSourceID.intValue == choice.dataSourceID
        }) else {
            return report
        }

        // This runs once capture is already under way, so switching the route can
        // disturb the opening moments of a take. iOS frequently selects the
        // directional pickup on its own, and in that case there is nothing to gain
        // by touching it.
        if session.inputDataSource?.dataSourceID == source.dataSourceID,
           source.selectedPolarPattern == choice.pattern.platformPattern {
            report.appliedDataSource = source.dataSourceName
            report.appliedPattern = choice.pattern.rawValue
            report.alreadySelected = true
            return report
        }

        // Any failure here leaves the default route in place; a recording with
        // omnidirectional pickup is far better than a recording that never starts.
        do {
            try source.setPreferredPolarPattern(choice.pattern.platformPattern)
            try session.setPreferredInput(port)
            try session.setInputDataSource(source)
            report.appliedDataSource = source.dataSourceName
            report.appliedPattern = choice.pattern.rawValue
        } catch {
            report.failureDescription = String(describing: error)
        }
        return report
    }
}

#endif
