import Foundation

/// Stable table identity for one Mihomo proxy group.
///
/// Mihomo exposes groups as keys in a single runtime proxy dictionary, so a
/// group name is unique for the lifetime of one catalog generation. Keeping
/// that guarantee explicit here avoids row-index and random-UUID selection.
nonisolated struct ProxiesGroupID: RawRepresentable, Hashable, Sendable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }
}

nonisolated struct ProxiesDelayKey: Hashable, Sendable {
    let groupID: ProxiesGroupID
    let nodeID: ProxyCatalogID
}

nonisolated enum ProxiesWorkspaceState: String, Equatable, Hashable, Sendable {
    case loading
    case loaded
    case refreshing
    case pendingMutation
    case stale
    case empty
    case fullFailure
    case partialFailure
    case offline
}

nonisolated enum ProxiesMutationPhase: String, Equatable, Hashable, Sendable {
    /// EngineStore exposes an in-flight, not-yet-confirmed selection. It does
    /// not expose internal validation/verification phases, so presentation
    /// truthfully reports the only phase supported by the current contract.
    case applying
}

nonisolated struct ProxiesLatencySnapshot: Equatable, Sendable {
    let state: VelaLatencyState
    let milliseconds: Int?
    let diagnostic: String?

    init(sessionState: ProxyDelayState?, catalogDelay: ProxyDelay) {
        let presentation = ProxyLatencyPresentation(
            sessionState: sessionState,
            catalogDelay: catalogDelay
        )
        state = presentation.state
        milliseconds = presentation.milliseconds
        diagnostic = presentation.diagnostic
    }
}

nonisolated struct ProxiesCandidateSnapshot: Identifiable, Equatable, Sendable {
    let id: ProxyCatalogID
    let name: String
    let type: String?
    let source: String
    let latency: ProxiesLatencySnapshot
    let isAvailable: Bool?
    let isCurrent: Bool
    let isFixed: Bool
    let isPlaceholder: Bool
    let isRequested: Bool
}

nonisolated struct ProxiesGroupRowSnapshot: Identifiable, Equatable, Sendable {
    let id: ProxiesGroupID
    let name: String
    let currentProxy: String?
    let strategy: String
    let latency: ProxiesLatencySnapshot
    let semanticStatus: VelaSemanticStatus
    let candidateCount: Int
    let isPending: Bool
}

nonisolated struct ProxiesGroupInspectorSnapshot: Equatable, Sendable {
    let id: ProxiesGroupID
    let name: String
    let strategy: String
    let currentProxy: String?
    let currentLatency: ProxiesLatencySnapshot
    let candidates: [ProxiesCandidateSnapshot]
    let sourceSummary: String?
    let snapshotUpdatedAt: Date?
    let referenceDate: Date
    let measuredSampleCount: Int
    let semanticStatus: VelaSemanticStatus
    let requestedProxy: String?
    let mutationPhase: ProxiesMutationPhase?
    let allowsManualSelection: Bool
    let canTest: Bool
    let failureSummary: String?
}

nonisolated enum ProxiesInspectorState: Equatable, Sendable {
    case loading
    case noSelection
    case selected(ProxiesGroupInspectorSnapshot)
    case empty
    case failure(String?)
    case offline
}

nonisolated struct ProxiesActionAvailability: Equatable, Sendable {
    let canRefresh: Bool
    let canTestGroup: Bool
    let canMutateSelection: Bool
    let showsOpenConfiguration: Bool
    let showsDiagnostics: Bool
}

nonisolated struct ProxiesPresentationSnapshot: Equatable, Sendable {
    let generation: String
    let state: ProxiesWorkspaceState
    let rows: [ProxiesGroupRowSnapshot]
    let groups: [ProxiesGroupID: ProxiesGroupInspectorSnapshot]
    let selectedGroupID: ProxiesGroupID?
    let errorSummary: String?
    let updatedAt: Date?
    let actions: ProxiesActionAvailability

    func inspectorState(for selection: ProxiesGroupID?) -> ProxiesInspectorState {
        switch state {
        case .loading:
            return .loading
        case .empty:
            return .empty
        case .fullFailure:
            return .failure(errorSummary)
        case .offline where rows.isEmpty:
            return .offline
        case .loaded, .refreshing, .pendingMutation, .stale, .partialFailure,
             .offline:
            guard let selection, let group = groups[selection] else {
                return .noSelection
            }
            return .selected(group)
        }
    }

    func resolvingSelection(_ requested: ProxiesGroupID?) -> ProxiesGroupID? {
        ProxiesSelectionPolicy.resolve(requested, rows: rows)
    }
}

