import AppKit
import SwiftUI

nonisolated struct RulesRuntimeAvailability: Equatable, Sendable {
    let isMihomoRunning: Bool
    let isControllerConnected: Bool
    let hasConfiguration: Bool
    let isTrafficTakeoverActive: Bool
    let runtimeMode: MihomoMode?

    init(
        isMihomoRunning: Bool,
        isControllerConnected: Bool,
        hasConfiguration: Bool,
        isTrafficTakeoverActive: Bool = true,
        runtimeMode: MihomoMode? = .rule
    ) {
        self.isMihomoRunning = isMihomoRunning
        self.isControllerConnected = isControllerConnected
        self.hasConfiguration = hasConfiguration
        self.isTrafficTakeoverActive = isTrafficTakeoverActive
        self.runtimeMode = runtimeMode
    }

    static let available = RulesRuntimeAvailability(
        isMihomoRunning: true,
        isControllerConnected: true,
        hasConfiguration: true,
        isTrafficTakeoverActive: true,
        runtimeMode: .rule
    )
}

nonisolated enum RulesRecoveryReason: String, Equatable, Sendable {
    case mihomoStopped
    case controllerDisconnected
    case ruleFetchFailed
    case emptyConfiguration

    static func resolve(
        phase: RulesWorkspacePhase,
        availability: RulesRuntimeAvailability
    ) -> RulesRecoveryReason? {
        if phase == .emptyConfiguration || !availability.hasConfiguration {
            return .emptyConfiguration
        }
        guard phase == .failure else { return nil }
        if !availability.isMihomoRunning { return .mihomoStopped }
        if !availability.isControllerConnected { return .controllerDisconnected }
        return .ruleFetchFailed
    }
}

struct RulesView: View {
#if DEBUG
    @Environment(\.visualUITestConfiguration) private var visualTestConfiguration
#endif
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let viewModel: RulesViewModel
    let runtimeAvailability: RulesRuntimeAvailability
    let onAddRule: (@MainActor (String) async throws -> Void)?
    @State private var refreshTask: Task<Void, Never>?
    @State private var activeRecoveryReason: RulesRecoveryReason?
    @State private var isAddingRule = false
#if DEBUG
    @State private var reloadAttemptCount = 0
#endif
    @State private var isInspectorPresented = false
    @FocusState private var isSearchFocused: Bool

    init(
        viewModel: RulesViewModel,
        runtimeAvailability: RulesRuntimeAvailability = .available,
        onAddRule: (@MainActor (String) async throws -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.runtimeAvailability = runtimeAvailability
        self.onAddRule = onAddRule
    }

    var body: some View {
        @Bindable var model = viewModel

        GeometryReader { geometry in
            let snapshot = model.presentation
            let compact = geometry.size.width < 920 || geometry.size.height < 760
            let pagePadding: CGFloat = compact ? 12 : 24
            let pageSpacing: CGFloat = compact ? 10 : 16
            let headerHeight: CGFloat = compact ? 48 : 64
            let summaryHeight: CGFloat = compact ? 92 : 120
            let previewHeight: CGFloat = compact
                ? 138
                : min(188, max(158, geometry.size.height * 0.19))
            let showsBanner = rulesShowsStateBanner(snapshot.phase)
            let bannerHeight: CGFloat = showsBanner ? (compact ? 48 : 56) : 0
            let workspaceHeight = max(
                300,
                geometry.size.height
                    - (pagePadding * 2)
                    - headerHeight
                    - summaryHeight
                    - previewHeight
                    - bannerHeight
                    - (pageSpacing * 3)
                    - (showsBanner ? pageSpacing : 0)
            )

            ZStack {
                VelaPageCanvas()

                VStack(spacing: pageSpacing) {
                    if showsBanner {
                        stateBanner(snapshot)
                            .frame(height: bannerHeight)
                    }
                    rulesPageHeader(
                        model: $model,
                        snapshot: snapshot,
                        compact: compact
                    )
                    .frame(height: headerHeight)

                    rulesSummary(snapshot: snapshot, compact: compact)
                        .frame(height: summaryHeight)

                    if snapshot.rows.isEmpty {
                        rulesEmptyWorkspace(
                            snapshot: snapshot,
                            compact: compact
                        )
                        .frame(height: workspaceHeight)
                    } else {
                        rulesWorkspace(
                            model: $model,
                            snapshot: snapshot,
                            compact: compact
                        )
                        .frame(height: workspaceHeight)
                    }

                    rulesRoutePreview(
                        model: $model,
                        snapshot: snapshot,
                        compact: compact
                    )
                        .frame(height: previewHeight)
                }
                .padding(pagePadding)
                .frame(
                    width: geometry.size.width,
                    height: geometry.size.height,
                    alignment: .top
                )
            }
            .frame(
                width: geometry.size.width,
                height: geometry.size.height,
                alignment: .topLeading
            )
            .clipped()
        }
        .velaPageRoot()
        .ignoresSafeArea(.container, edges: .top)
        .background(VelaPageCanvas())
        .sheet(isPresented: $isAddingRule) {
            AddRuleSheet(availablePolicies: viewModel.availablePolicies) { rule in
                guard let onAddRule else { return }
                try await onAddRule(rule)
            }
        }
        // Rules is designed as a light Liquid Glass workspace. Keep native
        // materials aligned with that canvas even when macOS uses Dark Mode.
        .environment(\.colorScheme, .light)
        .task {
#if DEBUG
            if let visualTestConfiguration {
                isInspectorPresented = visualTestConfiguration.inspector == .open
                return
            }
#endif
            if CatalogEntryRefreshPolicy.shouldRefresh(
                hasReceivedSnapshot: viewModel.hasReceivedSnapshot,
                hasError: viewModel.lastError != nil
            ) {
                await viewModel.refresh()
            }
        }
        .onDisappear {
            refreshTask?.cancel()
            refreshTask = nil
            activeRecoveryReason = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .velaFocusSearch)) { _ in
            isSearchFocused = true
        }
#if DEBUG
        .overlay(alignment: .topLeading) {
            VStack(spacing: 0) {
                if colorSchemeContrast == .increased {
                    VisualSurfaceMarker(
                        identifier: "rules.accessibility.increasedContrast",
                        label: VelaL10n.string(
                            "rules.accessibility.increasedContrast",
                            defaultValue: "Increased contrast"
                        )
                    )
                }
                if reduceMotion {
                    VisualSurfaceMarker(
                        identifier: "rules.accessibility.reduceMotion",
                        label: VelaL10n.string(
                            "rules.accessibility.reduceMotion",
                            defaultValue: "Reduce motion"
                        )
                    )
                }
            }
            .allowsHitTesting(false)
        }
#endif
    }

    private func rulesPageHeader(
        model: Bindable<RulesViewModel>,
        snapshot: RulesPresentationSnapshot,
        compact: Bool
    ) -> some View {
        HStack(alignment: .center, spacing: compact ? 10 : 16) {
            VStack(alignment: .leading, spacing: compact ? 2 : 4) {
                Text(VelaL10n.string("legacy.rules", defaultValue: "Rules"))
                    .font(VelaTypography.mainPageTitle)
                    .minimumScaleFactor(0.82)
                    .foregroundStyle(RulesLiquidTokens.textPrimary)
                if !compact {
                    Text(
                        VelaL10n.string(
                            "rules.subtitle",
                            defaultValue: "Traffic rules define how requests are routed"
                        )
                    )
                    .font(VelaTypography.pageSubtitle)
                    .foregroundStyle(RulesLiquidTokens.textSecondary)
                }
            }

            Spacer(minLength: 8)

            HStack(spacing: 9) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(RulesLiquidTokens.textSecondary)
                    TextField(
                        VelaL10n.string(
                            "rules.search.placeholder",
                            defaultValue: compact
                                ? "Search rules…"
                                : "Search rules or domains…"
                        ),
                        text: model.searchText
                    )
                    .textFieldStyle(.plain)
                    .focused($isSearchFocused)
                    .disabled(!snapshot.actions.canSearchAndFilter)
                    .accessibilityIdentifier("rules.search")
                }
                .padding(.horizontal, 13)
                .frame(width: compact ? 210 : 270, height: compact ? 36 : 42)
                .rulesLiquidSurface(radius: 13)

                Menu {
                    Button(VelaL10n.string("legacy.allRules", defaultValue: "All Rules")) {
                        model.wrappedValue.typeFilter = nil
                        model.wrappedValue.policyFilter = nil
                        model.wrappedValue.sourceFilter = nil
                    }

                    if !snapshot.availableTypes.isEmpty {
                        Menu(VelaL10n.string("legacy.type", defaultValue: "Type")) {
                            ForEach(snapshot.availableTypes, id: \.self) { value in
                                Button(value) {
                                    model.wrappedValue.typeFilter = value
                                }
                            }
                        }
                    }

                    if !snapshot.availablePolicies.isEmpty {
                        Menu(VelaL10n.string("legacy.policy", defaultValue: "Policy")) {
                            ForEach(snapshot.availablePolicies, id: \.self) { value in
                                Button(value) {
                                    model.wrappedValue.policyFilter = value
                                }
                            }
                        }
                    }

                    if !snapshot.availableSources.isEmpty {
                        Menu(VelaL10n.string("legacy.source", defaultValue: "Source")) {
                            ForEach(snapshot.availableSources, id: \.self) { value in
                                Button(value) {
                                    model.wrappedValue.sourceFilter = value
                                }
                            }
                        }
                    }
                } label: {
                    Label(
                        activeRulesFilterLabel,
                        systemImage: "line.3.horizontal.decrease"
                    )
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(RulesLiquidTokens.textPrimary)
                    .frame(minWidth: compact ? 92 : 108, maxHeight: .infinity)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.visible)
                .frame(minWidth: compact ? 92 : 108)
                .frame(height: compact ? 36 : 42)
                .rulesLiquidSurface(radius: 13)
                .disabled(!snapshot.actions.canSearchAndFilter)

                if shouldShowToolbarRefresh(snapshot) {
                    Button(action: startRefresh) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: compact ? 36 : 42, height: compact ? 36 : 42)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(RulesLiquidTokens.textPrimary)
                    .rulesLiquidSurface(radius: 13)
                    .disabled(!snapshot.actions.canRefresh)
                    .accessibilityIdentifier("rules.refresh")
                    .accessibilityLabel(
                        VelaL10n.string(
                            "legacy.refreshRuntimeRules",
                            defaultValue: "Refresh runtime rules"
                        )
                    )
                    .help(
                        VelaL10n.string(
                            "legacy.refreshRuntimeRules",
                            defaultValue: "Refresh runtime rules"
                        )
                    )
                }

