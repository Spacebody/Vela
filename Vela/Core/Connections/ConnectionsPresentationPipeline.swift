import Foundation

nonisolated struct ConnectionRowModel: Identifiable, Equatable, Sendable {
    let connection: MihomoConnection
    let application: String
    let host: String
    let destination: String
    let destinationIP: String
    let process: String
    let network: String
    let type: String
    let protocolText: String
    let rule: String
    let rulePayload: String
    let chain: String
    let proxy: String
    let finalOutbound: String
    let providerChain: String
    let uploadText: String
    let downloadText: String
    let durationText: String
    let source: String?
    let inbound: String?
    let startedAtText: String?

    var id: String { connection.id }
}

nonisolated struct ConnectionFilterOptions: Equatable, Sendable {
    static let empty = ConnectionFilterOptions(
        protocols: [],
        networks: [],
        processes: [],
        rules: []
    )

    let protocols: [String]
    let networks: [String]
    let processes: [String]
    let rules: [String]
}

nonisolated struct ConnectionMetricsPresentation: Equatable, Sendable {
    static let empty = ConnectionMetricsPresentation(
        connectionCount: 0,
        uploadText: "0 bytes",
        downloadText: "0 bytes",
        memoryText: nil
    )

    let connectionCount: Int
    let uploadText: String
    let downloadText: String
    let memoryText: String?
}

nonisolated struct ConnectionsProcessingRequest: Sendable {
    let snapshotRevision: UInt64
    let snapshot: ConnectionsSnapshot
    let query: String
    let filters: ConnectionFilterSelection
    let sort: ConnectionSortSelection
    let now: Date
    let localeIdentifier: String
}

nonisolated struct ConnectionsProcessingResult: Sendable {
    let snapshotRevision: UInt64
    let rows: [ConnectionRowModel]
    let rowsByID: [String: ConnectionRowModel]
    let options: ConnectionFilterOptions
    let metrics: ConnectionMetricsPresentation
}

nonisolated struct ConnectionsProcessingDiagnostics: Equatable, Sendable {
    let submittedRequestCount: Int
    let startedWorkerCount: Int
    let completedWorkerCount: Int
    let cancelledWorkerCount: Int
    let activeWorkerCount: Int
    let maximumConcurrentWorkerCount: Int
}

/// Serializes expensive presentation work while still running it outside the
/// main actor. Replacements cancel and join the previous worker before starting
/// the newest request, so rapid snapshots cannot accumulate detached sorts.
actor ConnectionsPresentationPipeline {
    private struct ActiveWorker {
        let ticket: UInt64
        let task: Task<ConnectionsProcessingResult?, Never>
    }

    private var nextTicket: UInt64 = 0
    private var latestRequestTicket: UInt64 = 0
    private var activeWorker: ActiveWorker?
    private var finalizedWorkerTicket: UInt64 = 0
    private var submittedRequestCount = 0
    private var startedWorkerCount = 0
    private var completedWorkerCount = 0
    private var cancelledWorkerCount = 0
    private var activeWorkerCount = 0
    private var maximumConcurrentWorkerCount = 0

    func process(
        _ request: ConnectionsProcessingRequest
    ) async -> ConnectionsProcessingResult? {
        nextTicket &+= 1
        let ticket = nextTicket
        latestRequestTicket = ticket
        submittedRequestCount += 1

        if let previous = activeWorker {
            previous.task.cancel()
            let previousResult = await previous.task.value
            recordCompletion(of: previous, result: previousResult)
            if activeWorker?.ticket == previous.ticket {
                activeWorker = nil
            }
        }

        guard ticket == latestRequestTicket, !Task.isCancelled else { return nil }

        // Escaping actor isolation is intentional: filtering, sorting and
        // Foundation formatting are CPU work and must never execute on the UI actor.
        let worker = ActiveWorker(
            ticket: ticket,
            task: Task.detached(priority: .userInitiated) {
                ConnectionsPresentationBuilder.build(request)
            }
        )
        activeWorker = worker
        startedWorkerCount += 1
        activeWorkerCount += 1
        maximumConcurrentWorkerCount = max(
            maximumConcurrentWorkerCount,
            activeWorkerCount
        )

        let result = await withTaskCancellationHandler {
            await worker.task.value
        } onCancel: {
            worker.task.cancel()
        }

        recordCompletion(of: worker, result: result)
        if activeWorker?.ticket == ticket {
            activeWorker = nil
        }

        guard ticket == latestRequestTicket, !Task.isCancelled else { return nil }
        return result
    }

    func cancel() async {
        nextTicket &+= 1
        latestRequestTicket = nextTicket
        guard let worker = activeWorker else { return }
        worker.task.cancel()
        let result = await worker.task.value
        recordCompletion(of: worker, result: result)
        if activeWorker?.ticket == worker.ticket {
            activeWorker = nil
        }
    }

    func diagnostics() -> ConnectionsProcessingDiagnostics {
        ConnectionsProcessingDiagnostics(
            submittedRequestCount: submittedRequestCount,
            startedWorkerCount: startedWorkerCount,
            completedWorkerCount: completedWorkerCount,
            cancelledWorkerCount: cancelledWorkerCount,
            activeWorkerCount: activeWorkerCount,
            maximumConcurrentWorkerCount: maximumConcurrentWorkerCount
        )
    }

    private func recordCompletion(
        of worker: ActiveWorker,
        result: ConnectionsProcessingResult?
    ) {
        guard worker.ticket > finalizedWorkerTicket else { return }
        finalizedWorkerTicket = worker.ticket
        activeWorkerCount = max(0, activeWorkerCount - 1)
        if result == nil {
            cancelledWorkerCount += 1
        } else {
            completedWorkerCount += 1
        }
    }
}

