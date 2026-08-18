import Foundation

nonisolated enum LogsCollectionPhase: Equatable, Sendable {
    case loading
    case live
    case reconnecting
    case paused(newCount: Int)
    case stale
    case failureWithBuffer(String)
    case fullFailure(String)
    case empty
}

nonisolated struct LogsFilterSelection: Equatable, Sendable {
    var levels: Set<LogLevel> = Set(LogLevel.allCases)
    var sources: Set<LogSource> = Set(LogSource.allCases)
    var query = ""

    var isActive: Bool {
        levels != Set(LogLevel.allCases)
            || sources != Set(LogSource.allCases)
            || !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func includes(_ entry: LogEntry) -> Bool {
        guard levels.contains(entry.level), sources.contains(entry.source) else {
            return false
        }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }
        return entry.message.localizedCaseInsensitiveContains(needle)
            || entry.category.localizedCaseInsensitiveContains(needle)
            || entry.eventCode?.localizedCaseInsensitiveContains(needle) == true
            || entry.source.rawValue.localizedCaseInsensitiveContains(needle)
            || entry.level.rawValue.localizedCaseInsensitiveContains(needle)
    }
}

nonisolated struct LogPresentationRow: Identifiable, Equatable, Sendable {
    let entry: LogEntry

    var id: String {
        entry.eventIdentity?.stableValue ?? "legacy:\(entry.id.uuidString.lowercased())"
    }

    var sessionID: UUID? { entry.eventIdentity?.sessionID }
    var sequence: UInt64? { entry.eventIdentity?.sequence }
    var source: LogSource { entry.source }
    var level: LogLevel { entry.level }
    var timestamp: Date { entry.timestamp }
    var category: String { entry.category }
    var eventCode: String? { entry.eventCode }
    var message: String { entry.message }

    var copyableText: String {
        let code = eventCode.map { " [\($0)]" } ?? ""
        return "[\(timestamp.formatted(.iso8601))] [\(level.rawValue)] [\(source.rawValue)]\(code) \(message)"
    }
}

nonisolated struct LogsPresentationSnapshot: Equatable, Sendable {
    let phase: LogsCollectionPhase
    let rows: [LogPresentationRow]
    let visibleRows: [LogPresentationRow]
    let totalCount: Int
    let newCount: Int
    let discardedCountLowerBound: UInt64
    let currentSessionID: UUID?
    let lastEventAt: Date?
    let filter: LogsFilterSelection

    var hasFilteredEmptyState: Bool {
        rows.isEmpty == false && visibleRows.isEmpty && filter.isActive
    }

    var selectedSessionCount: Int {
        Set(rows.compactMap(\.sessionID)).count
    }

    init(
        entries: [LogEntry],
        filter: LogsFilterSelection,
        controllerState: ControllerConnectionState,
        isRuntimeRunning: Bool,
        isLoading: Bool = false,
        isPaused: Bool = false,
        newCount: Int = 0
    ) {
        let rows = entries.map(LogPresentationRow.init)
        self.rows = rows
        visibleRows = rows.filter { filter.includes($0.entry) }
        totalCount = rows.count
        self.newCount = max(newCount, 0)
        discardedCountLowerBound = Self.discardedCountLowerBound(in: rows)
        currentSessionID = rows.last?.sessionID
        lastEventAt = rows.last?.timestamp
        self.filter = filter
        phase = Self.resolvePhase(
            controllerState: controllerState,
            isRuntimeRunning: isRuntimeRunning,
            hasRows: !rows.isEmpty,
            isLoading: isLoading,
            isPaused: isPaused,
            newCount: newCount
        )
    }

    private static func resolvePhase(
        controllerState: ControllerConnectionState,
        isRuntimeRunning: Bool,
        hasRows: Bool,
        isLoading: Bool,
        isPaused: Bool,
        newCount: Int
    ) -> LogsCollectionPhase {
        if isLoading { return .loading }
        if isPaused { return .paused(newCount: max(newCount, 0)) }
        switch controllerState {
        case .connected:
            return hasRows ? .live : .empty
        case .connecting:
            return .reconnecting
        case let .unavailable(message):
            return hasRows ? .failureWithBuffer(message) : .fullFailure(message)
        case .disconnected:
            if hasRows { return .stale }
            return isRuntimeRunning ? .reconnecting : .empty
        }
    }

    private static func discardedCountLowerBound(in rows: [LogPresentationRow]) -> UInt64 {
        let bySession = Dictionary(grouping: rows.compactMap { row -> (UUID, UInt64)? in
            guard let sessionID = row.sessionID, let sequence = row.sequence else { return nil }
            return (sessionID, sequence)
        }, by: \.0)
        return bySession.values.reduce(0) { result, identities in
            guard let first = identities.map(\.1).min(), first > 1 else { return result }
            return result &+ (first - 1)
        }
    }
}

