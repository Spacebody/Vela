import AppKit
import SwiftUI

nonisolated enum ProvidersContentState: Equatable, Sendable {
    case loading
    case loaded
    case globalEmpty
    case kindEmpty
    case filteredEmpty
    case failure
}

nonisolated struct ProvidersRuntimeAvailability: Equatable, Sendable {
    let isMihomoRunning: Bool
    let isControllerConnected: Bool
    let hasConfiguration: Bool
}

nonisolated enum ProvidersRecoveryReason: String, Equatable, Sendable {
    case controllerDisconnected
    case mihomoStopped
    case providerFetchFailed
    case emptyConfiguration
}

nonisolated enum ProvidersPresentation {
    static func contentState(
        visibleCount: Int,
        selectedKindCount: Int,
        totalCount: Int,
        isLoading: Bool,
        hasError: Bool
    ) -> ProvidersContentState {
        if visibleCount > 0 { return .loaded }
        if isLoading, totalCount == 0 { return .loading }
        if selectedKindCount > 0 { return .filteredEmpty }
        if totalCount > 0 { return .kindEmpty }
        if hasError { return .failure }
        return .globalEmpty
    }

    static func recoveryReason(
        runtimeAvailability: ProvidersRuntimeAvailability,
        hasCatalogSnapshot: Bool,
        hasCatalogFailure: Bool
    ) -> ProvidersRecoveryReason? {
        if !runtimeAvailability.hasConfiguration { return .emptyConfiguration }
        if !runtimeAvailability.isMihomoRunning { return .mihomoStopped }
        if !runtimeAvailability.isControllerConnected { return .controllerDisconnected }
        if hasCatalogFailure { return .providerFetchFailed }
        if !hasCatalogSnapshot { return .emptyConfiguration }
        return nil
    }

    static func shouldShowToolbarRefresh(
        hasAvailableSnapshot: Bool,
        recoveryReason: ProvidersRecoveryReason?,
        hasActiveRecovery: Bool
    ) -> Bool {
        hasAvailableSnapshot && recoveryReason == nil && !hasActiveRecovery
    }

    static func canUpdateAll(
        hasAvailableSnapshot: Bool,
        recoveryReason: ProvidersRecoveryReason?,
        isLoading: Bool,
        hasRunningOperations: Bool
    ) -> Bool {
        hasAvailableSnapshot
            && recoveryReason == nil
            && !isLoading
            && !hasRunningOperations
    }
}

struct ProvidersView: View {
#if DEBUG
    @Environment(\.visualUITestConfiguration) private var visualTestConfiguration
#endif
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let viewModel: ProvidersViewModel
    let activeProfileID: UUID?
    let runtimeGeneration: UUID
    let runtimeAvailability: ProvidersRuntimeAvailability
    let startMihomo: () async -> Void

    @State private var selectedFilter: ProviderFilter = .all
    @State private var selectedProviderID: ProviderIdentity?
    @State private var retainedBatchOutcomes: [ProviderOperationKey: ProviderBatchOutcome] = [:]
    @State private var searchText = ""
    @State private var isInspectorPresented = false
    @State private var lastTableWidth: CGFloat = .infinity
    @State private var retainedTableDensity: ProviderTableDensity?
    @State private var inspectorTransitionGeneration = 0
    @State private var activeRecoveryReason: ProvidersRecoveryReason?
    @FocusState private var isSearchFocused: Bool

    init(
        viewModel: ProvidersViewModel,
        activeProfileID: UUID? = nil,
        runtimeGeneration: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
        runtimeAvailability: ProvidersRuntimeAvailability = ProvidersRuntimeAvailability(
            isMihomoRunning: true,
            isControllerConnected: true,
            hasConfiguration: true
        ),
        startMihomo: @escaping () async -> Void = {}
    ) {
        self.viewModel = viewModel
        self.activeProfileID = activeProfileID
        self.runtimeGeneration = runtimeGeneration
        self.runtimeAvailability = runtimeAvailability
        self.startMihomo = startMihomo
    }

    var body: some View {
        page
            .navigationTitle(VelaL10n.string("legacy.providers", defaultValue: "Providers"))
            .task {
#if DEBUG
                if let visualTestConfiguration {
                    isInspectorPresented = visualTestConfiguration.inspector == .open
                    selectInitialProviderIfAvailable()
                    return
                }
#endif
                if runtimeAvailability.hasConfiguration,
                    runtimeAvailability.isMihomoRunning,
                    runtimeAvailability.isControllerConnected,
                    CatalogEntryRefreshPolicy.shouldRefresh(
                        hasReceivedSnapshot: viewModel.hasReceivedSnapshot,
                        hasError: viewModel.lastError != nil
                    )
                {
                    await viewModel.refresh()
                }
                selectInitialProviderIfAvailable()
            }
            .onChange(of: visibleRows.map(\.id)) { _, _ in
                selectedProviderID = ProvidersTablePresentation.reconciledSelection(
                    selectedProviderID,
                    visibleRows: visibleRows
                )
            }
            .onChange(of: runtimeGeneration) { _, _ in
                selectedProviderID = nil
            }
            .onChange(of: activeProfileID) { _, _ in
                selectedProviderID = nil
            }
            .onChange(of: viewModel.lastBatchSummary) { _, summary in
                guard let summary else { return }
                for result in summary.results {
                    retainedBatchOutcomes[result.key] = ProviderBatchOutcome(
                        operation: summary.operation,
                        result: result.result
                    )
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .velaFocusSearch)) { _ in
                guard hasAvailableSnapshot else { return }
                isSearchFocused = true
            }
            .sheet(item: Binding(
                get: { viewModel.lastBatchSummary },
                set: { if $0 == nil { viewModel.dismissBatchSummary() } }
            )) { summary in
                ProviderBatchSummaryView(
                    summary: summary,
                    dismiss: { viewModel.dismissBatchSummary() },
                    retryFailed: { retryFailedItems(in: summary) }
                )
            }
    }

