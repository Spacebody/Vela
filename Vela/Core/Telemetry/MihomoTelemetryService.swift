import Foundation

nonisolated protocol MihomoTelemetryStreaming: Sendable {
    func logs(level: LogLevel?) -> AsyncThrowingStream<LogEntry, Error>
    func traffic() -> AsyncThrowingStream<TrafficSample, Error>
}

nonisolated struct MihomoTelemetryService: MihomoTelemetryStreaming, Sendable {
    private let controllerURL: URL
    private let secret: String?
    private let transport: any TelemetryWebSocketTransporting
    private let timestampProvider: @Sendable () -> Date

    init(
        controllerURL: URL,
        secret: String?,
        transport: any TelemetryWebSocketTransporting = URLSessionWebSocketTransport(),
        timestampProvider: @escaping @Sendable () -> Date = { .now }
    ) {
        self.controllerURL = controllerURL
        self.secret = secret
        self.transport = transport
        self.timestampProvider = timestampProvider
    }

    func logs(level: LogLevel? = nil) -> AsyncThrowingStream<LogEntry, Error> {
        do {
            var queryItems: [URLQueryItem] = []
            if let queryValue = level?.controllerQueryValue {
                queryItems.append(URLQueryItem(name: "level", value: queryValue))
            }
            let request = try makeRequest(path: "/logs", queryItems: queryItems)

            return makeStream(
                request: request,
                bufferingPolicy: .bufferingNewest(LogBuffer.maximumCapacity)
            ) { message, receivedAt in
                try Self.decodeLog(message, receivedAt: receivedAt)
            }
        } catch {
            return failedStream(error)
        }
    }

    func traffic() -> AsyncThrowingStream<TrafficSample, Error> {
        do {
            let request = try makeRequest(path: "/traffic")
            return makeStream(
                request: request,
                bufferingPolicy: .bufferingNewest(1)
            ) { message, receivedAt in
                let payload = try JSONDecoder().decode(MihomoTrafficPayload.self, from: message.data)
                return TrafficSample(
                    timestamp: receivedAt,
                    uploadBytesPerSecond: payload.up,
                    downloadBytesPerSecond: payload.down,
                    totalUploadBytes: payload.upTotal,
                    totalDownloadBytes: payload.downTotal
                )
            }
        } catch {
            return failedStream(error)
        }
    }

    private func makeRequest(
        path: String,
        queryItems: [URLQueryItem] = []
    ) throws -> URLRequest {
        guard var components = URLComponents(url: controllerURL, resolvingAgainstBaseURL: false) else {
            throw MihomoTelemetryError.invalidControllerURL(controllerURL)
        }

        switch components.scheme?.lowercased() {
        case "http":
            components.scheme = "ws"
        case "https":
            components.scheme = "wss"
        case "ws", "wss":
            break
        default:
            throw MihomoTelemetryError.unsupportedControllerScheme(components.scheme)
        }

        let basePath = components.path.hasSuffix("/")
            ? String(components.path.dropLast())
            : components.path
        components.path = basePath + path
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        components.fragment = nil

        guard let url = components.url else {
            throw MihomoTelemetryError.invalidControllerURL(controllerURL)
        }

        var request = URLRequest(url: url)
        if let secret, !secret.isEmpty {
            request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func makeStream<Element: Sendable>(
        request: URLRequest,
        bufferingPolicy: AsyncThrowingStream<Element, Error>.Continuation.BufferingPolicy,
        decode: @escaping @Sendable (TelemetryWebSocketMessage, Date) throws -> Element
    ) -> AsyncThrowingStream<Element, Error> {
        let transport = self.transport
        let timestampProvider = self.timestampProvider

        return AsyncThrowingStream(bufferingPolicy: bufferingPolicy) { continuation in
            let lifecycle = TelemetryConnectionLifecycle()
            let worker = Task {
                do {
                    let connection = try await transport.connect(request: request)
                    await lifecycle.install(connection)
                    try Task.checkCancellation()

                    while !Task.isCancelled {
                        let message = try await connection.receive()
                        let value = try decode(message, timestampProvider())
                        continuation.yield(value)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch let error as URLError where error.code == .cancelled && Task.isCancelled {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }

                await lifecycle.close()
            }

            continuation.onTermination = { @Sendable _ in
                worker.cancel()
                Task { await lifecycle.close() }
            }
        }
    }

    private func failedStream<Element: Sendable>(_ error: Error) -> AsyncThrowingStream<Element, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: error)
        }
    }

    private static func decodeLog(
        _ message: TelemetryWebSocketMessage,
        receivedAt: Date
    ) throws -> LogEntry {
        let payload = try JSONDecoder().decode(MihomoLogPayload.self, from: message.data)
        let redactor = SensitiveTextRedactor(context: .log)

        if let type = payload.type, let message = payload.payload {
            return LogEntry(
                timestamp: receivedAt,
                level: LogLevel(mihomoValue: type),
                source: .controller,
                message: redactor.redact(message)
            )
        }

        if let level = payload.level, let message = payload.message {
            return LogEntry(
                timestamp: parseStructuredTimestamp(payload.time) ?? receivedAt,
                level: LogLevel(mihomoValue: level),
                source: .controller,
                message: redactor.redact(message)
            )
        }

        throw MihomoTelemetryError.invalidLogPayload
    }

    private static func parseStructuredTimestamp(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

private actor TelemetryConnectionLifecycle {
    private var connection: (any TelemetryWebSocketConnection)?
    private var isClosed = false

    func install(_ connection: any TelemetryWebSocketConnection) async {
        guard !isClosed else {
            await connection.close()
            return
        }
        self.connection = connection
    }

    func close() async {
        guard !isClosed else { return }
        isClosed = true
        let connection = self.connection
        self.connection = nil
        await connection?.close()
    }
}

nonisolated private struct MihomoLogPayload: Decodable, Sendable {
    let type: String?
    let payload: String?
    let time: String?
    let level: String?
    let message: String?
}

nonisolated private struct MihomoTrafficPayload: Decodable, Sendable {
    let up: Int64
    let down: Int64
    let upTotal: Int64
    let downTotal: Int64
}