nonisolated struct LogsPauseSnapshot: Equatable, Sendable {
    let entries: [LogEntry]
    private let stableIDs: Set<String>

    init(entries: [LogEntry]) {
        self.entries = entries
        stableIDs = Set(entries.map { LogPresentationRow(entry: $0).id })
    }

    func newEntryCount(in liveEntries: [LogEntry]) -> Int {
        liveEntries.reduce(into: 0) { count, entry in
            if !stableIDs.contains(LogPresentationRow(entry: entry).id) {
                count += 1
            }
        }
    }
}

nonisolated struct LogsGenerationGate: Equatable, Sendable {
    private(set) var generation: UInt64 = 0

    mutating func begin() -> UInt64 {
        generation &+= 1
        return generation
    }

    func accepts(_ candidate: UInt64) -> Bool {
        candidate == generation
    }
}

nonisolated struct LogsLayoutMetrics: Equatable, Sendable {
    let usesOverlayInspector: Bool
    let inspectorWidth: CGFloat
    let searchMinimumWidth: CGFloat
    let searchMaximumWidth: CGFloat
    let timeColumnWidth: CGFloat
    let sourceColumnWidth: CGFloat
    let levelColumnWidth: CGFloat

    static func resolve(contentWidth: CGFloat) -> Self {
        if contentWidth < 1_120 {
            return Self(
                usesOverlayInspector: true,
                inspectorWidth: 300,
                searchMinimumWidth: 160,
                searchMaximumWidth: 240,
                timeColumnWidth: 92,
                sourceColumnWidth: 104,
                levelColumnWidth: 80
            )
        }
        return Self(
            usesOverlayInspector: false,
            inspectorWidth: 300,
            searchMinimumWidth: 210,
            searchMaximumWidth: 320,
            timeColumnWidth: 120,
            sourceColumnWidth: 140,
            levelColumnWidth: 100
        )
    }
}

nonisolated struct LogExportMetadata: Encodable, Equatable, Sendable {
    let recordType = "metadata"
    let schemaVersion = "vela.logs.jsonl.v1"
    let redactionSchemaVersion = LogEventClassifier.redactionSchemaVersion
    let exportedAt: Date
    let totalCount: Int
    let discardedCountLowerBound: UInt64
    let sessionIDs: [UUID]
    let sourceFilters: [String]
    let levelFilters: [String]
    let queryWasApplied: Bool
    let snapshotWasStale: Bool
}

nonisolated struct LogExportRecord: Encodable, Equatable, Sendable {
    let recordType = "event"
    let identity: String
    let sessionID: UUID?
    let sequence: UInt64?
    let timestamp: Date
    let level: String
    let source: String
    let category: String
    let eventCode: String?
    let message: String
    let redactionState: String

    init(row: LogPresentationRow) {
        identity = row.id
        sessionID = row.sessionID
        sequence = row.sequence
        timestamp = row.timestamp
        level = row.level.rawValue
        source = row.source.rawValue
        category = row.category
        eventCode = row.eventCode
        message = SensitiveTextRedactor(context: .log).redact(row.message)
        redactionState = LogRedactionState.verifiedRedacted.rawValue
    }
}

actor LogJSONLExportWriter {
    enum ExportError: Error {
        case couldNotCreateTemporaryFile
    }

    func write(
        snapshot: LogsPresentationSnapshot,
        to destination: URL,
        exportedAt: Date = .now
    ) async throws {
        let fileManager = FileManager.default
        let directory = destination.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).tmp"
        )
        let metadata = LogExportMetadata(
            exportedAt: exportedAt,
            totalCount: snapshot.visibleRows.count,
            discardedCountLowerBound: snapshot.discardedCountLowerBound,
            sessionIDs: Array(Set(snapshot.visibleRows.compactMap(\.sessionID))).sorted {
                $0.uuidString < $1.uuidString
            },
            sourceFilters: snapshot.filter.sources.map(\.rawValue).sorted(),
            levelFilters: snapshot.filter.levels.map(\.rawValue).sorted(),
            queryWasApplied: !snapshot.filter.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            snapshotWasStale: snapshot.phase == .stale
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        guard fileManager.createFile(atPath: temporary.path, contents: nil) else {
            throw ExportError.couldNotCreateTemporaryFile
        }
        do {
            let handle = try FileHandle(forWritingTo: temporary)
            defer { try? handle.close() }
            try await writeLine(metadata, encoder: encoder, handle: handle)
            for row in snapshot.visibleRows {
                try Task.checkCancellation()
                try await writeLine(LogExportRecord(row: row), encoder: encoder, handle: handle)
            }
            try Task.checkCancellation()
            try handle.synchronize()
            try handle.close()

            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(
                    destination,
                    withItemAt: temporary,
                    backupItemName: nil,
                    options: .usingNewMetadataOnly
                )
            } else {
                try fileManager.moveItem(at: temporary, to: destination)
            }
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }

    private func writeLine<Value: Encodable>(
        _ value: Value,
        encoder: JSONEncoder,
        handle: FileHandle
    ) async throws {
        var data = try encoder.encode(value)
        data.append(0x0A)
        try handle.write(contentsOf: data)
        await Task.yield()
    }
}
