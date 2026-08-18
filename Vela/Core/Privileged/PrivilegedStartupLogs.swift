import Foundation
import VelaIPC

nonisolated enum PrivilegedStartupLogMapper {
    static let pageSize = 128

    static func processOutputs(
        from entries: [HelperLogEntry]
    ) -> [MihomoProcessOutput] {
        bounded(entries).map { entry in
            MihomoProcessOutput(
                id: UUID(),
                channel: processChannel(entry.channel),
                text: entry.message,
                timestamp: entry.timestamp
            )
        }
    }

    static func logEntries(
        from entries: [HelperLogEntry],
        sessionID: UUID = UUID()
    ) -> [LogEntry] {
        let redactor = SensitiveTextRedactor(context: .log)
        return bounded(entries).map { entry in
            let channel = processChannel(entry.channel)
            return LogEntry(
                timestamp: entry.timestamp,
                level: LogLevel(processMessage: entry.message, channel: channel),
                source: channel == .stdout ? .mihomoStdout : .mihomoStderr,
                message: redactor.redact(entry.message),
                eventIdentity: LogEventIdentity(
                    sessionID: sessionID,
                    source: channel == .stdout ? .mihomoStdout : .mihomoStderr,
                    sequence: entry.sequence
                ),
                redactionState: .verifiedRedacted
            )
        }
    }

    private static func bounded(_ entries: [HelperLogEntry]) -> [HelperLogEntry] {
        Array(
            entries
                .sorted { $0.sequence < $1.sequence }
                .prefix(VelaIPCConstants.maximumLogEntryCount)
        )
    }

    private static func processChannel(
        _ channel: String
    ) -> MihomoProcessOutputChannel {
        channel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "stdout"
            ? .stdout
            : .stderr
    }
}

nonisolated enum PrivilegedStartupLogReader {
    static func read(
        client: any PrivilegedHelperClientProtocol,
        sessionID: UUID
    ) async throws -> [HelperLogEntry] {
        var entries: [HelperLogEntry] = []
        var afterSequence: UInt64 = 0
        let maximumPages = (
            VelaIPCConstants.maximumLogEntryCount + PrivilegedStartupLogMapper.pageSize - 1
        ) / PrivilegedStartupLogMapper.pageSize

        for _ in 0..<maximumPages {
            try Task.checkCancellation()
            let response = try await client.readLogBatch(
                ReadLogBatchRequest(
                    sessionID: sessionID,
                    afterSequence: afterSequence,
                    maximumEntries: PrivilegedStartupLogMapper.pageSize
                )
            )
            try Task.checkCancellation()
            let page = response.entries
                .filter { $0.sequence > afterSequence }
                .sorted { $0.sequence < $1.sequence }
            guard !page.isEmpty else { break }
            entries.append(contentsOf: page)
            afterSequence = page[page.count - 1].sequence
            if response.entries.count < PrivilegedStartupLogMapper.pageSize { break }
        }
        return Array(entries.prefix(VelaIPCConstants.maximumLogEntryCount))
    }
}

nonisolated extension LogLevel {
    init(processMessage: String, channel _: MihomoProcessOutputChannel) {
        let normalized = processMessage.lowercased()
        let markers: [(LogLevel, [String])] = [
            (.error, ["level=error", "level=\"error\"", "[error]", " error:"]),
            (.warning, [
                "level=warn", "level=\"warn\"", "level=warning",
                "level=\"warning\"", "[warn]", "[warning]", " warning:",
            ]),
            (.info, ["level=info", "level=\"info\"", "[info]", " info:"]),
            (.debug, ["level=debug", "level=\"debug\"", "[debug]", " debug:"]),
        ]
        if let parsed = markers.first(where: { _, values in
            values.contains { normalized.contains($0) }
        })?.0 {
            self = parsed
        } else {
            self = .unknown
        }
    }
}

nonisolated struct RedactedPrivilegedStartupLog: Codable, Equatable, Sendable {
    let timestamp: Date
    let level: String
    let source: String
    let message: String
}

nonisolated enum DiagnosticsPrivilegedLogExport {
    static func make(
        entries: [LogEntry],
        include: Bool
    ) -> [RedactedPrivilegedStartupLog]? {
        guard include else { return nil }
        let redactor = SensitiveTextRedactor(context: .log)
        return entries.prefix(VelaIPCConstants.maximumLogEntryCount).map { entry in
            RedactedPrivilegedStartupLog(
                timestamp: entry.timestamp,
                level: entry.level.rawValue,
                source: entry.source.rawValue,
                message: redactor.redact(entry.message)
            )
        }
    }
}
