import SwiftUI

struct ProxiesView: View {
#if DEBUG
    @Environment(\.visualUITestConfiguration) private var visualTestConfiguration
#endif

    let engineStore: EngineStore

    @State private var selectedGroupID: ProxiesGroupID?
    @State private var showsInspector = true

    var body: some View {
        ProxiesLiquidGlassDashboardView(
            snapshot: snapshot,
            runtimeMode: engineStore.runtimeMode,
            isTrafficConnected: engineStore.isTrafficTakeoverActive,
            selectedGroupID: $selectedGroupID,
            showsInspector: $showsInspector,
            action: perform
        )
        .task(id: snapshot.generation) {
            selectedGroupID = snapshot.resolvingSelection(selectedGroupID)
#if DEBUG
            if let visualTestConfiguration {
                showsInspector = visualTestConfiguration.inspector == .open
            }
#endif
        }
        .task(id: engineStore.selectedProfileID) {
            await engineStore.refreshConfiguredProxyCatalog()
        }
    }

    private var snapshot: ProxiesPresentationSnapshot {
        ProxiesPresentationFactory.make(
            catalog: engineStore.proxyCatalog,
            controllerState: engineStore.controllerState,
            isLoading: engineStore.isLoadingProxies,
            operation: engineStore.proxyOperation,
            delayStates: delayStates,
            selectedGroupID: selectedGroupID,
            errorSummary: engineStore.proxyCatalogError.map(
                DiagnosticTextSanitizer.redact
            )
        )
    }

    private var delayStates: [ProxiesDelayKey: ProxyDelayState] {
        var result: [ProxiesDelayKey: ProxyDelayState] = [:]
        for group in engineStore.proxyCatalog.groups {
            let groupID = ProxiesGroupID(rawValue: group.name)
            for node in group.nodes {
                guard let state = engineStore.proxyDelayState(
                    group: group.name,
                    nodeID: node.id
                ) else { continue }
                result[ProxiesDelayKey(groupID: groupID, nodeID: node.id)] = state
            }
        }
        return result
    }

    @MainActor
    private func perform(_ action: ProxiesDashboardAction) {
        switch action {
        case .refresh:
            Task { await engineStore.refreshProxies() }
        case let .testGroup(groupID):
            Task { await engineStore.testProxyGroupDelay(group: groupID.rawValue) }
        case let .testGroups(groupIDs):
            Task {
                for groupID in groupIDs {
                    guard !Task.isCancelled else { return }
                    await engineStore.testProxyGroupDelay(
                        group: groupID.rawValue,
                        showsFailureAlert: false
                    )
                }
            }
        case let .testProxy(groupID, nodeID):
            Task {
                await engineStore.testProxyDelay(
                    group: groupID.rawValue,
                    nodeID: nodeID
                )
            }
        case let .selectProxy(groupID, nodeID):
            engineStore.requestProxySelection(
                group: groupID.rawValue,
                nodeID: nodeID
            )
        case .openConfiguration:
            SettingsMainNavigationRequest.navigateInCurrentWindow(.configuration)
        case .openDiagnostics:
            SettingsMainNavigationRequest.navigateInCurrentWindow(.diagnostics)
        }
    }
}

nonisolated enum ProxiesDashboardAction: Equatable, Sendable {
    case refresh
    case testGroup(ProxiesGroupID)
    case testGroups([ProxiesGroupID])
    case testProxy(ProxiesGroupID, ProxyCatalogID)
    case selectProxy(ProxiesGroupID, ProxyCatalogID)
    case openConfiguration
    case openDiagnostics
}

struct ProxiesDashboardView: View {
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let snapshot: ProxiesPresentationSnapshot
    @Binding var selectedGroupID: ProxiesGroupID?
    @Binding var showsInspector: Bool
    let action: @MainActor (ProxiesDashboardAction) -> Void

    @State private var searchText = ""
    @State private var isSearchPresented = false
    @State private var lastWorkspaceWidth: CGFloat = .infinity
    @State private var retainedLayoutMetrics: ProxiesLayoutMetrics?
    @State private var inspectorTransitionGeneration = 0
    @State private var selectedCandidateID: ProxyCatalogID?
    @State private var selectedTypeFilter = "all"
    @State private var selectedStrategyFilter = "all"
    @State private var sortOrder = [
        KeyPathComparator(\ProxiesGroupRowSnapshot.name),
    ]

    var body: some View {
        pageViewport
            .navigationTitle(strings.proxies)
            .searchable(
                text: $searchText,
                isPresented: $isSearchPresented,
                prompt: strings.searchPrompt
            )
            .inspector(isPresented: inspectorBinding) {
                inspector
                    .inspectorColumnWidth(
                        min: ProxiesLayoutMetrics.inspectorMinimumWidth,
                        ideal: ProxiesLayoutMetrics.inspectorIdealWidth,
                        max: ProxiesLayoutMetrics.inspectorMaximumWidth
                    )
            }
            .toolbar { toolbarContent }
            .task(id: selectionGeneration) {
                selectedGroupID = resolvedSelection
            }
            .onReceive(NotificationCenter.default.publisher(for: .velaFocusSearch)) { _ in
                isSearchPresented = true
            }
    }

