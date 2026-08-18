import SwiftUI
import VelaIPC

struct OverviewConnectionsSource {
    let snapshot: () -> ConnectionsSnapshot
    let refresh: () async -> Void
    let activate: () -> Void
    let deactivate: () -> Void

    static var unavailable: Self {
        Self(
            snapshot: {
                ConnectionsSnapshot(
                    downloadTotal: 0,
                    uploadTotal: 0,
                    connections: [],
                    memory: nil
                )
            },
            refresh: {},
            activate: {},
            deactivate: {}
        )
    }
}

@MainActor
final class OverviewProxySnapshotCache {
    private enum Key: Equatable {
        case live(Date)
        case staticCatalog(ProxyCatalog)

        init(catalog: ProxyCatalog) {
            if let updatedAt = catalog.updatedAt {
                self = .live(updatedAt)
            } else {
                self = .staticCatalog(catalog)
            }
        }
    }

    private var key: Key?
    private var value: [OverviewNodeSnapshot] = []

    func snapshots(
        for catalog: ProxyCatalog,
        build: () -> [OverviewNodeSnapshot]
    ) -> [OverviewNodeSnapshot] {
        let nextKey = Key(catalog: catalog)
        guard key != nextKey else { return value }

        let nextValue = build()
        key = nextKey
        value = nextValue
        return nextValue
    }
}

struct OverviewView: View {
    @Environment(\.locale) private var locale

    let engineStore: EngineStore
    let connectionsSource: OverviewConnectionsSource

    @State private var trafficHistory = OverviewTrafficHistory()
    @State private var currentDate = Date()
    @State private var proxySnapshotCache = OverviewProxySnapshotCache()
    @State private var showsTunOnboarding = false

    init(
        engineStore: EngineStore,
        connectionsSource: OverviewConnectionsSource = .unavailable
    ) {
        self.engineStore = engineStore
        self.connectionsSource = connectionsSource
    }

    var body: some View {
        OverviewDashboardView(
            snapshot: snapshot,
            isRefreshing: engineStore.isBusy || engineStore.isChangingMode,
            action: perform
        )
        .onAppear {
            connectionsSource.activate()
            beginTrafficGeneration()
            recordTrafficSample(engineStore.trafficSample)
        }
        .onDisappear {
            connectionsSource.deactivate()
        }
        .onChange(of: engineStore.selectedProfileID) { _, _ in
            beginTrafficGeneration()
            recordTrafficSample(engineStore.trafficSample)
        }
        .onChange(of: engineStore.activeRuntime) { _, _ in
            beginTrafficGeneration()
            recordTrafficSample(engineStore.trafficSample)
        }
        .onChange(of: engineStore.trafficSample) { _, sample in
            recordTrafficSample(sample)
        }
        .task(id: runtimeClockGeneration) {
            await updateRuntimeClock()
        }
        .sheet(isPresented: $showsTunOnboarding) {
            TunOnboardingView(engineStore: engineStore)
        }
    }

    private var strings: OverviewStrings {
        OverviewStrings(locale: locale)
    }

    private var snapshot: OverviewSnapshot {
        let state = connectionState
        let proxyGroups = proxyGroupSnapshots
        let node = nodeSnapshot(in: proxyGroups)
        return OverviewSnapshot(
            state: state,
            configurationName: engineStore.selectedProfile?.name,
            node: node,
            proxyGroups: proxyGroups,
            core: coreSnapshot(state: state),
            route: routeSnapshot(state: state, node: node),
            metrics: metricSnapshot,
            connections: connectionSnapshot,
            recovery: recoverySnapshot(state: state)
        )
    }

    private var connectionState: OverviewConnectionState {
        guard engineStore.selectedProfileID != nil else { return .noConfiguration }

        if engineStore.isTrafficTakeoverOperationInProgress {
            return .connecting
        }
        if engineStore.isTrafficTakeoverActive { return .connected }
        if case .failed = engineStore.state { return .error }
        return .disconnected
    }

    private func nodeSnapshot(
        in snapshots: [OverviewNodeSnapshot]
    ) -> OverviewNodeSnapshot? {
        guard let group = summaryProxyGroup else { return snapshots.first }
        return snapshots.first(where: { $0.groupName == group.name }) ?? snapshots.first
    }

