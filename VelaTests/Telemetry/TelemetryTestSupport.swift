import Foundation
import Synchronization
@testable import Vela

nonisolated enum Sprint2TelemetryTestError: Error, Equatable, Sendable {
    case endOfMessages
}

final class Sprint2TelemetryConnectionStub: TelemetryWebSocketConnection, Sendable {
    private struct State: Sendable {
        var messages: [TelemetryWebSocketMessage]
        var closed = false
        var closeInvocations = 0
    }

    private enum ReceiveAction: Sendable {
        case message(TelemetryWebSocketMessage)
        case end
        case wait
    }

    private let state: Mutex<State>
    private let endsAfterMessages: Bool

    init(
        messages: [TelemetryWebSocketMessage] = [],
        endsAfterMessages: Bool = true
    ) {
        state = Mutex(State(messages: messages))
        self.endsAfterMessages = endsAfterMessages
    }

    func receive() async throws -> TelemetryWebSocketMessage {
        let action = state.withLock { value -> ReceiveAction in
            if !value.messages.isEmpty {
                return .message(value.messages.removeFirst())
            }
            return endsAfterMessages ? .end : .wait
        }

        switch action {
        case let .message(message):
            return message
        case .end:
            throw Sprint2TelemetryTestError.endOfMessages
        case .wait:
            break
        }

        while !state.withLock({ $0.closed }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CancellationError()
    }

    func close() async {
        state.withLock { value in
            guard !value.closed else { return }
            value.closed = true
            value.closeInvocations += 1
        }
    }

    func closeCount() -> Int {
        state.withLock { $0.closeInvocations }
    }
}

final class Sprint2TelemetryTransportStub: TelemetryWebSocketTransporting, Sendable {
    private let connection: any TelemetryWebSocketConnection
    private let requests = Mutex<[URLRequest]>([])

    init(connection: any TelemetryWebSocketConnection) {
        self.connection = connection
    }

    func connect(request: URLRequest) async throws -> any TelemetryWebSocketConnection {
        requests.withLock { $0.append(request) }
        return connection
    }

    func recordedRequests() -> [URLRequest] {
        requests.withLock { $0 }
    }
}

nonisolated enum Sprint2TelemetryTestSupport {
    static func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }
}