nonisolated enum ProxiesSelectionPolicy {
    /// Preserve the selected identity while it remains visible. If it is
    /// removed, select the first stable row; an empty workspace always clears
    /// both table selection and Inspector identity.
    static func resolve(
        _ requested: ProxiesGroupID?,
        rows: [ProxiesGroupRowSnapshot]
    ) -> ProxiesGroupID? {
        guard !rows.isEmpty else { return nil }
        if let requested, rows.contains(where: { $0.id == requested }) {
            return requested
        }
        return rows.first?.id
    }
}

nonisolated struct ProxiesProcessingRequest: Sendable {
    let catalog: ProxyCatalog
    let controllerState: ControllerConnectionState
    let isLoading: Bool
    let operation: ProxyOperationState?
    let delayStates: [ProxiesDelayKey: ProxyDelayState]
    let errorSummary: String?
    let referenceDate: Date
}

nonisolated struct ProxiesProcessingDiagnostics: Equatable, Sendable {
    let submittedRequestCount: Int
    let startedWorkerCount: Int
    let completedWorkerCount: Int
    let cancelledWorkerCount: Int
    let activeWorkerCount: Int
    let maximumConcurrentWorkerCount: Int
}

/// Serializes expensive catalog projection away from MainActor. EngineStore
/// remains the sole owner of catalog and delay truth; this actor owns only the
/// currently replaceable presentation worker.
actor ProxiesPresentationPipeline {
    private struct ActiveWorker {
        let ticket: UInt64
        let task: Task<ProxiesPresentationSnapshot?, Never>
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

    func project(_ request: ProxiesProcessingRequest) async -> ProxiesPresentationSnapshot? {
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

        let worker = ActiveWorker(
            ticket: ticket,
            task: Task(priority: .userInitiated) {
                await Self.makeSnapshot(for: request)
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

    func diagnostics() -> ProxiesProcessingDiagnostics {
        ProxiesProcessingDiagnostics(
            submittedRequestCount: submittedRequestCount,
            startedWorkerCount: startedWorkerCount,
            completedWorkerCount: completedWorkerCount,
            cancelledWorkerCount: cancelledWorkerCount,
            activeWorkerCount: activeWorkerCount,
            maximumConcurrentWorkerCount: maximumConcurrentWorkerCount
        )
    }

    @concurrent
    private static func makeSnapshot(
        for request: ProxiesProcessingRequest
    ) async -> ProxiesPresentationSnapshot? {
        guard !Task.isCancelled else { return nil }
        let snapshot = ProxiesPresentationFactory.make(
            catalog: request.catalog,
            controllerState: request.controllerState,
            isLoading: request.isLoading,
            operation: request.operation,
            delayStates: request.delayStates,
            selectedGroupID: nil,
            errorSummary: request.errorSummary,
            referenceDate: request.referenceDate
        )
        return Task.isCancelled ? nil : snapshot
    }

    private func recordCompletion(
        of worker: ActiveWorker,
        result: ProxiesPresentationSnapshot?
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

nonisolated enum ProxiesPresentationFactory {
    static func make(
        catalog: ProxyCatalog,
        controllerState: ControllerConnectionState,
        isLoading: Bool,
        operation: ProxyOperationState?,
        delayStates: [ProxiesDelayKey: ProxyDelayState],
        selectedGroupID requestedSelection: ProxiesGroupID?,
        errorSummary: String?,
        referenceDate: Date = Date(),
        stateOverride: ProxiesWorkspaceState? = nil
    ) -> ProxiesPresentationSnapshot {
        let state = stateOverride ?? resolveState(
            hasRows: !catalog.groups.isEmpty,
            controllerState: controllerState,
            isLoading: isLoading,
            operation: operation,
            hasError: errorSummary != nil
        )
        let pendingSelection = pendingSelection(from: operation)
        let displayNames = ProxyNodeDisplayNameResolver.displayNames(
            for: catalog.groups
        )
        let rows = catalog.groups.map { group in
            makeRow(
                group: group,
                state: state,
                pendingSelection: pendingSelection,
                delayStates: delayStates,
                displayNames: displayNames
            )
        }
        let selectedGroupID = ProxiesSelectionPolicy.resolve(
            requestedSelection,
            rows: rows
        )
        let canUseController = controllerState == .connected
        let operationIsBlocking = operation != nil || isLoading
        let actions = ProxiesActionAvailability(
            canRefresh: canUseController && !operationIsBlocking,
            canTestGroup: canUseController && !operationIsBlocking && selectedGroupID != nil,
            canMutateSelection: canUseController && !operationIsBlocking,
            showsOpenConfiguration: state == .empty,
            showsDiagnostics: state == .fullFailure || state == .offline
        )
        let groups = Dictionary(uniqueKeysWithValues: catalog.groups.map { group in
            let groupID = ProxiesGroupID(rawValue: group.name)
            return (
                groupID,
                makeInspector(
                    group: group,
                    state: state,
                    pendingSelection: pendingSelection,
                    delayStates: delayStates,
                    updatedAt: catalog.updatedAt,
                    referenceDate: referenceDate,
                    actions: actions,
                    errorSummary: errorSummary,
                    displayNames: displayNames
                )
            )
        })

        return ProxiesPresentationSnapshot(
            generation: generation(
                catalog: catalog,
                state: state,
                operation: operation
            ),
            state: state,
            rows: rows,
            groups: groups,
            selectedGroupID: selectedGroupID,
            errorSummary: errorSummary,
            updatedAt: catalog.updatedAt,
            actions: actions
        )
    }

    private static func resolveState(
        hasRows: Bool,
        controllerState: ControllerConnectionState,
        isLoading: Bool,
        operation: ProxyOperationState?,
        hasError: Bool
    ) -> ProxiesWorkspaceState {
        guard controllerState == .connected else {
            return controllerState == .connecting ? .loading : .offline
        }
        if hasRows, case .selecting = operation { return .pendingMutation }
        if hasRows, operation == .refreshing || isLoading { return .refreshing }
        if hasRows, hasError { return .partialFailure }
        if hasRows { return .loaded }
        if isLoading { return .loading }
        if hasError { return .fullFailure }
        return .empty
    }

    private static func makeRow(
        group: ProxyGroup,
        state: ProxiesWorkspaceState,
        pendingSelection: (groupName: String, proxyID: ProxyCatalogID)?,
        delayStates: [ProxiesDelayKey: ProxyDelayState],
        displayNames: [ProxyCatalogID: String]
    ) -> ProxiesGroupRowSnapshot {
        let groupID = ProxiesGroupID(rawValue: group.name)
        let currentNode = currentNode(in: group)
        let latency = latency(
            groupID: groupID,
            node: currentNode,
            delayStates: delayStates
        )
        let isPending = pendingSelection?.groupName == group.name
        return ProxiesGroupRowSnapshot(
            id: groupID,
            name: group.name,
            currentProxy: currentNode.flatMap { displayNames[$0.id] } ?? group.now,
            strategy: group.type,
            latency: latency,
            semanticStatus: semanticStatus(
                workspaceState: state,
                latency: latency,
                isPending: isPending,
                hasCurrentProxy: group.now != nil
            ),
            candidateCount: group.nodes.count,
            isPending: isPending
        )
    }

    private static func makeInspector(
        group: ProxyGroup,
        state: ProxiesWorkspaceState,
        pendingSelection: (groupName: String, proxyID: ProxyCatalogID)?,
        delayStates: [ProxiesDelayKey: ProxyDelayState],
        updatedAt: Date?,
        referenceDate: Date,
        actions: ProxiesActionAvailability,
        errorSummary: String?,
        displayNames: [ProxyCatalogID: String]
    ) -> ProxiesGroupInspectorSnapshot {
        let groupID = ProxiesGroupID(rawValue: group.name)
        let requestedID = pendingSelection?.groupName == group.name
            ? pendingSelection?.proxyID
            : nil
        let candidates = group.nodes.map { node in
            ProxiesCandidateSnapshot(
                id: node.id,
                name: displayNames[node.id] ?? node.name,
                type: node.type,
                source: sourceLabel(node.origin),
                latency: latency(
                    groupID: groupID,
                    node: node,
                    delayStates: delayStates
                ),
                isAvailable: node.alive,
                isCurrent: node.isCurrent,
                isFixed: node.isFixed,
                isPlaceholder: node.isPlaceholder,
                isRequested: requestedID == node.id
            )
        }
        let currentLatency = latency(
            groupID: groupID,
            node: currentNode(in: group),
            delayStates: delayStates
        )
        let uniqueSources = Array(Set(candidates.map(\.source))).sorted()
        let sourceSummary = uniqueSources.isEmpty
            ? nil
            : uniqueSources.joined(separator: ", ")
        let requestedProxy = requestedID.flatMap { id in
            candidates.first(where: { $0.id == id })?.name
        }
        let measuredSamples = candidates.filter { candidate in
            candidate.latency.milliseconds != nil
        }.count
        let rowStatus = semanticStatus(
            workspaceState: state,
            latency: currentLatency,
            isPending: requestedID != nil,
            hasCurrentProxy: group.now != nil
        )

        return ProxiesGroupInspectorSnapshot(
            id: groupID,
            name: group.name,
            strategy: group.type,
            currentProxy: currentNode(in: group).flatMap { displayNames[$0.id] } ?? group.now,
            currentLatency: currentLatency,
            candidates: candidates,
            sourceSummary: sourceSummary,
            snapshotUpdatedAt: updatedAt,
            referenceDate: referenceDate,
            measuredSampleCount: measuredSamples,
            semanticStatus: rowStatus,
            requestedProxy: requestedProxy,
            mutationPhase: requestedProxy == nil ? nil : .applying,
            allowsManualSelection: group.type == "Selector",
            canTest: actions.canTestGroup,
            failureSummary: state == .partialFailure || state == .stale
                ? errorSummary
                : nil
        )
    }

    private static func currentNode(in group: ProxyGroup) -> ProxyNode? {
        group.nodes.first(where: \.isCurrent)
            ?? group.now.flatMap { current in
                group.nodes.first(where: { $0.name == current })
            }
    }

    private static func latency(
        groupID: ProxiesGroupID,
        node: ProxyNode?,
        delayStates: [ProxiesDelayKey: ProxyDelayState]
    ) -> ProxiesLatencySnapshot {
        guard let node else {
            return ProxiesLatencySnapshot(sessionState: nil, catalogDelay: .untested)
        }
        return ProxiesLatencySnapshot(
            sessionState: delayStates[
                ProxiesDelayKey(groupID: groupID, nodeID: node.id)
            ],
            catalogDelay: node.delay
        )
    }

    private static func semanticStatus(
        workspaceState: ProxiesWorkspaceState,
        latency: ProxiesLatencySnapshot,
        isPending: Bool,
        hasCurrentProxy: Bool
    ) -> VelaSemanticStatus {
        if isPending { return .pending }
        if workspaceState == .stale || workspaceState == .offline { return .stale }
        if workspaceState == .partialFailure { return .warning }
        guard hasCurrentProxy else { return .neutral }
        return switch latency.state {
        case .good: .success
        case .medium: .warning
        case .slow, .failed: .error
        case .testing: .pending
        case .unknown: .info
        }
    }

    private static func pendingSelection(
        from operation: ProxyOperationState?
    ) -> (groupName: String, proxyID: ProxyCatalogID)? {
        guard case let .selecting(groupName, proxyID) = operation else {
            return nil
        }
        return (groupName, proxyID)
    }

    private static func sourceLabel(_ origin: ProxyOrigin) -> String {
        switch origin {
        case .runtime:
            "Runtime"
        case let .provider(name):
            name
        }
    }

    private static func generation(
        catalog: ProxyCatalog,
        state: ProxiesWorkspaceState,
        operation: ProxyOperationState?
    ) -> String {
        let catalogIdentity = catalog.groups.map { group in
            let members = group.nodes.map { node in
                "\(node.id.sortKey):\(node.isCurrent):\(node.isFixed)"
            }.joined(separator: ",")
            return "\(group.name):\(group.type):\(group.now ?? "-"):\(members)"
        }.joined(separator: "|")
        let updateIdentity = catalog.updatedAt?.timeIntervalSinceReferenceDate ?? -1
        return "\(updateIdentity)#\(state.rawValue)#\(operationIdentity(operation))#\(catalogIdentity)"
    }

    private static func operationIdentity(_ operation: ProxyOperationState?) -> String {
        switch operation {
        case nil:
            "idle"
        case .refreshing:
            "refreshing"
        case let .selecting(groupName, proxyID):
            "selecting:\(groupName):\(proxyID.sortKey)"
        case let .testingProxy(groupName, proxyID):
            "testingProxy:\(groupName):\(proxyID.sortKey)"
        case let .testingGroup(groupName):
            "testingGroup:\(groupName)"
        }
    }
}

nonisolated private extension ProxyCatalogID {
    var sortKey: String {
        switch origin {
        case .runtime:
            "runtime:\(name)"
        case let .provider(providerName):
            "provider:\(providerName):\(name)"
        }
    }
}
