import Foundation

nonisolated enum TelemetryWebSocketMessage: Equatable, Sendable {
    case data(Data)
    case string(String)

    var data: Data {
        switch self {
        case let .data(data):
            data
        case let .string(string):
            Data(string.utf8)
        }
    }
}

nonisolated protocol TelemetryWebSocketConnection: Sendable {
    func receive() async throws -> TelemetryWebSocketMessage
    func close() async
}

nonisolated protocol TelemetryWebSocketTransporting: Sendable {
    func connect(request: URLRequest) async throws -> any TelemetryWebSocketConnection
}

nonisolated struct URLSessionWebSocketTransport: TelemetryWebSocketTransporting, Sendable {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func connect(request: URLRequest) async throws -> any TelemetryWebSocketConnection {
        let task = session.webSocketTask(with: request)
        task.resume()
        return URLSessionTelemetryWebSocketConnection(task: task, session: session)
    }
}

private actor URLSessionTelemetryWebSocketConnection: TelemetryWebSocketConnection {
    private let task: URLSessionWebSocketTask
    private let session: URLSession
    private var isClosed = false

    init(task: URLSessionWebSocketTask, session: URLSession) {
        self.task = task
        self.session = session
    }

    func receive() async throws -> TelemetryWebSocketMessage {
        guard !isClosed else {
            throw URLError(.cancelled)
        }

        switch try await task.receive() {
        case let .data(data):
            return .data(data)
        case let .string(string):
            return .string(string)
        @unknown default:
            throw MihomoTelemetryError.unsupportedWebSocketMessage
        }
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        task.cancel(with: .goingAway, reason: nil)
        _ = session
    }
}