nonisolated private enum ConnectionsPresentationBuilder {
    static func build(
        _ request: ConnectionsProcessingRequest
    ) -> ConnectionsProcessingResult? {
        let values = request.snapshot.connections
        var protocols = Set<String>()
        var networks = Set<String>()
        var processes = Set<String>()
        var rules = Set<String>()
        protocols.reserveCapacity(min(values.count, 32))
        networks.reserveCapacity(min(values.count, 16))
        processes.reserveCapacity(min(values.count, 256))
        rules.reserveCapacity(min(values.count, 128))

        var filtered: [MihomoConnection] = []
        filtered.reserveCapacity(values.count)
        for (index, connection) in values.enumerated() {
            if index.isMultiple(of: 64), Task.isCancelled { return nil }
            let metadata = connection.metadata
            insertNonEmpty(metadata.type, into: &protocols)
            insertNonEmpty(metadata.network, into: &networks)
            insertNonEmpty(metadata.process, into: &processes)
            insertNonEmpty(connection.rule, into: &rules)

            guard request.filters.matches(connection) else { continue }
            guard request.query.isEmpty || matchesSearch(connection, query: request.query) else {
                continue
            }
            filtered.append(connection)
        }
        guard !Task.isCancelled else { return nil }

        guard let sorted = cancellableStableSort(filtered, by: request.sort) else {
            return nil
        }

        var rows: [ConnectionRowModel] = []
        rows.reserveCapacity(sorted.count)
        var rowsByID: [String: ConnectionRowModel] = [:]
        rowsByID.reserveCapacity(sorted.count)
        for (index, connection) in sorted.enumerated() {
            if index.isMultiple(of: 64), Task.isCancelled { return nil }
            let row = makeRow(
                connection,
                now: request.now,
                localeIdentifier: request.localeIdentifier
            )
            rows.append(row)
            rowsByID[row.id] = row
        }
        guard !Task.isCancelled else { return nil }

        return ConnectionsProcessingResult(
            snapshotRevision: request.snapshotRevision,
            rows: rows,
            rowsByID: rowsByID,
            options: ConnectionFilterOptions(
                protocols: sortedValues(protocols),
                networks: sortedValues(networks),
                processes: sortedValues(processes),
                rules: sortedValues(rules)
            ),
            metrics: ConnectionMetricsPresentation(
                connectionCount: values.count,
                uploadText: ConnectionTextFormatter.shared.bytes(
                    request.snapshot.uploadTotal
                ),
                downloadText: ConnectionTextFormatter.shared.bytes(
                    request.snapshot.downloadTotal
                ),
                memoryText: request.snapshot.memory.map {
                    ConnectionTextFormatter.shared.bytes(Int64(clamping: $0))
                }
            )
        )
    }

    private static func insertNonEmpty(
        _ value: String?,
        into values: inout Set<String>
    ) {
        if let value, !value.isEmpty { values.insert(value) }
    }

    private static func sortedValues(_ values: Set<String>) -> [String] {
        values.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    private static func matchesSearch(
        _ connection: MihomoConnection,
        query: String
    ) -> Bool {
        let metadata = connection.metadata
        let candidates = [
            metadata.host,
            metadata.sniffHost,
            metadata.destinationIP,
            metadata.process,
            metadata.processPath,
            metadata.network,
            metadata.type,
            connection.rule,
            connection.rulePayload,
        ]
        if candidates.compactMap({ $0 }).contains(where: {
            $0.localizedCaseInsensitiveContains(query)
        }) {
            return true
        }
        return connection.chains.contains {
            $0.localizedCaseInsensitiveContains(query)
        }
    }

    private static func cancellableStableSort(
        _ values: [MihomoConnection],
        by sort: ConnectionSortSelection
    ) -> [MihomoConnection]? {
        guard values.count > 1 else { return Task.isCancelled ? nil : values }
        var source = values
        var destination = values
        var width = 1
        var comparisonCount = 0

        while width < source.count {
            if Task.isCancelled { return nil }
            var lowerBound = 0
            while lowerBound < source.count {
                let middle = min(lowerBound + width, source.count)
                let upperBound = min(lowerBound + width + width, source.count)
                var left = lowerBound
                var right = middle
                var output = lowerBound

                while left < middle, right < upperBound {
                    comparisonCount &+= 1
                    if comparisonCount.isMultiple(of: 256), Task.isCancelled {
                        return nil
                    }
                    // Prefer the left value when equal to keep the merge stable.
                    if sort.isOrderedBefore(source[right], source[left]) {
                        destination[output] = source[right]
                        right += 1
                    } else {
                        destination[output] = source[left]
                        left += 1
                    }
                    output += 1
                }
                while left < middle {
                    destination[output] = source[left]
                    left += 1
                    output += 1
                }
                while right < upperBound {
                    destination[output] = source[right]
                    right += 1
                    output += 1
                }
                lowerBound = upperBound
            }
            swap(&source, &destination)
            width &*= 2
        }
        return Task.isCancelled ? nil : source
    }

    private static func makeRow(
        _ connection: MihomoConnection,
        now: Date,
        localeIdentifier: String
    ) -> ConnectionRowModel {
        let metadata = connection.metadata
        let destinationIP = firstNonEmpty(metadata.destinationIP) ?? "—"
        let host = firstNonEmpty(
            metadata.sniffHost,
            metadata.host,
            metadata.destinationIP
        ) ?? "Unknown"
        let destination = address(host, port: metadata.destinationPort) ?? "—"
        let process = firstNonEmpty(
            metadata.process,
            executableName(from: metadata.processPath)
        ) ?? "—"
        let protocolValues: [String] = [metadata.type, metadata.network]
            .compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value.uppercased()
            }
        return ConnectionRowModel(
            connection: connection,
            application: process == "—" ? host : process,
            host: host,
            destination: destination,
            destinationIP: destinationIP,
            process: process,
            network: metadata.network ?? "—",
            type: metadata.type ?? "—",
            protocolText: protocolValues.isEmpty
                ? "—"
                : protocolValues.joined(separator: " · "),
            rule: connection.rule.isEmpty ? "—" : connection.rule,
            rulePayload: connection.rulePayload.isEmpty ? "—" : connection.rulePayload,
            chain: connection.chains.joined(separator: " → "),
            proxy: connection.chains.last ?? "—",
            finalOutbound: connection.chains.first ?? "—",
            providerChain: connection.providerChains.joined(separator: " → "),
            uploadText: ConnectionTextFormatter.shared.bytes(connection.upload),
            downloadText: ConnectionTextFormatter.shared.bytes(connection.download),
            durationText: ConnectionTextFormatter.shared.duration(
                from: connection.start,
                to: now,
                localeIdentifier: localeIdentifier
            ),
            source: address(metadata.sourceIP, port: metadata.sourcePort),
            inbound: inbound(metadata),
            startedAtText: connection.start.map {
                ConnectionTextFormatter.shared.date(
                    $0,
                    localeIdentifier: localeIdentifier
                )
            }
        )
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        values.lazy.compactMap { value in
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }.first
    }

    private static func executableName(from processPath: String?) -> String? {
        guard let processPath = firstNonEmpty(processPath) else { return nil }
        let name = URL(fileURLWithPath: processPath)
            .deletingPathExtension()
            .lastPathComponent
        return firstNonEmpty(name)
    }

    private static func inbound(_ metadata: ConnectionMetadata) -> String? {
        if let name = metadata.inboundName, !name.isEmpty {
            return name
        }
        return address(metadata.inboundIP, port: metadata.inboundPort)
    }

    private static func address(_ host: String?, port: Int?) -> String? {
        guard let host, !host.isEmpty else { return nil }
        return port.map { "\(host):\($0)" } ?? host
    }
}