    private var proxyGroupSnapshots: [OverviewNodeSnapshot] {
        let catalog = engineStore.proxyCatalog
        return proxySnapshotCache.snapshots(for: catalog) {
            let groups = catalog.groups.filter(\.isSelectable)
            let displayNames = ProxyNodeDisplayNameResolver.displayNames(for: groups)
            return groups.compactMap { group in
                proxyGroupSnapshot(for: group, displayNames: displayNames)
            }
        }
    }

    private func proxyGroupSnapshot(
        for group: ProxyGroup,
        displayNames: [ProxyCatalogID: String]
    ) -> OverviewNodeSnapshot? {
        guard let selectedName = group.now,
            let selectedNode = group.nodes.first(where: { $0.name == selectedName })
        else { return nil }

        return OverviewNodeSnapshot(
            name: displayNames[selectedNode.id] ?? selectedName,
            regionCode: ProxyCountryFlagResolver.regionCode(for: selectedName),
            latency: proxyDelayText(selectedNode.delay),
            groupName: group.name,
            candidates: group.nodes.map { node in
                OverviewProxyNodeSnapshot(
                    id: String(describing: node.id),
                    name: displayNames[node.id] ?? node.name,
                    selectionName: node.name,
                    regionCode: ProxyCountryFlagResolver.regionCode(for: node.name),
                    latency: proxyDelayText(node.delay),
                    isSelected: node.id == selectedNode.id
                )
            }
        )
    }

    private func coreSnapshot(
        state: OverviewConnectionState
    ) -> OverviewConnectionCoreSnapshot {
        let primaryAction = OverviewPrimaryActionDecision.resolve(
            isRunning: engineStore.isTrafficTakeoverActive,
            hasConfiguration: engineStore.selectedProfileID != nil,
            canStart: engineStore.canToggleTrafficTakeover,
            isBusy: engineStore.isTrafficTakeoverOperationInProgress
                || engineStore.isBusy,
            busyReason: strings.operationInProgress,
            startUnavailableReason: strings.startUnavailable
        )

        let primaryValue: String
        switch state {
        case .connected, .degraded:
            primaryValue = rateString(displayedTrafficPoint?.downloadBytesPerSecond)
        case .connecting:
            primaryValue = strings.connecting
        case .disconnected:
            primaryValue = strings.start
        case .noConfiguration:
            primaryValue = strings.chooseConfiguration
        case .error:
            primaryValue = strings.error
        }

        return OverviewConnectionCoreSnapshot(
            state: state,
            statusTitle: statusTitle(state),
            primaryValue: primaryValue,
            download: VelaRuntimeMetricPresentation.value(
                rateString(displayedTrafficPoint?.downloadBytesPerSecond),
                isAvailable: hasLiveRuntimeMetrics(for: state)
            ),
            upload: VelaRuntimeMetricPresentation.value(
                rateString(displayedTrafficPoint?.uploadBytesPerSecond),
                isAvailable: hasLiveRuntimeMetrics(for: state)
            ),
            primaryAction: primaryAction
        )
    }

    private func routeSnapshot(
        state: OverviewConnectionState,
        node: OverviewNodeSnapshot?
    ) -> OverviewRouteState {
        let mode = engineStore.runtimeMode
        let hasLiveRoute = state.isOperational
            && engineStore.controllerState == .connected
            && node != nil

        return OverviewRouteState(
            sourceTitle: strings.thisMac,
            sourceDetail: activeBackendTitle,
            destinationTitle: node?.name ?? strings.internet,
            destinationDetail: node?.groupName ?? strings.routeUnavailable,
            mode: mode,
            modeTitle: mode.map(strings.modeTitle) ?? strings.unavailable,
            modeIsEnabled: engineStore.isRunning
                && engineStore.controllerState == .connected
                && !engineStore.isChangingMode,
            modeDisabledReason: engineStore.isRunning
                && engineStore.controllerState == .connected
                ? nil
                : strings.modeUnavailable,
            isSystemProxyEnabled: engineStore.isSystemProxyApplied,
            systemProxyToggleIsEnabled: engineStore.isSystemProxyApplied
                ? engineStore.canRestoreSystemProxy
                : engineStore.canEnableSystemProxy,
            systemProxyDisabledReason: engineStore.isSystemProxyOperationInProgress
                ? strings.operationInProgress
                : (engineStore.controllerState == .connected
                    ? nil
                    : strings.controllerUnavailable),
            isTunEnabled: engineStore.isTunActive,
            tunToggleIsEnabled: !engineStore.isBusy,
            tunDisabledReason: engineStore.isBusy
                ? strings.operationInProgress
                : nil,
            isAvailable: hasLiveRoute
        )
    }

