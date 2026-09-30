#if os(iOS)
import AVFoundation
import Testing
@testable import CalliopeiaAudioCapture

struct RecorderCaptureRouteTests {
    @Test func captureRoutePolicyPrefersTheMostDirectionalPattern() {
        let choice = CaptureRoutePolicy.choose(from: [
            CaptureRouteOption(
                dataSourceID: 1,
                name: "Bottom",
                supportedPatterns: [.omnidirectional, .subcardioid]
            ),
            CaptureRouteOption(
                dataSourceID: 2,
                name: "Front",
                supportedPatterns: [.omnidirectional, .cardioid]
            ),
        ])

        #expect(choice?.pattern == .cardioid)
        #expect(choice?.dataSourceID == 2)
        #expect(choice?.name == "Front")
    }

    @Test func captureRoutePolicyLeavesRouteAloneWithoutADirectionalOption() {
        // Omnidirectional is already the default, and stereo is downmixed to mono,
        // so neither is worth churning the route for.
        #expect(CaptureRoutePolicy.choose(from: []) == nil)
        #expect(
            CaptureRoutePolicy.choose(from: [
                CaptureRouteOption(dataSourceID: 1, name: "Bottom", supportedPatterns: [])
            ]) == nil
        )
        #expect(
            CaptureRoutePolicy.choose(from: [
                CaptureRouteOption(
                    dataSourceID: 1,
                    name: "Bottom",
                    supportedPatterns: [.omnidirectional, .stereo]
                )
            ]) == nil
        )
    }

    @Test func captureRoutePolicyKeepsTheFirstOfEquallyDirectionalOptions() {
        let choice = CaptureRoutePolicy.choose(from: [
            CaptureRouteOption(dataSourceID: 7, name: "Front", supportedPatterns: [.cardioid]),
            CaptureRouteOption(dataSourceID: 9, name: "Back", supportedPatterns: [.cardioid]),
        ])

        #expect(choice?.dataSourceID == 7)
    }

    @Test func polarPatternBridgesToAndFromPlatformValues() {
        for pattern in MicrophonePolarPattern.allCases {
            let roundTripped = MicrophonePolarPattern(
                platformRawValue: pattern.platformPattern.rawValue
            )
            #expect(roundTripped == pattern)
        }
        #expect(MicrophonePolarPattern(platformRawValue: "NotAPattern") == nil)
    }

    @Test func captureRouteReportDistinguishesAppliedFromDefaultRoute() {
        #expect(!CaptureRouteReport.unavailable.didApplyDirectionalPickup)

        var report = CaptureRouteReport.unavailable
        report.appliedPattern = MicrophonePolarPattern.cardioid.rawValue
        #expect(report.didApplyDirectionalPickup)
    }
}
#endif