    private var strings: ProxiesStrings {
        ProxiesStrings(locale: locale)
    }

    private var pageViewport: some View {
        GeometryReader { viewport in
            page
                .frame(
                    width: viewport.size.width,
                    height: viewport.size.height,
                    alignment: .topLeading
                )
                .clipped()
        }
    }

    private var page: some View {
        VStack(spacing: 0) {
            stateBanner
            filterBar
            Divider()
            workspace
        }
        .velaPageRoot()
    }

    private var filterBar: some View {
        HStack(spacing: VelaSpacing.small) {
            Menu {
                Button(strings.allTypes) { selectedTypeFilter = "all" }
                ForEach(availableTypes, id: \.self) { type in
                    Button(type) { selectedTypeFilter = type }
                }
            } label: {
                Label(
                    selectedTypeFilter == "all" ? strings.allTypes : selectedTypeFilter,
                    systemImage: "line.3.horizontal.decrease.circle"
                )
            }

            Menu {
                Button(strings.allStrategies) { selectedStrategyFilter = "all" }
                ForEach(availableStrategies, id: \.self) { strategy in
                    Button(strategy) { selectedStrategyFilter = strategy }
                }
            } label: {
                Text(selectedStrategyFilter == "all" ? strings.allStrategies : selectedStrategyFilter)
            }

            Spacer(minLength: VelaSpacing.small)

            Text(strings.groupCount(displayedRows.count))
                .font(VelaTypography.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .controlSize(.regular)
        .padding(.horizontal, VelaSpacing.standard)
        .padding(.vertical, VelaSpacing.small)
        .accessibilityIdentifier("proxies.filters")
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            if snapshot.actions.showsOpenConfiguration {
                Button {
                    action(.openConfiguration)
                } label: {
                    Label(strings.openConfiguration, systemImage: "doc.badge.gearshape")
                }
                .accessibilityIdentifier("proxies.openConfiguration")
            } else {
                Button {
                    action(.refresh)
                } label: {
                    if snapshot.state == .refreshing {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel(strings.refreshing)
                    } else {
                        Label(strings.refresh, systemImage: "arrow.clockwise")
                    }
                }
                .help(strings.refreshHelp)
                .accessibilityIdentifier("proxies.refresh")
                .disabled(!snapshot.actions.canRefresh)
            }

            if let selectedGroupID = resolvedSelection,
                !snapshot.rows.isEmpty
            {
                Button {
                    action(.testGroup(selectedGroupID))
                } label: {
                    Label(strings.testGroup, systemImage: "gauge.with.dots.needle.50percent")
                }
                .help(
                    snapshot.actions.canTestGroup
                        ? strings.testGroupHelp
                        : strings.actionUnavailableWhileBusy
                )
                .accessibilityHint(
                    snapshot.actions.canTestGroup
                        ? strings.testGroupHelp
                        : strings.actionUnavailableWhileBusy
                )
                .accessibilityIdentifier("proxies.testAll")
                .disabled(!snapshot.actions.canTestGroup)
            }

            if snapshot.actions.showsDiagnostics {
                Button {
                    action(.openDiagnostics)
                } label: {
                    Label(strings.openDiagnostics, systemImage: "stethoscope")
                }
                .accessibilityIdentifier("proxies.openDiagnostics")
            }

            Button {
                setInspectorPresented(!showsInspector)
            } label: {
                Label(strings.toggleInspector, systemImage: "sidebar.right")
            }
            .help(showsInspector ? strings.hideInspector : strings.showInspector)
            .accessibilityIdentifier("proxies.toggleInspector")
        }
    }

    @ViewBuilder
    private var stateBanner: some View {
        switch snapshot.state {
        case .loaded, .empty, .fullFailure, .loading:
            EmptyView()
        case .refreshing:
            banner(
                kind: .info,
                title: strings.refreshing,
                detail: strings.refreshingDetail
            )
        case .pendingMutation:
            banner(
                kind: .recovery,
                title: strings.applyingSelection,
                detail: strings.applyingSelectionDetail
            )
        case .stale:
            banner(
                kind: .stale,
                title: strings.staleData,
                detail: strings.staleDetail
            )
        case .partialFailure:
            banner(
                kind: .warning,
                title: strings.partialFailure,
                detail: snapshot.errorSummary ?? strings.partialFailureDetail
            )
        case .offline:
            banner(
                kind: .stale,
                title: strings.controllerOffline,
                detail: strings.offlineDetail
            )
        }
    }

    private func banner(
        kind: VelaStateBannerKind,
        title: String,
        detail: String
    ) -> some View {
        VelaStateBanner(kind: kind, title: title, detail: detail)
            .padding(.horizontal, VelaSpacing.standard)
            .padding(.vertical, VelaSpacing.small)
    }

    private var workspace: some View {
        GeometryReader { proxy in
            let metrics = retainedLayoutMetrics
                ?? ProxiesLayoutMetrics.resolve(tableWidth: proxy.size.width)
            ZStack {
                proxyTable(metrics: metrics)
                if visibleRows.isEmpty {
                    workspaceOverlay
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear {
                lastWorkspaceWidth = proxy.size.width
            }
            .onChange(of: proxy.size.width) { _, width in
                lastWorkspaceWidth = width
            }
        }
    }

    private var inspectorBinding: Binding<Bool> {
        Binding(
            get: { showsInspector },
            set: { isPresented in
                setInspectorPresented(isPresented)
            }
        )
    }

    private func setInspectorPresented(_ isPresented: Bool) {
        guard showsInspector != isPresented else { return }

        retainedLayoutMetrics = ProxiesLayoutMetrics.resolve(
            tableWidth: lastWorkspaceWidth
        )
        inspectorTransitionGeneration &+= 1
        let generation = inspectorTransitionGeneration

        withAnimation(
            VelaMotion.animation(VelaMotion.slowSeconds, reduceMotion: reduceMotion)
        ) {
            showsInspector = isPresented
        }

        guard !reduceMotion else {
            retainedLayoutMetrics = nil
            return
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(VelaMotion.slowSeconds))
            guard generation == inspectorTransitionGeneration else { return }
            retainedLayoutMetrics = nil
        }
    }

    @ViewBuilder
    private func proxyTable(metrics: ProxiesLayoutMetrics) -> some View {
        VStack(spacing: 0) {
            nodeTableHeader(metrics: metrics)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(displayedRows) { row in
                        VStack(spacing: 0) {
                            groupHeader(row)
                            if let group = snapshot.groups[row.id] {
                                ForEach(filteredCandidates(in: group)) { candidate in
                                    nodeRow(candidate, group: group, metrics: metrics)
                                    Divider()
                                }
                            }
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier("proxies.groups.table")
    }

    private func nodeTableHeader(metrics: ProxiesLayoutMetrics) -> some View {
        HStack(spacing: 0) {
            tableHeader(strings.name, width: 220, alignment: .leading)
            tableHeader(strings.columnType, width: 116, alignment: .leading)
            tableHeader(strings.address, width: nil, alignment: .leading)
            tableHeader(strings.latency, width: 132, alignment: .trailing)
            if metrics.showsStatusColumn {
                tableHeader(strings.testResult, width: 108, alignment: .center)
            }
        }
        .frame(height: VelaMetrics.tableRowHeight)
        .padding(.horizontal, VelaSpacing.standard)
        .background(.bar)
    }

    private func tableHeader(
        _ title: String,
        width: CGFloat?,
        alignment: Alignment
    ) -> some View {
        Text(title)
            .font(VelaTypography.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(width: width, alignment: alignment)
            .frame(maxHeight: .infinity)
    }

    private func groupHeader(_ row: ProxiesGroupRowSnapshot) -> some View {
        Button {
            selectedGroupID = row.id
            selectedCandidateID = snapshot.groups[row.id]?.candidates.first(where: \.isCurrent)?.id
        } label: {
            HStack(spacing: VelaSpacing.small) {
                Text(row.name.uppercased())
                    .font(VelaTypography.caption.weight(.semibold))
                Text(row.strategy)
                    .font(VelaTypography.caption)
                    .foregroundStyle(.secondary)
                Text(verbatim: "\(row.candidateCount)")
                    .font(VelaTypography.caption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
            .padding(.horizontal, VelaSpacing.standard)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .background(.bar)
    }

    private func nodeRow(
        _ candidate: ProxiesCandidateSnapshot,
        group: ProxiesGroupInspectorSnapshot,
        metrics: ProxiesLayoutMetrics
    ) -> some View {
        let isSelected = selectedGroupID == group.id && selectedCandidateID == candidate.id
        return Button {
            selectedGroupID = group.id
            selectedCandidateID = candidate.id
            if !showsInspector { setInspectorPresented(true) }
        } label: {
            HStack(spacing: 0) {
                HStack(spacing: VelaSpacing.small) {
                    Image(systemName: candidate.isCurrent ? "record.circle.fill" : "circle")
                        .foregroundStyle(candidate.isCurrent ? Color.accentColor : Color.secondary)
                        .accessibilityHidden(true)
                    Text(candidate.name)
                        .font(VelaTypography.table.weight(.medium))
                        .lineLimit(1)
                }
                .frame(width: 220, alignment: .leading)

                Text(candidate.type ?? strings.unknown)
                    .frame(width: 116, alignment: .leading)

                Text(candidate.source)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                latencyBadge(candidate.latency)
                    .frame(width: 132, alignment: .trailing)

                if metrics.showsStatusColumn {
                    Image(systemName: candidateTestSymbol(candidate))
                        .foregroundStyle(candidateTestTint(candidate))
                        .frame(width: 108, alignment: .center)
                        .accessibilityLabel(candidateDetail(candidate))
                }
            }
            .font(VelaTypography.table)
            .frame(maxWidth: .infinity, minHeight: ProxiesLayoutMetrics.tableRowHeight)
            .padding(.horizontal, VelaSpacing.standard)
            .contentShape(.rect)
            .background(isSelected ? Color.accentColor.opacity(0.20) : Color.clear)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("proxies.node.\(group.id.rawValue).\(candidate.id.name)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func candidateTestSymbol(_ candidate: ProxiesCandidateSnapshot) -> String {
        if candidate.latency.state == .testing { return "arrow.triangle.2.circlepath" }
        if candidate.latency.state == .failed || candidate.isAvailable == false { return "xmark.circle.fill" }
        if candidate.latency.milliseconds != nil { return "checkmark.circle.fill" }
        return "circle"
    }

    private func candidateTestTint(_ candidate: ProxiesCandidateSnapshot) -> Color {
        if candidate.latency.state == .failed || candidate.isAvailable == false { return .red }
        if candidate.latency.milliseconds != nil { return .green }
        return .secondary
    }

    private func groupCell(_ row: ProxiesGroupRowSnapshot) -> some View {
        HStack(spacing: VelaSpacing.small) {
            if row.isPending {
                ProgressView()
                    .controlSize(.mini)
                    .accessibilityHidden(true)
            }
            Text(row.name)
                .font(VelaTypography.table.weight(.medium))
                .lineLimit(1)
                .accessibilityIdentifier("proxies.group.\(row.id.rawValue)")
            Text(verbatim: "\(row.candidateCount)")
                .font(VelaTypography.caption)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
        .frame(height: ProxiesLayoutMetrics.tableCellContentHeight)
    }

    private func currentProxyCell(_ row: ProxiesGroupRowSnapshot) -> some View {
        Text(row.currentProxy ?? strings.none)
            .font(VelaTypography.table)
            .lineLimit(1)
            .help(row.currentProxy ?? strings.none)
            .frame(height: ProxiesLayoutMetrics.tableCellContentHeight)
    }

    @ViewBuilder
    private var workspaceOverlay: some View {
        switch snapshot.state {
        case .loading:
            VelaLoadingState(
                title: strings.loadingProxyGroups,
                detail: strings.loadingDetail
            )
            .accessibilityIdentifier("proxies.state.loading")
        case .empty:
            VelaEmptyState(
                title: strings.noProxyGroups,
                description: strings.emptyDetail,
                systemImage: "square.stack.3d.up.slash"
            )
            .accessibilityIdentifier("proxies.state.empty")
        case .fullFailure:
            VelaEmptyState(
                title: strings.proxyGroupsUnavailable,
                description: snapshot.errorSummary ?? strings.failureDetail,
                systemImage: "exclamationmark.triangle"
            )
            .accessibilityIdentifier("proxies.state.failure")
        case .offline:
            VelaEmptyState(
                title: strings.proxyCatalogUnavailable,
                description: strings.offlineDetail,
                systemImage: "network.slash"
            )
            .accessibilityIdentifier("proxies.state.offline")
        case .loaded, .refreshing, .pendingMutation, .stale, .partialFailure:
            VelaEmptyState(
                title: strings.noMatchingGroups,
                description: strings.noMatchingDetail,
                systemImage: "line.3.horizontal.decrease.circle"
            ) {
                Button(strings.clearSearch) { searchText = "" }
            }
            .accessibilityIdentifier("proxies.state.filteredEmpty")
        }
#if DEBUG
        VisualReadyMarker(fixtureID: "proxies.\(snapshot.state.rawValue)")
#endif
    }

    private var inspector: some View {
        Group {
            switch snapshot.inspectorState(for: resolvedSelection) {
            case .loading:
                inspectorEmpty(
                    title: strings.loadingProxyGroups,
                    detail: strings.loadingDetail,
                    systemImage: "point.3.connected.trianglepath.dotted"
                )
            case .noSelection:
                inspectorEmpty(
                    title: strings.proxyGroupDetails,
                    detail: strings.selectGroupDetail,
                    systemImage: "sidebar.right"
                )
            case let .selected(group):
                groupInspector(group)
            case .empty:
                inspectorEmpty(
                    title: strings.noProxyGroups,
                    detail: strings.emptyDetail,
                    systemImage: "square.stack.3d.up.slash",
                    primaryTitle: strings.openConfiguration,
                    primaryAction: .openConfiguration
                )
            case let .failure(summary):
                inspectorEmpty(
                    title: strings.proxyGroupsUnavailable,
                    detail: summary ?? strings.failureDetail,
                    systemImage: "exclamationmark.triangle",
                    primaryTitle: strings.retry,
                    primaryAction: .refresh,
                    secondaryTitle: strings.openDiagnostics,
                    secondaryAction: .openDiagnostics
                )
            case .offline:
                inspectorEmpty(
                    title: strings.controllerOffline,
                    detail: strings.offlineDetail,
                    systemImage: "network.slash",
                    primaryTitle: strings.openDiagnostics,
                    primaryAction: .openDiagnostics
                )
            }
        }
    }

    private func groupInspector(_ group: ProxiesGroupInspectorSnapshot) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: VelaSpacing.xSmall) {
                    Text(group.name)
                        .font(VelaTypography.pageTitle)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text(strings.groupSubtitle(
                        strategy: group.strategy,
                        candidateCount: group.candidates.count
                    ))
                    .font(VelaTypography.caption)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, VelaSpacing.standard)

                if let failureSummary = group.failureSummary {
                    VelaStateBanner(
                        kind: snapshot.state == .stale ? .stale : .warning,
                        title: snapshot.state == .stale
                            ? strings.staleData
                            : strings.partialFailure,
                        detail: failureSummary
                    )
                    .padding(.top, VelaSpacing.standard)
                }

                VelaInspectorSection(title: strings.currentSelection) {
                    VStack(spacing: VelaSpacing.small) {
                        inspectorValue(
                            strings.currentProxy,
                            group.currentProxy ?? strings.none
                        )
                        LabeledContent(strings.latency) {
                            latencyBadge(group.currentLatency)
                        }
                        inspectorValue(
                            strings.status,
                            strings.statusLabel(group.semanticStatus)
                        )

                        if let requestedProxy = group.requestedProxy {
                            Divider()
                            inspectorValue(strings.requestedProxy, requestedProxy)
                            inspectorValue(strings.phase, strings.applying)
                        }

                        if group.allowsManualSelection {
                            changeProxyMenu(group)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            Label(strings.automaticStrategy, systemImage: "gearshape.2")
                                .font(VelaTypography.body)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }

                VelaInspectorSection(
                    title: strings.candidates,
                    subtitle: strings.candidateCount(group.candidates.count)
                ) {
                    if group.candidates.isEmpty {
                        Text(strings.candidateDetailsUnavailable)
                            .font(VelaTypography.body)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(group.candidates) { candidate in
                                candidateRow(candidate, group: group)
                                if candidate.id != group.candidates.last?.id {
                                    Divider()
                                }
                            }
                        }
                    }
                }

                VelaInspectorSection(title: strings.strategyAndSource) {
                    VStack(spacing: VelaSpacing.small) {
                        inspectorValue(strings.type, group.strategy)
                        if let source = group.sourceSummary {
                            inspectorValue(strings.source, source)
                        }
                    }
                }

                VelaInspectorSection(title: strings.healthEvidence) {
                    VStack(spacing: VelaSpacing.small) {
                        inspectorValue(
                            strings.snapshotAge,
                            strings.snapshotAge(
                                group.snapshotUpdatedAt,
                                relativeTo: group.referenceDate
                            )
                        )
                        inspectorValue(
                            strings.samples,
                            "\(group.measuredSampleCount)"
                        )
                    }
                }

                VelaInspectorSection(title: strings.actions, showsDivider: false) {
                    VStack(spacing: VelaSpacing.small) {
                        Button {
                            action(.testGroup(group.id))
                        } label: {
                            Label(strings.testGroup, systemImage: "gauge.with.dots.needle.50percent")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .disabled(!group.canTest)
                        .help(
                            group.canTest
                                ? strings.testGroupHelp
                                : strings.actionUnavailableWhileBusy
                        )
                        .accessibilityHint(
                            group.canTest
                                ? strings.testGroupHelp
                                : strings.actionUnavailableWhileBusy
                        )

                        if let current = group.candidates.first(where: \.isCurrent) {
                            Button {
                                action(.testProxy(group.id, current.id))
                            } label: {
                                Label(strings.testSelectedProxy, systemImage: "waveform.path.ecg")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .disabled(!group.canTest || current.isPlaceholder)
                            .help(
                                group.canTest
                                    ? strings.testSelectedProxy
                                    : strings.actionUnavailableWhileBusy
                            )
                            .accessibilityHint(
                                group.canTest
                                    ? strings.testSelectedProxy
                                    : strings.actionUnavailableWhileBusy
                            )
                        }
                    }
                    .controlSize(.regular)
                }
            }
            .padding(.horizontal, VelaSpacing.standard)
            .padding(.bottom, VelaSpacing.standard)
        }
        .accessibilityIdentifier("proxies.inspector.group.\(group.id.rawValue)")
    }

    private func candidateRow(
        _ candidate: ProxiesCandidateSnapshot,
        group: ProxiesGroupInspectorSnapshot
    ) -> some View {
        let canSelect = group.allowsManualSelection
            && snapshot.actions.canMutateSelection
            && !candidate.isCurrent
            && !candidate.isPlaceholder

        return Button {
            action(.selectProxy(group.id, candidate.id))
        } label: {
            HStack(spacing: VelaSpacing.small) {
                Image(systemName: candidateSymbol(candidate))
                    .foregroundStyle(candidateTint(candidate))
                    .frame(width: VelaSpacing.standard)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: VelaSpacing.micro) {
                    Text(candidate.name)
                        .font(VelaTypography.table.weight(.medium))
                        .lineLimit(1)
                    Text(candidateDetail(candidate))
                        .font(VelaTypography.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: VelaSpacing.small)
                latencyBadge(candidate.latency)
            }
            .padding(.vertical, VelaSpacing.xSmall)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canSelect)
        .help(canSelect ? strings.useProxy(candidate.name) : candidateDetail(candidate))
        .accessibilityLabel(strings.candidateAccessibility(candidate))
        .accessibilityIdentifier("proxies.candidate.\(candidate.id.name)")
    }

    private func changeProxyMenu(
        _ group: ProxiesGroupInspectorSnapshot
    ) -> some View {
        Menu {
            ForEach(group.candidates) { candidate in
                Button {
                    action(.selectProxy(group.id, candidate.id))
                } label: {
                    Label(
                        candidate.name,
                        systemImage: candidate.isCurrent ? "checkmark" : "circle"
                    )
                }
                .disabled(
                    candidate.isCurrent
                        || candidate.isPlaceholder
                        || !snapshot.actions.canMutateSelection
                )
            }
        } label: {
            Label(strings.changeProxy, systemImage: "arrow.left.arrow.right")
        }
        .controlSize(.regular)
        .disabled(
            group.candidates.allSatisfy { $0.isCurrent || $0.isPlaceholder }
                || !snapshot.actions.canMutateSelection
        )
        .accessibilityIdentifier("proxies.changeProxy")
    }

    private func inspectorEmpty(
        title: String,
        detail: String,
        systemImage: String,
        primaryTitle: String? = nil,
        primaryAction: ProxiesDashboardAction? = nil,
        secondaryTitle: String? = nil,
        secondaryAction: ProxiesDashboardAction? = nil
    ) -> some View {
        VelaEmptyState(
            title: title,
            description: detail,
            systemImage: systemImage
        ) {
            HStack(spacing: VelaSpacing.small) {
                if let primaryTitle, let primaryAction {
                    Button(primaryTitle) { action(primaryAction) }
                        .velaEmptyStateAction()
                        .buttonStyle(.borderedProminent)
                }
                if let secondaryTitle, let secondaryAction {
                    Button(secondaryTitle) { action(secondaryAction) }
                        .velaEmptyStateAction()
                        .buttonStyle(.bordered)
                }
            }
        }
    }

    private func latencyBadge(_ latency: ProxiesLatencySnapshot) -> some View {
        VelaLatencyBadge(
            state: latency.state,
            milliseconds: latency.milliseconds
        )
        .help(latency.diagnostic ?? latency.state.label)
    }

    private func inspectorValue(_ title: String, _ value: String) -> some View {
        LabeledContent(title) {
            Text(value)
                .font(VelaTypography.body)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
        }
    }

    private func candidateSymbol(_ candidate: ProxiesCandidateSnapshot) -> String {
        if candidate.isRequested { return "clock.fill" }
        if candidate.isCurrent { return "checkmark.circle.fill" }
        if candidate.isFixed { return "pin.circle.fill" }
        if candidate.isPlaceholder || candidate.isAvailable == false {
            return "xmark.circle"
        }
        return "circle"
    }

    private func candidateTint(_ candidate: ProxiesCandidateSnapshot) -> Color {
        if candidate.isRequested { return .blue }
        if candidate.isCurrent || candidate.isFixed { return .accentColor }
        if candidate.isPlaceholder || candidate.isAvailable == false { return .red }
        return .secondary
    }

    private func candidateDetail(_ candidate: ProxiesCandidateSnapshot) -> String {
        var values = [candidate.type, candidate.source].compactMap { $0 }
        if candidate.isRequested { values.append(strings.requested) }
        else if candidate.isCurrent { values.append(strings.current) }
        else if candidate.isFixed { values.append(strings.pinned) }
        else if candidate.isAvailable == false { values.append(strings.unavailable) }
        return values.joined(separator: " · ")
    }

    private var availableTypes: [String] {
        Array(Set(snapshot.groups.values.flatMap(\.candidates).compactMap(\.type))).sorted()
    }

    private var availableStrategies: [String] {
        Array(Set(snapshot.rows.map(\.strategy))).sorted()
    }

    private func filteredCandidates(
        in group: ProxiesGroupInspectorSnapshot
    ) -> [ProxiesCandidateSnapshot] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return group.candidates.filter { candidate in
            let matchesType = selectedTypeFilter == "all" || candidate.type == selectedTypeFilter
            let matchesQuery = query.isEmpty
                || candidate.name.localizedCaseInsensitiveContains(query)
                || candidate.source.localizedCaseInsensitiveContains(query)
                || candidate.type?.localizedCaseInsensitiveContains(query) == true
                || group.name.localizedCaseInsensitiveContains(query)
            return matchesType && matchesQuery
        }
    }

    private var visibleRows: [ProxiesGroupRowSnapshot] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return snapshot.rows.filter { row in
            guard selectedStrategyFilter == "all" || row.strategy == selectedStrategyFilter else {
                return false
            }
            guard let group = snapshot.groups[row.id] else { return false }
            if query.isEmpty && selectedTypeFilter == "all" { return true }
            return !filteredCandidates(in: group).isEmpty
        }
    }

    private var resolvedSelection: ProxiesGroupID? {
        ProxiesSelectionPolicy.resolve(selectedGroupID, rows: displayedRows)
    }

    private var displayedRows: [ProxiesGroupRowSnapshot] {
        visibleRows.sorted(using: sortOrder)
    }

    private var tableSelection: Binding<ProxiesGroupID?> {
        Binding(
            get: { resolvedSelection },
            set: { selectedGroupID = $0 }
        )
    }

    private var selectionGeneration: String {
        let visibleIdentity = displayedRows.map(\.id.rawValue).joined(separator: "|")
        return "\(snapshot.generation)#\(visibleIdentity)"
    }
}

nonisolated struct ProxiesStrings {
    let locale: Locale

    var proxies: String { value("navigation.proxies", "Proxies") }
    var searchPrompt: String { value("proxies.search.prompt", "Group, current proxy, or strategy") }
    var group: String { value("proxies.column.group", "Group") }
    var name: String { value("proxies.column.name", "Name") }
    var columnType: String { value("proxies.column.type", "Type") }
    var address: String { value("proxies.column.address", "Address / Source") }
    var testResult: String { value("proxies.column.testResult", "Test Result") }
    var allTypes: String { value("proxies.filter.allTypes", "All Types") }
    var allStrategies: String { value("proxies.filter.allStrategies", "All Strategies") }
    var unknown: String { value("proxies.value.unknown", "Unknown") }
    var currentProxy: String { value("proxies.column.currentProxy", "Current Proxy") }
    var strategy: String { value("proxies.column.strategy", "Strategy") }
    var latency: String { value("proxies.column.latency", "Latency") }
    var status: String { value("proxies.column.status", "Status") }
    var none: String { value("proxies.value.none", "None") }

    func groupCount(_ count: Int) -> String {
        value("proxies.summary.groupCount", "\(count) groups")
    }
    var refresh: String { value("proxies.action.refresh", "Refresh") }
    var refreshing: String { value("proxies.state.refreshing", "Refreshing proxy groups") }
    var refreshingDetail: String { value("proxies.state.refreshing.detail", "The last confirmed snapshot remains available during refresh.") }
    var refreshHelp: String { value("proxies.action.refresh.help", "Refresh proxy groups and current selections") }
    var testGroup: String { value("proxies.action.testGroup", "Test Group") }
    var testGroupHelp: String { value("proxies.action.testGroup.help", "Test every candidate in the selected proxy group") }
    var actionUnavailableWhileBusy: String { value("proxies.action.unavailable.busy", "Wait for the current proxy operation to finish") }
    var openConfiguration: String { value("proxies.action.openConfiguration", "Open Configuration") }
    var openDiagnostics: String { value("proxies.action.openDiagnostics", "Open Diagnostics") }
    var toggleInspector: String { value("proxies.action.toggleInspector", "Toggle Inspector") }
    var hideInspector: String { value("proxies.action.hideInspector", "Hide proxy group details") }
    var showInspector: String { value("proxies.action.showInspector", "Show proxy group details") }
    var applyingSelection: String { value("proxies.state.applying", "Applying proxy selection") }
    var applyingSelectionDetail: String { value("proxies.state.applying.detail", "The committed selection remains visible until Mihomo confirms the requested proxy.") }
    var staleData: String { value("proxies.state.stale", "Proxy data is stale") }
    var staleDetail: String { value("proxies.state.stale.detail", "Review the last confirmed snapshot and refresh when the Controller is available.") }
    var partialFailure: String { value("proxies.state.partialFailure", "Some proxy data could not be refreshed") }
    var partialFailureDetail: String { value("proxies.state.partialFailure.detail", "Vela is showing the last confirmed proxy groups.") }
    var controllerOffline: String { value("proxies.state.offline", "Controller offline") }
    var offlineDetail: String { value("proxies.state.offline.detail", "Proxy groups become available after Mihomo reconnects.") }
    var loadingProxyGroups: String { value("proxies.state.loading", "Loading Proxy Groups") }
    var loadingDetail: String { value("proxies.state.loading.detail", "Reading the authoritative proxy state from Mihomo.") }
    var noProxyGroups: String { value("proxies.state.empty", "No Proxy Groups") }
    var emptyDetail: String { value("proxies.state.empty.detail", "The current configuration does not expose any proxy groups.") }
    var proxyGroupsUnavailable: String { value("proxies.state.failure", "Proxy Groups Unavailable") }
    var failureDetail: String { value("proxies.state.failure.detail", "Mihomo did not return a usable proxy catalog.") }
    var proxyCatalogUnavailable: String { value("proxies.state.catalogUnavailable", "Proxy catalog unavailable") }
    var noMatchingGroups: String { value("proxies.state.noMatches", "No Matching Proxy Groups") }
    var noMatchingDetail: String { value("proxies.state.noMatches.detail", "Clear the search to show available proxy groups.") }
    var clearSearch: String { value("proxies.action.clearSearch", "Clear Search") }
    var proxyGroupDetails: String { value("proxies.inspector.details", "Proxy Group Details") }
    var selectGroupDetail: String { value("proxies.inspector.select.detail", "Select a proxy group to inspect its candidates and health.") }
    var retry: String { value("proxies.action.retry", "Retry") }
    var currentSelection: String { value("proxies.inspector.currentSelection", "Current Selection") }
    var requestedProxy: String { value("proxies.inspector.requestedProxy", "Requested Proxy") }
    var phase: String { value("proxies.inspector.phase", "Phase") }
    var applying: String { value("proxies.phase.applying", "Applying") }
    var automaticStrategy: String { value("proxies.inspector.automaticStrategy", "Automatic Strategy") }
    var candidates: String { value("proxies.inspector.candidates", "Candidates") }
    var candidateDetailsUnavailable: String { value("proxies.inspector.candidatesUnavailable", "Candidate details unavailable") }
    var strategyAndSource: String { value("proxies.inspector.strategySource", "Strategy / Source") }
    var type: String { value("proxies.inspector.type", "Type") }
    var source: String { value("proxies.inspector.source", "Source") }
    var healthEvidence: String { value("proxies.inspector.healthEvidence", "Health Evidence") }
    var snapshotAge: String { value("proxies.inspector.snapshotAge", "Snapshot Age") }
    var samples: String { value("proxies.inspector.samples", "Samples") }
    var actions: String { value("proxies.inspector.actions", "Actions") }
    var testSelectedProxy: String { value("proxies.action.testSelected", "Test Selected Proxy") }
    var changeProxy: String { value("proxies.action.changeProxy", "Change Proxy") }
    var requested: String { value("proxies.value.requested", "Requested") }
    var current: String { value("proxies.value.current", "Current") }
    var pinned: String { value("proxies.value.pinned", "Pinned") }
    var unavailable: String { value("proxies.value.unavailable", "Unavailable") }

    func groupSubtitle(strategy: String, candidateCount: Int) -> String {
        format(
            "proxies.inspector.subtitle.format",
            "%@ · %lld candidates",
            strategy,
            Int64(candidateCount)
        )
    }

    func candidateCount(_ count: Int) -> String {
        format(
            "proxies.inspector.candidateCount.format",
            "%lld candidates",
            Int64(count)
        )
    }

    func statusLabel(_ status: VelaSemanticStatus) -> String {
        switch status {
        case .neutral: value("proxies.status.unknown", "Unknown")
        case .info: value("proxies.status.ready", "Ready")
        case .success: value("proxies.status.healthy", "Healthy")
        case .warning: value("proxies.status.degraded", "Degraded")
        case .error: value("proxies.status.unavailable", "Unavailable")
        case .pending: value("proxies.status.pending", "Pending")
        case .stale: value("proxies.status.stale", "Stale")
        case .permission: value("proxies.status.permissionRequired", "Permission Required")
        }
    }

    func snapshotAge(_ date: Date?, relativeTo referenceDate: Date) -> String {
        guard let date else { return value("proxies.value.notAvailable", "Not available") }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.dateTimeStyle = .numeric
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: referenceDate)
    }

    func useProxy(_ name: String) -> String {
        format("proxies.action.useProxy.format", "Use %@", name)
    }

    func candidateAccessibility(_ candidate: ProxiesCandidateSnapshot) -> String {
        let state = candidate.isRequested
            ? requested
            : (candidate.isCurrent ? current : candidateDetailState(candidate))
        return format(
            "proxies.accessibility.candidate.format",
            "%@, %@, %@",
            candidate.name,
            state,
            candidate.latency.state.label
        )
    }

    private func candidateDetailState(_ candidate: ProxiesCandidateSnapshot) -> String {
        if candidate.isFixed { return pinned }
        if candidate.isAvailable == false || candidate.isPlaceholder { return unavailable }
        return statusLabel(candidate.latency.state.status)
    }

    private var bundle: Bundle {
        let identifier = VelaSupportedLocale.resolve(locale).rawValue
        guard let path = Bundle.main.path(forResource: identifier, ofType: "lproj"),
            let localizedBundle = Bundle(path: path)
        else { return .main }
        return localizedBundle
    }

    private func value(_ key: String, _ fallback: String) -> String {
        VelaL10n.string(key, defaultValue: fallback, bundle: bundle)
    }

    private func format(
        _ key: String,
        _ fallback: String,
        _ arguments: CVarArg...
    ) -> String {
        let format = value(key, fallback)
        return String(format: format, locale: locale, arguments: arguments)
    }
}
