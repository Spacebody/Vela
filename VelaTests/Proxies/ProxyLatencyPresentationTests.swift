import Testing
@testable import Vela

@Suite("Proxy latency presentation")
struct ProxyLatencyPresentationTests {
    @Test("Measured delays use stable visual thresholds")
    func measuredDelayThresholds() {
        let good = ProxyLatencyPresentation(
            sessionState: .measured(milliseconds: 199),
            catalogDelay: .untested
        )
        let mediumLowerBound = ProxyLatencyPresentation(
            sessionState: .measured(milliseconds: 200),
            catalogDelay: .untested
        )
        let mediumUpperBound = ProxyLatencyPresentation(
            sessionState: .measured(milliseconds: 499),
            catalogDelay: .untested
        )
        let slow = ProxyLatencyPresentation(
            sessionState: .measured(milliseconds: 500),
            catalogDelay: .untested
        )

        #expect(good.state == .good)
        #expect(good.milliseconds == 199)
        #expect(mediumLowerBound.state == .medium)
        #expect(mediumUpperBound.state == .medium)
        #expect(slow.state == .slow)
        #expect(slow.milliseconds == 500)
    }

    @Test("Session test state remains authoritative over catalog delay")
    func sessionStateWins() {
        let catalogDelay = ProxyDelay.measured(milliseconds: 72)
        let testing = ProxyLatencyPresentation(
            sessionState: .testing,
            catalogDelay: catalogDelay
        )
        let unavailable = ProxyLatencyPresentation(
            sessionState: .unavailable,
            catalogDelay: catalogDelay
        )
        let failed = ProxyLatencyPresentation(
            sessionState: .failed("timeout"),
            catalogDelay: catalogDelay
        )

        #expect(testing.state == .testing)
        #expect(testing.milliseconds == nil)
        #expect(unavailable.state == .failed)
        #expect(unavailable.milliseconds == nil)
        #expect(failed.state == .failed)
        #expect(failed.diagnostic == "timeout")
    }

    @Test("Catalog delay supplies unknown, failed, and measured fallback states")
    func catalogFallbackStates() {
        let unknown = ProxyLatencyPresentation(
            sessionState: nil,
            catalogDelay: .untested
        )
        let failed = ProxyLatencyPresentation(
            sessionState: nil,
            catalogDelay: .unavailable
        )
        let measured = ProxyLatencyPresentation(
            sessionState: nil,
            catalogDelay: .measured(milliseconds: 241)
        )

        #expect(unknown.state == .unknown)
        #expect(failed.state == .failed)
        #expect(measured.state == .medium)
        #expect(measured.milliseconds == 241)
    }

    @Test("Display text covers every latency state")
    func displayTextCoversEveryState() {
        let measurement = VelaL10n.string(
            "latency.measurement.millisecondsFormat",
            defaultValue: "%lld ms",
            arguments: Int64(241)
        )

        #expect(ProxyLatencyPresentation.displayText(state: .unknown, milliseconds: nil) == "—")
        #expect(ProxyLatencyPresentation.displayText(state: .testing, milliseconds: nil) == VelaLatencyState.testing.label)
        #expect(ProxyLatencyPresentation.displayText(state: .good, milliseconds: 241) == measurement)
        #expect(ProxyLatencyPresentation.displayText(state: .medium, milliseconds: 241) == measurement)
        #expect(ProxyLatencyPresentation.displayText(state: .slow, milliseconds: 241) == measurement)
        #expect(ProxyLatencyPresentation.displayText(state: .failed, milliseconds: nil) == VelaLatencyState.failed.label)
        #expect(ProxyLatencyPresentation.displayText(state: .good, milliseconds: nil) == "—")
    }

    @Test("Signal strength covers every latency state")
    func signalStrengthCoversEveryState() {
        #expect(ProxyLatencyPresentation.signalStrength(for: .unknown) == 1)
        #expect(ProxyLatencyPresentation.signalStrength(for: .testing) == 2)
        #expect(ProxyLatencyPresentation.signalStrength(for: .good) == 4)
        #expect(ProxyLatencyPresentation.signalStrength(for: .medium) == 3)
        #expect(ProxyLatencyPresentation.signalStrength(for: .slow) == 2)
        #expect(ProxyLatencyPresentation.signalStrength(for: .failed) == 1)
    }
}
