import Foundation

actor LogBuffer {
    nonisolated static let maximumCapacity = 2_000

    private let capacity: Int
    private let redactor: SensitiveTextRedactor
    private var storage: [LogEntry] = []
    private var oldestIndex = 0
    private var sessionID: UUID
    private var nextSequence: UInt64 = 1

    init(
        capacity: Int = LogBuffer.maximumCapacity,
        redactor: SensitiveTextRedactor = SensitiveTextRedactor(context: .log),
        sessionID: UUID = UUID()
    ) {
        self.capacity = min(max(capacity, 0), LogBuffer.maximumCapacity)
        self.redactor = redactor
        self.sessionID = sessionID
    }

    func append(_ entry: LogEntry) {
        append(contentsOf: [entry])
    }

    func append(contentsOf newEntries: [LogEntry]) {
        guard capacity > 0, !newEntries.isEmpty else { return }
        let redactedEntries = newEntries.map(prepareForStorage)

        if redactedEntries.count >= capacity {
            storage = Array(redactedEntries.suffix(capacity))
            oldestIndex = 0
            return
        }

        for entry in redactedEntries {
            if storage.count < capacity {
                storage.append(entry)
            } else {
                storage[oldestIndex] = entry
                oldestIndex = (oldestIndex + 1) % capacity
            }
        }
    }

    func entries() -> [LogEntry] {
        orderedEntries()
    }

    func clear() {
        storage.removeAll(keepingCapacity: true)
        oldestIndex = 0
        sessionID = UUID()
        nextSequence = 1
    }

    /// Starts a new collection identity without discarding the bounded history.
    /// Runtime lifecycle remains owned by `MihomoControllerSession`; this only
    /// prevents entries from separate Controller sessions sharing row identity.
    func beginSession(_ id: UUID) {
        sessionID = id
        nextSequence = 1
    }

    func filtered(
        levels: Set<LogLevel> = [],
        sources: Set<LogSource> = [],
        query: String = ""
    ) -> [LogEntry] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)

        return orderedEntries().filter { entry in
            let matchesLevel = levels.isEmpty || levels.contains(entry.level)
            let matchesSource = sources.isEmpty || sources.contains(entry.source)
            let matchesQuery = normalizedQuery.isEmpty
                || entry.message.localizedCaseInsensitiveContains(normalizedQuery)
                || entry.eventCode?.localizedCaseInsensitiveContains(normalizedQuery) == true
                || entry.category.localizedCaseInsensitiveContains(normalizedQuery)
                || entry.source.rawValue.localizedCaseInsensitiveContains(normalizedQuery)
            return matchesLevel && matchesSource && matchesQuery
        }
    }

    private func orderedEntries() -> [LogEntry] {
        guard storage.count == capacity, oldestIndex != 0 else {
            return storage
        }

        return Array(storage[oldestIndex...]) + Array(storage[..<oldestIndex])
    }

    private func prepareForStorage(_ entry: LogEntry) -> LogEntry {
        let identity: LogEventIdentity
        if let existingIdentity = entry.eventIdentity {
            identity = existingIdentity
        } else {
            identity = LogEventIdentity(
                sessionID: sessionID,
                source: entry.source,
                sequence: nextSequence
            )
            nextSequence &+= 1
        }
        return LogEntry(
            id: entry.id,
            timestamp: entry.timestamp,
            level: entry.level,
            source: entry.source,
            message: redactor.redact(entry.message),
            eventIdentity: identity,
            category: entry.category,
            eventCode: entry.eventCode ?? LogEventClassifier.eventCode(
                for: entry.source,
                message: entry.message
            ),
            redactionState: .verifiedRedacted
        )
    }
}
