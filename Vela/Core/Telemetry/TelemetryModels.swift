import Foundation

nonisolated enum LogLevel: String, Codable, CaseIterable, Hashable, Sendable {
    case debug
    case info
    case warning
    case error
    case silent
    case unknown

    init(mihomoValue: String) {
        switch mihomoValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "debug":
            self = .debug
        case "info":
            self = .info
        case "warn", "warning":
            self = .warning
        case "error":
            self = .error
        case "silent":
            self = .silent
        default:
            self = .unknown
        }
    }

    var controllerQueryValue: String? {
        switch self {
        case .debug, .info, .warning, .error, .silent:
            rawValue
        case .unknown:
            nil
        }
    }
}

nonisolated enum LogSource: String, Codable, CaseIterable, Hashable, Sendable {
    case mihomoStdout
    case mihomoStderr
    case controller
    case application
}

nonisolated struct LogEventIdentity: Codable, Equatable, Hashable, Sendable {
    let sessionID: UUID
    let source: LogSource
    let sequence: UInt64

    var stableValue: String {
        "\(sessionID.uuidString.lowercased()):\(source.rawValue):\(sequence)"
    }
}

nonisolated enum LogRedactionState: String, Codable, Equatable, Sendable {
    case pending
    case verifiedRedacted
}

nonisolated struct LogEntry: Identifiable, Equatable, Sendable {
    let id: UUID
    let timestamp: Date
    let level: LogLevel
    let source: LogSource
    let message: String
    let eventIdentity: LogEventIdentity?
    let category: String
    let eventCode: String?
    let redactionState: LogRedactionState

    init(
        id: UUID = UUID(),
        timestamp: Date = .now,
        level: LogLevel,
        source: LogSource,
        message: String,
        eventIdentity: LogEventIdentity? = nil,
        category: String? = nil,
        eventCode: String? = nil,
        redactionState: LogRedactionState = .pending
    ) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.source = source
        self.message = message
        self.eventIdentity = eventIdentity
        self.category = category ?? LogEventClassifier.category(for: source)
        self.eventCode = eventCode
        self.redactionState = redactionState
    }
}

nonisolated enum LogEventClassifier {
    static let redactionSchemaVersion = "vela.log.redaction.v1"

    static func category(for source: LogSource) -> String {
        switch source {
        case .mihomoStdout:
            "process.stdout"
        case .mihomoStderr:
            "process.stderr"
        case .controller:
            "controller.stream"
        case .application:
            "application.runtime"
        }
    }

    static func eventCode(for source: LogSource, message: String) -> String? {
        guard source == .application else { return nil }
        if message.hasPrefix("Connecting to the Mihomo controller") {
            return "controller.connecting"
        }
        if message.hasPrefix("Connected to Mihomo") {
            return "controller.connected"
        }
        if message.hasPrefix("Mihomo controller unavailable") {
            return "controller.unavailable"
        }
        if message.hasPrefix("Controller reconnect") {
            return "controller.reconnecting"
        }
        if message.hasPrefix("Runtime mode changed") {
            return "runtime.mode.changed"
        }
        if message.hasPrefix("Proxy group") {
            return "proxy.selection.changed"
        }
        if message.hasPrefix("Proxy catalog unavailable") {
            return "proxy.catalog.unavailable"
        }
        if message.hasPrefix("Privileged Mihomo startup logs were unavailable") {
            return "privileged.logs.unavailable"
        }
        return "application.event"
    }
}

nonisolated struct TrafficSample: Equatable, Sendable {
    let timestamp: Date
    let uploadBytesPerSecond: Int64
    let downloadBytesPerSecond: Int64
    let totalUploadBytes: Int64
    let totalDownloadBytes: Int64

    init(
        timestamp: Date = .now,
        uploadBytesPerSecond: Int64,
        downloadBytesPerSecond: Int64,
        totalUploadBytes: Int64,
        totalDownloadBytes: Int64
    ) {
        self.timestamp = timestamp
        self.uploadBytesPerSecond = uploadBytesPerSecond
        self.downloadBytesPerSecond = downloadBytesPerSecond
        self.totalUploadBytes = totalUploadBytes
        self.totalDownloadBytes = totalDownloadBytes
    }
}

nonisolated enum MihomoTelemetryError: Error, Equatable, Sendable {
    case invalidControllerURL(URL)
    case unsupportedControllerScheme(String?)
    case unsupportedWebSocketMessage
    case invalidLogPayload
}

extension MihomoTelemetryError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .invalidControllerURL(url):
            "Could not construct a Mihomo telemetry URL from \(url.absoluteString)."
        case let .unsupportedControllerScheme(scheme):
            "Mihomo telemetry requires an HTTP, HTTPS, WS, or WSS controller URL, not \(scheme ?? "no scheme")."
        case .unsupportedWebSocketMessage:
            "The Mihomo controller sent an unsupported WebSocket message."
        case .invalidLogPayload:
            "The Mihomo controller log message did not contain a supported log payload."
        }
    }
}
