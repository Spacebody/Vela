nonisolated struct ProxyLatencyPresentation: Sendable {
    static let goodUpperBoundMilliseconds: UInt16 = 200
    static let mediumUpperBoundMilliseconds: UInt16 = 500

    let state: VelaLatencyState
    let milliseconds: Int?
    let diagnostic: String?

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
