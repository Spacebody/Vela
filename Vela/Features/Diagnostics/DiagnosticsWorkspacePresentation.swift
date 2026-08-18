import Foundation

nonisolated enum DiagnosticsCheckCategory: String, CaseIterable, Equatable, Hashable, Sendable {
    case runtimeConfiguration
    case networkPrivilege
    case connectivityDNS
    case updatesCore
    case supportEvidence
}

nonisolated enum DiagnosticsCheckResult: String, CaseIterable, Equatable, Hashable, Sendable {
    case passed
    case warning
    case failed
    case skipped
    case blocked
    case notApplicable
    case notRun
    case running
    case stale

    var isApplicable: Bool { self != .notApplicable }

    func isTerminal(skippedCountsAsComplete: Bool) -> Bool {
        switch self {
        case .passed, .warning, .failed, .stale:
            true
        case .skipped:
            skippedCountsAsComplete
        case .blocked, .notApplicable, .notRun, .running:
            false
        }
    }
}

nonisolated enum DiagnosticsEvidenceState: String, CaseIterable, Equatable, Hashable, Sendable {
    case sufficient
    case partial
    case insufficient
    case stale
    case unavailable
}

nonisolated enum DiagnosticsPermissionState: Equatable, Hashable, Sendable {
    case notRequired
    case required(name: String, purpose: String, settingsTitle: String?)
    case denied(name: String, purpose: String, settingsTitle: String?)
    case restricted(name: String, purpose: String)
}

nonisolated enum DiagnosticsRepairAction: String, CaseIterable, Equatable, Hashable, Sendable {
    case restoreSystemProxy
    case cleanupPrivilegedRuntime
    case reinstallPrivilegedComponent
}

nonisolated struct DiagnosticsEvidencePresentation: Equatable, Hashable, Sendable {
    let state: DiagnosticsEvidenceState
    let source: String
    let capturedAt: Date?
    let summary: String
    let technicalDetails: String?
    let confidence: String
    let skipReason: String?

    init(
        state: DiagnosticsEvidenceState,
        source: String,
        capturedAt: Date?,
        summary: String,
        technicalDetails: String? = nil,
        confidence: String,
        skipReason: String? = nil
    ) {
        self.state = state
        self.source = source
        self.capturedAt = capturedAt
        self.summary = summary
        self.technicalDetails = technicalDetails
        self.confidence = confidence
        self.skipReason = skipReason
    }
}

nonisolated struct DiagnosticsRunHistoryEntry: Identifiable, Equatable, Hashable, Sendable {
    let id: String
    let checkID: String
    let runID: String
    let result: DiagnosticsCheckResult
    let completedAt: Date
    let durationSeconds: Double?
}

nonisolated enum DiagnosticsRunStepOutcome: Equatable, Sendable {
    case completed
    case skipped(reason: String)
    case failed(message: String)
    case timedOut(seconds: Double)
    case cancelled

    var failureDescription: String? {
        switch self {
        case .completed, .skipped, .cancelled:
            nil
        case let .failed(message):
            message
        case let .timedOut(seconds):
            "Diagnostic step timed out after \(seconds.formatted(.number.precision(.fractionLength(0...1)))) seconds."
        }
    }
}

nonisolated enum DiagnosticsRunHistoryPolicy {
    static func resolvedResult(
        current: DiagnosticsCheckResult,
        latestHistory: DiagnosticsRunHistoryEntry?
    ) -> DiagnosticsCheckResult {
        guard current == .notRun, let latestHistory else { return current }
        return latestHistory.result == .running ? .notRun : latestHistory.result
    }

    static func entries(
        runID: String,
        rows: [DiagnosticsCheckRowModel],
        attemptedCheckIDs: [String],
        outcome: DiagnosticsRunStepOutcome,
        completedAt: Date,
        durationSeconds: Double
    ) -> [DiagnosticsRunHistoryEntry] {
        let rowsByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        return attemptedCheckIDs.compactMap { checkID in
            guard let row = rowsByID[checkID] else { return nil }
            let result: DiagnosticsCheckResult = switch outcome {
            case .completed:
                row.result
            case .skipped:
                .skipped
            case .failed, .timedOut:
                .failed
            case .cancelled:
                .notRun
            }
            guard result != .notRun else { return nil }
            return DiagnosticsRunHistoryEntry(
                id: "\(runID).\(checkID).\(completedAt.timeIntervalSinceReferenceDate)",
                checkID: checkID,
                runID: runID,
                result: result,
                completedAt: completedAt,
                durationSeconds: durationSeconds
            )
        }
    }
}