                Button(action: toggleInspector) {
                    Image(systemName: "sidebar.trailing")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: compact ? 36 : 42, height: compact ? 36 : 42)
                }
                .buttonStyle(.plain)
                .foregroundStyle(
                    isInspectorPresented
                        ? RulesLiquidTokens.mint
                        : RulesLiquidTokens.textPrimary
                )
                .rulesLiquidSurface(radius: 13)
                .accessibilityIdentifier("rules.inspector.toggle")
                .accessibilityLabel(
                    VelaL10n.string(
                        isInspectorPresented
                            ? "legacy.hideTheRuleInspector"
                            : "legacy.showTheRuleInspector",
                        defaultValue: isInspectorPresented
                            ? "Hide the rule inspector"
                            : "Show the rule inspector"
                    )
                )
                .help(
                    VelaL10n.string(
                        isInspectorPresented
                            ? "legacy.hideTheRuleInspector"
                            : "legacy.showTheRuleInspector",
                        defaultValue: isInspectorPresented
                            ? "Hide the rule inspector"
                            : "Show the rule inspector"
                    )
                )
            }
        }
    }

    private func rulesSummary(
        snapshot: RulesPresentationSnapshot,
        compact: Bool
    ) -> some View {
        let hasLiveStatistics = runtimeAvailability.isTrafficTakeoverActive
            && runtimeAvailability.isMihomoRunning
            && runtimeAvailability.isControllerConnected
        let matchedCount = snapshot.allRows.reduce(UInt64.zero) {
            $0 + ($1.hitCount ?? 0)
        }
        let directHits = snapshot.allRows.reduce(UInt64.zero) { partial, row in
            row.policy.caseInsensitiveCompare("DIRECT") == .orderedSame
                ? partial + (row.hitCount ?? 0)
                : partial
        }
        let proxyHits = matchedCount >= directHits
            ? matchedCount - directHits
            : 0
        let matchedPercent = matchedCount == 0
            ? 0
            : Double(proxyHits) / Double(matchedCount) * 100
        let bypassedPercent = matchedCount == 0
            ? 0
            : Double(directHits) / Double(matchedCount) * 100

        return HStack(spacing: compact ? 8 : 14) {
            rulesMetricCard(
                title: VelaL10n.string("rules.metrics.total", defaultValue: "Total Rules"),
                value: snapshot.totalRuleCount.formatted(),
                detail: VelaL10n.string(
                    "rules.metrics.groups",
                    defaultValue: "Across %lld groups",
                    arguments: ruleGroups(
                        for: snapshot.allRows,
                        availableTypes: snapshot.availableTypes
                    ).count
                ),
                tint: RulesLiquidTokens.blue,
                systemImage: "list.bullet.rectangle",
                compact: compact
            )
            rulesMetricCard(
                title: VelaL10n.string("rules.metrics.matched", defaultValue: "Matched"),
                value: VelaRuntimeMetricPresentation.value(
                    proxyHits.formatted(),
                    isAvailable: hasLiveStatistics
                ),
                detail: VelaRuntimeMetricPresentation.value(
                    VelaL10n.string(
                        "rules.metrics.percentOfTotal",
                        defaultValue: "%.1f%% of total",
                        arguments: matchedPercent
                    ),
                    isAvailable: hasLiveStatistics
                ),
                tint: RulesLiquidTokens.mint,
                systemImage: "waveform.path.ecg",
                compact: compact
            )
            rulesMetricCard(
                title: VelaL10n.string("rules.metrics.bypassed", defaultValue: "Bypassed"),
                value: VelaRuntimeMetricPresentation.value(
                    directHits.formatted(),
                    isAvailable: hasLiveStatistics
                ),
                detail: VelaRuntimeMetricPresentation.value(
                    VelaL10n.string(
                        "rules.metrics.percentOfTotal",
                        defaultValue: "%.1f%% of total",
                        arguments: bypassedPercent
                    ),
                    isAvailable: hasLiveStatistics
                ),
                tint: RulesLiquidTokens.violet,
                systemImage: "point.3.connected.trianglepath.dotted",
                compact: compact
            )
            rulesMetricCard(
                title: VelaL10n.string("rules.metrics.mode", defaultValue: "Rule Mode"),
                value: runtimeAvailability.runtimeMode?.displayName
                    ?? VelaRuntimeMetricPresentation.unavailable,
                detail: VelaL10n.string("rules.metrics.currentMode", defaultValue: "Current Mode"),
                tint: RulesLiquidTokens.mint,
                systemImage: "checkmark.shield",
                emphasizesValue: true,
                compact: compact
            )
            rulesMetricCard(
                title: VelaL10n.string("rules.metrics.updated", defaultValue: "Last Updated"),
                value: snapshot.snapshotAge.map(compactDuration) ?? "—",
                detail: VelaL10n.string("rules.metrics.autoUpdate", defaultValue: "Auto Update"),
                tint: RulesLiquidTokens.blue,
                systemImage: "arrow.clockwise",
                compact: compact
            )
        }
        .accessibilityIdentifier("rules.metrics")
    }

    private func rulesMetricCard(
        title: String,
        value: String,
        detail: String,
        tint: Color,
        systemImage: String,
        emphasizesValue: Bool = false,
        compact: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: compact ? 5 : 8) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: compact ? 10 : 12, weight: .medium))
                    .foregroundStyle(tint)
                Text(title)
                    .font(VelaTypography.table.weight(.medium))
                    .foregroundStyle(RulesLiquidTokens.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
            Text(value)
                .font(.system(size: compact ? 18 : 23, weight: .semibold, design: .rounded))
                .foregroundStyle(
                    emphasizesValue
                        ? RulesLiquidTokens.mint
                        : RulesLiquidTokens.textPrimary
                )
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(detail)
                .font(VelaTypography.caption.weight(.medium))
                .foregroundStyle(RulesLiquidTokens.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
        }
        .padding(.horizontal, compact ? 10 : 15)
        .padding(.vertical, compact ? 9 : 13)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .rulesLiquidSurface(radius: compact ? 14 : 17)
        .accessibilityElement(children: .combine)
    }

    private func rulesWorkspace(
        model: Bindable<RulesViewModel>,
        snapshot: RulesPresentationSnapshot,
        compact: Bool
    ) -> some View {
        GeometryReader { proxy in
            let groupWidth: CGFloat = compact ? 170 : 218
            let inspectorWidth: CGFloat = isInspectorPresented
                ? (compact ? 290 : 258)
                : 0
            let listWidth = max(
                compact ? 310 : 320,
                proxy.size.width
                    - groupWidth
                    - inspectorWidth
                    - (isInspectorPresented ? (compact ? 20 : 28) : (compact ? 10 : 14))
            )

            HStack(alignment: .top, spacing: compact ? 10 : 14) {
                rulesGroupPane(model: model, snapshot: snapshot, compact: compact)
                    .frame(width: groupWidth)

                rulesListPane(
                    model: model,
                    snapshot: snapshot,
                    compactColumns: listWidth < 455,
                    compact: compact
                )
                .frame(maxWidth: .infinity)

                if isInspectorPresented {
                    rulesInspectorCard(snapshot: snapshot, compact: compact)
                        .frame(width: inspectorWidth)
                }
            }
        }
    }

    private func rulesEmptyWorkspace(
        snapshot: RulesPresentationSnapshot,
        compact: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: compact ? 10 : 14) {
            rulesEmptyState(snapshot)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .rulesLiquidSurface(radius: compact ? 16 : 20)

            if isInspectorPresented {
                rulesInspectorCard(snapshot: snapshot, compact: compact)
                    .frame(width: compact ? 290 : 258)
            }
        }
    }

    private func rulesGroupPane(
        model: Bindable<RulesViewModel>,
        snapshot: RulesPresentationSnapshot,
        compact: Bool
    ) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(VelaL10n.string("rules.groups.title", defaultValue: "Rule Groups"))
                    .font(VelaTypography.sectionTitle)
                Spacer()
                Button {
                    isAddingRule = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .disabled(!runtimeAvailability.hasConfiguration || onAddRule == nil)
                .accessibilityLabel(
                    VelaL10n.string(
                        "rules.action.add",
                        defaultValue: "Add Rule"
                    )
                )
                .help(
                    VelaL10n.string(
                        "rules.action.add.help",
                        defaultValue: "Add a persistent rule before subscription rules."
                    )
                )
            }
            .padding(.horizontal, 14)
            .frame(height: compact ? 42 : 50)

            Rectangle()
                .fill(RulesLiquidTokens.divider)
                .frame(height: 1)

            ScrollView {
                LazyVStack(spacing: 6) {
                    Button {
                        model.wrappedValue.typeFilter = nil
                        model.wrappedValue.policyFilter = nil
                        model.wrappedValue.sourceFilter = nil
                    } label: {
                        rulesGroupLabel(
                            RulesVisualGroup(
                                title: VelaL10n.string(
                                    "legacy.allRules",
                                    defaultValue: "All Rules"
                                ),
                                filterValues: [],
                                count: snapshot.totalRuleCount,
                                hitCount: aggregatedRuleHitCount(in: snapshot.allRows),
                                systemImage: "list.bullet.rectangle",
                                order: -1,
                                isPrimary: true
                            ),
                            isSelected: !model.wrappedValue.hasActiveFilters,
                            compact: compact,
                            showsSubmenu: false
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("rules.group.all")

                    ForEach(
                        ruleGroups(
                            for: snapshot.allRows,
                            availableTypes: snapshot.availableTypes
                        )
                    ) { group in
                        let isSelected = group.filterValues.contains {
                            model.wrappedValue.typeFilter == $0
                        }
                        if group.filterValues.count > 1 {
                            VStack(spacing: 2) {
                                rulesGroupLabel(
                                    group,
                                    isSelected: isSelected,
                                    compact: compact,
                                    showsSubmenu: false
                                )
                                .accessibilityElement(children: .combine)
                                .accessibilityIdentifier("rules.group.\(group.order)")

                                ForEach(group.filterValues, id: \.self) { type in
                                    let subtypeSelected = model.wrappedValue.typeFilter == type
                                    Button {
                                        model.wrappedValue.typeFilter = subtypeSelected ? nil : type
                                    } label: {
                                        rulesSubtypeLabel(
                                            type,
                                            count: snapshot.allRows.lazy.filter { $0.type == type }.count,
                                            isSelected: subtypeSelected,
                                            compact: compact
                                        )
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityIdentifier(
                                        "rules.group.\(group.order).\(type)"
                                    )
                                }
                            }
                        } else {
                            Button {
                                model.wrappedValue.typeFilter = isSelected
                                    ? nil
                                    : group.filterValues.first
                            } label: {
                                rulesGroupLabel(
                                    group,
                                    isSelected: isSelected,
                                    compact: compact,
                                    showsSubmenu: false
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(group.filterValues.isEmpty)
                            .accessibilityIdentifier("rules.group.\(group.order)")
                        }
                    }
                }
                .padding(10)
            }

            Rectangle()
                .fill(RulesLiquidTokens.divider)
                .frame(height: 1)

            Button {
                SettingsMainNavigationRequest.navigateInCurrentWindow(.diagnostics)
            } label: {
                Label(
                    VelaL10n.string("rules.group.statistics", defaultValue: "Rule Statistics"),
                    systemImage: "chart.bar"
                )
                .font(VelaTypography.caption.weight(.medium))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
            .frame(height: compact ? 38 : 44)
        }
        .rulesLiquidSurface(radius: compact ? 16 : 19)
    }

    private func rulesGroupLabel(
        _ group: RulesVisualGroup,
        isSelected: Bool,
        compact: Bool,
        showsSubmenu: Bool
    ) -> some View {
        HStack(spacing: compact ? 8 : 10) {
            Image(systemName: group.systemImage)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(
                    isSelected ? RulesLiquidTokens.blue : RulesLiquidTokens.textSecondary
                )
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(group.title)
                    .font(VelaTypography.table.weight(.semibold))
                    .foregroundStyle(RulesLiquidTokens.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                    .layoutPriority(1)
                Text(
                    group.count == 1
                        ? VelaL10n.string(
                            "rules.group.count.singular",
                            defaultValue: "%lld rule",
                            arguments: group.count
                        )
                        : VelaL10n.string(
                            "rules.group.count",
                            defaultValue: "%lld rules",
                            arguments: group.count
                        )
                )
                .font(VelaTypography.caption.weight(.medium))
                .foregroundStyle(RulesLiquidTokens.textSecondary)
            }
            Spacer(minLength: 4)
            if let hits = group.hitCount, hits > 0 {
                Text(hits.formatted())
                    .font(VelaTypography.caption.weight(.semibold))
                    .foregroundStyle(RulesLiquidTokens.mint)
            }
            if showsSubmenu {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(RulesLiquidTokens.textSecondary)
            }
        }
        .padding(.horizontal, compact ? 9 : 12)
        .frame(
            maxWidth: .infinity,
            minHeight: compact ? 38 : 52,
            alignment: .leading
        )
        .background(
            isSelected ? RulesLiquidTokens.selectedFill : Color.clear,
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .contentShape(.rect)
    }

    private func rulesSubtypeLabel(
        _ type: String,
        count: Int,
        isSelected: Bool,
        compact: Bool
    ) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(
                    isSelected
                        ? RulesLiquidTokens.blue
                        : RulesLiquidTokens.textSecondary.opacity(0.5)
                )
                .frame(width: 5, height: 5)
            Text(type)
                .font(VelaTypography.caption.weight(.medium))
                .foregroundStyle(RulesLiquidTokens.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(count.formatted())
                .font(VelaTypography.caption.weight(.semibold))
                .foregroundStyle(RulesLiquidTokens.textSecondary)
        }
        .padding(.leading, compact ? 31 : 38)
        .padding(.trailing, compact ? 9 : 12)
        .frame(maxWidth: .infinity, minHeight: compact ? 30 : 34, alignment: .leading)
        .background(
            isSelected ? RulesLiquidTokens.selectedFill : Color.clear,
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .contentShape(.rect)
    }

    private func rulesListPane(
        model: Bindable<RulesViewModel>,
        snapshot: RulesPresentationSnapshot,
        compactColumns: Bool,
        compact: Bool
    ) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(
                    VelaL10n.string(
                        "rules.list.count",
                        defaultValue: "Rules (%lld)",
                        arguments: snapshot.rows.count
                    )
                )
                .font(VelaTypography.sectionTitle)
                Spacer()
                Button {
                    SettingsMainNavigationRequest.navigateInCurrentWindow(.configuration)
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    VelaL10n.string(
                        "rules.action.openWorkbench",
                        defaultValue: "Open Workbench"
                    )
                )
                .help(
                    VelaL10n.string(
                        "rules.action.openWorkbench.help",
                        defaultValue: "Open the exact editable source in Configuration Workbench."
                    )
                )
            }
            .padding(.horizontal, 14)
            .frame(height: compact ? 42 : 50)

            HStack(spacing: 8) {
                Text(VelaL10n.string("rules.column.source", defaultValue: "Source / Domain"))
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !compactColumns {
                    Text(VelaL10n.string("rules.column.matchType", defaultValue: "Match Type"))
                        .frame(width: 104, alignment: .leading)
                    Text(VelaL10n.string("rules.column.target", defaultValue: "Target"))
                        .frame(width: 62, alignment: .leading)
                }
                Text(VelaL10n.string("legacy.proxy", defaultValue: "Proxy"))
                    .frame(width: compactColumns ? 76 : 96, alignment: .leading)
                Text(VelaL10n.string("rules.column.hits", defaultValue: "Hits"))
                    .frame(width: 38, alignment: .trailing)
            }
            .font(VelaTypography.caption.weight(.medium))
            .foregroundStyle(RulesLiquidTokens.textSecondary)
            .padding(.horizontal, 14)
            .frame(height: 34)

            Rectangle()
                .fill(RulesLiquidTokens.divider)
                .frame(height: 1)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(
                        Array(snapshot.rows.enumerated()),
                        id: \.element.id
                    ) { index, row in
                        let isSelected = snapshot.selectedRuleID == row.id
                        Button {
                            model.wrappedValue.selectedRuleID = row.id
                            if !isInspectorPresented {
                                toggleInspector()
                            }
                        } label: {
                            HStack(spacing: 8) {
                                HStack(spacing: 9) {
                                    Image(systemName: rulesIcon(for: row))
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(rulesIconTint(for: row))
                                        .frame(width: 24, height: 24)
                                        .background(
                                            rulesIconTint(for: row).opacity(0.10),
                                            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        )
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(row.payload.isEmpty ? "Final Match" : row.payload)
                                            .font(VelaTypography.table.weight(.semibold))
                                            .foregroundStyle(RulesLiquidTokens.textPrimary)
                                            .lineLimit(1)
                                        if compactColumns {
                                            Text(row.type.isEmpty ? "—" : row.type)
                                                .font(VelaTypography.caption.weight(.medium))
                                                .foregroundStyle(RulesLiquidTokens.textSecondary)
                                                .lineLimit(1)
                                        }
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)

                                if !compactColumns {
                                    Text(row.type.isEmpty ? "—" : row.type)
                                        .frame(width: 104, alignment: .leading)
                                    Text(
                                        row.policy.caseInsensitiveCompare("DIRECT") == .orderedSame
                                            ? "Direct"
                                            : "Proxy"
                                    )
                                    .frame(width: 62, alignment: .leading)
                                }

                                HStack(spacing: 5) {
                                    Image(
                                        systemName: row.policy.caseInsensitiveCompare("DIRECT") == .orderedSame
                                            ? "nosign"
                                            : "globe"
                                    )
                                    .foregroundStyle(
                                        row.policy.caseInsensitiveCompare("DIRECT") == .orderedSame
                                            ? RulesLiquidTokens.danger
                                            : RulesLiquidTokens.blue
                                    )
                                    Text(row.policy.isEmpty ? "—" : row.policy)
                                        .lineLimit(1)
                                }
                                .frame(width: compactColumns ? 76 : 96, alignment: .leading)

                                Text(row.hitCount?.formatted() ?? "—")
                                    .monospacedDigit()
                                    .frame(width: 38, alignment: .trailing)
                            }
                            .font(VelaTypography.caption.weight(.medium))
                            .foregroundStyle(RulesLiquidTokens.textSecondary)
                            .padding(.horizontal, 14)
                            .frame(maxWidth: .infinity, minHeight: compact ? 32 : 44)
                            .background(isSelected ? RulesLiquidTokens.selectedFill : Color.clear)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .focusable()
                        .onMoveCommand { direction in
                            let nextIndex: Int
                            switch direction {
                            case .up:
                                nextIndex = max(snapshot.rows.startIndex, index - 1)
                            case .down:
                                nextIndex = min(
                                    snapshot.rows.index(before: snapshot.rows.endIndex),
                                    index + 1
                                )
                            default:
                                return
                            }
                            model.wrappedValue.selectedRuleID = snapshot.rows[nextIndex].id
                        }
                        .accessibilityIdentifier("rules.row.\(row.runtimeIndex)")

                        Rectangle()
                            .fill(RulesLiquidTokens.divider.opacity(0.72))
                            .frame(height: 1)
                    }
                }
            }
            .accessibilityIdentifier("rules.table")

            Rectangle()
                .fill(RulesLiquidTokens.divider)
                .frame(height: 1)

            HStack(spacing: 10) {
                Text(VelaL10n.string("rules.pagination.showing", defaultValue: "Showing"))
                Text(snapshot.rows.count.formatted())
                    .fontWeight(.semibold)
                Spacer()
                Text(
                    "\(snapshot.rows.count) / \(snapshot.totalRuleCount)"
                )
                .monospacedDigit()
            }
            .buttonStyle(.plain)
            .font(VelaTypography.caption.weight(.medium))
            .foregroundStyle(RulesLiquidTokens.textSecondary)
            .padding(.horizontal, 14)
            .frame(height: compact ? 38 : 44)
        }
        .rulesLiquidSurface(radius: compact ? 16 : 19)
#if DEBUG
        .overlay(alignment: .topLeading) {
            VisualSurfaceMarker(
                identifier: "rules.columns.\(compactColumns ? "compact" : "regular")",
                label: compactColumns ? "compact" : "regular"
            )
            .allowsHitTesting(false)
            .accessibilityHidden(false)
        }
#endif
    }

    private func rulesInspectorCard(
        snapshot: RulesPresentationSnapshot,
        compact: Bool
    ) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(VelaL10n.string("rules.inspector.title", defaultValue: "Rule Details"))
                    .font(VelaTypography.sectionTitle)
                Spacer()
                Button {
                    toggleInspector()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("rules.inspector.close")
            }
            .padding(.horizontal, 14)
            .frame(height: compact ? 42 : 50)

            Rectangle()
                .fill(RulesLiquidTokens.divider)
                .frame(height: 1)

            if let inspector = snapshot.inspector {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 12) {
                            Image(systemName: rulesIcon(for: inspector.row))
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(rulesIconTint(for: inspector.row))
                                .frame(width: 48, height: 48)
                                .background(
                                    rulesIconTint(for: inspector.row).opacity(0.10),
                                    in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                                )
                            VStack(alignment: .leading, spacing: 3) {
                                Text(
                                    inspector.row.payload.isEmpty
                                        ? "Final Match"
                                        : inspector.row.payload
                                )
                                .font(.system(size: compact ? 12.5 : 14, weight: .semibold))
                                .lineLimit(2)
                                .truncationMode(.middle)
                                .minimumScaleFactor(0.78)
                                HStack(spacing: 5) {
                                    Circle()
                                        .fill(RulesLiquidTokens.mint)
                                        .frame(width: 6, height: 6)
                                    Text(
                                        VelaL10n.string(
                                            "rules.inspector.active",
                                            defaultValue: "Active Rule"
                                        )
                                    )
                                    .font(VelaTypography.caption.weight(.semibold))
                                    .foregroundStyle(RulesLiquidTokens.mint)
                                }
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            Color.white.opacity(0.48),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                        )

                        VStack(spacing: 0) {
                            rulesInspectorDetail(
                                VelaL10n.string("rules.field.ruleName", defaultValue: "Rule Name"),
                                "#\(inspector.row.runtimeIndex) \(inspector.row.type)"
                            )
                            rulesInspectorDetail(
                                VelaL10n.string("legacy.source", defaultValue: "Source"),
                                inspector.row.provenance.sourceDisplayName ?? "Runtime"
                            )
                            rulesInspectorDetail(
                                VelaL10n.string(
                                    "rules.field.sourceConfidence",
                                    defaultValue: "Source Confidence"
                                ),
                                rulesConfidenceLabel(inspector.confidence)
                            )
                            rulesInspectorDetail(
                                VelaL10n.string("rules.column.matchType", defaultValue: "Match Type"),
                                inspector.row.type
                            )
                            rulesInspectorDetail(
                                VelaL10n.string("rules.field.pattern", defaultValue: "Pattern"),
                                inspector.row.payload
                            )
                            rulesInspectorDetail(
                                VelaL10n.string("rules.column.target", defaultValue: "Target"),
                                inspector.row.policy.caseInsensitiveCompare("DIRECT") == .orderedSame
                                    ? "Direct"
                                    : "Proxy"
                            )
                            if inspector.row.policy.caseInsensitiveCompare("DIRECT") == .orderedSame {
                                rulesInspectorDetail(
                                    VelaL10n.string("legacy.policy", defaultValue: "Policy"),
                                    inspector.row.policy
                                )
                            } else {
                                rulesInspectorDetail(
                                    VelaL10n.string(
                                        "rules.field.proxyGroup",
                                        defaultValue: "Proxy Group"
                                    ),
                                    inspector.row.policy
                                )
                            }
                            if let provider = inspector.row.provenance.providerDisplayName {
                                Button {
                                    SettingsMainNavigationRequest.navigateInCurrentWindow(.providers)
                                } label: {
                                    rulesInspectorDetail(
                                        VelaL10n.string(
                                            "rules.field.provider",
                                            defaultValue: "Rule Provider"
                                        ),
                                        provider
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                            rulesInspectorDetail(
                                VelaL10n.string("rules.field.matches", defaultValue: "Hit Count"),
                                inspector.row.hitCount?.formatted() ?? "—"
                            )
                            rulesInspectorDetail(
                                VelaL10n.string(
                                    "rules.field.lastMatched",
                                    defaultValue: "Last Matched"
                                ),
                                inspector.row.lastMatchedAt?.formatted(
                                    date: .omitted,
                                    time: .standard
                                ) ?? "—"
                            )
                            rulesInspectorDetail(
                                VelaL10n.string("rules.field.priority", defaultValue: "Priority"),
                                inspector.row.runtimeIndex.formatted()
                            )
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(VelaL10n.string("rules.field.rawRule", defaultValue: "Rule Raw"))
                                    .font(VelaTypography.caption.weight(.medium))
                                    .foregroundStyle(RulesLiquidTokens.textSecondary)
                                Spacer()
                                Button {
                                    copyRedactedRuleSummary(inspector.row)
                                } label: {
                                    Image(systemName: "doc.on.clipboard")
                                        .font(.system(size: 9.5, weight: .semibold))
                                }
                                .buttonStyle(.plain)
                                .help(
                                    VelaL10n.string(
                                        "rules.action.copyRedacted",
                                        defaultValue: "Copy Redacted Technical Summary"
                                    )
                                )
                                .accessibilityIdentifier("rules.inspector.copyRedacted")
                            }
                            Text(inspector.row.rawRule)
                                .font(VelaTypography.code)
                                .foregroundStyle(RulesLiquidTokens.textPrimary)
                                .textSelection(.enabled)
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    RulesLiquidTokens.codeFill,
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                                )
                        }
                    }
                    .padding(14)
                }
                .accessibilityIdentifier("rules.inspector.scroll")

                Rectangle()
                    .fill(RulesLiquidTokens.divider)
                    .frame(height: 1)

                VStack(spacing: 8) {
                    Button(action: startRefresh) {
                        Label(
                            VelaL10n.string(
                                "rules.action.refreshEvidence",
                                defaultValue: "Refresh Evidence"
                            ),
                            systemImage: "arrow.clockwise"
                        )
                        .frame(maxWidth: .infinity, minHeight: 32)
                    }
                    .buttonStyle(.plain)
                    .font(VelaTypography.caption.weight(.semibold))
                    .foregroundStyle(RulesLiquidTokens.textPrimary)
                    .background(
                        Color.white.opacity(0.52),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                    .disabled(!snapshot.actions.canRefresh)

                    Button {
                        let current = inspector.row.isTemporarilyDisabled ?? false
                        Task {
                            await viewModel.setDisabled(
                                !current,
                                rule: inspector.row.rule
                            )
                        }
                    } label: {
                        Label(
                            inspector.row.isTemporarilyDisabled == true
                                ? VelaL10n.string(
                                    "legacy.enableTemporarily",
                                    defaultValue: "Enable Rule"
                                )
                                : VelaL10n.string(
                                    "legacy.disableTemporarily",
                                    defaultValue: "Disable Rule"
                                ),
                            systemImage: inspector.row.isTemporarilyDisabled == true
                                ? "play.circle"
                                : "nosign"
                        )
                        .frame(maxWidth: .infinity, minHeight: 32)
                    }
                    .buttonStyle(.plain)
                    .font(VelaTypography.caption.weight(.semibold))
                    .foregroundStyle(RulesLiquidTokens.danger)
                    .disabled(!snapshot.actions.canToggleTemporaryState)
                    .accessibilityIdentifier("rules.inspector.toggleTemporary")
                }
                .padding(12)
            } else {
                VelaEmptyState(
                    title: inspectorEmptyTitle(snapshot.phase),
                    description: inspectorEmptyDetail(snapshot.phase),
                    systemImage: "sidebar.right"
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .rulesLiquidSurface(radius: compact ? 16 : 19, emphasized: true)
#if DEBUG
        .overlay(alignment: .topLeading) {
            VStack(spacing: 0) {
                VisualSurfaceMarker(
                    identifier: "rules.inspector.pane",
                    label: VelaL10n.string(
                        "rules.inspector.title",
                        defaultValue: "Rule Details"
                    )
                )
                if snapshot.inspector == nil {
                    VisualSurfaceMarker(
                        identifier: "rules.inspector.empty",
                        label: VelaL10n.string(
                            "rules.inspector.empty.title",
                            defaultValue: "No Rule Selected"
                        )
                    )
                } else {
                    VisualSurfaceMarker(
                        identifier: "rules.inspector.selected",
                        label: VelaL10n.string(
                            "rules.accessibility.selectedInspector",
                            defaultValue: "Selected rule inspector"
                        )
                    )
                }
            }
            .allowsHitTesting(false)
        }
        .overlay {
            if snapshot.inspector == nil {
                VisualSurfaceMarker(
                    identifier: "rules.inspector.empty.center",
                    label: VelaL10n.string(
                        "rules.inspector.empty.center.debugLabel",
                        defaultValue: "Empty rule inspector center"
                    )
                )
                .allowsHitTesting(false)
            }
        }
#endif
    }

    private func rulesInspectorDetail(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .foregroundStyle(RulesLiquidTokens.textSecondary)
            Spacer(minLength: 8)
            Text(value.isEmpty ? "—" : value)
                .foregroundStyle(RulesLiquidTokens.textPrimary)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
        .font(VelaTypography.table.weight(.medium))
        .padding(.vertical, 7)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(RulesLiquidTokens.divider)
                .frame(height: 1)
        }
    }

    private func copyRedactedRuleSummary(_ row: RuntimeRuleRowModel) {
        let value = [
            "runtimeIndex=\(row.runtimeIndex)",
            "type=\(row.type)",
            "policy=\(row.policy)",
            "hasMatchEvidence=\(row.hitCount != nil)",
        ].joined(separator: "\n")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }

    private func rulesConfidenceLabel(_ confidence: RuleSourceConfidence) -> String {
        switch confidence {
        case .exact:
            VelaL10n.string("rules.confidence.exact", defaultValue: "Exact Source")
        case .ambiguous:
            VelaL10n.string(
                "rules.confidence.ambiguous",
                defaultValue: "Ambiguous Source"
            )
        case .unavailable:
            VelaL10n.string(
                "rules.confidence.unavailable",
                defaultValue: "Source Unavailable"
            )
        case .stale:
            VelaL10n.string("rules.confidence.stale", defaultValue: "Stale Source")
        }
    }

    private func rulesRoutePreview(
        model: Bindable<RulesViewModel>,
        snapshot: RulesPresentationSnapshot,
        compact: Bool
    ) -> some View {
        let selected = snapshot.inspector?.row ?? snapshot.rows.first
        let routeIsLive = runtimeAvailability.isMihomoRunning
            && runtimeAvailability.isControllerConnected
            && runtimeAvailability.isTrafficTakeoverActive

        return VStack(alignment: .leading, spacing: compact ? 8 : 11) {
            VStack(alignment: .leading, spacing: 2) {
                Text(VelaL10n.string("rules.preview.title", defaultValue: "Rule Preview"))
                    .font(VelaTypography.sectionTitle)
                if !compact {
                    Text(
                        VelaL10n.string(
                            "rules.preview.subtitle",
                            defaultValue: "Traffic flow for this rule"
                        )
                    )
                    .font(VelaTypography.caption.weight(.medium))
                    .foregroundStyle(RulesLiquidTokens.textSecondary)
                }
            }

            if let selected {
                HStack(alignment: .top, spacing: compact ? 8 : 12) {
                    rulesRouteNode(
                        title: VelaL10n.string("rules.preview.thisMac", defaultValue: "This Mac"),
                        detail: "",
                        systemImage: "desktopcomputer",
                        tint: RulesLiquidTokens.textSecondary,
                        compact: compact
                    )
                    RulesRouteConnector(tint: RulesLiquidTokens.divider)
                        .frame(height: compact ? 36 : 44)
                    rulesRouteNode(
                        title: selected.payload.isEmpty ? "Final Match" : selected.payload,
                        detail: selected.type,
                        systemImage: rulesIcon(for: selected),
                        tint: RulesLiquidTokens.mint,
                        compact: compact
                    )
                    RulesRouteConnector(
                        tint: routeIsLive
                            ? RulesLiquidTokens.mint
                            : RulesLiquidTokens.divider
                    )
                        .frame(height: compact ? 36 : 44)
                    let isDirect = selected.policy.caseInsensitiveCompare("DIRECT") == .orderedSame
                    rulesRouteNode(
                        title: selected.policy,
                        detail: isDirect
                            ? VelaL10n.string("rules.preview.direct", defaultValue: "Direct")
                            : VelaL10n.string(
                                "rules.preview.proxyGroup",
                                defaultValue: "Proxy Group"
                            ),
                        systemImage: isDirect
                            ? "arrow.right.circle"
                            : "point.3.connected.trianglepath.dotted",
                        tint: isDirect ? RulesLiquidTokens.blue : RulesLiquidTokens.violet,
                        compact: compact
                    )
                    RulesRouteConnector(tint: RulesLiquidTokens.divider)
                        .frame(height: compact ? 36 : 44)
                    rulesRouteNode(
                        title: VelaL10n.string(
                            "rules.preview.internet",
                            defaultValue: "Internet"
                        ),
                        detail: "",
                        systemImage: "globe",
                        tint: RulesLiquidTokens.textSecondary,
                        compact: compact
                    )
                }
                .frame(maxHeight: .infinity)
            } else {
                VStack(spacing: 7) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: compact ? 20 : 24, weight: .medium))
                        .foregroundStyle(RulesLiquidTokens.textSecondary)
                    Text(
                        VelaL10n.string(
                            "rules.preview.unavailable",
                            defaultValue: "Select a rule to preview its traffic flow"
                        )
                    )
                    .font(VelaTypography.caption.weight(.medium))
                    .foregroundStyle(RulesLiquidTokens.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Button {
                guard let selected else { return }
                model.wrappedValue.selectedRuleID = selected.id
                if !isInspectorPresented {
                    toggleInspector()
                }
                startRefresh()
            } label: {
                Label(
                    VelaL10n.string(
                        "rules.action.refreshEvidence",
                        defaultValue: "Refresh Rule Evidence"
                    ),
                    systemImage: "point.3.connected.trianglepath.dotted"
                )
                .font(VelaTypography.caption.weight(.semibold))
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .center)
            .disabled(selected == nil)
        }
        .padding(compact ? 12 : 16)
        .rulesLiquidSurface(radius: compact ? 16 : 19)
        .accessibilityIdentifier("rules.routePreview")
    }

    private func rulesRouteNode(
        title: String,
        detail: String,
        systemImage: String,
        tint: Color,
        compact: Bool
    ) -> some View {
        VStack(spacing: compact ? 4 : 6) {
            Image(systemName: systemImage)
                .font(.system(size: compact ? 15 : 18, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: compact ? 36 : 44, height: compact ? 36 : 44)
                .background(
                    Color.white.opacity(0.64),
                    in: RoundedRectangle(cornerRadius: compact ? 11 : 13, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: compact ? 11 : 13, style: .continuous)
                        .stroke(tint.opacity(0.16), lineWidth: 1)
                }
            Text(title)
                .font(VelaTypography.table.weight(.semibold))
                .foregroundStyle(RulesLiquidTokens.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
            if !detail.isEmpty {
                Text(detail)
                    .font(VelaTypography.caption.weight(.medium))
                    .foregroundStyle(RulesLiquidTokens.textSecondary)
                    .lineLimit(1)
            }
        }
        .frame(width: compact ? 92 : 126)
    }

    private func ruleGroups(
        for rows: [RuntimeRuleRowModel],
        availableTypes: [String]
    ) -> [RulesVisualGroup] {
        let grouped = Dictionary(grouping: rows) { row in
            rulesGroupIdentity(for: row.type)
        }
        let order = [
            rulesGroupTitle("domain", defaultValue: "Domain"),
            rulesGroupTitle("ipCIDR", defaultValue: "IP-CIDR"),
            rulesGroupTitle("geoIP", defaultValue: "GeoIP"),
            rulesGroupTitle("process", defaultValue: "Process"),
            rulesGroupTitle("final", defaultValue: "Final"),
            rulesGroupTitle("providerRules", defaultValue: "Provider Rules"),
            rulesGroupTitle("others", defaultValue: "Others"),
        ]
        let availableByGroup = Dictionary(grouping: availableTypes) {
            rulesGroupIdentity(for: $0)
        }
        let titles = Set(grouped.keys).union(availableByGroup.keys)

        return titles.map { title in
            let groupedRows = grouped[title] ?? []
            let filterValues = Set(groupedRows.map(\.type))
                .union(availableByGroup[title] ?? [])
                .sorted()
            return RulesVisualGroup(
                title: title,
                filterValues: filterValues,
                count: groupedRows.count,
                hitCount: aggregatedRuleHitCount(in: groupedRows),
                systemImage: rulesGroupIcon(for: title),
                order: order.firstIndex(of: title) ?? order.count,
                isPrimary: false
            )
        }
        .sorted {
            if $0.order == $1.order { return $0.title < $1.title }
            return $0.order < $1.order
        }
    }

    private func aggregatedRuleHitCount(
        in rows: [RuntimeRuleRowModel]
    ) -> UInt64? {
        let availableHitCounts = rows.compactMap(\.hitCount)
        guard !availableHitCounts.isEmpty else { return nil }
        return availableHitCounts.reduce(0, +)
    }

    private func rulesGroupIdentity(for type: String) -> String {
        let normalized = type.uppercased()
        if normalized.contains("DOMAIN") {
            return rulesGroupTitle("domain", defaultValue: "Domain")
        }
        if normalized.contains("IP-CIDR") {
            return rulesGroupTitle("ipCIDR", defaultValue: "IP-CIDR")
        }
        if normalized.contains("GEOIP") {
            return rulesGroupTitle("geoIP", defaultValue: "GeoIP")
        }
        if normalized.contains("PROCESS") {
            return rulesGroupTitle("process", defaultValue: "Process")
        }
        if normalized == "MATCH" {
            return rulesGroupTitle("final", defaultValue: "Final")
        }
        if normalized.contains("RULE-SET") {
            return rulesGroupTitle("providerRules", defaultValue: "Provider Rules")
        }
        return rulesGroupTitle("others", defaultValue: "Others")
    }

    private func rulesGroupTitle(_ key: String, defaultValue: String) -> String {
        VelaL10n.string("rules.group.\(key)", defaultValue: defaultValue)
    }

    private var activeRulesFilterLabel: String {
        let activeFilters = [
            viewModel.typeFilter,
            viewModel.policyFilter,
            viewModel.sourceFilter,
        ].compactMap { $0 }
        if activeFilters.isEmpty {
            return VelaL10n.string("legacy.allRules", defaultValue: "All Rules")
        }
        if activeFilters.count == 1 {
            return activeFilters[0]
        }
        return VelaL10n.string(
            "rules.filter.multiple",
            defaultValue: "%lld filters",
            arguments: activeFilters.count
        )
    }

    private func rulesGroupIcon(for title: String) -> String {
        let icons = [
            rulesGroupTitle("domain", defaultValue: "Domain"): "globe",
            rulesGroupTitle("ipCIDR", defaultValue: "IP-CIDR"): "network",
            rulesGroupTitle("geoIP", defaultValue: "GeoIP"): "mappin.and.ellipse",
            rulesGroupTitle("process", defaultValue: "Process"): "macwindow",
            rulesGroupTitle("final", defaultValue: "Final"): "flag",
            rulesGroupTitle("providerRules", defaultValue: "Provider Rules"): "cloud",
        ]
        return icons[title] ?? "ellipsis"
    }

    private func rulesIcon(for row: RuntimeRuleRowModel?) -> String {
        let unavailableIcon = "questionmark"
        guard let row else { return unavailableIcon }
        return rulesIcon(for: row)
    }

    private func rulesIcon(for row: RuntimeRuleRowModel) -> String {
        let icons = [
            rulesGroupTitle("domain", defaultValue: "Domain"): "globe",
            rulesGroupTitle("ipCIDR", defaultValue: "IP-CIDR"): "network",
            rulesGroupTitle("geoIP", defaultValue: "GeoIP"): "mappin.and.ellipse",
            rulesGroupTitle("process", defaultValue: "Process"): "macwindow",
            rulesGroupTitle("final", defaultValue: "Final"): "flag",
            rulesGroupTitle("providerRules", defaultValue: "Provider Rules"): "shippingbox",
        ]
        return icons[rulesGroupIdentity(for: row.type)] ?? "doc.text"
    }

    private func rulesIconTint(for row: RuntimeRuleRowModel) -> Color {
        row.policy.caseInsensitiveCompare("DIRECT") == .orderedSame
            ? RulesLiquidTokens.blue
            : RulesLiquidTokens.mint
    }

    private func toggleInspector() {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            isInspectorPresented.toggle()
        }
    }

    private func rulesShowsStateBanner(_ phase: RulesWorkspacePhase) -> Bool {
        switch phase {
        case .refreshing, .stale, .partialFailure, .configurationApplying,
             .temporaryMutation:
            true
        case .loading, .loaded, .emptyConfiguration, .failure, .noFilterResults:
            false
        }
    }

    @ViewBuilder
    private func stateBanner(
        _ snapshot: RulesPresentationSnapshot
    ) -> some View {
        switch snapshot.phase {
        case .refreshing:
            banner(
                kind: .info,
                identifier: "rules.state.refreshing",
                title: VelaL10n.string(
                    "rules.phase.refreshing.title",
                    defaultValue: "Refreshing Runtime Rules"
                ),
                detail: snapshotAgeDetail(snapshot)
            )
        case .stale:
            banner(
                kind: .stale,
                identifier: "rules.state.stale",
                title: VelaL10n.string(
                    "rules.phase.stale.title",
                    defaultValue: "Rules Snapshot May Be Out of Date"
                ),
                detail: snapshotAgeDetail(snapshot)
            )
        case .partialFailure:
            banner(
                kind: .warning,
                identifier: "rules.state.partialFailure",
                title: VelaL10n.string(
                    "rules.phase.partialFailure.title",
                    defaultValue: "Last Confirmed Rules"
                ),
                detail: snapshot.lastError.map(errorDescription)
                    ?? VelaL10n.string(
                        "rules.phase.partialFailure.detail",
                        defaultValue: "The last confirmed runtime rules remain visible; no specific row is claimed to be affected."
                    )
            )
        case .configurationApplying:
            banner(
                kind: .info,
                identifier: "rules.state.configurationApplying",
                title: VelaL10n.string(
                    "rules.phase.configurationApplying.title",
                    defaultValue: "Applying Configuration"
                ),
                detail: VelaL10n.string(
                    "rules.phase.configurationApplying.detail",
                    defaultValue: "The committed rule generation remains visible while Vela loads the already-applied configuration."
                )
            )
        case .temporaryMutation:
            banner(
                kind: .info,
                identifier: "rules.state.temporaryMutation",
                title: temporaryMutationTitle(snapshot.pendingMutation),
                detail: VelaL10n.string(
                    "rules.phase.temporaryMutation.detail",
                    defaultValue: "The committed rule stays visible until Mihomo confirms the requested temporary state."
                )
            )
#if DEBUG
            .overlay(alignment: .topLeading) {
                if let mutation = snapshot.pendingMutation {
                    VisualSurfaceMarker(
                        identifier: "rules.pending.\(mutation.targetRuleID.originalIndex).\(mutation.phase.rawValue)",
                        label: VelaL10n.string(
                            "rules.accessibility.pendingMutation",
                            defaultValue: "Pending temporary rule target and phase"
                        )
                    )
                }
            }
#endif
        case .loading, .loaded, .emptyConfiguration, .noFilterResults, .failure:
            EmptyView()
        }
    }

    private func banner(
        kind: VelaStateBannerKind,
        identifier: String,
        title: String,
        detail: String
    ) -> some View {
        VelaStateBanner(kind: kind, title: title, detail: detail) {
            if kind == .stale || kind == .warning {
                Button(
                    VelaL10n.string("legacy.refresh", defaultValue: "Refresh"),
                    action: startRefresh
                )
                .buttonStyle(.bordered)
                .disabled(!viewModel.presentation.actions.canRefresh)
            }
        }
        .accessibilityIdentifier(identifier)
        .padding(.horizontal, VelaSpacing.standard)
        .padding(.top, VelaSpacing.medium)
        .padding(.bottom, VelaSpacing.small)
    }

    @ViewBuilder
    private func rulesToolbar(
        model: Bindable<RulesViewModel>,
        snapshot: RulesPresentationSnapshot,
        layout: RulesLayoutMetrics
    ) -> some View {
        if layout.columnSet == .compact {
            VStack(spacing: VelaSpacing.small) {
                HStack(spacing: VelaSpacing.small) {
                    countLabel(snapshot)
                    searchField(model: model, snapshot: snapshot)
                    if shouldShowToolbarRefresh(snapshot) {
                        refreshButton(snapshot)
                    }
                }
                HStack(spacing: VelaSpacing.small) {
                    typeFilter(model: model, snapshot: snapshot)
                    policyFilter(model: model, snapshot: snapshot)
                    sourceFilter(model: model, snapshot: snapshot)
                    Spacer(minLength: VelaSpacing.small)
                    workbenchButton(snapshot)
                }
            }
            .padding(.horizontal, VelaSpacing.standard)
            .padding(.vertical, VelaSpacing.small)
        } else {
            HStack(spacing: VelaSpacing.small) {
                countLabel(snapshot)
                typeFilter(model: model, snapshot: snapshot)
                policyFilter(model: model, snapshot: snapshot)
                sourceFilter(model: model, snapshot: snapshot)
                searchField(model: model, snapshot: snapshot)
                Spacer(minLength: VelaSpacing.small)
                if snapshot.hasSearchOrFilters {
                    Button(
                        VelaL10n.string(
                            "legacy.clearFilters",
                            defaultValue: "Clear Filters"
                        )
                    ) {
                        viewModel.clearFilters()
                    }
                }
                workbenchButton(snapshot)
                if shouldShowToolbarRefresh(snapshot) {
                    refreshButton(snapshot)
                }
            }
            .padding(.horizontal, VelaSpacing.standard)
            .padding(.vertical, VelaSpacing.small)
        }
    }

    private func countLabel(
        _ snapshot: RulesPresentationSnapshot
    ) -> some View {
        Text(countText(snapshot))
            .font(VelaTypography.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .accessibilityIdentifier("rules.count")
    }

    private func countText(
        _ snapshot: RulesPresentationSnapshot
    ) -> String {
        if snapshot.hasSearchOrFilters {
            return VelaL10n.string(
                "rules.count.filteredFormat",
                defaultValue: "%lld of %lld rules",
                arguments: snapshot.rows.count,
                snapshot.totalRuleCount
            )
        }
        if snapshot.phase == .stale, let age = snapshot.snapshotAge {
            return VelaL10n.string(
                "rules.count.staleFormat",
                defaultValue: "%lld rules · updated %@ ago",
                arguments: snapshot.totalRuleCount,
                compactDuration(age)
            )
        }
        return VelaL10n.string(
            "rules.count.totalFormat",
            defaultValue: "%lld rules",
            arguments: snapshot.totalRuleCount
        )
    }

    private func searchField(
        model: Bindable<RulesViewModel>,
        snapshot: RulesPresentationSnapshot
    ) -> some View {
        TextField(
            VelaL10n.string("legacy.searchRules", defaultValue: "Search rules"),
            text: model.searchText
        )
        .textFieldStyle(.roundedBorder)
        .focused($isSearchFocused)
        .frame(minWidth: 140, idealWidth: 220, maxWidth: 320)
        .disabled(!snapshot.actions.canSearchAndFilter)
        .accessibilityIdentifier("rules.search")
    }

    private func typeFilter(
        model: Bindable<RulesViewModel>,
        snapshot: RulesPresentationSnapshot
    ) -> some View {
        Picker(
            VelaL10n.string("legacy.type", defaultValue: "Type"),
            selection: model.typeFilter
        ) {
            Text(VelaL10n.string("legacy.allTypes", defaultValue: "All Types"))
                .tag(String?.none)
            ForEach(snapshot.availableTypes, id: \.self) { value in
                Text(verbatim: value).tag(Optional(value))
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .disabled(!snapshot.actions.canSearchAndFilter)
        .accessibilityIdentifier("rules.filter.type")
    }

    private func policyFilter(
        model: Bindable<RulesViewModel>,
        snapshot: RulesPresentationSnapshot
    ) -> some View {
        Picker(
            VelaL10n.string("legacy.policy", defaultValue: "Policy"),
            selection: model.policyFilter
        ) {
            Text(
                VelaL10n.string(
                    "legacy.allPolicies",
                    defaultValue: "All Policies"
                )
            )
            .tag(String?.none)
            ForEach(snapshot.availablePolicies, id: \.self) { value in
                Text(verbatim: value).tag(Optional(value))
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .disabled(!snapshot.actions.canSearchAndFilter)
        .accessibilityIdentifier("rules.filter.policy")
    }

    private func sourceFilter(
        model: Bindable<RulesViewModel>,
        snapshot: RulesPresentationSnapshot
    ) -> some View {
        Picker(
            VelaL10n.string("legacy.source", defaultValue: "Source"),
            selection: model.sourceFilter
        ) {
            Text(
                snapshot.availableSources.isEmpty
                    ? VelaL10n.string(
                        "rules.filter.source.unavailable",
                        defaultValue: "Source Unavailable"
                    )
                    : VelaL10n.string(
                        "rules.filter.source.all",
                        defaultValue: "All Sources"
                    )
            )
            .tag(String?.none)
            ForEach(snapshot.availableSources, id: \.self) { value in
                Text(verbatim: value).tag(Optional(value))
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .disabled(
            !snapshot.actions.canSearchAndFilter
                || snapshot.availableSources.isEmpty
        )
        .help(
            snapshot.availableSources.isEmpty
                ? VelaL10n.string(
                    "rules.filter.source.unavailable.help",
                    defaultValue: "The runtime rules endpoint does not expose source mapping."
                )
                : VelaL10n.string(
                    "rules.filter.source.help",
                    defaultValue: "Filter by the exact runtime rule source."
                )
        )
        .accessibilityIdentifier("rules.filter.source")
    }

    private func workbenchButton(
        _ snapshot: RulesPresentationSnapshot
    ) -> some View {
        Button {
            SettingsMainNavigationRequest.navigateInCurrentWindow(.configuration)
        } label: {
            Label(
                VelaL10n.string(
                    "rules.action.openWorkbench",
                    defaultValue: "Open in Workbench"
                ),
                systemImage: "slider.horizontal.3"
            )
        }
        .controlSize(.regular)
        .disabled(!snapshot.actions.canOpenWorkbench)
        .help(
            snapshot.actions.canOpenWorkbench
                ? VelaL10n.string(
                    "rules.action.openWorkbench.help",
                    defaultValue: "Open the exact editable source in Configuration Workbench."
                )
                : VelaL10n.string(
                    "rules.action.openWorkbench.unavailable",
                    defaultValue: "Exact source mapping is unavailable for the selected runtime rule."
                )
        )
        .accessibilityIdentifier("rules.openWorkbench")
    }

    private func refreshButton(
        _ snapshot: RulesPresentationSnapshot
    ) -> some View {
        Button(action: startRefresh) {
            if snapshot.phase == .loading || snapshot.phase == .refreshing {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(
                        VelaL10n.string(
                            "legacy.refreshingRules",
                            defaultValue: "Refreshing rules"
                        )
                    )
            } else {
                Label(
                    VelaL10n.string("legacy.refresh", defaultValue: "Refresh"),
                    systemImage: "arrow.clockwise"
                )
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .controlSize(.regular)
        .disabled(!snapshot.actions.canRefresh)
        .accessibilityIdentifier("rules.refresh")
    }

    private func shouldShowToolbarRefresh(
        _ snapshot: RulesPresentationSnapshot
    ) -> Bool {
        activeRecoveryReason == nil
            && recoveryReason(for: snapshot) == nil
    }

    private func rulesTable(
        model: Bindable<RulesViewModel>,
        snapshot: RulesPresentationSnapshot,
        layout: RulesLayoutMetrics
    ) -> some View {
        Table(snapshot.rows, selection: model.selectedRuleID) {
            TableColumn(
                VelaL10n.string("legacy.index", defaultValue: "Index")
            ) { row in
                Text(row.runtimeIndex, format: .number)
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(
                min: layout.columnSet == .compact ? 36 : 42,
                ideal: layout.columnSet == .compact ? 42 : 48
            )

            if layout.columnSet == .compact {
                TableColumn(
                    VelaL10n.string("rules.column.rule", defaultValue: "Rule")
                ) { row in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: row.type.isEmpty ? "—" : row.type)
                            .font(VelaTypography.table.weight(.medium))
                            .lineLimit(1)
                        Text(verbatim: row.payload.isEmpty ? "—" : row.payload)
                            .font(VelaTypography.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(height: RulesLayoutMetrics.tableCellContentHeight)
                    .accessibilityIdentifier("rules.row.\(row.runtimeIndex)")
                }
                .width(min: 112, ideal: 154)
            } else {
                TableColumn(
                    VelaL10n.string("legacy.type", defaultValue: "Type")
                ) { row in
                    Text(verbatim: row.type.isEmpty ? "—" : row.type)
                        .lineLimit(1)
                        .accessibilityIdentifier("rules.row.\(row.runtimeIndex)")
                }
                .width(min: 76, ideal: 92)

                TableColumn(
                    VelaL10n.string("legacy.payload", defaultValue: "Payload")
                ) { row in
                    Text(verbatim: row.payload.isEmpty ? "—" : row.payload)
                        .lineLimit(1)
                        .help(row.payload)
                }
                .width(min: 116, ideal: 168)
            }

            TableColumn(
                VelaL10n.string("legacy.policy", defaultValue: "Policy")
            ) { row in
                Text(verbatim: row.policy.isEmpty ? "—" : row.policy)
                    .lineLimit(1)
                    .help(row.policy)
            }
            .width(
                min: layout.columnSet == .compact ? 62 : 78,
                ideal: layout.columnSet == .compact ? 76 : 98
            )

            if layout.columnSet != .compact {
                TableColumn(
                    VelaL10n.string("legacy.source", defaultValue: "Source")
                ) { row in
                    Text(
                        row.provenance.sourceDisplayName
                            ?? VelaL10n.string(
                                "rules.value.unavailable",
                                defaultValue: "Unavailable"
                            )
                    )
                    .lineLimit(1)
                }
                .width(min: 80, ideal: 96)
            }

            if layout.columnSet == .spacious {
                TableColumn(
                    VelaL10n.string("rules.field.provider", defaultValue: "Provider")
                ) { row in
                    Text(
                        row.provenance.providerDisplayName
                            ?? VelaL10n.string(
                                "rules.value.unavailable",
                                defaultValue: "Unavailable"
                            )
                    )
                    .lineLimit(1)
                }
                .width(min: 80, ideal: 96)
            }

            if layout.columnSet != .compact {
                TableColumn(
                    VelaL10n.string("rules.field.matches", defaultValue: "Matches")
                ) { row in
                    if let hitCount = row.hitCount {
                        Text(verbatim: hitCount.formatted(.number))
                            .monospacedDigit()
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    } else {
                        Text(verbatim: "—")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                .width(min: 52, ideal: 60)
            }
        }
        .font(VelaTypography.table)
        .environment(\.defaultMinListRowHeight, RulesLayoutMetrics.tableRowHeight)
        .alternatingRowBackgrounds(.disabled)
        .accessibilityIdentifier("rules.table")
        .overlay {
            if snapshot.rows.isEmpty {
                rulesEmptyState(snapshot)
            }
        }
#if DEBUG
        .overlay(alignment: .topLeading) {
            VisualSurfaceMarker(
                identifier: "rules.columns.\(layout.columnSet.rawValue)",
                label: VelaL10n.string(
                    "rules.accessibility.columns",
                    defaultValue: "Responsive runtime rule columns"
                )
            )
        }
#endif
    }

    @ViewBuilder
    private func rulesEmptyState(
        _ snapshot: RulesPresentationSnapshot
    ) -> some View {
        if let reason = activeRecoveryReason ?? recoveryReason(for: snapshot) {
            recoveryEmptyState(reason: reason, snapshot: snapshot)
        } else {
            switch snapshot.phase {
            case .loading:
                VelaEmptyState(
                    title: VelaL10n.string(
                        "rules.empty.loading.title",
                        defaultValue: "Loading Rules"
                    ),
                    description: VelaL10n.string(
                        "rules.empty.loading.description",
                        defaultValue: "Fetching the current runtime rule table from Mihomo."
                    ),
                    systemImage: "arrow.clockwise"
                ) {
                    ProgressView().controlSize(.small)
                }
                .accessibilityIdentifier("rules.empty.loading")
            case .noFilterResults:
                VelaEmptyState(
                    title: VelaL10n.string(
                        "rules.empty.filtered.title",
                        defaultValue: "No Matching Rules"
                    ),
                    description: VelaL10n.string(
                        "rules.empty.filtered.description",
                        defaultValue: "No rules match the current search or filters."
                    ),
                    systemImage: "line.3.horizontal.decrease.circle"
                ) {
                    Button(
                        VelaL10n.string(
                            "legacy.clearFilters",
                            defaultValue: "Clear Filters"
                        )
                    ) {
                        viewModel.clearFilters()
                    }
                    .velaEmptyStateAction()
                    .buttonStyle(.bordered)
                }
                .accessibilityIdentifier("rules.empty.filtered")
            case .emptyConfiguration, .failure, .loaded, .refreshing, .stale,
                 .partialFailure, .configurationApplying, .temporaryMutation:
                EmptyView()
            }
        }
    }

    private func recoveryEmptyState(
        reason: RulesRecoveryReason,
        snapshot: RulesPresentationSnapshot
    ) -> some View {
        VelaEmptyState(
            title: recoveryTitle(reason),
            description: recoveryDescription(reason),
            systemImage: recoverySystemImage(reason)
        ) {
            if reason == .emptyConfiguration {
                PageRecoveryActions(
                    primaryTitle: VelaL10n.string(
                        "rules.action.openWorkbench",
                        defaultValue: "Open Workbench"
                    ),
                    pendingTitle: VelaL10n.string(
                        "rules.action.openWorkbench",
                        defaultValue: "Open Workbench"
                    ),
                    primarySystemImage: "slider.horizontal.3",
                    isPending: false,
                    isPrimaryEnabled: true,
                    primaryMinimumWidth: PageRecoveryActionMetrics.compactContentMinimumWidth,
                    primaryAccessibilityIdentifier: "rules.recovery.openWorkbench",
                    primaryAccessibilityHint: VelaL10n.string(
                        "rules.action.openWorkbench.recoveryHint",
                        defaultValue: "Open Configuration Workbench to choose or edit the active configuration."
                    ),
                    primaryAccessibilityValue: nil,
                    primaryAction: {
                        SettingsMainNavigationRequest.navigateInCurrentWindow(.configuration)
                    },
                    secondaryAction: nil
                )
            } else {
                PageRecoveryActions(
                    primaryTitle: VelaL10n.string(
                        "rules.action.reload",
                        defaultValue: "Reload Rules"
                    ),
                    pendingTitle: VelaL10n.string(
                        "rules.action.reloading",
                        defaultValue: "Reloading…"
                    ),
                    primarySystemImage: "arrow.clockwise",
                    isPending: activeRecoveryReason != nil,
                    isPrimaryEnabled: canReloadRules(reason, snapshot: snapshot),
                    primaryMinimumWidth: PageRecoveryActionMetrics.compactContentMinimumWidth,
                    primaryAccessibilityIdentifier: "rules.recovery.reload",
                    primaryAccessibilityHint: reloadHint(reason),
                    primaryAccessibilityValue: reloadAttemptAccessibilityValue,
                    primaryAction: startRefresh,
                    secondaryAction: PageRecoveryActions.SecondaryAction(
                        title: VelaL10n.string(
                            "legacy.openDiagnostics",
                            defaultValue: "Open Diagnostics"
                        ),
                        systemImage: "chevron.right",
                        accessibilityIdentifier: "rules.recovery.openDiagnostics",
                        accessibilityHint: VelaL10n.string(
                            "rules.action.openDiagnostics.hint",
                            defaultValue: "Open guided checks for Mihomo and its Controller."
                        ),
                        action: {
                            SettingsMainNavigationRequest.navigateInCurrentWindow(.diagnostics)
                        }
                    )
                )
            }
        }
        .accessibilityIdentifier("rules.empty.recovery.\(reason.rawValue)")
    }

    @ViewBuilder
    private func ruleInspector(
        snapshot: RulesPresentationSnapshot
    ) -> some View {
        if let inspector = snapshot.inspector {
            RuntimeRuleInspectorView(
                inspector: inspector,
                workspacePhase: snapshot.phase,
                actions: snapshot.actions,
                toggleTemporaryState: { requestedDisabled in
                    Task {
                        await viewModel.setDisabled(
                            requestedDisabled,
                            rule: inspector.row.rule
                        )
                    }
                },
                openWorkbench: {
                    SettingsMainNavigationRequest.navigateInCurrentWindow(.configuration)
                },
                openProvider: {
                    SettingsMainNavigationRequest.navigateInCurrentWindow(.providers)
                }
            )
        } else {
            VelaEmptyState(
                title: inspectorEmptyTitle(snapshot.phase),
                description: inspectorEmptyDetail(snapshot.phase),
                systemImage: "sidebar.right"
            )
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity,
                alignment: .center
            )
#if DEBUG
            .overlay {
                VisualSurfaceMarker(
                    identifier: "rules.inspector.empty.center",
                    label: VelaL10n.string(
                        "rules.inspector.empty.center.debugLabel",
                        defaultValue: "Empty rule inspector center"
                    )
                )
            }
#endif
            .background(VelaAppearance.controlBackground)
        }
    }

    private func inspectorEmptyTitle(
        _ phase: RulesWorkspacePhase
    ) -> String {
        switch phase {
        case .loading:
            VelaL10n.string(
                "rules.empty.loading.title",
                defaultValue: "Loading Rules"
            )
        case .emptyConfiguration:
            VelaL10n.string(
                "rules.empty.configuration.title",
                defaultValue: "No Runtime Rules"
            )
        case .noFilterResults:
            VelaL10n.string(
                "rules.empty.filtered.title",
                defaultValue: "No Matching Rules"
            )
        case .failure:
            VelaL10n.string(
                "rules.inspector.failure.title",
                defaultValue: "No Current Rule Snapshot"
            )
        case .loaded, .refreshing, .stale, .partialFailure,
             .configurationApplying, .temporaryMutation:
            VelaL10n.string(
                "rules.inspector.empty.title",
                defaultValue: "Rule Details"
            )
        }
    }

    private func inspectorEmptyDetail(
        _ phase: RulesWorkspacePhase
    ) -> String {
        switch phase {
        case .loading:
            VelaL10n.string(
                "rules.inspector.loading.detail",
                defaultValue: "Rule details will become available after the runtime snapshot loads."
            )
        case .emptyConfiguration:
            VelaL10n.string(
                "rules.inspector.emptyConfiguration.detail",
                defaultValue: "The active configuration has no runtime rule to inspect."
            )
        case .noFilterResults:
            VelaL10n.string(
                "rules.inspector.noFilterResults.detail",
                defaultValue: "Clear the current search or filters to select a rule."
            )
        case .failure:
            VelaL10n.string(
                "rules.inspector.failure.detail",
                defaultValue: "Retry the runtime snapshot before inspecting source or match evidence."
            )
        case .loaded, .refreshing, .stale, .partialFailure,
             .configurationApplying, .temporaryMutation:
            VelaL10n.string(
                "rules.inspector.empty.selection.description",
                defaultValue: "Select a rule to inspect its source and routing evidence."
            )
        }
    }

    private func recoveryReason(
        for snapshot: RulesPresentationSnapshot
    ) -> RulesRecoveryReason? {
        RulesRecoveryReason.resolve(
            phase: snapshot.phase,
            availability: runtimeAvailability
        )
    }

    private func recoveryTitle(_ reason: RulesRecoveryReason) -> String {
        switch reason {
        case .mihomoStopped:
            VelaL10n.string(
                "rules.recovery.mihomoStopped.title",
                defaultValue: "Mihomo Is Stopped"
            )
        case .controllerDisconnected:
            VelaL10n.string(
                "rules.recovery.controllerDisconnected.title",
                defaultValue: "Controller Disconnected"
            )
        case .ruleFetchFailed:
            VelaL10n.string(
                "rules.recovery.ruleFetchFailed.title",
                defaultValue: "Rules Couldn’t Be Loaded"
            )
        case .emptyConfiguration:
            VelaL10n.string(
                "rules.empty.configuration.title",
                defaultValue: "No Runtime Rules"
            )
        }
    }

    private func recoveryDescription(_ reason: RulesRecoveryReason) -> String {
        switch reason {
        case .mihomoStopped:
            VelaL10n.string(
                "rules.recovery.mihomoStopped.description",
                defaultValue: "Mihomo is not running, so Vela cannot read runtime rules. Start Mihomo, then reload the rule table."
            )
        case .controllerDisconnected:
            VelaL10n.string(
                "rules.recovery.controllerDisconnected.description",
                defaultValue: "Mihomo is running, but its Controller is disconnected. Restore the Controller connection, then reload the rule table."
            )
        case .ruleFetchFailed:
            VelaL10n.string(
                "rules.recovery.ruleFetchFailed.description",
                defaultValue: "The Controller is reachable, but it did not return a usable rule snapshot. Reload the rules or open Diagnostics for details."
            )
        case .emptyConfiguration:
            VelaL10n.string(
                "rules.recovery.emptyConfiguration.description",
                defaultValue: "No configuration is selected, or the active configuration produces no runtime rules. Open Configuration Workbench to choose or edit it."
            )
        }
    }

    private func recoverySystemImage(_ reason: RulesRecoveryReason) -> String {
        let systemImage: String
        switch reason {
        case .mihomoStopped:
            systemImage = "stop.circle"
        case .controllerDisconnected:
            systemImage = "network.slash"
        case .ruleFetchFailed:
            systemImage = "exclamationmark.triangle"
        case .emptyConfiguration:
            systemImage = "list.bullet.rectangle"
        }
        return systemImage
    }

    private func canReloadRules(
        _ reason: RulesRecoveryReason,
        snapshot: RulesPresentationSnapshot
    ) -> Bool {
        reason != .mihomoStopped
            && activeRecoveryReason == nil
            && snapshot.actions.canRefresh
    }

    private func reloadHint(_ reason: RulesRecoveryReason) -> String {
        if activeRecoveryReason != nil {
            return VelaL10n.string(
                "rules.action.reload.pendingHint",
                defaultValue: "A rule reload request is already in progress."
            )
        }
        if reason == .mihomoStopped {
            return VelaL10n.string(
                "rules.action.reload.mihomoStoppedHint",
                defaultValue: "Start Mihomo before reloading runtime rules."
            )
        }
        return VelaL10n.string(
            "rules.action.reload.hint",
            defaultValue: "Request the current runtime rule snapshot from the Controller."
        )
    }

    private var reloadAttemptAccessibilityValue: String? {
#if DEBUG
        reloadAttemptCount.formatted()
#else
        nil
#endif
    }

    private func startRefresh() {
        let snapshot = viewModel.presentation
        guard refreshTask == nil,
              snapshot.actions.canRefresh
        else { return }

        let reason = recoveryReason(for: snapshot)
        if reason == .mihomoStopped { return }

        activeRecoveryReason = reason
#if DEBUG
        if reason != nil { reloadAttemptCount += 1 }
#endif
        refreshTask = Task { @MainActor in
            let minimumFeedback = reason == nil
                ? nil
                : Task { try? await Task.sleep(for: .milliseconds(750)) }
            await viewModel.refresh()
            await minimumFeedback?.value
            guard !Task.isCancelled else { return }
            activeRecoveryReason = nil
            refreshTask = nil
        }
    }

    private func snapshotAgeDetail(
        _ snapshot: RulesPresentationSnapshot
    ) -> String {
        guard let age = snapshot.snapshotAge else {
            return VelaL10n.string(
                "rules.snapshotAge.unavailable",
                defaultValue: "The last successful refresh time is unavailable."
            )
        }
        return VelaL10n.string(
            "rules.snapshotAge.detailFormat",
            defaultValue: "Showing the committed generation last refreshed %@ ago.",
            arguments: compactDuration(age)
        )
    }

    private func compactDuration(
        _ interval: TimeInterval
    ) -> String {
        let seconds = max(0, Int(interval.rounded()))
        if seconds < 60 {
            return VelaL10n.string(
                "rules.duration.secondsFormat",
                defaultValue: "%llds",
                arguments: seconds
            )
        }
        return VelaL10n.string(
            "rules.duration.minutesFormat",
            defaultValue: "%lldm",
            arguments: seconds / 60
        )
    }

    private func temporaryMutationTitle(
        _ mutation: PendingRuleMutation?
    ) -> String {
        guard let mutation else {
            return VelaL10n.string(
                "rules.phase.temporaryMutation.title",
                defaultValue: "Applying Temporary Rule Change"
            )
        }
        return VelaL10n.string(
            "rules.phase.temporaryMutation.targetFormat",
            defaultValue: "Rule #%lld · %@",
            arguments: mutation.targetRuleID.originalIndex,
            mutation.phase.localizedLabel
        )
    }

    private func errorDescription(
        _ error: RulesFailure
    ) -> String {
        switch error {
        case .fetchFailed:
            VelaL10n.string(
                "rules.error.fetchFailed",
                defaultValue: "Mihomo did not return the current rule list."
            )
        case .toggleUnsupported:
            VelaL10n.string(
                "rules.error.toggleUnsupported",
                defaultValue: "This rule does not support temporary runtime toggling."
            )
        case .toggleFailed:
            VelaL10n.string(
                "rules.error.toggleFailed",
                defaultValue: "Mihomo did not confirm the temporary rule change."
            )
        case .configurationGenerationChanged:
            VelaL10n.string(
                "rules.error.configurationGenerationChanged",
                defaultValue: "The configuration changed during the operation; the committed rules remain visible."
            )
        case .ruleNotFound:
            VelaL10n.string(
                "rules.error.ruleNotFound",
                defaultValue: "The selected rule no longer exists in the current configuration."
            )
        case .operationAlreadyRunning:
            VelaL10n.string(
                "rules.error.operationAlreadyRunning",
                defaultValue: "A temporary change for this rule is already in progress."
            )
        }
    }
}

private struct RuntimeRuleInspectorView: View {
    let inspector: RuleInspectorSnapshot
    let workspacePhase: RulesWorkspacePhase
    let actions: RulesActionAvailability
    let toggleTemporaryState: (Bool) -> Void
    let openWorkbench: () -> Void
    let openProvider: () -> Void

    private var row: RuntimeRuleRowModel { inspector.row }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ruleInformation
                    provenance
                    matchEvidence
                    actionsSection
                }
                .padding(.horizontal, VelaSpacing.standard)
                .padding(.bottom, VelaSpacing.standard)
                .textSelection(.enabled)
            }
            .accessibilityIdentifier("rules.inspector.scroll")
        }
        .background(VelaAppearance.controlBackground)
#if DEBUG
        .overlay(alignment: .topLeading) {
            VisualSurfaceMarker(
                identifier: "rules.inspector.selected",
                label: VelaL10n.string(
                    "rules.accessibility.selectedInspector",
                    defaultValue: "Selected runtime rule inspector"
                )
            )
        }
#endif
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: VelaSpacing.micro) {
            Text(
                VelaL10n.string(
                    "rules.inspector.headerFormat",
                    defaultValue: "#%lld %@",
                    arguments: row.runtimeIndex,
                    row.type.isEmpty ? "—" : row.type
                )
            )
            .font(VelaTypography.sectionTitle)
            Text(verbatim: "\(row.payload.isEmpty ? "—" : row.payload) → \(row.policy.isEmpty ? "—" : row.policy)")
                .font(VelaTypography.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, VelaSpacing.medium)
        .padding(.vertical, VelaSpacing.small)
    }

    private var ruleInformation: some View {
        VelaInspectorSection(
            title: VelaL10n.string(
                "rules.inspector.information.title",
                defaultValue: "Rule Information"
            ),
            subtitle: VelaL10n.string(
                "rules.inspector.information.subtitle",
                defaultValue: "Runtime order and expression"
            )
        ) {
            LabeledContent(
                VelaL10n.string("rules.field.runtimeIndex", defaultValue: "Runtime Index"),
                value: String(row.runtimeIndex)
            )
            LabeledContent(
                VelaL10n.string("legacy.type", defaultValue: "Type"),
                value: row.type.isEmpty ? "—" : row.type
            )
            LabeledContent(
                VelaL10n.string("legacy.payload", defaultValue: "Payload"),
                value: row.payload.isEmpty ? "—" : row.payload
            )
            LabeledContent(
                VelaL10n.string("legacy.policy", defaultValue: "Policy"),
                value: row.policy.isEmpty ? "—" : row.policy
            )
            LabeledContent(
                VelaL10n.string("rules.field.rawRule", defaultValue: "Raw Rule"),
                value: row.rawRule.isEmpty ? "—" : row.rawRule
            )
            LabeledContent(
                VelaL10n.string(
                    "legacy.configurationGeneration",
                    defaultValue: "Configuration Generation"
                ),
                value: generationText
            )
            if inspector.isFinalFallback {
                VelaStateBanner(
                    kind: .info,
                    title: VelaL10n.string(
                        "rules.inspector.fallback.title",
                        defaultValue: "Final Fallback Rule"
                    ),
                    detail: VelaL10n.string(
                        "rules.inspector.fallback.detail",
                        defaultValue: "This MATCH rule is evaluated after every earlier runtime rule."
                    )
                )
            }
        }
    }

    private var provenance: some View {
        VelaInspectorSection(
            title: VelaL10n.string(
                "rules.inspector.provenance.title",
                defaultValue: "Source and Provenance"
            ),
            subtitle: VelaL10n.string(
                "rules.inspector.provenance.subtitle",
                defaultValue: "Runtime source evidence"
            )
        ) {
            VelaStatusPill(
                status: inspector.confidence.semanticStatus,
                label: inspector.confidence.localizedLabel
            )
            LabeledContent(
                VelaL10n.string("rules.field.sourceLayer", defaultValue: "Source Layer"),
                value: row.provenance.sourceLayer.localizedLabel
            )
            LabeledContent(
                VelaL10n.string("legacy.source", defaultValue: "Source"),
                value: row.provenance.sourceDisplayName
                    ?? VelaL10n.string(
                        "rules.value.unavailable",
                        defaultValue: "Unavailable"
                    )
            )
            LabeledContent(
                VelaL10n.string("rules.field.sourcePointer", defaultValue: "Source Pointer"),
                value: row.provenance.sourcePointer
                    ?? VelaL10n.string(
                        "rules.value.unavailable",
                        defaultValue: "Unavailable"
                    )
            )
            LabeledContent(
                VelaL10n.string("rules.field.provider", defaultValue: "Provider"),
                value: row.provenance.providerDisplayName
                    ?? VelaL10n.string(
                        "rules.value.unavailable",
                        defaultValue: "Unavailable"
                    )
            )
            if inspector.confidence == .unavailable {
                Text(
                    VelaL10n.string(
                        "rules.inspector.provenance.unavailable.detail",
                        defaultValue: "Mihomo's runtime rules response does not expose source-layer or provider provenance. Vela does not infer it from display values."
                    )
                )
                .font(VelaTypography.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var matchEvidence: some View {
        VelaInspectorSection(
            title: VelaL10n.string(
                "rules.inspector.matches.title",
                defaultValue: "Match Evidence"
            ),
            subtitle: VelaL10n.string(
                "rules.inspector.matches.subtitle",
                defaultValue: "Current runtime counters"
            )
        ) {
            LabeledContent(
                VelaL10n.string("rules.field.matches", defaultValue: "Matches"),
                value: row.hitCount.map(String.init)
                    ?? VelaL10n.string(
                        "rules.value.unavailable",
                        defaultValue: "Unavailable"
                    )
            )
            LabeledContent(
                VelaL10n.string("rules.field.lastMatched", defaultValue: "Last Matched"),
                value: row.lastMatchedAt?.formatted()
                    ?? VelaL10n.string(
                        "rules.value.unavailable",
                        defaultValue: "Unavailable"
                    )
            )
            LabeledContent(
                VelaL10n.string(
                    "rules.field.evidenceGeneration",
                    defaultValue: "Evidence Generation"
                ),
                value: evidenceGenerationText
            )
            LabeledContent(
                VelaL10n.string("rules.field.providerStatus", defaultValue: "Provider Status"),
                value: row.provenance.providerStatus
                    ?? VelaL10n.string(
                        "rules.value.unavailable",
                        defaultValue: "Unavailable"
                    )
            )
        }
    }

    private var actionsSection: some View {
        VelaInspectorSection(
            title: VelaL10n.string(
                "rules.inspector.actions.title",
                defaultValue: "Actions"
            ),
            subtitle: VelaL10n.string(
                "rules.inspector.actions.subtitle",
                defaultValue: "Copy, navigate, or apply a verified temporary state"
            ),
            showsDivider: false
        ) {
            if let pending = inspector.pendingMutation {
                VelaStateBanner(
                    kind: .warning,
                    title: VelaL10n.string(
                        "rules.inspector.pending.title",
                        defaultValue: "Temporary Change in Progress"
                    ),
                    detail: VelaL10n.string(
                        "rules.inspector.pending.detailFormat",
                        defaultValue: "Current: %@ · Requested: %@ · Phase: %@",
                        arguments: temporaryStateLabel(pending.currentDisabled),
                        temporaryStateLabel(pending.requestedDisabled),
                        pending.phase.localizedLabel
                    )
                )
            }

            Button {
                copy(row.rawRule)
            } label: {
                Label(
                    VelaL10n.string(
                        "rules.action.copyRule",
                        defaultValue: "Copy Rule"
                    ),
                    systemImage: "doc.on.doc"
                )
            }
            .accessibilityIdentifier("rules.inspector.copyRule")

            Button {
                copy(redactedSummary)
            } label: {
                Label(
                    VelaL10n.string(
                        "rules.action.copyRedacted",
                        defaultValue: "Copy Redacted Technical Summary"
                    ),
                    systemImage: "doc.on.clipboard"
                )
            }
            .accessibilityIdentifier("rules.inspector.copyRedacted")

            Button(action: openWorkbench) {
                Label(
                    VelaL10n.string(
                        "rules.action.openWorkbench",
                        defaultValue: "Open in Workbench"
                    ),
                    systemImage: "slider.horizontal.3"
                )
            }
            .disabled(!actions.canOpenWorkbench)
            .help(
                actions.canOpenWorkbench
                    ? VelaL10n.string(
                        "rules.action.openWorkbench.help",
                        defaultValue: "Open the exact editable source in Configuration Workbench."
                    )
                    : VelaL10n.string(
                        "rules.action.openWorkbench.unavailable",
                        defaultValue: "Exact source mapping is unavailable for this runtime rule."
                    )
            )
            .accessibilityIdentifier("rules.inspector.openWorkbench")

            Button(action: openProvider) {
                Label(
                    VelaL10n.string(
                        "rules.action.openProvider",
                        defaultValue: "Open Provider"
                    ),
                    systemImage: "shippingbox"
                )
            }
            .disabled(!actions.canOpenProvider)
            .accessibilityIdentifier("rules.inspector.openProvider")

            if let disabled = row.isTemporarilyDisabled {
                Divider()
                LabeledContent(
                    VelaL10n.string(
                        "rules.inspector.temporary.current",
                        defaultValue: "Current Temporary State"
                    ),
                    value: temporaryStateLabel(disabled)
                )
                Text(
                    VelaL10n.string(
                        "rules.inspector.temporary.resetWarning",
                        defaultValue: "Temporary — resets when the configuration reloads."
                    )
                )
                .font(VelaTypography.caption)
                .foregroundStyle(.secondary)
                Button {
                    toggleTemporaryState(!disabled)
                } label: {
                    Label(
                        disabled
                            ? VelaL10n.string(
                                "legacy.enableTemporarily",
                                defaultValue: "Enable Temporarily"
                            )
                            : VelaL10n.string(
                                "legacy.disableTemporarily",
                                defaultValue: "Disable Temporarily"
                            ),
                        systemImage: disabled ? "play" : "pause"
                    )
                }
                .buttonStyle(.bordered)
                .disabled(!actions.canToggleTemporaryState)
                .accessibilityIdentifier("rules.inspector.toggleTemporary")
            }
        }
    }

    private var generationText: String {
        String(row.id.configurationGeneration.id.uuidString.prefix(8))
    }

    private var evidenceGenerationText: String {
        guard let id = row.provenance.evidenceGenerationID else {
            return VelaL10n.string(
                "rules.value.unavailable",
                defaultValue: "Unavailable"
            )
        }
        return String(id.uuidString.prefix(8))
    }

    private var redactedSummary: String {
        [
            "runtimeIndex=\(row.runtimeIndex)",
            "type=\(row.type)",
            "generation=\(generationText)",
            "sourceConfidence=\(inspector.confidence.rawValue)",
            "hasMatchEvidence=\(row.hitCount != nil)",
        ].joined(separator: "\n")
    }

    private func temporaryStateLabel(
        _ disabled: Bool
    ) -> String {
        disabled
            ? VelaL10n.string("rules.status.disabled", defaultValue: "Disabled")
            : VelaL10n.string("rules.status.enabled", defaultValue: "Enabled")
    }

    private func copy(
        _ value: String
    ) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }
}

private extension RuleSourceLayer {
    var localizedLabel: String {
        switch self {
        case .upstream:
            VelaL10n.string("rules.source.upstream", defaultValue: "Upstream")
        case .global:
            VelaL10n.string("rules.source.global", defaultValue: "Global")
        case .configuration:
            VelaL10n.string(
                "rules.source.configuration",
                defaultValue: "Configuration"
            )
        case .scene:
            VelaL10n.string("rules.source.scene", defaultValue: "Scene")
        case .runtimeForced:
            VelaL10n.string(
                "rules.source.runtimeForced",
                defaultValue: "Runtime Forced"
            )
        case .builtIn:
            VelaL10n.string("rules.source.builtIn", defaultValue: "Built-in")
        case .provider:
            VelaL10n.string("rules.source.provider", defaultValue: "Provider")
        case .unavailable:
            VelaL10n.string(
                "rules.value.unavailable",
                defaultValue: "Unavailable"
            )
        }
    }
}

private extension RuleSourceConfidence {
    var localizedLabel: String {
        switch self {
        case .exact:
            VelaL10n.string("rules.confidence.exact", defaultValue: "Exact Source")
        case .ambiguous:
            VelaL10n.string(
                "rules.confidence.ambiguous",
                defaultValue: "Ambiguous Source"
            )
        case .unavailable:
            VelaL10n.string(
                "rules.confidence.unavailable",
                defaultValue: "Source Unavailable"
            )
        case .stale:
            VelaL10n.string(
                "rules.confidence.stale",
                defaultValue: "Stale Source Evidence"
            )
        }
    }

    var semanticStatus: VelaSemanticStatus {
        switch self {
        case .exact:
            .success
        case .ambiguous:
            .warning
        case .unavailable:
            .neutral
        case .stale:
            .stale
        }
    }
}

private extension RuleMutationPhase {
    var localizedLabel: String {
        switch self {
        case .preparing:
            VelaL10n.string(
                "rules.mutation.preparing",
                defaultValue: "Preparing"
            )
        case .applying:
            VelaL10n.string(
                "rules.mutation.applying",
                defaultValue: "Applying"
            )
        case .verifying:
            VelaL10n.string(
                "rules.mutation.verifying",
                defaultValue: "Verifying"
            )
        case .rollingBack:
            VelaL10n.string(
                "rules.mutation.rollingBack",
                defaultValue: "Rolling Back"
            )
        }
    }
}

private struct RulesVisualGroup: Identifiable {
    var id: String { title }

    let title: String
    let filterValues: [String]
    let count: Int
    let hitCount: UInt64?
    let systemImage: String
    let order: Int
    let isPrimary: Bool
}

private struct RulesRouteConnector: View {
    let tint: Color

    var body: some View {
        HStack(spacing: 0) {
            Circle()
                .fill(tint)
                .frame(width: 5, height: 5)
            Rectangle()
                .fill(tint)
                .frame(height: 1)
            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity)
    }
}

private enum RulesLiquidTokens {
    static let textPrimary = Color(red: 22 / 255, green: 28 / 255, blue: 35 / 255)
    static let textSecondary = Color(red: 93 / 255, green: 107 / 255, blue: 124 / 255)
    static let mint = Color(red: 38 / 255, green: 194 / 255, blue: 145 / 255)
    static let blue = Color(red: 38 / 255, green: 139 / 255, blue: 1)
    static let violet = Color(red: 139 / 255, green: 87 / 255, blue: 1)
    static let danger = Color(red: 229 / 255, green: 69 / 255, blue: 76 / 255)
    static let divider = Color(red: 116 / 255, green: 138 / 255, blue: 158 / 255).opacity(0.16)
    static let selectedFill = Color(red: 220 / 255, green: 244 / 255, blue: 237 / 255).opacity(0.56)
    static let codeFill = Color(red: 116 / 255, green: 138 / 255, blue: 158 / 255).opacity(0.07)
}

private struct RulesLiquidSurfaceModifier: ViewModifier {
    let radius: CGFloat
    let emphasized: Bool

    func body(content: Content) -> some View {
        content.velaWorkspaceGlassSurface(
            radius: radius,
            emphasized: emphasized
        )
    }
}

private extension View {
    func rulesLiquidSurface(
        radius: CGFloat,
        emphasized: Bool = false
    ) -> some View {
        modifier(
            RulesLiquidSurfaceModifier(
                radius: radius,
                emphasized: emphasized
            )
        )
    }
}