    private var page: some View {
        GeometryReader { _ in
            ZStack {
                VelaPageCanvas()

                VStack(alignment: .leading, spacing: VelaSpacing.medium) {
                    providerHeader

                    HStack(alignment: .top, spacing: VelaSpacing.medium) {
                        VStack(spacing: 0) {
                            if hasAvailableSnapshot, let recoveryReason {
                                providerSnapshotBanner(recoveryReason)
                            } else if let error = viewModel.lastError,
                                !viewModel.isLoading,
                                providerContentState != .failure
                            {
                                providerErrorBanner(error)
                            }
                            providerToolbar
                            Divider()
                            providerContent
                            if providerContentState == .loaded {
                                Divider()
                                selectedProviderActions
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .velaPanelSurface()

                        if isInspectorPresented {
                            providerInspector
                                .frame(width: VelaMetrics.inspectorIdealWidth)
                                .frame(maxHeight: .infinity, alignment: .topLeading)
                                .velaPanelSurface()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .padding(VelaSpacing.standard)
            }
        }
        .velaPageRoot()
        .accessibilityIdentifier("providers.workspace")
    }

    private var providerHeader: some View {
        HStack(alignment: .center, spacing: VelaSpacing.medium) {
            VStack(alignment: .leading, spacing: VelaSpacing.micro) {
                Text(VelaL10n.string("legacy.providers", defaultValue: "Providers"))
                    .font(VelaTypography.mainPageTitle)
                Text(locale.language.languageCode?.identifier == "zh"
                    ? "检查代理与规则提供器的新鲜度。"
                    : "Review proxy and rule provider freshness.")
                .font(VelaTypography.pageSubtitle)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: VelaSpacing.large)

            HStack(spacing: VelaSpacing.small) {
                HStack(spacing: VelaSpacing.small) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField(
                        VelaL10n.string(
                            "providers.search.prompt",
                            defaultValue: "Name, kind, source, or status"
                        ),
                        text: $searchText
                    )
                    .textFieldStyle(.plain)
                    .focused($isSearchFocused)
                    .accessibilityIdentifier("providers.search")
                }
                .padding(.horizontal, VelaSpacing.medium)
                .frame(width: 260, height: 40)
                .velaPanelSurface(radius: 14)
                .disabled(!hasAvailableSnapshot)

                if shouldShowToolbarRefresh {
                    Button {
                        startRecovery(.providerFetchFailed)
                    } label: {
                        Label(
                            VelaL10n.string("legacy.refresh", defaultValue: "Refresh"),
                            systemImage: "arrow.clockwise"
                        )
                    }
                    .buttonStyle(.bordered)
                    .disabled(viewModel.isLoading)
                    .accessibilityIdentifier("providers.refresh")
                }

                Button {
                    setInspectorPresented(!isInspectorPresented)
                } label: {
                    Label(
                        isInspectorPresented
                            ? VelaL10n.string("legacy.hideInspector", defaultValue: "Hide Inspector")
                            : VelaL10n.string("legacy.showInspector", defaultValue: "Show Inspector"),
                        systemImage: "sidebar.trailing"
                    )
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("providers.inspector.toggle")
            }
        }
    }

    private var providerToolbar: some View {
        HStack(spacing: VelaSpacing.medium) {
            Picker(
                VelaL10n.string("legacy.providerType", defaultValue: "Provider Type"),
                selection: $selectedFilter
            ) {
                Text(VelaL10n.string("providers.filter.all", defaultValue: "All"))
                    .tag(ProviderFilter.all)
                Text(VelaL10n.string("providers.filter.proxy", defaultValue: "Proxy"))
                    .tag(ProviderFilter.proxy)
                Text(VelaL10n.string("providers.filter.rule", defaultValue: "Rule"))
                    .tag(ProviderFilter.rule)
            }
            .pickerStyle(.segmented)
            .controlSize(.regular)
            .frame(width: 230)
            .disabled(!hasAvailableSnapshot)
            .help(
                hasAvailableSnapshot
                    ? VelaL10n.string(
                        "providers.filter.help",
                        defaultValue: "Filter providers by kind"
                    )
                    : VelaL10n.string(
                        "providers.filter.unavailable.help",
                        defaultValue: "Provider filters are available after a provider snapshot is loaded."
                    )
            )
            .accessibilityIdentifier("providers.filter")

            Text(providerCountText)
                .font(VelaTypography.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Spacer(minLength: VelaSpacing.medium)

            if !viewModel.runningOperations.isEmpty {
                VelaStatusPill(
                    status: .pending,
                    label: VelaL10n.string(
                        "providers.status.updatingTargets",
                        defaultValue: "Updating Providers"
                    ),
                    detail: String(viewModel.runningOperations.count)
                )
                .accessibilityIdentifier("providers.batch.progress")
            }

            if canUpdateAll {
                Button(VelaL10n.string("legacy.updateAll", defaultValue: "Update All")) {
                    retainedBatchOutcomes.removeAll()
                    Task { await viewModel.updateAll() }
                }
                .accessibilityIdentifier("providers.updateAll")
            }
        }
        .controlSize(.regular)
        .padding(.horizontal, VelaSpacing.standard)
        .padding(.vertical, VelaSpacing.small)
    }

    @ViewBuilder
    private var providerContent: some View {
        if let recoveryReason, !hasAvailableSnapshot {
            providerRecoveryState(recoveryReason)
        } else {
            switch providerContentState {
        case .loading:
            ProviderTableLoadingView()
                .accessibilityIdentifier("providers.loading.state")
        case .loaded:
            providerTable
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        case .globalEmpty:
            providerEmptyState(
                title: VelaL10n.string("providers.empty.title", defaultValue: "No Providers"),
                description: VelaL10n.string(
                    "providers.empty.description",
                    defaultValue: "The active configuration does not define proxy or rule providers."
                ),
                actionTitle: VelaL10n.string(
                    "legacy.openConfiguration",
                    defaultValue: "Open Configuration"
                ),
                action: openConfiguration
            )
            .accessibilityIdentifier("providers.empty.state")
#if DEBUG
            .overlay(alignment: .topLeading) {
                VisualReadyMarker(fixtureID: "providers.empty")
            }
#endif
        case .kindEmpty:
            providerEmptyState(
                title: VelaL10n.string(
                    "providers.empty.filter.title",
                    defaultValue: "No Providers in This Filter"
                ),
                description: VelaL10n.string(
                    "providers.empty.filter.description",
                    defaultValue: "The active catalog contains providers of another kind."
                ),
                actionTitle: VelaL10n.string("providers.filter.showAll", defaultValue: "Show All"),
                action: { selectedFilter = .all }
            )
            .accessibilityIdentifier("providers.kindEmpty.state")
        case .filteredEmpty:
            providerEmptyState(
                title: VelaL10n.string(
                    "providers.search.empty.title",
                    defaultValue: "No Matching Providers"
                ),
                description: VelaL10n.string(
                    "providers.search.empty.description",
                    defaultValue: "No providers match the current search and kind filter."
                ),
                actionTitle: VelaL10n.string(
                    "providers.search.clear",
                    defaultValue: "Clear Search"
                ),
                action: { searchText = "" }
            )
            .accessibilityIdentifier("providers.filteredEmpty.state")
        case .failure:
                providerRecoveryState(.providerFetchFailed)
            }
        }
    }

    private var providerTable: some View {
        GeometryReader { proxy in
            let density = retainedTableDensity
                ?? ProviderTableDensity.resolve(availableWidth: proxy.size.width)
            Group {
                switch density {
                case .compact:
                    compactTable
                case .regular:
                    regularTable
                case .spacious:
                    spaciousTable
                }
            }
            .accessibilityIdentifier("providers.table")
            .onAppear {
                lastTableWidth = proxy.size.width
            }
            .onChange(of: proxy.size.width) { _, width in
                lastTableWidth = width
            }
        }
    }

    private func setInspectorPresented(_ isPresented: Bool) {
        guard isInspectorPresented != isPresented else { return }

        retainedTableDensity = ProviderTableDensity.resolve(
            availableWidth: lastTableWidth
        )
        inspectorTransitionGeneration &+= 1
        let generation = inspectorTransitionGeneration

        withAnimation(
            VelaMotion.animation(VelaMotion.slowSeconds, reduceMotion: reduceMotion)
        ) {
            isInspectorPresented = isPresented
        }

        guard !reduceMotion else {
            retainedTableDensity = nil
            return
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(VelaMotion.slowSeconds))
            guard generation == inspectorTransitionGeneration else { return }
            retainedTableDensity = nil
        }
    }

    private var compactTable: some View {
        Table(visibleRows, selection: $selectedProviderID) {
            TableColumn(VelaL10n.string("providers.column.provider", defaultValue: "Provider")) { row in
                providerNameCell(row)
            }
            .width(min: 130, ideal: 190)
            TableColumn(VelaL10n.string("providers.column.kind", defaultValue: "Kind")) { row in
                providerKindCell(row)
            }
            .width(min: 62, ideal: 78)
            TableColumn(VelaL10n.string("providers.column.items", defaultValue: "Items")) { row in
                providerItemsCell(row)
            }
            .width(58)
            TableColumn(VelaL10n.string("legacy.status", defaultValue: "Status")) { row in
                providerStatusCell(row)
            }
            .width(min: 94, ideal: 126)
        }
        .providerContextMenu(action: contextAction)
        .scrollContentBackground(.hidden)
    }

    private var regularTable: some View {
        Table(visibleRows, selection: $selectedProviderID) {
            TableColumn(VelaL10n.string("providers.column.provider", defaultValue: "Provider")) { row in
                providerNameCell(row)
            }
            .width(min: 130, ideal: 190)
            TableColumn(VelaL10n.string("providers.column.kind", defaultValue: "Kind")) { row in
                providerKindCell(row)
            }
            .width(min: 62, ideal: 78)
            TableColumn(VelaL10n.string("providers.column.items", defaultValue: "Items")) { row in
                providerItemsCell(row)
            }
            .width(58)
            TableColumn(VelaL10n.string("providers.column.lastUpdate", defaultValue: "Last Update")) { row in
                providerUpdatedCell(row)
            }
            .width(min: 100, ideal: 132)
            TableColumn(VelaL10n.string("legacy.status", defaultValue: "Status")) { row in
                providerStatusCell(row)
            }
            .width(min: 94, ideal: 126)
        }
        .providerContextMenu(action: contextAction)
        .scrollContentBackground(.hidden)
    }

    private var spaciousTable: some View {
        Table(visibleRows, selection: $selectedProviderID) {
            TableColumn(VelaL10n.string("providers.column.provider", defaultValue: "Provider")) { row in
                providerNameCell(row)
            }
            .width(min: 130, ideal: 190)
            TableColumn(VelaL10n.string("providers.column.kind", defaultValue: "Kind")) { row in
                providerKindCell(row)
            }
            .width(min: 62, ideal: 78)
            TableColumn(VelaL10n.string("providers.column.source", defaultValue: "Source / Vehicle")) { row in
                providerSourceCell(row)
            }
            .width(min: 88, ideal: 118)
            TableColumn(VelaL10n.string("providers.column.items", defaultValue: "Items")) { row in
                providerItemsCell(row)
            }
            .width(58)
            TableColumn(VelaL10n.string("providers.column.lastUpdate", defaultValue: "Last Update")) { row in
                providerUpdatedCell(row)
            }
            .width(min: 100, ideal: 132)
            TableColumn(VelaL10n.string("providers.column.nextUpdate", defaultValue: "Next Update")) { _ in
                Text(VelaL10n.string("providers.value.notReported", defaultValue: "Not Reported"))
                    .font(VelaTypography.table)
                    .foregroundStyle(.secondary)
            }
            .width(min: 90, ideal: 112)
            TableColumn(VelaL10n.string("legacy.status", defaultValue: "Status")) { row in
                providerStatusCell(row)
            }
            .width(min: 94, ideal: 126)
        }
        .providerContextMenu(action: contextAction)
        .scrollContentBackground(.hidden)
    }

    private func providerNameCell(_ row: ProviderRowModel) -> some View {
        Text(verbatim: row.rawName)
            .font(VelaTypography.table.weight(.medium))
            .lineLimit(1)
            .padding(.vertical, 3)
            .accessibilityIdentifier("providers.row.\(row.kind.rawValue).\(row.rawName)")
    }

    private func providerKindCell(_ row: ProviderRowModel) -> some View {
        Label(providerKindLabel(row.kind), systemImage: row.kind == .proxy ? "network" : "list.bullet.rectangle")
            .font(VelaTypography.table)
            .labelStyle(.titleOnly)
    }

    private func providerSourceCell(_ row: ProviderRowModel) -> some View {
        Text(row.vehicle ?? VelaL10n.string("providers.value.notReported", defaultValue: "Not Reported"))
            .font(VelaTypography.table)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    private func providerItemsCell(_ row: ProviderRowModel) -> some View {
        Text(row.itemCount, format: .number)
            .font(VelaTypography.table.monospacedDigit())
    }

    private func providerUpdatedCell(_ row: ProviderRowModel) -> some View {
        Text(row.updatedAt ?? VelaL10n.string("providers.value.notReported", defaultValue: "Not Reported"))
            .font(VelaTypography.table)
            .foregroundStyle(row.updatedAt == nil ? .secondary : .primary)
            .lineLimit(1)
    }

    private func providerStatusCell(_ row: ProviderRowModel) -> some View {
        let status = ProviderRowStatusPresentation.resolve(row)
        return VelaStatusPill(status: status.status, label: status.label, detail: status.detail)
    }

    @ViewBuilder
    private var providerInspector: some View {
        VStack(spacing: 0) {
            if hasAvailableSnapshot, recoveryReason != nil {
                VelaStateBanner(
                    kind: .stale,
                    title: VelaL10n.string(
                        "providers.snapshot.stale.title",
                        defaultValue: "Provider Details May Be Out of Date"
                    ),
                    detail: VelaL10n.string(
                        "providers.snapshot.stale.description",
                        defaultValue: "Showing the last provider snapshot while live Controller data is unavailable."
                    )
                )
                .padding(VelaSpacing.medium)
            }

            if let selectedRow {
                ProviderDetailInspector(
                    row: selectedRow,
                    activeProfileID: activeProfileID,
                    update: { runUpdate(selectedRow.operationKey) },
                    healthCheck: selectedRow.kind == .proxy
                        ? { runHealthCheck(named: selectedRow.rawName) }
                        : nil,
                    openRelatedPage: {
                        SettingsMainNavigationRequest.navigateInCurrentWindow(
                            selectedRow.kind == .proxy ? .proxies : .rules
                        )
                    },
                    openConfiguration: openConfiguration
                )
            } else {
                ProviderInspectorPlaceholder(state: providerContentState)
            }
        }
    }

    private var selectedProviderActions: some View {
        HStack(spacing: VelaSpacing.small) {
            Group {
                if let selectedRow {
                    Text(verbatim: selectedRow.rawName)
                } else {
                    Text(VelaL10n.string(
                        "providers.selection.none",
                        defaultValue: "No Provider Selected"
                    ))
                }
            }
            .font(VelaTypography.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)

            Spacer(minLength: VelaSpacing.medium)

            Button(VelaL10n.string("legacy.update", defaultValue: "Update")) {
                guard let selectedRow else { return }
                runUpdate(selectedRow.operationKey)
            }
            .disabled(
                selectedRow == nil
                    || selectedOperationIsRunning
                    || recoveryReason != nil
            )
            .accessibilityIdentifier("providers.updateSelected")

            if selectedRow?.kind == .proxy {
                Button(VelaL10n.string("legacy.healthCheck", defaultValue: "Health Check")) {
                    guard let selectedRow else { return }
                    runHealthCheck(named: selectedRow.rawName)
                }
                .disabled(selectedOperationIsRunning || recoveryReason != nil)
                .accessibilityIdentifier("providers.healthCheckSelected")
            }
        }
        .controlSize(.regular)
        .padding(.horizontal, VelaSpacing.standard)
        .padding(.vertical, VelaSpacing.small)
    }

    private func providerErrorBanner(_ error: ProviderFailure) -> some View {
        VelaStateBanner(
            kind: .error,
            title: VelaL10n.string(
                "providers.error.title",
                defaultValue: "Provider Operation Failed"
            ),
            detail: errorDescription(error)
        )
        .padding(.horizontal, VelaSpacing.standard)
        .padding(.top, VelaSpacing.medium)
        .padding(.bottom, VelaSpacing.small)
    }

    private func providerSnapshotBanner(_ reason: ProvidersRecoveryReason) -> some View {
        VelaStateBanner(
            kind: .stale,
            title: VelaL10n.string(
                "providers.snapshot.stale.banner.title",
                defaultValue: "Showing Saved Provider Data"
            ),
            detail: recoveryDescription(reason)
        )
        .padding(.horizontal, VelaSpacing.standard)
        .padding(.top, VelaSpacing.medium)
        .padding(.bottom, VelaSpacing.small)
    }

    private func providerRecoveryState(_ reason: ProvidersRecoveryReason) -> some View {
        VelaEmptyState(
            title: recoveryTitle(reason),
            description: recoveryDescription(reason),
            systemImage: reason == .emptyConfiguration ? "shippingbox" : "network.slash"
        ) {
            PageRecoveryActions(
                primaryTitle: recoveryActionTitle(reason),
                pendingTitle: recoveryPendingTitle(reason),
                primarySystemImage: recoveryActionSystemImage(reason),
                isPending: activeRecoveryReason == reason,
                isPrimaryEnabled: activeRecoveryReason == nil,
                primaryMinimumWidth: PageRecoveryActionMetrics.compactContentMinimumWidth,
                primaryAccessibilityIdentifier: "providers.recovery.primary",
                primaryAccessibilityHint: recoveryActionHint(reason),
                primaryAction: { startRecovery(reason) },
                secondaryAction: reason == .emptyConfiguration
                    ? nil
                    : PageRecoveryActions.SecondaryAction(
                        title: VelaL10n.string(
                            "legacy.openDiagnostics",
                            defaultValue: "Open Diagnostics"
                        ),
                        systemImage: "chevron.right",
                        accessibilityIdentifier: "providers.recovery.diagnostics",
                        accessibilityHint: VelaL10n.string(
                            "providers.recovery.diagnostics.hint",
                            defaultValue: "Open Diagnostics to inspect the Controller and Mihomo state."
                        ),
                        action: {
                            SettingsMainNavigationRequest.navigateInCurrentWindow(.diagnostics)
                        }
                    )
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("providers.recovery.\(reason.rawValue)")
    }

    private func providerEmptyState(
        title: String,
        description: String,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        VelaEmptyState(
            title: title,
            description: description,
            systemImage: "shippingbox"
        ) {
            Button(actionTitle, action: action)
                .velaEmptyStateAction()
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var allOutcomes: [ProviderOperationKey: ProviderBatchOutcome] {
        var outcomes = retainedBatchOutcomes
        if let summary = viewModel.lastBatchSummary {
            for result in summary.results {
                outcomes[result.key] = ProviderBatchOutcome(
                    operation: summary.operation,
                    result: result.result
                )
            }
        }
        return outcomes
    }

    private var allRows: [ProviderRowModel] {
        ProvidersTablePresentation.rows(
            snapshot: viewModel.snapshot,
            activeProfileID: activeProfileID,
            runtimeGeneration: runtimeGeneration,
            runningOperations: viewModel.runningOperations,
            outcomes: allOutcomes
        )
    }

    private var visibleRows: [ProviderRowModel] {
        ProvidersTablePresentation.filter(allRows, kind: selectedFilter, query: searchText)
    }

    private var selectedFilterCount: Int {
        allRows.count { selectedFilter.includes($0.kind) }
    }

    private var providerContentState: ProvidersContentState {
        ProvidersPresentation.contentState(
            visibleCount: visibleRows.count,
            selectedKindCount: selectedFilterCount,
            totalCount: allRows.count,
            isLoading: viewModel.isLoading,
            hasError: hasCatalogFailure
        )
    }

    private var hasAvailableSnapshot: Bool {
        runtimeAvailability.hasConfiguration
            && viewModel.hasReceivedSnapshot
            && !allRows.isEmpty
    }

    private var recoveryReason: ProvidersRecoveryReason? {
        ProvidersPresentation.recoveryReason(
            runtimeAvailability: runtimeAvailability,
            hasCatalogSnapshot: viewModel.hasReceivedSnapshot,
            hasCatalogFailure: hasCatalogFailure
        )
    }

    private var hasCatalogFailure: Bool {
        guard let error = viewModel.lastError else { return false }
        switch error {
        case .fetchFailed, .decodeFailed:
            return true
        case .updateFailed, .healthCheckFailed, .providerNotFound,
            .operationAlreadyRunning, .unsupportedOperation,
            .cancelledBeforeStart, .cancelledResultUnknown,
            .updateInProgress:
            return false
        }
    }

    private var shouldShowToolbarRefresh: Bool {
        ProvidersPresentation.shouldShowToolbarRefresh(
            hasAvailableSnapshot: hasAvailableSnapshot,
            recoveryReason: recoveryReason,
            hasActiveRecovery: activeRecoveryReason != nil
        )
    }

    private var selectedRow: ProviderRowModel? {
        guard let selectedProviderID else { return nil }
        return allRows.first { $0.id == selectedProviderID }
    }

    private var selectedOperationIsRunning: Bool {
        guard let selectedRow else { return false }
        return viewModel.runningOperations.contains(selectedRow.operationKey)
    }

    private var canUpdateAll: Bool {
        ProvidersPresentation.canUpdateAll(
            hasAvailableSnapshot: hasAvailableSnapshot,
            recoveryReason: recoveryReason,
            isLoading: viewModel.isLoading,
            hasRunningOperations: !viewModel.runningOperations.isEmpty
        )
    }

    private var providerCountText: String {
        if visibleRows.count == allRows.count {
            return VelaL10n.string(
                "providers.count.format",
                defaultValue: "%lld Providers",
                arguments: Int64(allRows.count)
            )
        }
        return VelaL10n.string(
            "providers.count.filtered.format",
            defaultValue: "%lld of %lld Providers",
            arguments: Int64(visibleRows.count), Int64(allRows.count)
        )
    }

    private func selectInitialProviderIfAvailable() {
        guard selectedProviderID == nil else { return }
        selectedProviderID = visibleRows.first?.id
    }

    private func providerKindLabel(_ kind: ProviderKind) -> String {
        switch kind {
        case .proxy: VelaL10n.string("providers.kind.proxy", defaultValue: "Proxy")
        case .rule: VelaL10n.string("providers.kind.rule", defaultValue: "Rule")
        }
    }

    private func contextAction(_ ids: Set<ProviderIdentity>) -> ProviderContextMenuAction? {
        guard let id = ids.first,
            let row = allRows.first(where: { $0.id == id })
        else { return nil }
        return ProviderContextMenuAction(
            update: { runUpdate(row.operationKey) },
            healthCheck: row.kind == .proxy ? { runHealthCheck(named: row.rawName) } : nil
        )
    }

    private func openConfiguration() {
        SettingsMainNavigationRequest.navigateInCurrentWindow(.configuration)
    }

    private func startRecovery(_ reason: ProvidersRecoveryReason) {
        guard activeRecoveryReason == nil else { return }
        if reason == .emptyConfiguration {
            openConfiguration()
            return
        }

        activeRecoveryReason = reason
        Task { @MainActor in
            defer { activeRecoveryReason = nil }
            switch reason {
            case .mihomoStopped:
                await startMihomo()
                await viewModel.refresh()
            case .controllerDisconnected, .providerFetchFailed:
                await viewModel.refresh()
            case .emptyConfiguration:
                break
            }
        }
    }

    private func recoveryTitle(_ reason: ProvidersRecoveryReason) -> String {
        switch reason {
        case .controllerDisconnected:
            VelaL10n.string(
                "providers.recovery.controller.title",
                defaultValue: "Connection Service Unavailable"
            )
        case .mihomoStopped:
            VelaL10n.string(
                "providers.recovery.mihomo.title",
                defaultValue: "Connection Service Is Not Ready"
            )
        case .providerFetchFailed:
            VelaL10n.string(
                "providers.recovery.fetch.title",
                defaultValue: "Provider Data Could Not Be Loaded"
            )
        case .emptyConfiguration:
            VelaL10n.string(
                "providers.recovery.empty.title",
                defaultValue: "No Provider Configuration"
            )
        }
    }

    private func recoveryDescription(_ reason: ProvidersRecoveryReason) -> String {
        switch reason {
        case .controllerDisconnected:
            VelaL10n.string(
                "providers.recovery.controller.description",
                defaultValue: "Vela cannot reach the runtime provider service right now."
            )
        case .mihomoStopped:
            VelaL10n.string(
                "providers.recovery.mihomo.description",
                defaultValue: "Vela will restart its connection service before loading providers."
            )
        case .providerFetchFailed:
            VelaL10n.string(
                "providers.recovery.fetch.description",
                defaultValue: "The Controller did not return a readable provider snapshot. Reload the catalog or inspect Diagnostics."
            )
        case .emptyConfiguration:
            VelaL10n.string(
                "providers.recovery.empty.description",
                defaultValue: "Choose or edit a configuration before loading proxy and rule providers."
            )
        }
    }

    private func recoveryActionTitle(_ reason: ProvidersRecoveryReason) -> String {
        switch reason {
        case .controllerDisconnected:
            VelaL10n.string("providers.recovery.reconnect", defaultValue: "Reconnect")
        case .mihomoStopped:
            VelaL10n.string("providers.recovery.startMihomo", defaultValue: "Retry")
        case .providerFetchFailed:
            VelaL10n.string("providers.recovery.reload", defaultValue: "Reload")
        case .emptyConfiguration:
            VelaL10n.string(
                "providers.recovery.openWorkbench",
                defaultValue: "Open Workbench"
            )
        }
    }

    private func recoveryPendingTitle(_ reason: ProvidersRecoveryReason) -> String {
        switch reason {
        case .controllerDisconnected:
            VelaL10n.string("providers.recovery.connecting", defaultValue: "Connecting…")
        case .mihomoStopped:
            VelaL10n.string("providers.recovery.starting", defaultValue: "Preparing…")
        case .providerFetchFailed:
            VelaL10n.string("providers.recovery.loading", defaultValue: "Loading…")
        case .emptyConfiguration:
            recoveryActionTitle(reason)
        }
    }

    private func recoveryActionSystemImage(_ reason: ProvidersRecoveryReason) -> String {
        switch reason {
        case .controllerDisconnected, .providerFetchFailed:
            return "arrow.clockwise"
        case .mihomoStopped:
            return "play.fill"
        case .emptyConfiguration:
            return "slider.horizontal.3"
        }
    }

    private func recoveryActionHint(_ reason: ProvidersRecoveryReason) -> String {
        switch reason {
        case .controllerDisconnected:
            VelaL10n.string(
                "providers.recovery.reconnect.hint",
                defaultValue: "Try to reconnect to Mihomo Controller and reload providers."
            )
        case .mihomoStopped:
            VelaL10n.string(
                "providers.recovery.startMihomo.hint",
                defaultValue: "Restart Vela's connection service and load providers."
            )
        case .providerFetchFailed:
            VelaL10n.string(
                "providers.recovery.reload.hint",
                defaultValue: "Request a fresh provider snapshot from Mihomo Controller."
            )
        case .emptyConfiguration:
            VelaL10n.string(
                "providers.recovery.openWorkbench.hint",
                defaultValue: "Open Configuration Workbench to choose or edit a configuration."
            )
        }
    }

    private func retryFailedItems(in summary: ProviderBatchSummary) {
        let failedKeys = summary.results.compactMap { result -> ProviderOperationKey? in
            guard case let .failure(failure) = result.result,
                failure != .cancelledBeforeStart
            else { return nil }
            return result.key
        }
        guard !failedKeys.isEmpty else { return }
        for key in failedKeys { retainedBatchOutcomes.removeValue(forKey: key) }
        viewModel.dismissBatchSummary()
        Task {
            for key in failedKeys {
                switch summary.operation {
                case .update: await viewModel.update(key)
                case .healthCheck: await viewModel.healthCheck(named: key.name)
                }
            }
        }
    }

    private func runUpdate(_ key: ProviderOperationKey) {
        retainedBatchOutcomes.removeValue(forKey: key)
        Task { await viewModel.update(key) }
    }

    private func runHealthCheck(named name: String) {
        retainedBatchOutcomes.removeValue(
            forKey: ProviderOperationKey(kind: .proxy, name: name)
        )
        Task { await viewModel.healthCheck(named: name) }
    }

    private func errorDescription(_ error: ProviderFailure) -> String {
        switch error {
        case .fetchFailed:
            VelaL10n.string("providers.error.fetchFailed", defaultValue: "Mihomo did not return the provider catalog.")
        case .updateFailed:
            VelaL10n.string("providers.error.updateFailed", defaultValue: "One or more provider updates failed. Review the batch summary and retry.")
        case .healthCheckFailed:
            VelaL10n.string("providers.error.healthCheckFailed", defaultValue: "The provider health check failed.")
        case .decodeFailed:
            VelaL10n.string("providers.error.decodeFailed", defaultValue: "Mihomo returned provider data Vela could not read.")
        case .providerNotFound:
            VelaL10n.string("providers.error.providerNotFound", defaultValue: "The selected provider no longer exists.")
        case .operationAlreadyRunning:
            VelaL10n.string("providers.error.operationAlreadyRunning", defaultValue: "An operation for this provider is already running.")
        case .unsupportedOperation:
            VelaL10n.string("providers.error.unsupportedOperation", defaultValue: "This provider does not support the requested operation.")
        case .cancelledBeforeStart:
            VelaL10n.string("providers.error.cancelledBeforeStart", defaultValue: "The queued provider operation was cancelled before it started.")
        case .cancelledResultUnknown:
            VelaL10n.string("providers.error.cancelledResultUnknown", defaultValue: "Vela stopped waiting, but Mihomo may have completed the operation. Refresh to verify.")
        case .updateInProgress:
            VelaL10n.string("providers.error.updateInProgress", defaultValue: "Provider changes are paused while Vela prepares or recovers an update.")
        }
    }
}

enum ProviderTableDensity {
    case compact
    case regular
    case spacious

    static func resolve(availableWidth: CGFloat) -> Self {
        if availableWidth < 660 { return .compact }
        if availableWidth < 940 { return .regular }
        return .spacious
    }
}

private struct ProviderContextMenuAction {
    let update: () -> Void
    let healthCheck: (() -> Void)?
}

private extension View {
    func providerContextMenu(
        action: @escaping (Set<ProviderIdentity>) -> ProviderContextMenuAction?
    ) -> some View {
        contextMenu(forSelectionType: ProviderIdentity.self) { ids in
            if let menu = action(ids) {
                Button(VelaL10n.string("legacy.update", defaultValue: "Update"), action: menu.update)
                if let healthCheck = menu.healthCheck {
                    Button(VelaL10n.string("legacy.healthCheck", defaultValue: "Health Check"), action: healthCheck)
                }
            }
        } primaryAction: { _ in }
    }
}

struct ProviderRowStatusPresentation {
    let status: VelaSemanticStatus
    let label: String
    let detail: String?

    static func resolve(_ row: ProviderRowModel) -> Self {
        switch row.freshness {
        case .updating:
            return Self(status: .pending, label: VelaL10n.string("providers.status.updating", defaultValue: "Updating"), detail: nil)
        case .failed:
            return Self(status: .error, label: VelaL10n.string("providers.status.failed", defaultValue: "Failed"), detail: nil)
        case .current, .unknown:
            break
        }
        if let health = row.proxyHealth, health.hasEvidence {
            if health.failed > 0 {
                return Self(status: .warning, label: VelaL10n.string("providers.status.degraded", defaultValue: "Degraded"), detail: String(health.failed))
            }
            return Self(status: .success, label: VelaL10n.string("providers.status.healthy", defaultValue: "Healthy"), detail: String(health.healthy))
        }
        return Self(
            status: row.freshness == .current ? .success : .neutral,
            label: row.freshness == .current
                ? VelaL10n.string("providers.status.loaded", defaultValue: "Loaded")
                : VelaL10n.string("providers.status.unknown", defaultValue: "Unknown"),
            detail: nil
        )
    }
}

struct ProviderTableLoadingView: View {
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(VelaL10n.string("providers.column.provider", defaultValue: "Provider"))
                Spacer()
                Text(VelaL10n.string("providers.column.kind", defaultValue: "Kind"))
                Spacer()
                Text(VelaL10n.string("providers.column.items", defaultValue: "Items"))
                Spacer()
                Text(VelaL10n.string("legacy.status", defaultValue: "Status"))
            }
            .font(VelaTypography.table.weight(.semibold))
            .padding(.horizontal, VelaSpacing.standard)
            .frame(height: 30)
            Divider()
            ForEach(0 ..< 7, id: \.self) { _ in
                HStack(spacing: VelaSpacing.medium) {
                    RoundedRectangle(cornerRadius: 3).frame(width: 150, height: 10)
                    RoundedRectangle(cornerRadius: 3).frame(width: 58, height: 10)
                    Spacer()
                    RoundedRectangle(cornerRadius: 3).frame(width: 76, height: 10)
                }
                .foregroundStyle(.quaternary)
                .padding(.horizontal, VelaSpacing.standard)
                .frame(height: 32)
                Divider()
            }
            Spacer()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(VelaL10n.string("providers.loading.title", defaultValue: "Loading Providers"))
    }
}

struct ProviderInspectorPlaceholder: View {
    let state: ProvidersContentState

    var body: some View {
        Group {
            switch state {
            case .loading:
                VelaLoadingState(
                    title: VelaL10n.string("providers.loading.title", defaultValue: "Loading Providers"),
                    detail: VelaL10n.string("providers.loading.description", defaultValue: "Reading the committed provider catalog.")
                )
            case .failure:
                VelaEmptyState(
                    title: VelaL10n.string("providers.inspector.failure.title", defaultValue: "Provider Details Unavailable"),
                    description: VelaL10n.string("providers.inspector.failure.description", defaultValue: "No provider snapshot is available."),
                    systemImage: "exclamationmark.triangle"
                )
            case .globalEmpty:
                VelaEmptyState(
                    title: VelaL10n.string("providers.empty.title", defaultValue: "No Providers"),
                    description: VelaL10n.string("providers.empty.description", defaultValue: "The active configuration does not define proxy or rule providers."),
                    systemImage: "shippingbox"
                )
            case .loaded, .kindEmpty, .filteredEmpty:
                VelaEmptyState(
                    title: VelaL10n.string("providers.inspector.empty.title", defaultValue: "Provider Details"),
                    description: VelaL10n.string("providers.inspector.empty.description", defaultValue: "Select a provider to inspect freshness, source, and actions."),
                    systemImage: "sidebar.right"
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(VelaAppearance.windowBackground)
        .accessibilityIdentifier("providers.inspector.placeholder")
    }
}

struct ProviderDetailInspector: View {
    let row: ProviderRowModel
    let activeProfileID: UUID?
    let update: () -> Void
    let healthCheck: (() -> Void)?
    let openRelatedPage: () -> Void
    let openConfiguration: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    VelaInspectorSection(
                        title: row.rawName,
                        subtitle: inspectorSubtitle,
                        help: VelaL10n.string(
                            "providers.inspector.controllerSource.help",
                            defaultValue: "Values are read from the committed Mihomo provider catalog."
                        )
                    ) {
                        LabeledContent(VelaL10n.string("providers.column.kind", defaultValue: "Kind"), value: kindLabel)
                        LabeledContent(VelaL10n.string("providers.inspector.availability", defaultValue: "Availability"), value: VelaL10n.string("providers.availability.loaded", defaultValue: "Loaded"))
                        LabeledContent(VelaL10n.string("providers.inspector.freshness", defaultValue: "Freshness"), value: freshnessLabel)
                        LabeledContent(VelaL10n.string("providers.column.items", defaultValue: "Items"), value: String(row.itemCount))
                        LabeledContent(VelaL10n.string("providers.inspector.context", defaultValue: "Source Context"), value: activeProfileID == nil
                            ? VelaL10n.string("providers.context.runtime", defaultValue: "Runtime Catalog")
                            : VelaL10n.string("providers.context.activeConfiguration", defaultValue: "Active Configuration"))
                    }

                    VelaInspectorSection(title: VelaL10n.string("providers.inspector.source.title", defaultValue: "Source")) {
                        LabeledContent(VelaL10n.string("legacy.vehicle", defaultValue: "Vehicle"), value: row.vehicle ?? notReported)
                        if let format = row.format {
                            LabeledContent(VelaL10n.string("legacy.format", defaultValue: "Format"), value: format)
                        }
                        if let behavior = row.behavior {
                            LabeledContent(VelaL10n.string("legacy.behavior", defaultValue: "Behavior"), value: behavior)
                        }
                        Text(VelaL10n.string("providers.inspector.redaction", defaultValue: "Credentials, private paths, and full source URLs are not displayed."))
                            .font(VelaTypography.caption)
                            .foregroundStyle(.secondary)
                    }

                    VelaInspectorSection(title: VelaL10n.string("providers.inspector.freshness.title", defaultValue: "Freshness and Update Evidence")) {
                        LabeledContent(VelaL10n.string("providers.column.lastUpdate", defaultValue: "Last Update"), value: row.updatedAt ?? notReported)
                        LabeledContent(VelaL10n.string("providers.column.nextUpdate", defaultValue: "Next Update"), value: notReported)
                        LabeledContent(VelaL10n.string("providers.inspector.phase", defaultValue: "Current Phase"), value: freshnessLabel)
                        LabeledContent(VelaL10n.string("providers.inspector.lastGoodCount", defaultValue: "Last Good Item Count"), value: String(row.itemCount))
                    }

                    kindSpecificSection
                }
                .padding(.horizontal, VelaSpacing.standard)
                .padding(.bottom, VelaSpacing.medium)
            }

            Divider()
            VStack(spacing: VelaSpacing.small) {
                Button(VelaL10n.string("providers.action.updateNow", defaultValue: "Update Now"), action: update)
                    .frame(maxWidth: .infinity)
                if let healthCheck {
                    Button(VelaL10n.string("legacy.healthCheck", defaultValue: "Health Check"), action: healthCheck)
                        .frame(maxWidth: .infinity)
                }
                Button(openRelatedTitle, action: openRelatedPage)
                    .frame(maxWidth: .infinity)
                Button(VelaL10n.string("providers.action.openConfiguration", defaultValue: "Open Configuration"), action: openConfiguration)
                    .frame(maxWidth: .infinity)
                Button(VelaL10n.string("providers.action.copySummary", defaultValue: "Copy Redacted Technical Summary"), action: copySummary)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .padding(VelaSpacing.standard)
        }
        .background(VelaAppearance.windowBackground)
        .accessibilityIdentifier("providers.inspector.loaded")
    }

    @ViewBuilder
    private var kindSpecificSection: some View {
        switch row.details {
        case let .proxy(provider):
            VelaInspectorSection(
                title: VelaL10n.string("providers.inspector.proxySummary", defaultValue: "Proxy Summary"),
                showsDivider: false
            ) {
                let health = row.proxyHealth ?? ProviderProxyHealthSummary(healthy: 0, failed: 0, unknown: provider.proxies.count)
                LabeledContent(VelaL10n.string("legacy.nodes", defaultValue: "Nodes"), value: String(provider.proxies.count))
                LabeledContent(VelaL10n.string("providers.health.healthy", defaultValue: "Healthy"), value: String(health.healthy))
                LabeledContent(VelaL10n.string("providers.health.failed", defaultValue: "Failed"), value: String(health.failed))
                LabeledContent(VelaL10n.string("providers.health.unknown", defaultValue: "Unknown"), value: String(health.unknown))
            }
        case let .rule(provider):
            VelaInspectorSection(
                title: VelaL10n.string("providers.inspector.ruleSummary", defaultValue: "Rule Summary"),
                showsDivider: false
            ) {
                LabeledContent(VelaL10n.string("legacy.ruleCount", defaultValue: "Rule Count"), value: String(row.itemCount))
                LabeledContent(VelaL10n.string("legacy.behavior", defaultValue: "Behavior"), value: provider.behavior ?? notReported)
                LabeledContent(VelaL10n.string("legacy.format", defaultValue: "Format"), value: provider.format ?? notReported)
            }
        }
    }

    private var inspectorSubtitle: String {
        VelaL10n.string(
            row.kind == .proxy
                ? "providers.inspector.proxy.count.format"
                : "providers.inspector.rule.count.format",
            defaultValue: row.kind == .proxy ? "Proxy Provider · %lld items" : "Rule Provider · %lld rules",
            arguments: Int64(row.itemCount)
        )
    }

    private var kindLabel: String {
        row.kind == .proxy
            ? VelaL10n.string("providers.kind.proxyProvider", defaultValue: "Proxy Provider")
            : VelaL10n.string("providers.kind.ruleProvider", defaultValue: "Rule Provider")
    }

    private var freshnessLabel: String {
        switch row.freshness {
        case .current: VelaL10n.string("providers.freshness.current", defaultValue: "Current")
        case .updating: VelaL10n.string("providers.freshness.updating", defaultValue: "Updating")
        case .failed: VelaL10n.string("providers.freshness.failed", defaultValue: "Last Update Failed")
        case .unknown: VelaL10n.string("providers.freshness.unknown", defaultValue: "Not Reported")
        }
    }

    private var notReported: String {
        VelaL10n.string("providers.value.notReported", defaultValue: "Not Reported")
    }

    private var openRelatedTitle: String {
        row.kind == .proxy
            ? VelaL10n.string("providers.action.openProxies", defaultValue: "Open in Proxies")
            : VelaL10n.string("providers.action.openRules", defaultValue: "Open in Rules")
    }

    private func copySummary() {
        let summary = [
            "kind=\(row.kind.rawValue)",
            "name=\(row.rawName)",
            "items=\(row.itemCount)",
            "vehicle=\(row.vehicle ?? "not-reported")",
            "updated=\(row.updatedAt ?? "not-reported")",
        ].joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(summary, forType: .string)
    }
}

private struct ProviderBatchSummaryView: View {
    let summary: ProviderBatchSummary
    let dismiss: () -> Void
    let retryFailed: () -> Void

    var body: some View {
        VStack(spacing: VelaSpacing.medium) {
            Text(summary.operation == .update
                ? VelaL10n.string("legacy.providerUpdateSummary", defaultValue: "Provider Update Summary")
                : VelaL10n.string("legacy.providerHealthCheckSummary", defaultValue: "Provider Health Check Summary"))
                .font(VelaTypography.pageTitle)
                .frame(maxWidth: .infinity, alignment: .leading)

            VelaStateBanner(
                kind: summary.failedCount > 0 ? .warning : .recovery,
                title: summary.failedCount > 0
                    ? VelaL10n.string("providers.batch.attention.title", defaultValue: "Some Providers Need Attention")
                    : VelaL10n.string("providers.batch.completed.title", defaultValue: "Batch Completed"),
                detail: batchDescription
            )

            List {
                ForEach(summary.results, id: \.key) { result in
                    HStack(spacing: VelaSpacing.medium) {
                        Text(verbatim: result.key.name)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(result.key.kind == .proxy
                            ? VelaL10n.string("providers.kind.proxy", defaultValue: "Proxy")
                            : VelaL10n.string("providers.kind.rule", defaultValue: "Rule"))
                            .foregroundStyle(.secondary)
                            .frame(width: 80, alignment: .leading)
                        Text(resultLabel(result.result))
                            .frame(width: 110, alignment: .leading)
                    }
                    .font(VelaTypography.table)
                }
            }

            HStack {
                if summary.failedCount > 0 {
                    Button(VelaL10n.string("providers.batch.retryFailed", defaultValue: "Retry Failed"), action: retryFailed)
                }
                Spacer()
                Button(VelaL10n.string("legacy.done", defaultValue: "Done"), action: dismiss)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(VelaSpacing.large)
        .frame(minWidth: 620, minHeight: 430)
    }

    private var batchDescription: String {
        VelaL10n.string(
            "providers.batch.summary.format",
            defaultValue: "%lld succeeded · %lld failed · %lld skipped. Each provider is committed independently.",
            arguments: Int64(summary.succeededCount), Int64(summary.failedCount), Int64(summary.skippedCount)
        )
    }

    private func resultLabel(_ result: Result<Void, ProviderFailure>) -> String {
        switch result {
        case .success: VelaL10n.string("providers.batch.result.succeeded", defaultValue: "Succeeded")
        case .failure(.cancelledBeforeStart): VelaL10n.string("providers.batch.result.skipped", defaultValue: "Skipped")
        case .failure(.cancelledResultUnknown): VelaL10n.string("providers.batch.result.unknown", defaultValue: "Result Unknown")
        case .failure: VelaL10n.string("providers.batch.result.failed", defaultValue: "Failed")
        }
    }
}