    private var metricSnapshot: OverviewMetricStripSnapshot {
        let isAvailable = hasLiveRuntimeMetrics(for: connectionState)

        return OverviewMetricStripSnapshot(
            download: VelaRuntimeMetricPresentation.value(
                rateString(displayedTrafficPoint?.downloadBytesPerSecond),
                isAvailable: isAvailable
            ),
            upload: VelaRuntimeMetricPresentation.value(
                rateString(displayedTrafficPoint?.uploadBytesPerSecond),
                isAvailable: isAvailable
            ),
            activeConnections: VelaRuntimeMetricPresentation.value(
                String(connectionSnapshot.activeCount),
                isAvailable: isAvailable
            ),
            runtime: VelaRuntimeMetricPresentation.value(
                runtimeText,
                isAvailable: isAvailable
            ),
            trafficPoints: isAvailable ? trafficHistory.points : []
        )
    }

    private func hasLiveRuntimeMetrics(for state: OverviewConnectionState) -> Bool {
        state.isOperational && engineStore.controllerState == .connected
    }

    private var connectionSnapshot: OverviewConnectionSnapshot {
        OverviewConnectionSnapshot(snapshot: connectionsSource.snapshot())
    }

    private func recoverySnapshot(
        state: OverviewConnectionState
    ) -> OverviewRecoverySnapshot? {
        switch state {
        case .connected, .connecting, .disconnected:
            return nil
        case .noConfiguration:
            return OverviewRecoverySnapshot(
                title: strings.noConfigurationTitle,
                detail: strings.noConfigurationDetail,
                actionTitle: strings.chooseConfiguration,
                systemImage: "doc.badge.plus",
                action: .chooseConfiguration,
                isEnabled: true,
                disabledReason: nil
            )
        case .error:
            return OverviewRecoverySnapshot(
                title: strings.controllerErrorTitle,
                detail: strings.controllerErrorDetail,
                actionTitle: strings.retry,
                systemImage: "network.slash",
                action: .retry,
                isEnabled: !engineStore.isBusy,
                disabledReason: engineStore.isBusy ? strings.operationInProgress : nil
            )
        case .degraded:
            return OverviewRecoverySnapshot(
                title: strings.degradedTitle,
                detail: engineStore.lastHealthReport?.issues.first?.summary
                    ?? strings.degradedDetail,
                actionTitle: strings.openDiagnostics,
                systemImage: "exclamationmark.triangle",
                action: .openDiagnostics,
                isEnabled: true,
                disabledReason: nil
            )
        }
    }

    private func statusTitle(_ state: OverviewConnectionState) -> String {
        switch state {
        case .connected: strings.connected
        case .connecting: strings.connecting
        case .disconnected: strings.disconnected
        case .noConfiguration: strings.noConfiguration
        case .error: strings.error
        case .degraded: strings.degraded
        }
    }

    private var displayedTrafficPoint: OverviewTrafficPoint? {
        engineStore.trafficSample.map(OverviewTrafficPoint.init) ?? trafficHistory.points.last
    }

    private var activeBackendTitle: String {
        if engineStore.isTunActive { return "TUN" }
        if engineStore.isSystemProxyApplied { return "System Proxy" }
        return engineStore.isRunning ? strings.routeReady : strings.routeUnavailable
    }

