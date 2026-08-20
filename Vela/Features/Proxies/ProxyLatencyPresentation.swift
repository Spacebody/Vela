nonisolated struct ProxyLatencyPresentation: Sendable {
    static let goodUpperBoundMilliseconds: UInt16 = 200
    static let mediumUpperBoundMilliseconds: UInt16 = 500

    let state: VelaLatencyState
    let milliseconds: Int?
    let diagnostic: String?

    static func displayText(
        state: VelaLatencyState,
        milliseconds: Int?
    ) -> String {
        switch state {
        case .testing, .failed:
            return state.label
        case .good, .medium, .slow:
            guard let milliseconds else { return "—" }
            return VelaL10n.string(
                "latency.measurement.millisecondsFormat",
                defaultValue: "%lld ms",
                arguments: Int64(milliseconds)
            )
        case .unknown:
            return "—"
        }
    }

    static func signalStrength(for state: VelaLatencyState) -> Int {
        switch state {
        case .good:
            4
        case .medium:
            3
        case .slow, .testing:
            2
        case .unknown, .failed:
            1
        }
    }

    init(sessionState: ProxyDelayState?, catalogDelay: ProxyDelay) {
        switch sessionState {
        case .testing:
            self.init(state: .testing)
        case let .measured(milliseconds):
            self.init(measuredMilliseconds: milliseconds)
        case .unavailable:
            self.init(state: .failed)
        case let .failed(message):
            self.init(state: .failed, diagnostic: message)
        case nil:
            switch catalogDelay {
            case .untested:
                self.init(state: .unknown)
            case .unavailable:
                self.init(state: .failed)
            case let .measured(milliseconds):
                self.init(measuredMilliseconds: milliseconds)
            }
        }
    }

    private init(measuredMilliseconds: UInt16) {
        let state: VelaLatencyState
        if measuredMilliseconds < Self.goodUpperBoundMilliseconds {
            state = .good
        } else if measuredMilliseconds < Self.mediumUpperBoundMilliseconds {
            state = .medium
        } else {
            state = .slow
        }
        self.init(state: state, milliseconds: Int(measuredMilliseconds))
    }

    private init(
        state: VelaLatencyState,
        milliseconds: Int? = nil,
        diagnostic: String? = nil
    ) {
        self.state = state
        self.milliseconds = milliseconds
        self.diagnostic = diagnostic
    }
}