@MainActor
enum DiagnosticsRunOperationExecutor {
    static func execute(
        timeoutSeconds: Double,
        operation: @escaping @MainActor @Sendable () async -> DiagnosticsRunStepOutcome
    ) async -> DiagnosticsRunStepOutcome {
        guard !Task.isCancelled else { return .cancelled }
        let (results, continuation) = AsyncStream.makeStream(
            of: DiagnosticsRunStepOutcome.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        let operationTask = Task { @MainActor in
            let result = await operation()
            continuation.yield(result)
        }
        // Keep the deadline off MainActor. Diagnostic operations are allowed to
        // await UI-owned state, and a busy main executor must not delay the
        // timeout that bounds them.
        let timeoutTask = Task.detached(priority: .userInitiated) {
            do {
                try await Task.sleep(for: .seconds(timeoutSeconds))
                continuation.yield(.timedOut(seconds: timeoutSeconds))
            } catch {
                // Cancellation is delivered by the parent handler or the winning task.
            }
        }

        return await withTaskCancellationHandler {
            var iterator = results.makeAsyncIterator()
            let result = await iterator.next()
                ?? (Task.isCancelled
                    ? .cancelled
                    : .failed(message: "Diagnostic step ended without a result."))
            operationTask.cancel()
            timeoutTask.cancel()
            continuation.finish()
            return result
        } onCancel: {
            operationTask.cancel()
            timeoutTask.cancel()
            continuation.yield(.cancelled)
            continuation.finish()
        }
    }
}

nonisolated struct DiagnosticsCheckRowModel: Identifiable, Equatable, Hashable, Sendable {
    let id: String
    let category: DiagnosticsCheckCategory
    let title: String
    let result: DiagnosticsCheckResult
    let resultLabel: String
    let detail: String?
    let evidence: DiagnosticsEvidencePresentation
    let lastRunID: String?
    let lastRunAt: Date?
    let durationSeconds: Double?
    let skippedCountsAsComplete: Bool
    let applicability: String
    let permission: DiagnosticsPermissionState
    let repairAction: DiagnosticsRepairAction?
    let timeoutSeconds: Double?
    let evidenceSchema: String
    let dependencies: [String]
    let supportedBackends: [String]
    let history: [DiagnosticsRunHistoryEntry]

    var offersRepair: Bool {
        guard repairAction != nil else { return false }
        switch result {
        case .warning, .failed, .blocked, .stale:
            return true
        case .passed, .skipped, .notApplicable, .notRun, .running:
            return false
        }
    }

    init(
        id: String,
        category: DiagnosticsCheckCategory,
        title: String,
        result: DiagnosticsCheckResult,
        resultLabel: String,
        detail: String? = nil,
        evidence: DiagnosticsEvidencePresentation,
        lastRunID: String? = nil,
        lastRunAt: Date? = nil,
        durationSeconds: Double? = nil,
        skippedCountsAsComplete: Bool = true,
        applicability: String,
        permission: DiagnosticsPermissionState = .notRequired,
        repairAction: DiagnosticsRepairAction? = nil,
        timeoutSeconds: Double? = nil,
        evidenceSchema: String,
        dependencies: [String] = [],
        supportedBackends: [String] = ["System Proxy", "TUN"],
        history: [DiagnosticsRunHistoryEntry] = []
    ) {
        self.id = id
        self.category = category
        self.title = title
        self.result = result
        self.resultLabel = resultLabel
        self.detail = detail
        self.evidence = evidence
        self.lastRunID = lastRunID
        self.lastRunAt = lastRunAt
        self.durationSeconds = durationSeconds
        self.skippedCountsAsComplete = skippedCountsAsComplete
        self.applicability = applicability
        self.permission = permission
        self.repairAction = repairAction
        self.timeoutSeconds = timeoutSeconds
        self.evidenceSchema = evidenceSchema
        self.dependencies = dependencies
        self.supportedBackends = supportedBackends
        self.history = Array(history.prefix(20))
    }
}

nonisolated struct DiagnosticsCheckGroupModel: Identifiable, Equatable, Hashable, Sendable {
    var id: DiagnosticsCheckCategory { category }
    let category: DiagnosticsCheckCategory
    let checks: [DiagnosticsCheckRowModel]
}

nonisolated enum DiagnosticsOverallState: String, CaseIterable, Equatable, Hashable, Sendable {
    case healthy
    case needsAttention
    case critical
    case incomplete
    case notEvaluated
    case running
    case stale
}

nonisolated struct DiagnosticsWorkspaceSummary: Equatable, Sendable {
    let overall: DiagnosticsOverallState
    let evidence: DiagnosticsEvidenceState
    let applicableCount: Int
    let terminalCount: Int
    let completionFraction: Double
    let distribution: [DiagnosticsCheckResult: Int]
    let lastRunAt: Date?
    let lastRunID: String?

    init(
        rows: [DiagnosticsCheckRowModel],
        isRunning: Bool,
        isSnapshotStale: Bool = false
    ) {
        distribution = Dictionary(grouping: rows, by: \.result).mapValues(\.count)
        let applicable = rows.filter { $0.result.isApplicable }
        applicableCount = applicable.count
        terminalCount = applicable.filter {
            $0.result.isTerminal(skippedCountsAsComplete: $0.skippedCountsAsComplete)
        }.count
        completionFraction = applicable.isEmpty
            ? 0
            : Double(terminalCount) / Double(applicable.count)
        let resolvedLastRunAt = rows.compactMap(\.lastRunAt).max()
        let resolvedLastRunID = rows
            .filter { $0.lastRunAt == resolvedLastRunAt }
            .compactMap(\.lastRunID)
            .first
        lastRunAt = resolvedLastRunAt
        lastRunID = resolvedLastRunID

        if isRunning {
            overall = .running
        } else if rows.isEmpty || applicable.allSatisfy({ $0.result == .notRun }) {
            overall = .notEvaluated
        } else if applicable.contains(where: { $0.result == .failed }) {
            overall = .critical
        } else if isSnapshotStale || applicable.contains(where: { $0.result == .stale }) {
            overall = .stale
        } else if applicable.contains(where: { $0.result == .blocked || $0.result == .notRun }) {
            overall = .incomplete
        } else if applicable.contains(where: { $0.result == .warning }) {
            overall = .needsAttention
        } else {
            overall = .healthy
        }

        let evidenceStates = rows.map(\.evidence.state)
        if evidenceStates.isEmpty || evidenceStates.allSatisfy({ $0 == .unavailable }) {
            evidence = .unavailable
        } else if evidenceStates.contains(.stale) {
            evidence = .stale
        } else if evidenceStates.allSatisfy({ $0 == .sufficient }) {
            evidence = .sufficient
        } else if evidenceStates.contains(.sufficient) || evidenceStates.contains(.partial) {
            evidence = .partial
        } else {
            evidence = .insufficient
        }
    }
}

nonisolated struct DiagnosticsWorkspaceSnapshot: Equatable, Sendable {
    let registryRevision: String
    let groups: [DiagnosticsCheckGroupModel]
    let registryError: String?
    let isRegistryLoading: Bool
    let isStale: Bool

    var rows: [DiagnosticsCheckRowModel] { groups.flatMap(\.checks) }

    var duplicateCheckIDs: [String] {
        Dictionary(grouping: rows, by: \.id)
            .filter { $0.value.count > 1 }
            .map(\.key)
            .sorted()
    }

    func summary(isRunning: Bool) -> DiagnosticsWorkspaceSummary {
        DiagnosticsWorkspaceSummary(
            rows: rows,
            isRunning: isRunning,
            isSnapshotStale: isStale
        )
    }
}

nonisolated enum DiagnosticsRunPhase: String, Equatable, Hashable, Sendable {
    case preparing
    case running
    case cancelling
    case completed
    case cancelled
    case failed
}

nonisolated struct DiagnosticsRunPresentation: Equatable, Sendable {
    let id: UUID
    let registryRevision: String
    var phase: DiagnosticsRunPhase
    var completedStepCount: Int
    let totalStepCount: Int
    var currentStepID: String?
    var currentStepTitle: String?
    let startedAt: Date
    var finishedAt: Date?
    var failureDescription: String?

    var shortID: String { String(id.uuidString.prefix(8)).uppercased() }
    var isActive: Bool { phase == .preparing || phase == .running || phase == .cancelling }
}

nonisolated enum DiagnosticsRunProgressPresentation {
    static func summary(
        format: String,
        locale: Locale,
        runID: String,
        completedStepCount: Int,
        totalStepCount: Int,
        duration: String,
        currentStep: String
    ) -> String {
        String(
            format: format,
            locale: locale,
            arguments: [
                runID as NSString,
                Int64(completedStepCount),
                Int64(totalStepCount),
                duration as NSString,
                currentStep as NSString,
            ]
        )
    }
}

nonisolated enum DiagnosticsRepairPhase: String, Equatable, Hashable, Sendable {
    case preparing
    case requestingPrivilege
    case applying
    case verifying
    case completed
    case failed

    var isActive: Bool {
        switch self {
        case .preparing, .requestingPrivilege, .applying, .verifying:
            true
        case .completed, .failed:
            false
        }
    }
}

nonisolated struct DiagnosticsRepairPresentation: Equatable, Sendable {
    let id: String
    let targetCheckID: String
    let action: DiagnosticsRepairAction
    let phase: DiagnosticsRepairPhase
    let privilege: String
    let requestedState: String
    let cleanupOrRollback: String
    let postcondition: String
    let message: String?
}

nonisolated struct DiagnosticsRunGenerationGate: Equatable, Sendable {
    private(set) var activeRunID: UUID?

    mutating func begin(_ runID: UUID) -> Bool {
        guard activeRunID == nil else { return false }
        activeRunID = runID
        return true
    }

    func accepts(_ runID: UUID) -> Bool { activeRunID == runID }

    mutating func finish(_ runID: UUID) -> Bool {
        guard activeRunID == runID else { return false }
        activeRunID = nil
        return true
    }
}

nonisolated enum DiagnosticsFilter: String, CaseIterable, Equatable, Hashable, Sendable {
    case all
    case attention
    case failed
    case blocked

    func includes(_ row: DiagnosticsCheckRowModel) -> Bool {
        switch self {
        case .all:
            true
        case .attention:
            [.warning, .failed, .blocked, .stale].contains(row.result)
        case .failed:
            row.result == .failed
        case .blocked:
            row.result == .blocked
        }
    }
}

nonisolated struct DiagnosticsWorkspaceLayout: Equatable, Sendable {
    let showsCategoryColumn: Bool
    let showsEvidenceColumn: Bool
    let showsDurationColumn: Bool
    let inspectorWidth: CGFloat
    let searchWidth: CGFloat
    let filterWidth: CGFloat

    static func forContentWidth(_ width: CGFloat) -> Self {
        let bounded = max(0, width)
        return Self(
            showsCategoryColumn: bounded >= 900,
            showsEvidenceColumn: bounded >= 900,
            showsDurationColumn: bounded >= 1_220,
            inspectorWidth: min(380, max(300, bounded * 0.3)),
            searchWidth: bounded < 900 ? 180 : 280,
            filterWidth: bounded < 900 ? 220 : 360
        )
    }
}