/// Foundation's reference-type formatters are cached for the lifetime of the
/// process. The lock makes the shared instance safe when future presentation
/// work moves between executor threads.
nonisolated final class ConnectionTextFormatter: @unchecked Sendable {
    static let shared = ConnectionTextFormatter()

    private let lock = NSLock()
    private let byteFormatter: ByteCountFormatter
    private var dateFormatters: [String: DateFormatter] = [:]
    private var durationFormatters: [String: DateComponentsFormatter] = [:]

    private init() {
        byteFormatter = ByteCountFormatter()
        byteFormatter.countStyle = .file
        byteFormatter.allowedUnits = .useAll
        byteFormatter.includesUnit = true
        byteFormatter.isAdaptive = true

    }

    func bytes(_ value: Int64) -> String {
        lock.lock()
        defer { lock.unlock() }
        return byteFormatter.string(fromByteCount: max(0, value))
    }

    func date(_ value: Date, localeIdentifier: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        let formatter: DateFormatter
        if let cached = dateFormatters[localeIdentifier] {
            formatter = cached
        } else {
            let created = DateFormatter()
            created.locale = Locale(identifier: localeIdentifier)
            created.dateStyle = .medium
            created.timeStyle = .medium
            dateFormatters[localeIdentifier] = created
            formatter = created
        }
        return formatter.string(from: value)
    }

    func duration(
        from start: Date?,
        to end: Date,
        localeIdentifier: String
    ) -> String {
        guard let start else { return "—" }
        let interval = max(0, end.timeIntervalSince(start))
        let units: NSCalendar.Unit
        let keySuffix: String
        if interval >= 86_400 {
            units = [.day, .hour]
            keySuffix = "day"
        } else if interval >= 3_600 {
            units = [.hour, .minute]
            keySuffix = "hour"
        } else if interval >= 60 {
            units = [.minute, .second]
            keySuffix = "minute"
        } else {
            units = [.second]
            keySuffix = "second"
        }

        lock.lock()
        defer { lock.unlock() }
        let key = "\(localeIdentifier)|\(keySuffix)"
        let formatter: DateComponentsFormatter
        if let cached = durationFormatters[key] {
            formatter = cached
        } else {
            let created = DateComponentsFormatter()
            created.unitsStyle = .abbreviated
            created.allowedUnits = units
            created.maximumUnitCount = 2
            created.zeroFormattingBehavior = .dropLeading
            var calendar = Calendar(identifier: .gregorian)
            calendar.locale = Locale(identifier: localeIdentifier)
            created.calendar = calendar
            durationFormatters[key] = created
            formatter = created
        }
        return formatter.string(from: interval) ?? "—"
    }
}

