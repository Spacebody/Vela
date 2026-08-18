import SwiftUI

nonisolated enum ProxyGroupFilter {
    case all
    case needsAttention
}

nonisolated enum ProxyGroupSort {
    case configuration
    case name
}

nonisolated enum ProxyGroupListPresentation {
    static func rows(
        from rows: [ProxiesGroupRowSnapshot],
        groups: [ProxiesGroupID: ProxiesGroupInspectorSnapshot],
        searchText: String,
        filter: ProxyGroupFilter,
        sort: ProxyGroupSort
    ) -> [ProxiesGroupRowSnapshot] {
        var result = rows

        if filter == .needsAttention {
            result = result.filter { row in
                row.isPending
                    || row.semanticStatus == .warning
                    || row.semanticStatus == .error
                    || row.semanticStatus == .permission
            }
        }

        if !searchText.isEmpty {
            result = result.filter { row in
                row.name.localizedCaseInsensitiveContains(searchText)
                    || row.currentProxy?.localizedCaseInsensitiveContains(searchText) == true
                    || groups[row.id]?.candidates.contains(where: {
                        $0.name.localizedCaseInsensitiveContains(searchText)
                            || $0.type?.localizedCaseInsensitiveContains(searchText) == true
                    }) == true
            }
        }

        if sort == .name {
            result.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        return result
    }
}

nonisolated enum ProxiesRoutePreviewPolicy {
    static func isActive(
        isTrafficConnected: Bool,
        hasSelectedCandidate: Bool
    ) -> Bool {
        isTrafficConnected && hasSelectedCandidate
    }
}

/// The Proxies V2 workspace. This view deliberately consumes the existing
/// presentation snapshot and command closure so visual reconstruction does not
/// create a second source of truth for Mihomo state.
struct ProxiesLiquidGlassDashboardView: View {
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    let snapshot: ProxiesPresentationSnapshot
    let runtimeMode: MihomoMode?
    let isTrafficConnected: Bool
    @Binding var selectedGroupID: ProxiesGroupID?
    @Binding var showsInspector: Bool
    let action: @MainActor (ProxiesDashboardAction) -> Void

    @AppStorage("vela.proxies.favoriteNodeKeys")
    private var favoriteNodeKeys = ""

    @State private var searchText = ""
    @State private var selectedCandidateID: ProxyCatalogID?
    @State private var groupFilter: ProxyGroupFilter = .all
    @State private var groupSort: ProxyGroupSort = .configuration
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        GeometryReader { proxy in
            let metrics = ProxiesLiquidLayoutMetrics.resolve(
                width: proxy.size.width,
                height: proxy.size.height
            )

            VStack(spacing: metrics.sectionSpacing) {
                header(metrics: metrics)
                currentRouteCard(metrics: metrics)
                    .padding(
                        .trailing,
                        showsInspector && shouldShowWorkspace
                            ? metrics.inspectorWidth + metrics.columnSpacing
                            : 0
                    )
                workspace(metrics: metrics)
                routePreview(metrics: metrics)
            }
            .padding(.horizontal, metrics.pagePadding)
            .padding(.top, metrics.topPadding)
            .padding(.bottom, metrics.bottomPadding)
            .frame(
                width: proxy.size.width,
                height: proxy.size.height,
                alignment: .topLeading
            )
            .background(VelaPageCanvas())
        }
        .task(id: selectionGeneration) {
            selectedGroupID = resolvedGroupID
            resolveCandidateSelection()
        }
        .onChange(of: selectedGroupID) {
            resolveCandidateSelection()
        }
        .onChange(of: searchText) {
            resolveCandidateSelection()
        }
        .onReceive(NotificationCenter.default.publisher(for: .velaFocusSearch)) { _ in
            isSearchFocused = true
        }
        .textSelection(.enabled)
        .accessibilityIdentifier("proxies.liquidGlass.page")
        // This V2 workspace is a light Liquid Glass surface. Without an
        // explicit local scheme, native materials resolve as dark glass on a
        // Dark Mode desktop while the custom canvas remains light.
        .environment(\.colorScheme, .light)
    }

    private var strings: ProxiesLiquidStrings {
        ProxiesLiquidStrings(locale: locale)
    }

    private var actionIconColor: Color {
        colorSchemeContrast == .increased
            ? ProxiesActionPalette.highContrastIconMint
            : ProxiesActionPalette.iconMint
    }

    private func header(metrics: ProxiesLiquidLayoutMetrics) -> some View {
        let canTestAll = snapshot.actions.canTestGroup && !snapshot.rows.isEmpty

        return HStack(spacing: 16) {
            Text(strings.title)
                .font(VelaTypography.mainPageTitle)
                .foregroundStyle(.primary)

            Spacer(minLength: 24)

            VelaLiquidGlassGroup(spacing: 8) {
                HStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField(strings.searchPrompt, text: $searchText)
                            .textFieldStyle(.plain)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                            .focused($isSearchFocused)
                            .accessibilityIdentifier("proxies.search")
                    }
                    .padding(.horizontal, 14)
                    .frame(width: metrics.searchWidth, height: 40)
                    .proxiesGlassSurface(radius: 14, shadow: .soft)

                    Button {
                        action(
                            .testGroups(
                                snapshot.rows.compactMap { group in
                                    group.isPending ? nil : group.id
                                }
                            )
                        )
                    } label: {
                        Label {
                            Text(strings.testAll)
                                .foregroundStyle(Color.primary.opacity(0.90))
                        } icon: {
                            Image(systemName: "gauge.with.dots.needle.67percent")
                                .foregroundStyle(actionIconColor)
                        }
                    }
                    .buttonStyle(
                        ProxiesSecondaryActionButtonStyle(
                            height: 40,
                            horizontalPadding: 14,
                            minimumWidth: 110
                        )
                    )
                    .disabled(!canTestAll)
                    .help(strings.testAllHelp)
                    .accessibilityIdentifier("proxies.testAll")

                    Menu {
                        Button {
                            action(.refresh)
                        } label: {
                            Label(strings.refresh, systemImage: "arrow.clockwise")
                        }
                        .disabled(!snapshot.actions.canRefresh)

                        Divider()

                        Button {
                            showsInspector.toggle()
                        } label: {
                            Label(
                                showsInspector ? strings.hideDetails : strings.showDetails,
                                systemImage: "sidebar.right"
                            )
                        }

                        if snapshot.actions.showsDiagnostics {
                            Button {
                                action(.openDiagnostics)
                            } label: {
                                Label(strings.openDiagnostics, systemImage: "stethoscope")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(width: 24, height: 24)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(width: 42, height: 40)
                    .proxiesGlassSurface(radius: 14, shadow: .soft)
                    .accessibilityLabel(strings.moreActions)
                }
            }
        }
        .controlSize(.regular)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("proxies.header")
    }

    private func currentRouteCard(metrics: ProxiesLiquidLayoutMetrics) -> some View {
        let hasActiveRoute = runtimeMode != nil && selectedGroup != nil

        return GeometryReader { proxy in
            let dividerWidth: CGFloat = 1
            let columnUnits: CGFloat = hasActiveRoute ? 4 : 3
            let unitWidth = max(
                0,
                (proxy.size.width - dividerWidth * 2) / columnUnits
            )
            let nodeWidth = unitWidth * (hasActiveRoute ? 2 : 1)

            VStack(alignment: .leading, spacing: 0) {
                Text(strings.currentRoute)
                    .font(.system(size: VelaTypeSize.table, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 18)
                    .frame(height: 25)

                HStack(spacing: 0) {
                    routeSummaryColumn(
                        title: strings.ruleMode,
                        value: runtimeMode?.displayName ?? strings.unavailable,
                        tint: runtimeMode == nil ? .secondary : .green
                    )
                    .frame(width: unitWidth)

                    Divider()
                        .frame(width: dividerWidth)
                        .padding(.vertical, 4)

                    routeSummaryColumn(
                        title: strings.proxyGroup,
                        value: selectedGroup?.name ?? strings.unavailable,
                        tint: selectedGroup == nil ? .secondary : .green
                    )
                    .frame(width: unitWidth)

                    Divider()
                        .frame(width: dividerWidth)
                        .padding(.vertical, 4)

                    HStack(spacing: 12) {
                        nodeGlyph(for: selectedCandidate)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(strings.currentNode)
                                .font(.system(size: VelaTypeSize.table, weight: .medium))
                                .foregroundStyle(.secondary)
                            Text(
                                selectedCandidate?.name
                                    ?? selectedGroup?.currentProxy
                                    ?? strings.unavailable
                            )
                            .font(.system(size: 17, weight: .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.78)
                        }
                        .layoutPriority(1)

                        Spacer(minLength: 4)

                        latencyBadge(selectedCandidate?.latency ?? selectedGroup?.currentLatency)
                        signalBars(
                            state: selectedCandidate?.latency.state
                                ?? selectedGroup?.currentLatency.state
                                ?? .unknown
                        )
                    }
                    .padding(.horizontal, 16)
                    .frame(width: nodeWidth, alignment: .leading)
                }
                .frame(maxHeight: .infinity)
            }
        }
        .frame(height: metrics.currentRouteHeight)
        .proxiesGlassSurface(radius: 18, shadow: .soft)
        .accessibilityIdentifier("proxies.currentRoute")
    }

    private func routeSummaryColumn(
        title: String,
        value: String,
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: VelaTypeSize.table, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
        .frame(maxWidth: 210, alignment: .leading)
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private func workspace(metrics: ProxiesLiquidLayoutMetrics) -> some View {
        if shouldShowWorkspace {
            HStack(alignment: .top, spacing: metrics.columnSpacing) {
                proxyGroupsPane
                    .frame(width: metrics.groupPaneWidth)

                nodesPane(metrics: metrics)
                    .frame(maxWidth: .infinity)

                if showsInspector {
                    inspectorPane
                        .frame(width: metrics.inspectorWidth)
                }
            }
            .frame(height: metrics.workspaceHeight, alignment: .top)
        } else {
            recoveryState
                .frame(height: metrics.workspaceHeight)
        }
    }

    private var proxyGroupsPane: some View {
        VStack(spacing: 0) {
            paneHeader(
                title: strings.proxyGroups,
                trailing: AnyView(
                    Button {
                        action(.refresh)
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    .disabled(!snapshot.actions.canRefresh)
                    .help(strings.refresh)
                )
            )

            Divider()

            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(filteredRows) { row in
                        groupRow(row)
                    }
                }
                .padding(6)
            }

            Divider()

            HStack {
                Menu {
                    Button {
                        groupFilter = .all
                    } label: {
                        Label(
                            VelaL10n.string("proxies.groups.filter.all", defaultValue: "All Groups"),
                            systemImage: groupFilter == .all ? "checkmark" : "circle"
                        )
                    }
                    Button {
                        groupFilter = .needsAttention
                    } label: {
                        Label(
                            VelaL10n.string(
                                "proxies.groups.filter.needsAttention",
                                defaultValue: "Needs Attention"
                            ),
                            systemImage: groupFilter == .needsAttention ? "checkmark" : "circle"
                        )
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease")
                }
                .help(VelaL10n.string("proxies.groups.filter", defaultValue: "Filter Proxy Groups"))
                .accessibilityLabel(
                    VelaL10n.string("proxies.groups.filter", defaultValue: "Filter Proxy Groups")
                )
                .accessibilityIdentifier("proxies.groups.filter")

                Menu {
                    Button {
                        groupSort = .configuration
                    } label: {
                        Label(
                            VelaL10n.string(
                                "proxies.groups.sort.configuration",
                                defaultValue: "Configuration Order"
                            ),
                            systemImage: groupSort == .configuration ? "checkmark" : "circle"
                        )
                    }
                    Button {
                        groupSort = .name
                    } label: {
                        Label(
                            VelaL10n.string("proxies.groups.sort.name", defaultValue: "Name"),
                            systemImage: groupSort == .name ? "checkmark" : "circle"
                        )
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                .help(VelaL10n.string("proxies.groups.sort", defaultValue: "Sort Proxy Groups"))
                .accessibilityLabel(
                    VelaL10n.string("proxies.groups.sort", defaultValue: "Sort Proxy Groups")
                )
                .accessibilityIdentifier("proxies.groups.sort")
                Spacer()
                Button {
                    action(.refresh)
                } label: {
                    Image(systemName: "gearshape")
                }
                .disabled(!snapshot.actions.canRefresh)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 14)
            .frame(height: 44)
            .foregroundStyle(.secondary)
        }
        .frame(maxHeight: .infinity)
        .proxiesGlassSurface(radius: 18, shadow: .soft)
        .accessibilityIdentifier("proxies.groups")
    }

    private func groupRow(_ row: ProxiesGroupRowSnapshot) -> some View {
        let isSelected = row.id == resolvedGroupID

        return Button {
            selectedGroupID = row.id
        } label: {
            HStack(spacing: 10) {
                Image(systemName: groupSymbol(row))
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 3) {
                    Text(row.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                    Text(strings.nodeCount(row.candidateCount))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)

                Circle()
                    .fill(row.semanticStatus.tint)
                    .frame(width: 7, height: 7)
                    .accessibilityLabel(row.semanticStatus.accessibilityValue)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.accentColor.opacity(0.065))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("proxies.group.\(row.id.rawValue)")
    }

    private func nodesPane(metrics: ProxiesLiquidLayoutMetrics) -> some View {
        VStack(spacing: 0) {
            paneHeader(
                title: strings.nodes(filteredCandidates.count),
                trailing: AnyView(
                    HStack(spacing: metrics.showsNodeType ? 26 : 0) {
                        if metrics.showsNodeType {
                            Text(strings.type)
                        }
                        Text(strings.latency)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                )
            )

            Divider()

            if filteredCandidates.isEmpty {
                ContentUnavailableView(
                    strings.noMatchingNodes,
                    systemImage: "magnifyingglass",
                    description: Text(strings.noMatchingNodesDescription)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(filteredCandidates) { candidate in
                            nodeRow(candidate, metrics: metrics)
                        }
                    }
                    .padding(6)
                }
            }
        }
        .frame(maxHeight: .infinity)
        .proxiesGlassSurface(radius: 18, shadow: .soft)
        .accessibilityIdentifier("proxies.nodes")
    }

    private func nodeRow(
        _ candidate: ProxiesCandidateSnapshot,
        metrics: ProxiesLiquidLayoutMetrics
    ) -> some View {
        let isSelected = candidate.id == selectedCandidateID
        let isFavorite = favoriteKeys.contains(favoriteKey(candidate))

        return HStack(spacing: metrics.nodeRowSpacing) {
            nodeGlyph(for: candidate, size: 32)

            HStack(spacing: 7) {
                Text(candidate.name)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                    .layoutPriority(3)
                if metrics.showsNodeStatusPills, candidate.isCurrent {
                    statusPill(strings.current, tint: .green)
                }
                if metrics.showsNodeStatusPills, candidate.isRequested {
                    statusPill(strings.applying, tint: .blue)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(2)

            if metrics.showsNodeType {
                Text(candidate.type ?? "—")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 92, alignment: .leading)
                    .lineLimit(1)
            }

            latencyText(candidate.latency)
                .frame(width: 60, alignment: .trailing)

            signalBars(state: candidate.latency.state)
                .frame(width: 24)

            Button {
                toggleFavorite(candidate)
            } label: {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .foregroundStyle(isFavorite ? .yellow : .secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(
                isFavorite ? strings.removeFavorite : strings.addFavorite
            )
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 44)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(
                    isSelected
                        ? Color.green.opacity(0.07)
                        : Color.clear
                )
        )
        .contentShape(Rectangle())
        .onTapGesture {
            selectedCandidateID = candidate.id
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("proxies.node.\(candidate.name)")
    }

    private var inspectorPane: some View {
        VStack(spacing: 0) {
            paneHeader(
                title: strings.nodeDetails,
                trailing: AnyView(
                    Button {
                        showsInspector = false
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(strings.closeDetails)
                )
            )

            Divider()

            if let candidate = selectedCandidate {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        inspectorHero(candidate)

                        VStack(spacing: 0) {
                            detailRow(strings.type, candidate.type ?? "—")
                            detailRow(strings.source, candidate.source)
                            detailRow(
                                strings.delay,
                                latencyValue(candidate.latency),
                                tint: latencyColor(candidate.latency.state)
                            )
                            detailRow(
                                strings.availability,
                                availabilityText(candidate.isAvailable)
                            )
                            detailRow(
                                strings.selection,
                                candidate.isCurrent ? strings.current : strings.notSelected
                            )
                            detailRow(
                                strings.group,
                                selectedGroup?.name ?? "—"
                            )
                            detailRow(
                                strings.strategy,
                                selectedGroup?.strategy ?? "—"
                            )
                            detailRow(
                                strings.measuredSamples,
                                "\(selectedGroup?.measuredSampleCount ?? 0)"
                            )
                        }

                        if let failure = selectedGroup?.failureSummary {
                            Label(failure, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    Color.orange.opacity(0.08),
                                    in: RoundedRectangle(cornerRadius: 10)
                                )
                        }
                    }
                    .padding(16)
                }

                Divider()

                let canTestCandidate = selectedGroupCanTest
                let canSelectCandidate =
                    !candidate.isCurrent
                    && !candidate.isPlaceholder
                    && snapshot.actions.canMutateSelection
                    && selectedGroup?.allowsManualSelection == true

                HStack(spacing: 8) {
                    Button {
                        guard let groupID = resolvedGroupID else { return }
                        action(.testProxy(groupID, candidate.id))
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "gauge.with.dots.needle.50percent")
                                .foregroundStyle(actionIconColor)
                            Text(strings.test)
                                .foregroundStyle(Color.primary.opacity(0.88))
                                .lineLimit(1)
                                .minimumScaleFactor(0.82)
                        }
                    }
                    .buttonStyle(
                        ProxiesSecondaryActionButtonStyle(
                            height: 34,
                            horizontalPadding: 8,
                            expandsHorizontally: true
                        )
                    )
                    .frame(maxWidth: .infinity)
                    .disabled(!canTestCandidate)

                    Button {
                        guard let groupID = resolvedGroupID else { return }
                        action(.selectProxy(groupID, candidate.id))
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                            Text(candidate.isCurrent ? strings.selected : strings.select)
                                .lineLimit(1)
                                .minimumScaleFactor(0.78)
                        }
                    }
                    .buttonStyle(
                        ProxiesPrimaryActionButtonStyle(
                            height: 34,
                            horizontalPadding: 8,
                            expandsHorizontally: true,
                            preservesSelectedAppearance: candidate.isCurrent
                        )
                    )
                    .frame(maxWidth: .infinity)
                    .disabled(!canSelectCandidate)
                }
                .frame(maxWidth: .infinity)
                .padding(12)
            } else {
                ContentUnavailableView(
                    strings.selectNode,
                    systemImage: "cursorarrow.click.2",
                    description: Text(strings.selectNodeDescription)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxHeight: .infinity)
        .proxiesGlassSurface(radius: 18, shadow: .soft)
    }

    private func inspectorHero(_ candidate: ProxiesCandidateSnapshot) -> some View {
        HStack(spacing: 12) {
            nodeGlyph(for: candidate, size: 48)
            VStack(alignment: .leading, spacing: 4) {
                Text(candidate.name)
                    .font(.system(size: 17, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.76)
                HStack(spacing: 6) {
                    Circle()
                        .fill(availabilityColor(candidate.isAvailable))
                        .frame(width: 8, height: 8)
                    Text(availabilityText(candidate.isAvailable))
                        .font(VelaTypography.body)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.white.opacity(0.34),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
    }

    private func routePreview(metrics: ProxiesLiquidLayoutMetrics) -> some View {
        let canCheckRoute = selectedCandidate != nil
            && selectedGroupCanTest
            && resolvedGroupID != nil

        return VStack(alignment: .leading, spacing: 4) {
            Text(strings.routePreview)
                .font(.system(size: 14, weight: .semibold))
                .accessibilityIdentifier("proxies.routePreview")

            GeometryReader { proxy in
                let availableFlowWidth = max(
                    240,
                    proxy.size.width - metrics.routeCheckReservedWidth
                )
                let flowWidth = min(
                    availableFlowWidth,
                    proxy.size.width * metrics.routeFlowWidthRatio
                )

                ZStack(alignment: .bottomTrailing) {
                    ZStack(alignment: .top) {
                        Image("OverviewWorldMap")
                            .resizable()
                            .scaledToFit()
                            .foregroundStyle(Color.secondary.opacity(0.18))
                            .opacity(0.26)
                            .frame(width: flowWidth * 0.72)

                        HStack(alignment: .top, spacing: 4) {
                            routeStop(
                                title: strings.thisMac,
                                subtitle: strings.localAddress,
                                metrics: metrics
                            ) {
                                Image(systemName: "desktopcomputer")
                                    .font(.system(size: 20, weight: .medium))
                            }

                            routeLine(metrics: metrics)

                            routeStop(
                                title: selectedCandidate?.name
                                    ?? selectedGroup?.currentProxy
                                    ?? strings.unavailable,
                                subtitle: latencyValue(
                                    selectedCandidate?.latency ?? selectedGroup?.currentLatency
                                ),
                                metrics: metrics
                            ) {
                                routeNodeIcon(
                                    name: selectedCandidate?.name
                                        ?? selectedGroup?.currentProxy
                                        ?? ""
                                )
                            }

                            routeLine(metrics: metrics)

                            routeStop(
                                title: strings.internet,
                                subtitle: selectedCandidate == nil
                                    ? strings.unavailable
                                    : (isTrafficConnected
                                        ? strings.routeReady
                                        : strings.disconnected),
                                metrics: metrics
                            ) {
                                Image(systemName: "globe")
                                    .font(.system(size: 20, weight: .medium))
                            }
                        }
                        .frame(width: flowWidth, height: metrics.routeStopHeight, alignment: .top)
                    }
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity,
                        alignment: .top
                    )

                    Button {
                        guard let groupID = resolvedGroupID,
                              let candidate = selectedCandidate
                        else { return }
                        action(.testProxy(groupID, candidate.id))
                    } label: {
                        Label(strings.checkRoute, systemImage: "checkmark.circle")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(
                                canCheckRoute
                                    ? Color.primary.opacity(0.82)
                                    : Color.secondary.opacity(0.58)
                            )
                            .padding(.horizontal, 11)
                            .frame(height: metrics.routeCheckButtonHeight)
                            .background(
                                Color.black.opacity(canCheckRoute ? 0.060 : 0.038),
                                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .stroke(Color.white.opacity(0.74), lineWidth: 1)
                            }
                    }
                    .buttonStyle(.plain)
                    .disabled(!canCheckRoute)
                    .help(strings.checkRouteHelp)
                    .accessibilityIdentifier("proxies.checkRoute")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .frame(height: metrics.routePreviewHeight, alignment: .topLeading)
        .proxiesGlassSurface(radius: 18, shadow: .soft)
        .accessibilityElement(children: .contain)
    }

    private func routeLine(metrics: ProxiesLiquidLayoutMetrics) -> some View {
        GeometryReader { proxy in
            TimelineView(
                .animation(
                    minimumInterval: 1.0 / 30.0,
                    paused: reduceMotion || !hasActiveTrafficRoute
                )
            ) { timeline in
                let pulseWidth = min(68, max(28, proxy.size.width * 0.18))
                let travel = max(0, proxy.size.width - pulseWidth)
                let progress = routePulseProgress(at: timeline.date)

                ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    Circle()
                        .fill(routeTint)
                        .frame(width: 7, height: 7)
                        Rectangle()
                            .fill(routeTint)
                            .frame(height: 2)
                    Circle()
                        .fill(routeTint)
                        .frame(width: 7, height: 7)
                }
                .frame(maxWidth: .infinity)

                if !reduceMotion, hasActiveTrafficRoute {
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        .clear,
                                        Color.white.opacity(0.78),
                                        .clear,
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: pulseWidth, height: 4)
                            .blur(radius: 1.5)
                            .offset(x: travel * progress)
                            .accessibilityHidden(true)
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
        .frame(height: 7)
        .frame(maxWidth: .infinity)
        .padding(.top, metrics.routeLineTopPadding)
    }

    private func routePulseProgress(at date: Date) -> CGFloat {
        let duration = 2.8
        let phase = date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: duration)
        return CGFloat(phase / duration)
    }

    private func routeStop<Icon: View>(
        title: String,
        subtitle: String,
        metrics: ProxiesLiquidLayoutMetrics,
        @ViewBuilder icon: () -> Icon
    ) -> some View {
        ZStack {
            Circle()
                .fill(Color.white.opacity(0.76))
            Circle()
                .stroke(routeTint.opacity(0.18), lineWidth: 1.5)
            icon()
                .scaleEffect(metrics.routeIconScale)
        }
        .frame(width: metrics.routeStopDiameter, height: metrics.routeStopDiameter)
        .shadow(color: routeTint.opacity(0.08), radius: 12)
        .overlay(alignment: .top) {
            VStack(spacing: metrics.routeStopTextSpacing) {
                Color.clear
                    .frame(height: metrics.routeStopDiameter)

                Text(title)
                    .font(
                        .system(
                            size: max(metrics.routeStopTitleSize, VelaTypeSize.table),
                            weight: .semibold
                        )
                    )
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                Text(subtitle)
                    .font(
                        .system(
                            size: max(metrics.routeStopSubtitleSize, VelaTypeSize.caption)
                        )
                    )
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: metrics.routeStopLabelWidth)
        }
        .frame(
            width: metrics.routeStopColumnWidth,
            height: metrics.routeStopHeight,
            alignment: .top
        )
    }

    @ViewBuilder
    private func routeNodeIcon(name: String) -> some View {
        if let flag = ProxyCountryFlagResolver.flag(for: name) {
            Text(flag)
                .font(.system(size: 22))
                .accessibilityHidden(true)
        } else {
            Image(systemName: "location.fill")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(routeTint)
        }
    }

    private var recoveryState: some View {
        VStack(spacing: 18) {
            Image(systemName: recoverySymbol)
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(recoveryTint)

            VStack(spacing: 7) {
                Text(recoveryTitle)
                    .font(VelaTypography.sectionTitle)
                Text(recoveryDescription)
                    .font(VelaTypography.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
            }

            HStack(spacing: 12) {
                if snapshot.actions.showsOpenConfiguration {
                    Button {
                        action(.openConfiguration)
                    } label: {
                        Label(strings.openConfiguration, systemImage: "doc.badge.gearshape")
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button {
                        action(.refresh)
                    } label: {
                        Label(strings.reload, systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!snapshot.actions.canRefresh)
                }

                if snapshot.actions.showsDiagnostics {
                    Button {
                        action(.openDiagnostics)
                    } label: {
                        Label(strings.openDiagnostics, systemImage: "chevron.right")
                    }
                    .buttonStyle(.borderless)
                }
            }
            .controlSize(.regular)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .proxiesGlassSurface(radius: 18, shadow: .soft)
        .accessibilityIdentifier("proxies.recovery")
    }

    private func paneHeader(title: String, trailing: AnyView) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
    }

    private func detailRow(
        _ label: String,
        _ value: String,
        tint: Color = .primary
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(VelaTypography.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(VelaTypography.body)
                .foregroundStyle(tint)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    @ViewBuilder
    private func nodeGlyph(
        for candidate: ProxiesCandidateSnapshot?,
        size: CGFloat = 34
    ) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .fill(Color.white.opacity(0.62))
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .stroke(Color.white.opacity(0.74), lineWidth: 1)
            if let flag = ProxyCountryFlagResolver.flag(
                for: candidate?.name ?? ""
            ) {
                Text(flag)
                    .font(.system(size: size * 0.50))
                    .accessibilityHidden(true)
            } else {
                Image(systemName: candidateSymbol(candidate))
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(candidateTint(candidate))
            }
        }
        .frame(width: size, height: size)
        .shadow(color: candidateTint(candidate).opacity(0.10), radius: 8)
    }

    @ViewBuilder
    private func latencyBadge(_ latency: ProxiesLatencySnapshot?) -> some View {
        if let latency {
            Text(latencyValue(latency))
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(latencyColor(latency.state))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    latencyColor(latency.state).opacity(0.10),
                    in: Capsule()
                )
        }
    }

    private func latencyText(_ latency: ProxiesLatencySnapshot) -> some View {
        Text(latencyValue(latency))
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(latencyColor(latency.state))
            .monospacedDigit()
    }

    private func signalBars(state: VelaLatencyState) -> some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<4, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(index < signalStrength(state) ? latencyColor(state) : Color.secondary.opacity(0.20))
                    .frame(width: 3, height: CGFloat(6 + index * 4))
            }
        }
        .frame(height: 20)
        .accessibilityHidden(true)
    }

    private func statusPill(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(VelaTypography.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(tint.opacity(0.10), in: Capsule())
    }

    private var selectionGeneration: String {
        "\(snapshot.generation)|\(searchText)"
    }

    private var resolvedGroupID: ProxiesGroupID? {
        snapshot.resolvingSelection(selectedGroupID)
    }

    private var selectedGroup: ProxiesGroupInspectorSnapshot? {
        guard let resolvedGroupID else { return nil }
        return snapshot.groups[resolvedGroupID]
    }

    private var selectedCandidate: ProxiesCandidateSnapshot? {
        guard let selectedCandidateID else {
            return filteredCandidates.first(where: \.isCurrent) ?? filteredCandidates.first
        }
        return selectedGroup?.candidates.first(where: { $0.id == selectedCandidateID })
    }

    private var filteredRows: [ProxiesGroupRowSnapshot] {
        ProxyGroupListPresentation.rows(
            from: snapshot.rows,
            groups: snapshot.groups,
            searchText: searchText,
            filter: groupFilter,
            sort: groupSort
        )
    }

    private var filteredCandidates: [ProxiesCandidateSnapshot] {
        guard let candidates = selectedGroup?.candidates else { return [] }
        guard !searchText.isEmpty else { return sortedCandidates(candidates) }
        return sortedCandidates(
            candidates.filter {
                $0.name.localizedCaseInsensitiveContains(searchText)
                    || $0.type?.localizedCaseInsensitiveContains(searchText) == true
                    || $0.source.localizedCaseInsensitiveContains(searchText)
            }
        )
    }

    private func sortedCandidates(
        _ candidates: [ProxiesCandidateSnapshot]
    ) -> [ProxiesCandidateSnapshot] {
        candidates.sorted { lhs, rhs in
            let lhsFavorite = favoriteKeys.contains(favoriteKey(lhs))
            let rhsFavorite = favoriteKeys.contains(favoriteKey(rhs))
            if lhsFavorite != rhsFavorite { return lhsFavorite }
            if lhs.isCurrent != rhs.isCurrent { return lhs.isCurrent }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private var favoriteKeys: Set<String> {
        Set(favoriteNodeKeys.split(separator: "\n").map(String.init))
    }

    private func favoriteKey(_ candidate: ProxiesCandidateSnapshot) -> String {
        "\(resolvedGroupID?.rawValue ?? "")|\(candidate.id.name)"
    }

    private func toggleFavorite(_ candidate: ProxiesCandidateSnapshot) {
        var keys = favoriteKeys
        let key = favoriteKey(candidate)
        if keys.contains(key) {
            keys.remove(key)
        } else {
            keys.insert(key)
        }
        favoriteNodeKeys = keys.sorted().joined(separator: "\n")
    }

    private func resolveCandidateSelection() {
        let candidates = filteredCandidates
        if let selectedCandidateID,
           candidates.contains(where: { $0.id == selectedCandidateID }) {
            return
        }
        self.selectedCandidateID =
            candidates.first(where: \.isCurrent)?.id ?? candidates.first?.id
    }

    private var selectedGroupCanTest: Bool {
        snapshot.actions.canTestGroup && selectedGroup?.canTest == true
    }

    private var shouldShowWorkspace: Bool {
        switch snapshot.state {
        case .loaded, .refreshing, .pendingMutation, .stale, .partialFailure:
            !snapshot.rows.isEmpty
        case .offline:
            !snapshot.rows.isEmpty
        case .loading, .empty, .fullFailure:
            false
        }
    }

    private var routeTint: Color {
        hasActiveTrafficRoute ? .green.opacity(0.78) : .secondary.opacity(0.55)
    }

    private var hasActiveTrafficRoute: Bool {
        ProxiesRoutePreviewPolicy.isActive(
            isTrafficConnected: isTrafficConnected,
            hasSelectedCandidate: selectedCandidate != nil
        )
    }

    private var recoverySymbol: String {
        switch snapshot.state {
        case .loading, .refreshing:
            "arrow.triangle.2.circlepath"
        case .empty:
            "shippingbox"
        case .offline:
            "network.slash"
        case .fullFailure, .partialFailure:
            "exclamationmark.triangle"
        case .loaded, .pendingMutation, .stale:
            "network"
        }
    }

    private var recoveryTint: Color {
        switch snapshot.state {
        case .fullFailure, .partialFailure:
            .orange
        case .offline, .empty:
            .secondary
        case .loading, .refreshing, .loaded, .pendingMutation, .stale:
            .accentColor
        }
    }

    private var recoveryTitle: String {
        switch snapshot.state {
        case .loading:
            strings.loading
        case .empty:
            strings.noProxyGroups
        case .offline:
            strings.controllerOffline
        case .fullFailure:
            strings.proxyCatalogUnavailable
        case .refreshing:
            strings.refreshing
        case .partialFailure:
            strings.partialFailure
        case .loaded, .pendingMutation, .stale:
            strings.noProxyGroups
        }
    }

    private var recoveryDescription: String {
        if let errorSummary = snapshot.errorSummary, !errorSummary.isEmpty {
            return errorSummary
        }
        switch snapshot.state {
        case .empty:
            return strings.noProxyGroupsDescription
        case .offline:
            return strings.controllerOfflineDescription
        case .fullFailure, .partialFailure:
            return strings.proxyCatalogUnavailableDescription
        case .loading, .refreshing:
            return strings.loadingDescription
        case .loaded, .pendingMutation, .stale:
            return strings.noProxyGroupsDescription
        }
    }

    private func groupSymbol(_ row: ProxiesGroupRowSnapshot) -> String {
        let value = "\(row.name) \(row.strategy)".lowercased()
        if value.contains("global") { return "globe" }
        if value.contains("stream") { return "play.tv" }
        if value.contains("direct") { return "location.circle" }
        if value.contains("reject") { return "xmark.circle" }
        if value.contains("fallback") { return "arrow.triangle.branch" }
        return "scope"
    }

    private func candidateSymbol(_ candidate: ProxiesCandidateSnapshot?) -> String {
        guard let candidate else { return "network" }
        let value = "\(candidate.name) \(candidate.type ?? "")".lowercased()
        if value.contains("direct") { return "location.fill" }
        if value.contains("reject") { return "xmark" }
        if value.contains("trojan") { return "shield.lefthalf.filled" }
        if value.contains("vless") { return "bolt.horizontal.fill" }
        return "location.circle.fill"
    }

    private func candidateTint(_ candidate: ProxiesCandidateSnapshot?) -> Color {
        guard let candidate else { return .secondary }
        if candidate.isCurrent { return .green }
        if candidate.isRequested { return .blue }
        return .accentColor
    }

    private func latencyValue(_ latency: ProxiesLatencySnapshot?) -> String {
        guard let latency else { return "—" }
        if latency.state == .testing { return strings.testing }
        if let milliseconds = latency.milliseconds { return "\(milliseconds) ms" }
        return latency.state == .failed ? strings.failed : "—"
    }

    private func latencyColor(_ state: VelaLatencyState) -> Color {
        switch state {
        case .good:
            .green
        case .medium:
            .orange
        case .slow, .failed:
            .red
        case .testing:
            .blue
        case .unknown:
            .secondary
        }
    }

    private func signalStrength(_ state: VelaLatencyState) -> Int {
        switch state {
        case .good:
            4
        case .medium:
            3
        case .slow:
            2
        case .testing:
            2
        case .unknown, .failed:
            1
        }
    }

    private func availabilityText(_ availability: Bool?) -> String {
        switch availability {
        case true:
            strings.online
        case false:
            strings.offline
        case nil:
            strings.unknown
        }
    }

    private func availabilityColor(_ availability: Bool?) -> Color {
        switch availability {
        case true:
            .green
        case false:
            .red
        case nil:
            .secondary
        }
    }
}

nonisolated struct ProxyCountryFlagResolver {
    private static let regionCodes: Set<String> = Set(
        Locale.Region.isoRegions
            .map(\.identifier)
            .filter { code in
                code.count == 2 && code.unicodeScalars.allSatisfy {
                    CharacterSet.letters.contains($0)
                }
            }
            .map { $0.uppercased() }
    )

    private static let aliases: [(String, String)] = [
        ("los angeles", "US"), ("new york", "US"), ("san francisco", "US"),
        ("united states", "US"), ("america", "US"), ("美国", "US"), ("美國", "US"),
        ("tokyo", "JP"), ("osaka", "JP"), ("yokohama", "JP"),
        ("japan", "JP"), ("日本", "JP"), ("东京", "JP"), ("東京", "JP"), ("大阪", "JP"),
        ("singapore", "SG"), ("新加坡", "SG"), ("狮城", "SG"), ("獅城", "SG"),
        ("hong kong", "HK"), ("hongkong", "HK"), ("香港", "HK"),
        ("taipei", "TW"), ("taiwan", "TW"), ("台北", "TW"), ("台湾", "TW"), ("臺灣", "TW"),
        ("seoul", "KR"), ("busan", "KR"), ("korea", "KR"), ("韩国", "KR"), ("韓國", "KR"),
        ("london", "GB"), ("united kingdom", "GB"), ("britain", "GB"), ("英国", "GB"), ("英國", "GB"),
        ("frankfurt", "DE"), ("berlin", "DE"), ("germany", "DE"), ("德国", "DE"), ("德國", "DE"),
        ("paris", "FR"), ("marseille", "FR"), ("france", "FR"), ("法国", "FR"), ("法國", "FR"),
        ("sydney", "AU"), ("melbourne", "AU"), ("australia", "AU"), ("澳大利亚", "AU"), ("澳洲", "AU"),
        ("toronto", "CA"), ("vancouver", "CA"), ("canada", "CA"), ("加拿大", "CA"),
        ("moscow", "RU"), ("russia", "RU"), ("俄罗斯", "RU"), ("俄羅斯", "RU"),
        ("mumbai", "IN"), ("new delhi", "IN"), ("india", "IN"), ("印度", "IN"),
        ("bangkok", "TH"), ("thailand", "TH"), ("泰国", "TH"), ("泰國", "TH"),
        ("kuala lumpur", "MY"), ("malaysia", "MY"), ("马来西亚", "MY"), ("馬來西亞", "MY"),
        ("jakarta", "ID"), ("indonesia", "ID"), ("印度尼西亚", "ID"), ("印尼", "ID"),
        ("manila", "PH"), ("philippines", "PH"), ("菲律宾", "PH"), ("菲律賓", "PH"),
        ("hanoi", "VN"), ("ho chi minh", "VN"), ("vietnam", "VN"), ("越南", "VN"),
        ("amsterdam", "NL"), ("netherlands", "NL"), ("荷兰", "NL"), ("荷蘭", "NL"),
        ("zurich", "CH"), ("switzerland", "CH"), ("瑞士", "CH"),
        ("stockholm", "SE"), ("sweden", "SE"), ("瑞典", "SE"),
        ("oslo", "NO"), ("norway", "NO"), ("挪威", "NO"),
        ("helsinki", "FI"), ("finland", "FI"), ("芬兰", "FI"), ("芬蘭", "FI"),
        ("warsaw", "PL"), ("poland", "PL"), ("波兰", "PL"), ("波蘭", "PL"),
        ("madrid", "ES"), ("spain", "ES"), ("西班牙", "ES"),
        ("milan", "IT"), ("rome", "IT"), ("italy", "IT"), ("意大利", "IT"),
        ("istanbul", "TR"), ("turkey", "TR"), ("土耳其", "TR"),
        ("dubai", "AE"), ("united arab emirates", "AE"), ("阿联酋", "AE"), ("阿聯酋", "AE"),
        ("sao paulo", "BR"), ("brazil", "BR"), ("巴西", "BR"),
        ("mexico city", "MX"), ("mexico", "MX"), ("墨西哥", "MX"),
        ("johannesburg", "ZA"), ("south africa", "ZA"), ("南非", "ZA"),
    ].sorted { $0.0.count > $1.0.count }

    private static let localizedRegionNames: [(String, String)] = {
        let locales = [
            Locale(identifier: "en_US"),
            Locale(identifier: "zh_Hans"),
            Locale(identifier: "zh_Hant"),
            Locale(identifier: "ja_JP"),
        ]

        return regionCodes.flatMap { code in
            locales.compactMap { locale -> (String, String)? in
                guard let name = locale.localizedString(forRegionCode: code) else {
                    return nil
                }
                return (normalize(name), code)
            }
        }
        .sorted { $0.0.count > $1.0.count }
    }()

    static func regionCode(for nodeName: String) -> String? {
        if let embeddedCode = embeddedFlagRegionCode(in: nodeName) {
            return embeddedCode
        }

        let normalizedName = normalize(nodeName)
        let tokens = normalizedName
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .map { $0.uppercased() }

        if let code = tokens.first(where: regionCodes.contains) {
            return code
        }

        if let alias = aliases.first(where: {
            normalizedName.range(of: $0.0) != nil
        }) {
            return alias.1
        }

        return localizedRegionNames.first(where: {
            normalizedName.range(of: $0.0) != nil
        })?.1
    }

    static func flag(for nodeName: String) -> String? {
        guard let code = regionCode(for: nodeName) else { return nil }
        let scalars = code.unicodeScalars.compactMap { scalar in
            UnicodeScalar(127_397 + Int(scalar.value))
        }
        guard scalars.count == 2 else { return nil }
        return String(String.UnicodeScalarView(scalars))
    }

    private static func embeddedFlagRegionCode(in value: String) -> String? {
        let scalars = Array(value.unicodeScalars)
        guard scalars.count >= 2 else { return nil }

        for index in 0..<(scalars.count - 1) {
            let first = scalars[index].value
            let second = scalars[index + 1].value
            guard (127_462...127_487).contains(first),
                  (127_462...127_487).contains(second)
            else { continue }

            let firstLetter = UnicodeScalar(first - 127_397)
            let secondLetter = UnicodeScalar(second - 127_397)
            guard let firstLetter, let secondLetter else { continue }
            return String(String.UnicodeScalarView([firstLetter, secondLetter]))
        }
        return nil
    }

    private static func normalize(_ value: String) -> String {
        value
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .lowercased()
    }
}

private struct ProxiesLiquidLayoutMetrics {
    let pagePadding: CGFloat
    let topPadding: CGFloat
    let bottomPadding: CGFloat
    let sectionSpacing: CGFloat
    let columnSpacing: CGFloat
    let searchWidth: CGFloat
    let groupPaneWidth: CGFloat
    let inspectorWidth: CGFloat
    let currentRouteHeight: CGFloat
    let routeModeWidth: CGFloat
    let routeGroupWidth: CGFloat
    let nodeRowSpacing: CGFloat
    let showsNodeType: Bool
    let showsNodeStatusPills: Bool
    let workspaceHeight: CGFloat
    let routePreviewHeight: CGFloat
    let routeFlowWidthRatio: CGFloat
    let routeCheckReservedWidth: CGFloat
    let routeCheckButtonHeight: CGFloat
    let routeStopDiameter: CGFloat
    let routeStopColumnWidth: CGFloat
    let routeStopHeight: CGFloat
    let routeStopLabelWidth: CGFloat
    let routeStopTextSpacing: CGFloat
    let routeStopTitleSize: CGFloat
    let routeStopSubtitleSize: CGFloat
    let routeLineTopPadding: CGFloat
    let routeIconScale: CGFloat

    static func resolve(width: CGFloat, height: CGFloat) -> ProxiesLiquidLayoutMetrics {
        let usableWidth = max(width, 0)
        let widthScale = min(max((usableWidth - 760) / 560, 0), 1)
        let usableHeight = max(height, 0)
        let heightScale = min(max((usableHeight - 620) / 360, 0), 1)

        let pagePadding = 18 + (10 * widthScale)
        let topPadding = 14 + (8 * heightScale)
        let bottomPadding = 14 + (6 * heightScale)
        let sectionSpacing = 10 + (6 * min(widthScale, heightScale))
        let currentRouteHeight = 92 + (10 * heightScale)
        let routePreviewHeight = 108 + (56 * heightScale)
        let fixedHeight =
            topPadding
            + bottomPadding
            + 40
            + currentRouteHeight
            + routePreviewHeight
            + (sectionSpacing * 3)
        let workspaceHeight = max(200, usableHeight - fixedHeight)

        return ProxiesLiquidLayoutMetrics(
            pagePadding: pagePadding,
            topPadding: topPadding,
            bottomPadding: bottomPadding,
            sectionSpacing: sectionSpacing,
            columnSpacing: 10 + (6 * widthScale),
            searchWidth: 205 + (75 * widthScale),
            groupPaneWidth: 176 + (52 * widthScale),
            inspectorWidth: 214 + (54 * widthScale),
            currentRouteHeight: currentRouteHeight,
            routeModeWidth: 108 + (36 * widthScale),
            routeGroupWidth: 132 + (52 * widthScale),
            nodeRowSpacing: 8 + (4 * widthScale),
            showsNodeType: usableWidth >= 920,
            showsNodeStatusPills: usableWidth >= 840,
            workspaceHeight: workspaceHeight,
            routePreviewHeight: routePreviewHeight,
            routeFlowWidthRatio: 0.70 + (0.08 * widthScale),
            routeCheckReservedWidth: 102 + (18 * widthScale),
            routeCheckButtonHeight: 28 + (2 * heightScale),
            routeStopDiameter: 38 + (12 * heightScale),
            routeStopColumnWidth: 54 + (12 * heightScale),
            routeStopHeight: 70 + (22 * heightScale),
            routeStopLabelWidth: 94 + (38 * widthScale),
            routeStopTextSpacing: 3 + (3 * heightScale),
            routeStopTitleSize: 11.5 + (1.5 * heightScale),
            routeStopSubtitleSize: 10 + heightScale,
            routeLineTopPadding: 15.5 + (6 * heightScale),
            routeIconScale: 0.82 + (0.18 * heightScale)
        )
    }
}

private struct ProxiesGlassSurfaceModifier: ViewModifier {
    enum Shadow {
        case soft
    }

    let radius: CGFloat
    let shadow: Shadow

    func body(content: Content) -> some View {
        content.velaWorkspaceGlassSurface(radius: radius)
    }
}

private enum ProxiesActionPalette {
    static let iconMint = Color(red: 36 / 255, green: 155 / 255, blue: 124 / 255)
    static let highContrastIconMint = Color(red: 15 / 255, green: 116 / 255, blue: 90 / 255)
    static let mint = Color(red: 175 / 255, green: 226 / 255, blue: 212 / 255)
    static let mintHighlight = Color(red: 208 / 255, green: 238 / 255, blue: 230 / 255)
    static let mintShadow = Color(red: 12 / 255, green: 104 / 255, blue: 81 / 255)
    static let highContrastText = Color(red: 9 / 255, green: 89 / 255, blue: 65 / 255)
}

private struct ProxiesSecondaryActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    let height: CGFloat
    let horizontalPadding: CGFloat
    var minimumWidth: CGFloat? = nil
    var expandsHorizontally = false

    @ViewBuilder
    func makeBody(configuration: Configuration) -> some View {
        let radius: CGFloat = height >= 40 ? 14 : 10
        let label = configuration.label
            .font(.system(size: height >= 40 ? 13 : 12.5, weight: .semibold))
            .padding(.horizontal, horizontalPadding)
            .frame(
                minWidth: minimumWidth,
                maxWidth: expandsHorizontally ? .infinity : nil,
                minHeight: height,
                maxHeight: height
            )

        if #available(macOS 26.0, *), !reduceTransparency, contrast != .increased {
            label
                .glassEffect(
                    .regular.interactive(),
                    in: .rect(cornerRadius: radius)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .stroke(Color.white.opacity(0.72), lineWidth: 1)
                }
                .shadow(color: Color.black.opacity(0.026), radius: 7, y: 3)
                .opacity(isEnabled ? 1 : 0.48)
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
        } else {
            label
                .background(
                    Color.white.opacity(configuration.isPressed ? 0.64 : 0.82),
                    in: RoundedRectangle(cornerRadius: radius, style: .continuous)
                )
                .background(
                    .ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: radius, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .stroke(
                            Color.white.opacity(contrast == .increased ? 1 : 0.92),
                            lineWidth: 1
                        )
                }
                .shadow(color: Color.black.opacity(0.032), radius: 7, y: 3)
                .opacity(isEnabled ? 1 : 0.48)
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
        }
    }
}

private struct ProxiesPrimaryActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    let height: CGFloat
    let horizontalPadding: CGFloat
    var expandsHorizontally = false
    let preservesSelectedAppearance: Bool

    @ViewBuilder
    func makeBody(configuration: Configuration) -> some View {
        let radius: CGFloat = height >= 40 ? 14 : 10
        let label = configuration.label
            .font(.system(size: height >= 40 ? 13 : 12.5, weight: .semibold))
            .foregroundStyle(
                contrast == .increased
                    ? ProxiesActionPalette.highContrastText
                    : ProxiesActionPalette.mintShadow
            )
            .padding(.horizontal, horizontalPadding)
            .frame(
                maxWidth: expandsHorizontally ? .infinity : nil,
                minHeight: height,
                maxHeight: height
            )

        if #available(macOS 26.0, *), !reduceTransparency, contrast != .increased {
            label
                .glassEffect(
                    .regular
                        .tint(ProxiesActionPalette.mint.opacity(0.88))
                        .interactive(),
                    in: .rect(cornerRadius: radius)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .stroke(Color.white.opacity(0.62), lineWidth: 1)
                }
                .shadow(
                    color: ProxiesActionPalette.mintShadow.opacity(isEnabled ? 0.18 : 0.08),
                    radius: 9,
                    y: 4
                )
                .opacity(isEnabled || preservesSelectedAppearance ? 1 : 0.44)
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
        } else {
            label
                .background(
                    .ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: radius, style: .continuous)
                )
                .background(
                    LinearGradient(
                        colors: [
                            ProxiesActionPalette.mintHighlight,
                            ProxiesActionPalette.mint,
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .opacity(configuration.isPressed ? 0.90 : 0.96),
                    in: RoundedRectangle(cornerRadius: radius, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .stroke(
                            Color.white.opacity(contrast == .increased ? 1 : 0.70),
                            lineWidth: 1
                        )
                }
                .shadow(
                    color: ProxiesActionPalette.mintShadow.opacity(isEnabled ? 0.18 : 0.08),
                    radius: 9,
                    y: 4
                )
                .opacity(isEnabled || preservesSelectedAppearance ? 1 : 0.44)
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
        }
    }
}

private extension View {
    func proxiesGlassSurface(
        radius: CGFloat,
        shadow: ProxiesGlassSurfaceModifier.Shadow
    ) -> some View {
        modifier(ProxiesGlassSurfaceModifier(radius: radius, shadow: shadow))
    }
}

private struct ProxiesLiquidStrings {
    let isChinese: Bool

    init(locale: Locale) {
        isChinese = locale.identifier.lowercased().hasPrefix("zh")
    }

    var title: String { isChinese ? "代理节点" : "Proxies" }
    var searchPrompt: String { isChinese ? "搜索节点或代理组…" : "Search nodes or groups…" }
    var testAll: String { isChinese ? "全部测速" : "Test All" }
    var testAllHelp: String { isChinese ? "测试所有代理组中的节点延迟" : "Test latency for every proxy group" }
    var refresh: String { isChinese ? "刷新" : "Refresh" }
    var reload: String { isChinese ? "重新加载" : "Reload" }
    var moreActions: String { isChinese ? "更多操作" : "More actions" }
    var showDetails: String { isChinese ? "显示详情" : "Show Details" }
    var hideDetails: String { isChinese ? "隐藏详情" : "Hide Details" }
    var currentRoute: String { isChinese ? "当前路由" : "Current Route" }
    var ruleMode: String { isChinese ? "代理模式" : "Rule Mode" }
    var proxyGroup: String { isChinese ? "代理组" : "Proxy Group" }
    var currentNode: String { isChinese ? "当前节点" : "Current Node" }
    var unavailable: String { isChinese ? "不可用" : "Unavailable" }
    var proxyGroups: String { isChinese ? "代理组" : "Proxy Groups" }
    var type: String { isChinese ? "类型" : "Type" }
    var latency: String { isChinese ? "延迟" : "Latency" }
    var nodeDetails: String { isChinese ? "节点详情" : "Node Details" }
    var closeDetails: String { isChinese ? "关闭详情" : "Close details" }
    var noMatchingNodes: String { isChinese ? "没有匹配的节点" : "No matching nodes" }
    var noMatchingNodesDescription: String { isChinese ? "尝试其他名称、类型或来源。" : "Try another name, type, or source." }
    var current: String { isChinese ? "当前" : "Current" }
    var applying: String { isChinese ? "正在应用" : "Applying" }
    var addFavorite: String { isChinese ? "收藏节点" : "Add favorite" }
    var removeFavorite: String { isChinese ? "取消收藏" : "Remove favorite" }
    var source: String { isChinese ? "来源" : "Source" }
    var delay: String { isChinese ? "延迟" : "Delay" }
    var availability: String { isChinese ? "可用性" : "Availability" }
    var selection: String { isChinese ? "选择状态" : "Selection" }
    var group: String { isChinese ? "代理组" : "Group" }
    var strategy: String { isChinese ? "策略" : "Strategy" }
    var measuredSamples: String { isChinese ? "已测样本" : "Measured Samples" }
    var test: String { isChinese ? "测速" : "Test" }
    var select: String { isChinese ? "选择" : "Select" }
    var selected: String { isChinese ? "已选择" : "Selected" }
    var notSelected: String { isChinese ? "未选择" : "Not selected" }
    var selectNode: String { isChinese ? "选择一个节点" : "Select a node" }
    var selectNodeDescription: String { isChinese ? "从中间列表选择节点以查看实时详情。" : "Choose a node from the list to inspect its live details." }
    var routePreview: String { isChinese ? "路由预览" : "Route Preview" }
    var checkRoute: String { isChinese ? "检查路由" : "Check Route" }
    var checkRouteHelp: String { isChinese ? "测试当前路由节点的延迟" : "Test latency for the current route node" }
    var thisMac: String { isChinese ? "这台 Mac" : "This Mac" }
    var localAddress: String { isChinese ? "本地设备" : "Local device" }
    var internet: String { isChinese ? "互联网" : "Internet" }
    var routeReady: String { isChinese ? "路由可用" : "Route ready" }
    var disconnected: String { isChinese ? "未连接" : "Disconnected" }
    var loading: String { isChinese ? "正在加载代理节点" : "Loading proxies" }
    var refreshing: String { isChinese ? "正在刷新代理节点" : "Refreshing proxies" }
    var loadingDescription: String { isChinese ? "正在从 Mihomo Controller 获取最新代理目录。" : "Fetching the latest proxy catalog from Mihomo Controller." }
    var noProxyGroups: String { isChinese ? "没有代理组" : "No proxy groups" }
    var noProxyGroupsDescription: String { isChinese ? "选择或编辑配置后，代理组和节点会显示在这里。" : "Choose or edit a configuration to populate proxy groups and nodes." }
    var controllerOffline: String { isChinese ? "Controller 已断开" : "Controller is offline" }
    var controllerOfflineDescription: String { isChinese ? "启动 Mihomo 或重新连接 Controller 后即可管理代理节点。" : "Start Mihomo or reconnect Controller to manage proxy nodes." }
    var proxyCatalogUnavailable: String { isChinese ? "代理目录不可用" : "Proxy catalog unavailable" }
    var proxyCatalogUnavailableDescription: String { isChinese ? "暂时无法读取代理组和节点，请重新加载或打开诊断。" : "The proxy catalog could not be read. Reload it or open Diagnostics." }
    var partialFailure: String { isChinese ? "部分代理数据不可用" : "Some proxy data is unavailable" }
    var openConfiguration: String { isChinese ? "打开配置工作台" : "Open Configuration Workbench" }
    var openDiagnostics: String { isChinese ? "打开诊断" : "Open Diagnostics" }
    var online: String { isChinese ? "在线" : "Online" }
    var offline: String { isChinese ? "离线" : "Offline" }
    var unknown: String { isChinese ? "未知" : "Unknown" }
    var testing: String { isChinese ? "测试中…" : "Testing…" }
    var failed: String { isChinese ? "失败" : "Failed" }

    func nodeCount(_ count: Int) -> String {
        isChinese ? "\(count) 个节点" : "\(count) nodes"
    }

    func nodes(_ count: Int) -> String {
        isChinese ? "节点（\(count)）" : "Nodes (\(count))"
    }
}