    private var runtimeText: String {
        guard let startedAt = engineStore.trafficTakeoverStartedAt else {
            return "—"
        }
        let elapsed = max(0, Int(currentDate.timeIntervalSince(startedAt)))
        let hours = elapsed / 3_600
        let minutes = (elapsed % 3_600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }

    private var summaryProxyGroup: ProxyGroup? {
        engineStore.proxyCatalog.groups.first { group in
            guard let now = group.now else { return false }
            return group.nodes.contains { $0.name == now }
        }
    }

    private var trafficGeneration: String {
        let profile = engineStore.selectedProfileID?.uuidString ?? "no-configuration"
        let runtime = engineStore.activeRuntime?.instanceID.uuidString ?? "stopped"
        return "\(profile)|\(runtime)"
    }

    private var runtimeClockGeneration: Date? {
        engineStore.trafficTakeoverStartedAt
    }

    private func updateRuntimeClock() async {
        currentDate = Date()
        guard engineStore.trafficTakeoverStartedAt != nil else { return }
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                return
            }
            currentDate = Date()
        }
    }

    private func perform(_ action: OverviewDashboardAction) {
        switch action {
        case let .primary(primaryAction):
            performPrimary(primaryAction)
        case let .selectProxy(group, proxy):
            engineStore.requestProxySelection(group: group, proxy: proxy)
        case let .changeMode(mode):
            Task { await engineStore.changeMode(mode) }
        case let .setSystemProxyEnabled(enabled):
            engineStore.requestSystemProxyEnabled(enabled)
        case let .setTunEnabled(enabled):
            switch OverviewTunActionDecision.resolve(
                requestedEnabled: enabled,
                privilegedComponentIsReady: engineStore.privilegedComponentIsReady
            ) {
            case .showSetup:
                showsTunOnboarding = true
            case let .apply(requestedEnabled):
                Task { await engineStore.setTunEnabled(requestedEnabled) }
            }
        case .openProxies:
            SettingsMainNavigationRequest.navigateInCurrentWindow(.proxies)
        case .openConnections:
            SettingsMainNavigationRequest.navigateInCurrentWindow(.connections)
        case .openDiagnostics:
            SettingsMainNavigationRequest.navigateInCurrentWindow(.diagnostics)
        case .openConfiguration:
            SettingsMainNavigationRequest.navigateInCurrentWindow(.configuration)
        case let .recovery(recoveryAction):
            performRecovery(recoveryAction)
        }
    }

    private func performPrimary(_ primaryAction: OverviewPrimaryAction) {
        switch primaryAction {
        case .start:
            Task { await engineStore.setTrafficTakeoverEnabled(true) }
        case .pause:
            Task { await engineStore.setTrafficTakeoverEnabled(false) }
        case .chooseConfiguration:
            SettingsMainNavigationRequest.navigateInCurrentWindow(.configuration)
        }
    }

    private func performRecovery(_ recoveryAction: OverviewRecoveryAction) {
        switch recoveryAction {
        case .chooseConfiguration:
            SettingsMainNavigationRequest.navigateInCurrentWindow(.configuration)
        case .start:
            Task { await engineStore.setTrafficTakeoverEnabled(true) }
        case .retry:
            Task {
                await engineStore.setTrafficTakeoverEnabled(true)
                await connectionsSource.refresh()
            }
        case .openDiagnostics:
            SettingsMainNavigationRequest.navigateInCurrentWindow(.diagnostics)
        }
    }

    private func beginTrafficGeneration() {
        trafficHistory.beginGeneration(trafficGeneration)
    }

    private func recordTrafficSample(_ sample: TrafficSample?) {
        guard let sample else { return }
        trafficHistory.record(
            OverviewTrafficPoint(sample),
            generation: trafficGeneration
        )
    }

    private func rateString(_ bytesPerSecond: Int64?) -> String {
        guard let bytesPerSecond else { return "—" }
        return ByteCountFormatter.string(
            fromByteCount: max(0, bytesPerSecond),
            countStyle: .file
        ) + "/s"
    }

    private func proxyDelayText(_ delay: ProxyDelay) -> String? {
        switch delay {
        case let .measured(milliseconds):
            return "\(milliseconds) ms"
        case .unavailable, .untested:
            return nil
        }
    }
}

private extension OverviewTrafficPoint {
    init(_ sample: TrafficSample) {
        self.init(
            timestamp: sample.timestamp,
            downloadBytesPerSecond: sample.downloadBytesPerSecond,
            uploadBytesPerSecond: sample.uploadBytesPerSecond,
            totalDownloadBytes: sample.totalDownloadBytes,
            totalUploadBytes: sample.totalUploadBytes
        )
    }
}