nonisolated enum ConnectionSortField: String, CaseIterable, Identifiable, Sendable {
    case host
    case process
    case upload
    case download
    case rule
    case started

    var id: Self { self }

    var title: String {
        switch self {
        case .host: "Host"
        case .process: "Process"
        case .upload: "Uploaded"
        case .download: "Downloaded"
        case .rule: "Rule"
        case .started: "Started"
        }
    }
}

nonisolated struct ConnectionFilterSelection: Sendable {
    let protocolName: String?
    let network: String?
    let process: String?
    let rule: String?

    fileprivate func matches(_ connection: MihomoConnection) -> Bool {
        let metadata = connection.metadata
        return (protocolName == nil || metadata.type == protocolName)
            && (network == nil || metadata.network == network)
            && (process == nil || metadata.process == process)
            && (rule == nil || connection.rule == rule)
    }
}

nonisolated struct ConnectionSortSelection: Sendable {
    let field: ConnectionSortField
    let ascending: Bool

    fileprivate func isOrderedBefore(
        _ lhs: MihomoConnection,
        _ rhs: MihomoConnection
    ) -> Bool {
        let comparison = compare(lhs, rhs)
        if comparison == .orderedSame { return lhs.id < rhs.id }
        return ascending
            ? comparison == .orderedAscending
            : comparison == .orderedDescending
    }

    private func compare(_ lhs: MihomoConnection, _ rhs: MihomoConnection) -> ComparisonResult {
        switch field {
        case .host:
            return host(lhs).localizedCaseInsensitiveCompare(host(rhs))
        case .process:
            return (lhs.metadata.process ?? "")
                .localizedCaseInsensitiveCompare(rhs.metadata.process ?? "")
        case .upload:
            return comparison(lhs.upload, rhs.upload)
        case .download:
            return comparison(lhs.download, rhs.download)
        case .rule:
            return lhs.rule.localizedCaseInsensitiveCompare(rhs.rule)
        case .started:
            return comparison(lhs.start ?? .distantPast, rhs.start ?? .distantPast)
        }
    }

    private func comparison<Value: Comparable>(
        _ lhs: Value,
        _ rhs: Value
    ) -> ComparisonResult {
        if lhs < rhs { return .orderedAscending }
        if lhs > rhs { return .orderedDescending }
        return .orderedSame
    }

    private func host(_ connection: MihomoConnection) -> String {
        connection.metadata.sniffHost
            ?? connection.metadata.host
            ?? connection.metadata.destinationIP
            ?? ""
    }
}
