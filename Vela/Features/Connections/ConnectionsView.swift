import AppKit
import SwiftUI

nonisolated enum ConnectionRouteEvidenceConfidence: Equatable, Sendable {
    case exact
    case ambiguous
    case unavailable
    case staleGeneration
}

nonisolated struct ConnectionRouteEvidencePresentation: Equatable, Sendable {
    let confidence: ConnectionRouteEvidenceConfidence

    /// Mihomo reports the chosen rule and chains, but the connection response
    /// does not identify a rule-source generation or an exact runtime index.
    static let currentMihomoResponse = Self(confidence: .unavailable)

    var semanticStatus: VelaSemanticStatus {
        switch confidence {
        case .exact: .success
        case .ambiguous: .warning
        case .unavailable: .neutral
        case .staleGeneration: .stale
        }
    }

    var label: String {
        switch confidence {
        case .exact: "Exact Runtime Evidence"
        case .ambiguous: "Ambiguous Route Evidence"
        case .unavailable: "Confidence Unavailable"
        case .staleGeneration: "Stale Route Evidence"
        }
    }

    var localizedLabel: String {
        switch confidence {
        case .exact:
            VelaL10n.string("connections.routeEvidence.exact", defaultValue: label)
        case .ambiguous:
            VelaL10n.string("connections.routeEvidence.ambiguous", defaultValue: label)
        case .unavailable:
            VelaL10n.string("connections.routeEvidence.unavailable", defaultValue: label)
        case .staleGeneration:
            VelaL10n.string("connections.routeEvidence.stale", defaultValue: label)
        }
    }
}

nonisolated enum ConnectionsTablePresentation {
    static func contentState(
        visibleCount: Int,
        totalCount: Int,
        isStreaming: Bool,
        hasActiveFilters: Bool,
        hasQuery: Bool,
        hasError: Bool
    ) -> VelaTableContentState {
        if visibleCount > 0 { return .loaded }
        if (hasActiveFilters || hasQuery), totalCount > 0 { return .filteredEmpty }
        if hasError { return .failure }
        return isStreaming ? .empty : .offline
    }
}

struct ConnectionsView: View {
#if DEBUG
    @Environment(\.visualUITestConfiguration) private var visualTestConfiguration
#endif
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let viewModel: ConnectionsViewModel
    let showsLiveMetrics: Bool

    @State private var isCloseAllConfirmationPresented = false
    @State private var isInspectorPresented = false
    @State private var lastWorkspaceWidth: CGFloat = .infinity
    @State private var retainedColumnSet: ConnectionsColumnSet?
    @State private var inspectorTransitionGeneration = 0
    @State private var isReconnectPending = false
#if DEBUG
    @State private var reconnectAttemptCount = 0
#endif
    @FocusState private var isSearchFocused: Bool

    init(
        viewModel: ConnectionsViewModel,
        showsLiveMetrics: Bool = true
    ) {
        self.viewModel = viewModel
        self.showsLiveMetrics = showsLiveMetrics
    }

    var body: some View {
        @Bindable var model = viewModel

        GeometryReader { geometry in
            let currentWindow = (
                NSApplication.shared.keyWindow
                    ?? NSApplication.shared.mainWindow
            )
            let windowFrameSize = currentWindow?.frame.size
                ?? CGSize(width: geometry.size.width + 240, height: geometry.size.height)
            let windowContentHeight = currentWindow.map {
                $0.contentRect(forFrameRect: $0.frame).height
            } ?? geometry.size.height
            let visibleDetailSize = CGSize(
                width: max(1, windowFrameSize.width - 240),
                height: max(1, windowContentHeight)
            )
            let canvasTopInset: CGFloat = 0
            let canvasViewportSize = CGSize(
                width: visibleDetailSize.width,
                height: max(1, visibleDetailSize.height - canvasTopInset)
            )
            let layoutSize = canvasViewportSize
            let inspectorWidth = min(
                340,
                max(
                    ConnectionsLayoutMetrics.inspectorMinimumWidth,
                    layoutSize.width * 0.225
                )
            )
            let horizontalPageChrome: CGFloat = layoutSize.height < 760 ? 24 : 48
            let tableAvailableWidth = layoutSize.width
                - (isInspectorPresented ? inspectorWidth + 12 : 0)
                - horizontalPageChrome
            let resolvedMetrics = ConnectionsLayoutMetrics.resolve(
                detailWidth: layoutSize.width,
                tableAvailableWidth: tableAvailableWidth
            )
            let resolvedColumnSet = retainedColumnSet ?? resolvedMetrics.columnSet
            let visualColumnSet: ConnectionsColumnSet =
                resolvedColumnSet == .regular && tableAvailableWidth >= 748
                    ? .spacious
                    : resolvedColumnSet
            let metrics = ConnectionsLayoutMetrics(
                columnSet: visualColumnSet,
                inspectorIdealWidth: resolvedMetrics.inspectorIdealWidth
            )
            workspace(
                model: $model,
                layout: metrics,
                availableSize: layoutSize,
                inspectorWidth: inspectorWidth
            )
                .frame(
                    width: layoutSize.width,
                    height: layoutSize.height,
                    alignment: .topLeading
                )
                .offset(y: canvasTopInset)
                .frame(
                    width: layoutSize.width,
                    height: layoutSize.height + canvasTopInset,
                    alignment: .topLeading
                )
                .onAppear {
                    lastWorkspaceWidth = geometry.size.width
                }
                .onChange(of: geometry.size.width) { _, width in
                    lastWorkspaceWidth = width
                }
        }
        .ignoresSafeArea(.container, edges: .top)
        .background {
            VelaPageCanvas()
                .ignoresSafeArea()
        }
        .confirmationDialog(
            VelaL10n.string(
                "legacy.disconnectAllConnectionsQuestion",
                defaultValue: "Disconnect All Connections?"
            ),
            isPresented: $isCloseAllConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button(
                VelaL10n.string(
                    "legacy.disconnectAllConnectionsIntegerFormat",
                    defaultValue: "Disconnect All %lld Connections",
                    arguments: viewModel.presentation.totalConnectionCount
                ),
                role: .destructive
            ) {
                Task { await viewModel.closeAll() }
            }
            Button(VelaL10n.string("legacy.cancel", defaultValue: "Cancel"), role: .cancel) {}
        } message: {
            Text(
                VelaL10n.string(
                    "legacy.mihomoWillTerminateEveryActiveConnectionApplicationsMayReconnectImmediately",
                    defaultValue: "Mihomo will terminate every active connection. Applications may reconnect immediately."
                )
            )
        }
        .onAppear {
#if DEBUG
            if let visualTestConfiguration {
                isInspectorPresented = visualTestConfiguration.inspector == .open
            } else {
                viewModel.viewDidAppear()
            }
#else
            viewModel.viewDidAppear()
#endif
        }
        .onDisappear {
#if DEBUG
            guard visualTestConfiguration == nil else { return }
#endif
            viewModel.viewDidDisappear()
        }
        .onReceive(NotificationCenter.default.publisher(for: .velaFocusSearch)) { _ in
            isSearchFocused = true
        }
    }

    private func workspace(
        model: Bindable<ConnectionsViewModel>,
        layout: ConnectionsLayoutMetrics,
        availableSize: CGSize,
        inspectorWidth: CGFloat
    ) -> some View {
        let snapshot = model.wrappedValue.presentation
        let isCompactHeight = availableSize.height < 900
        let usesCompactToolbar = availableSize.width < 1_160
        let pagePadding: CGFloat = isCompactHeight ? 16 : 24
        let pageSpacing: CGFloat = isCompactHeight ? 10 : 16
        let headerHeight: CGFloat = usesCompactToolbar ? 64 : 80
        let metricsHeight: CGFloat = isCompactHeight ? 84 : 124
        let statusHeight: CGFloat = isCompactHeight ? 46 : 58
        let bottomBreathingRoom: CGFloat = isCompactHeight ? 8 : 12
        let workspaceHeight = max(
            220,
            availableSize.height
                - (pagePadding * 2)
                - bottomBreathingRoom
                - headerHeight
                - metricsHeight
                - statusHeight
                - (pageSpacing * 3)
        )

        return ZStack {
            VelaPageCanvas()

            VStack(spacing: pageSpacing) {
                pageHeader(model: model, snapshot: snapshot, compact: usesCompactToolbar)
                metricsBar(snapshot: snapshot, compact: isCompactHeight)

                HStack(alignment: .top, spacing: 12) {
                    connectionPanel(
                        model: model,
                        snapshot: snapshot,
                        layout: layout,
                        compact: isCompactHeight
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if isInspectorPresented {
                        connectionInspector(snapshot: snapshot)
                            .frame(width: inspectorWidth)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .frame(height: workspaceHeight)

                bottomStatus(snapshot: snapshot, compact: isCompactHeight)
            }
            .padding(.horizontal, pagePadding)
            .padding(.top, pagePadding)
            .padding(.bottom, pagePadding + bottomBreathingRoom)
            .frame(
                width: availableSize.width,
                height: availableSize.height,
                alignment: .top
            )

        }
        .frame(
            width: availableSize.width,
            height: availableSize.height,
            alignment: .top
        )
        .clipped()
        .environment(\.colorScheme, .light)
    }

    private func metricsBar(
        snapshot: ConnectionsPresentationSnapshot,
        compact: Bool
    ) -> some View {
        let tcpCount = snapshot.rows.count { $0.protocolText.localizedCaseInsensitiveContains("TCP") }
        let udpCount = snapshot.rows.count { $0.protocolText.localizedCaseInsensitiveContains("UDP") }
        let selectedDuration = snapshot.inspector?.row.durationText

        return HStack(spacing: compact ? 8 : 14) {
            connectionMetric(
                VelaL10n.string("connections.metrics.total", defaultValue: "Total Connections"),
                runtimeMetric(snapshot.metrics.connectionCount.formatted()),
                subtitle: VelaL10n.string("connections.metrics.active", defaultValue: "Active"),
                systemImage: "person.2",
                tint: ConnectionsDesignTokens.mint,
                compact: compact
            )
            connectionMetric(
                VelaL10n.string("connections.metrics.downloaded", defaultValue: "Download"),
                runtimeMetric(snapshot.metrics.downloadText),
                subtitle: VelaL10n.string("connections.metrics.totalTraffic", defaultValue: "Total traffic"),
                systemImage: "arrow.down.circle",
                tint: ConnectionsDesignTokens.blue,
                compact: compact
            )
            connectionMetric(
                VelaL10n.string("connections.metrics.uploaded", defaultValue: "Upload"),
                runtimeMetric(snapshot.metrics.uploadText),
                subtitle: VelaL10n.string("connections.metrics.totalTraffic", defaultValue: "Total traffic"),
                systemImage: "arrow.up.circle",
                tint: ConnectionsDesignTokens.violet,
                compact: compact
            )
            connectionMetric(
                VelaL10n.string("connections.metrics.transport", defaultValue: "TCP / UDP"),
                runtimeMetric("\(tcpCount) / \(udpCount)"),
                subtitle: showsLiveMetrics
                    ? snapshot.metrics.memoryText.map {
                        VelaL10n.string(
                            "connections.metrics.memoryFormat",
                            defaultValue: "Memory %@",
                            arguments: $0
                        )
                    } ?? VelaL10n.string(
                        "connections.metrics.protocols",
                        defaultValue: "Active protocols"
                    )
                    : VelaRuntimeMetricPresentation.unavailable,
                systemImage: "square.3.layers.3d",
                tint: ConnectionsDesignTokens.blue,
                compact: compact
            )
            connectionMetric(
                VelaL10n.string("connections.metrics.established", defaultValue: "Established"),
                selectedDuration ?? "—",
                subtitle: selectedDuration == nil
                    ? VelaL10n.string(
                        "connections.metrics.noSelection",
                        defaultValue: "No selection"
                    )
                    : VelaL10n.string(
                        "connections.metrics.session",
                        defaultValue: "Selected session"
                    ),
                systemImage: "clock",
                tint: ConnectionsDesignTokens.violet,
                compact: compact
            )
        }
        .frame(height: compact ? 92 : 132)
        .accessibilityIdentifier("connections.metrics")
    }

    private func connectionMetric(
        _ label: String,
        _ value: String,
        subtitle: String,
        systemImage: String,
        tint: Color,
        compact: Bool
    ) -> some View {
        let accessorySymbol: String
        switch systemImage {
        case "person.2":
            accessorySymbol = "chart.line.uptrend.xyaxis"
        case "arrow.down.circle", "arrow.up.circle":
            accessorySymbol = "waveform.path.ecg"
        case "square.3.layers.3d":
            accessorySymbol = "chart.pie.fill"
        default:
            accessorySymbol = "circle.fill"
        }

        return ZStack(alignment: .bottomTrailing) {
            VStack(alignment: .leading, spacing: compact ? 5 : 8) {
                HStack(spacing: 7) {
                    Image(systemName: systemImage)
                        .font(.system(size: VelaTypeSize.table, weight: .medium))
                        .foregroundStyle(tint)
                    Text(label)
                        .font(VelaTypography.table.weight(.medium))
                        .foregroundStyle(ConnectionsDesignTokens.textSecondary)
                        .lineLimit(1)
                }

                Text(value)
                    .font(.system(size: compact ? 19 : 24, weight: .semibold, design: .rounded))
                    .foregroundStyle(ConnectionsDesignTokens.textPrimary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)

                Text(subtitle)
                    .font(VelaTypography.caption.weight(.medium))
                    .foregroundStyle(tint.opacity(0.92))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

            Image(systemName: accessorySymbol)
                .font(
                    .system(
                        size: accessorySymbol == "circle.fill"
                            ? (compact ? 8 : 10)
                            : (compact ? 18 : 24),
                        weight: .medium
                    )
                )
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint.opacity(accessorySymbol == "circle.fill" ? 0.88 : 0.55))
                .padding(.trailing, compact ? 9 : 12)
                .padding(.bottom, compact ? 8 : 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.horizontal, compact ? 11 : 15)
        .padding(.vertical, compact ? 9 : 13)
        .connectionsGlassSurface(radius: compact ? 14 : 16)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func phasePill(_ snapshot: ConnectionsPresentationSnapshot) -> some View {
        if snapshot.isPaused {
            VelaStatusPill(
                status: .pending,
                label: VelaL10n.string("connections.status.paused", defaultValue: "Paused")
            )
        } else {
            switch snapshot.phase {
            case .loaded:
                VelaStatusPill(
                    status: .success,
                    label: VelaL10n.string("connections.status.live", defaultValue: "Live")
                )
            case .refreshing, .pendingMutation, .loading:
                VelaStatusPill(
                    status: .pending,
                    label: VelaL10n.string("connections.status.updating", defaultValue: "Updating")
                )
            case .stale, .offlineWithSnapshot:
                VelaStatusPill(
                    status: .stale,
                    label: VelaL10n.string("connections.status.stale", defaultValue: "Stale")
                )
            case .partialFailure:
                VelaStatusPill(
                    status: .warning,
                    label: VelaL10n.string("connections.status.degraded", defaultValue: "Degraded")
                )
            case .empty:
                VelaStatusPill(
                    status: .neutral,
                    label: VelaL10n.string("connections.status.ready", defaultValue: "Ready")
                )
            case .failure, .offlineWithoutSnapshot:
                VelaStatusPill(
                    status: .neutral,
                    label: VelaL10n.string(
                        "connections.status.disconnected",
                        defaultValue: "Disconnected"
                    )
                )
            }
        }
    }

    private func pageHeader(
        model: Bindable<ConnectionsViewModel>,
        snapshot: ConnectionsPresentationSnapshot,
        compact: Bool
    ) -> some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: compact ? 2 : 5) {
                Text(VelaL10n.string("legacy.connections", defaultValue: "Connections"))
                    .font(VelaTypography.mainPageTitle)
                    .foregroundStyle(ConnectionsDesignTokens.textPrimary)
                Text(
                    VelaL10n.string(
                        "connections.subtitle",
                        defaultValue: "Real-time connection monitor"
                    )
                )
                .font(VelaTypography.pageSubtitle)
                .foregroundStyle(ConnectionsDesignTokens.textSecondary)
            }

            Spacer(minLength: 12)
            localToolbar(model: model, snapshot: snapshot, compact: compact)
        }
        .padding(.vertical, compact ? 4 : 8)
        .frame(minHeight: compact ? 64 : 80)
    }

    private func localToolbar(
        model: Bindable<ConnectionsViewModel>,
        snapshot: ConnectionsPresentationSnapshot,
        compact: Bool
    ) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            VelaLiquidGlassGroup(spacing: compact ? 7 : 9) {
                HStack(spacing: compact ? 7 : 9) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(ConnectionsDesignTokens.textSecondary)
                            .accessibilityHidden(true)

                        TextField(
                            VelaL10n.string(
                                compact
                                    ? "connections.search.compact"
                                    : "legacy.searchConnections",
                                defaultValue: compact ? "Search…" : "Search connections"
                            ),
                            text: model.searchText
                        )
                        .textFieldStyle(.plain)
                        .focused($isSearchFocused)
                        .accessibilityIdentifier("connections.search")
                    }
                    .padding(.horizontal, 12)
                    .frame(width: compact ? 170 : 266, height: compact ? 34 : 44)
                    .connectionsGlassSurface(radius: 12)

                    connectionFilters(model: model)
                        .frame(
                            minWidth: compact ? 92 : 106,
                            minHeight: compact ? 34 : 44
                        )
                        .connectionsGlassSurface(radius: 12)

                    Button {
                        Task { await viewModel.setPaused(!snapshot.isPaused) }
                    } label: {
                        Label(
                            snapshot.isPaused
                                ? VelaL10n.string(
                                    "legacy.resumeUiUpdates",
                                    defaultValue: "Resume UI Updates"
                                )
                                : VelaL10n.string(
                                    "legacy.pauseUiUpdates",
                                    defaultValue: "Pause UI Updates"
                                ),
                            systemImage: snapshot.isPaused ? "play.fill" : "pause.fill"
                        )
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(ConnectionsGlassIconButtonStyle(size: compact ? 34 : 44))
                    .disabled(!canTogglePause(snapshot))
                    .help(pauseActionHint(snapshot))
                    .accessibilityLabel(
                        snapshot.isPaused
                            ? VelaL10n.string(
                                "legacy.resumeUiUpdates",
                                defaultValue: "Resume UI Updates"
                            )
                            : VelaL10n.string(
                                "legacy.pauseUiUpdates",
                                defaultValue: "Pause UI Updates"
                            )
                    )
                    .accessibilityHint(pauseActionHint(snapshot))
                    .accessibilityIdentifier("connections.pause")

                    if !compact, !showsCanonicalReconnect(snapshot) {
                        Button {
                            Task { await viewModel.refreshSnapshot() }
                        } label: {
                            Label(
                                VelaL10n.string("legacy.refresh", defaultValue: "Refresh"),
                                systemImage: "arrow.clockwise"
                            )
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(ConnectionsGlassIconButtonStyle(size: compact ? 34 : 44))
                        .disabled(!snapshot.actions.canRefresh)
                        .accessibilityIdentifier("connections.refresh")
                    }

                    Button {
                        setInspectorPresented(!isInspectorPresented)
                    } label: {
                        Label(
                            isInspectorPresented
                                ? VelaL10n.string(
                                    "legacy.hideInspector",
                                    defaultValue: "Hide Inspector"
                                )
                                : VelaL10n.string(
                                    "legacy.showInspector",
                                    defaultValue: "Show Inspector"
                                ),
                            systemImage: "sidebar.trailing"
                        )
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(ConnectionsGlassIconButtonStyle(size: compact ? 34 : 44))
                    .accessibilityIdentifier("connections.inspector.toggle")
                }
            }

            Label(
                VelaL10n.string(
                    "connections.autoRefresh",
                    defaultValue: "Auto Refresh"
                ),
                systemImage: "arrow.clockwise.circle.fill"
            )
            .font(VelaTypography.caption.weight(.semibold))
            .foregroundStyle(ConnectionsDesignTokens.mint)
            .frame(maxHeight: .infinity, alignment: .center)
            .padding(.trailing, 2)
            .fixedSize(horizontal: true, vertical: false)
        }
        .frame(height: compact ? 56 : 64, alignment: .top)
        .controlSize(.regular)
        .font(VelaTypography.body)
    }

    private func connectionPanel(
        model: Bindable<ConnectionsViewModel>,
        snapshot: ConnectionsPresentationSnapshot,
        layout: ConnectionsLayoutMetrics,
        compact: Bool
    ) -> some View {
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                protocolSegmentBar(model: model)
                    .frame(width: compact ? 250 : 280)
                    .accessibilityIdentifier("connections.protocolFilter")

                Spacer(minLength: 8)

                if !compact {
                    Text(
                        VelaL10n.string(
                            "connections.countFormat",
                            defaultValue: "%lld connections",
                            arguments: Int64(snapshot.rows.count)
                        )
                    )
                    .font(VelaTypography.caption.weight(.medium))
                    .foregroundStyle(ConnectionsDesignTokens.textSecondary)
                }

                connectionSort(model: model)
                    .frame(height: 30)
            }
            .padding(.horizontal, compact ? 12 : 16)
            .frame(height: compact ? 42 : 50)

            Rectangle()
                .fill(ConnectionsDesignTokens.divider)
                .frame(height: 1)

            connectionTable(model: model, snapshot: snapshot, layout: layout)
        }
        .connectionsGlassSurface(radius: compact ? 16 : 20)
    }

    private func protocolSegmentBar(model: Bindable<ConnectionsViewModel>) -> some View {
        let blockedFilterSentinel = "__vela_blocked__"
        let items: [(id: String, label: String)] = [
            ("all", VelaL10n.string("legacy.all", defaultValue: "All")),
            ("tcp", "TCP"),
            ("udp", "UDP"),
            (
                "blocked",
                VelaL10n.string(
                    "connections.filter.blocked",
                    defaultValue: "Blocked"
                )
            ),
        ]

        return HStack(spacing: 0) {
            ForEach(items, id: \.id) { item in
                let isSelected = switch item.id {
                case "tcp":
                    model.wrappedValue.networkFilter?.caseInsensitiveCompare("tcp") == .orderedSame
                        && model.wrappedValue.ruleFilter != blockedFilterSentinel
                case "udp":
                    model.wrappedValue.networkFilter?.caseInsensitiveCompare("udp") == .orderedSame
                        && model.wrappedValue.ruleFilter != blockedFilterSentinel
                case "blocked":
                    model.wrappedValue.ruleFilter == blockedFilterSentinel
                default:
                    model.wrappedValue.networkFilter == nil
                        && model.wrappedValue.protocolFilter == nil
                        && model.wrappedValue.ruleFilter != blockedFilterSentinel
                }
                Button {
                    model.wrappedValue.protocolFilter = nil
                    switch item.id {
                    case "tcp", "udp":
                        model.wrappedValue.networkFilter = item.id
                        if model.wrappedValue.ruleFilter == blockedFilterSentinel {
                            model.wrappedValue.ruleFilter = nil
                        }
                    case "blocked":
                        model.wrappedValue.networkFilter = nil
                        model.wrappedValue.ruleFilter = blockedFilterSentinel
                    default:
                        model.wrappedValue.networkFilter = nil
                        if model.wrappedValue.ruleFilter == blockedFilterSentinel {
                            model.wrappedValue.ruleFilter = nil
                        }
                    }
                } label: {
                    Text(item.label)
                    .font(VelaTypography.caption.weight(isSelected ? .semibold : .medium))
                    .foregroundStyle(
                        isSelected
                            ? ConnectionsDesignTokens.textPrimary
                            : ConnectionsDesignTokens.textSecondary
                    )
                    .frame(maxWidth: .infinity, minHeight: 28)
                    .background(
                        isSelected
                            ? ConnectionsDesignTokens.proxyFill.opacity(0.88)
                            : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.label)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(
            Color(red: 116 / 255, green: 138 / 255, blue: 158 / 255).opacity(0.07),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            VelaL10n.string("legacy.protocol", defaultValue: "Protocol")
        )
        .accessibilityIdentifier("connections.protocolFilter")
    }

    private func bottomStatus(
        snapshot: ConnectionsPresentationSnapshot,
        compact: Bool
    ) -> some View {
        HStack(spacing: compact ? 12 : 18) {
            VStack(alignment: .leading, spacing: 2) {
                Text(runtimeMetric(snapshot.metrics.connectionCount.formatted()))
                    .font(.system(size: compact ? 17 : 20, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(VelaL10n.string("connections.metrics.total", defaultValue: "Total Connections"))
                    .font(VelaTypography.caption.weight(.medium))
                    .foregroundStyle(ConnectionsDesignTokens.textSecondary)
            }

            Rectangle()
                .fill(ConnectionsDesignTokens.divider)
                .frame(width: 1, height: compact ? 26 : 34)

            HStack(spacing: 7) {
                Circle()
                    .fill(snapshot.isPaused ? ConnectionsDesignTokens.warning : ConnectionsDesignTokens.mint)
                    .frame(width: 7, height: 7)
                phasePill(snapshot)
                if let refreshed = snapshot.lastSuccessfulRefreshAt {
                    Text(
                        VelaL10n.string(
                            "connections.lastUpdatedFormat",
                            defaultValue: "Last updated %@",
                            arguments: refreshed.formatted(date: .omitted, time: .standard)
                        )
                    )
                    .font(VelaTypography.caption)
                    .foregroundStyle(ConnectionsDesignTokens.textSecondary)
                }
            }

            Spacer(minLength: 10)

            Button(role: .destructive) {
                isCloseAllConfirmationPresented = true
            } label: {
                Label(
                    VelaL10n.string("legacy.disconnectAll", defaultValue: "Disconnect All"),
                    systemImage: "xmark.circle"
                )
            }
            .buttonStyle(.plain)
            .font(VelaTypography.caption.weight(.medium))
            .foregroundStyle(ConnectionsDesignTokens.danger)
            .disabled(!snapshot.actions.canCloseAll)
            .help(closeAllActionHint(snapshot))
            .accessibilityHint(closeAllActionHint(snapshot))
            .accessibilityIdentifier("connections.closeAll")
        }
        .padding(.horizontal, compact ? 14 : 18)
        .frame(height: compact ? 46 : 58)
        .connectionsGlassSurface(radius: compact ? 14 : 17)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func runtimeMetric(_ value: String) -> String {
        VelaRuntimeMetricPresentation.value(value, isAvailable: showsLiveMetrics)
    }

    private func connectionTable(
        model: Bindable<ConnectionsViewModel>,
        snapshot: ConnectionsPresentationSnapshot,
        layout: ConnectionsLayoutMetrics
    ) -> some View {
        VStack(spacing: 0) {
            connectionListHeader(layout: layout)

            Rectangle()
                .fill(ConnectionsDesignTokens.divider)
                .frame(height: 1)

            List(snapshot.rows, selection: model.selectedConnectionID) { row in
                connectionListRow(row, layout: layout)
                    .tag(row.id)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparatorTint(ConnectionsDesignTokens.divider)
                    .listRowBackground(
                        row.id == snapshot.selectedConnectionID
                            ? ConnectionsDesignTokens.selectedRow
                            : Color.clear
                    )
                    .contextMenu {
                        if snapshot.actions.canCloseSelected,
                           snapshot.selectedConnectionID == row.id
                        {
                            Button(
                                VelaL10n.string(
                                    "legacy.disconnectConnection",
                                    defaultValue: "Disconnect Connection"
                                ),
                                role: .destructive
                            ) {
                                Task { await viewModel.closeConnection(id: row.id) }
                            }
                        }
                    }
                    .onTapGesture(count: 2) {
                        model.wrappedValue.selectedConnectionID = row.id
                        setInspectorPresented(true)
                    }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, ConnectionsDesignTokens.rowHeight)
        }
        .accessibilityIdentifier("connections.table")
        .overlay {
            if snapshot.rows.isEmpty {
                connectionEmptyState(model: model, snapshot: snapshot)
            }
        }
#if DEBUG
        .overlay(alignment: .topLeading) {
            VisualSurfaceMarker(
                identifier: "connections.columns.\(layout.columnSet.rawValue)",
                label: String(
                    format: VelaL10n.string(
                        "connections.accessibility.columnsFormat",
                        defaultValue: "Connections %@ columns"
                    ),
                    layout.columnSet.rawValue
                )
            )
        }
#endif
    }

    private func connectionListHeader(
        layout: ConnectionsLayoutMetrics
    ) -> some View {
        let isSpacious = layout.columnSet == .spacious

        return HStack(spacing: isSpacious ? 4 : ConnectionsDesignTokens.columnSpacing) {
            Text(VelaL10n.string("connections.column.process", defaultValue: "Process"))
                .frame(minWidth: isSpacious ? 112 : 150, maxWidth: .infinity, alignment: .leading)

            if isSpacious {
                Text(VelaL10n.string("connections.column.destination", defaultValue: "Destination"))
                    .frame(width: 98, alignment: .leading)
                Text(
                    VelaL10n.string(
                        "connections.column.destinationIP",
                        defaultValue: "Destination IP"
                    )
                )
                .frame(width: 82, alignment: .leading)
            }

            Text(VelaL10n.string("legacy.proxy", defaultValue: "Proxy / Direct"))
                .frame(
                    width: isSpacious ? 70 : (layout.columnSet == .compact ? 78 : 96),
                    alignment: .leading
                )

            if layout.columnSet != .compact {
                Text(VelaL10n.string("legacy.protocol", defaultValue: "Protocol"))
                    .frame(width: isSpacious ? 46 : 72, alignment: .leading)
            }

            Text(VelaL10n.string("legacy.down", defaultValue: "Down"))
                .frame(width: isSpacious ? 48 : 72, alignment: .trailing)

            if isSpacious {
                Text(VelaL10n.string("legacy.up", defaultValue: "Up"))
                    .frame(width: 48, alignment: .trailing)
            }

            Text(VelaL10n.string("legacy.duration", defaultValue: "Duration"))
                .frame(width: isSpacious ? 54 : 72, alignment: .trailing)

            Text(VelaL10n.string("connections.column.status", defaultValue: "Status"))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .frame(width: isSpacious ? 30 : 38, alignment: .center)
        }
        .font(VelaTypography.caption.weight(.semibold))
        .foregroundStyle(ConnectionsDesignTokens.textSecondary)
        .lineLimit(1)
        .minimumScaleFactor(0.82)
        .padding(.horizontal, isSpacious ? 8 : 14)
        .frame(height: 36)
    }

    private func connectionListRow(
        _ row: ConnectionRowModel,
        layout: ConnectionsLayoutMetrics
    ) -> some View {
        let isSpacious = layout.columnSet == .spacious

        return HStack(spacing: isSpacious ? 4 : ConnectionsDesignTokens.columnSpacing) {
            HStack(spacing: 9) {
                ConnectionApplicationIcon(row: row, size: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.application)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(ConnectionsDesignTokens.textPrimary)
                    Text(row.process)
                        .font(VelaTypography.caption)
                        .foregroundStyle(ConnectionsDesignTokens.textSecondary)
                }
                .lineLimit(1)
            }
            .frame(minWidth: isSpacious ? 112 : 150, maxWidth: .infinity, alignment: .leading)

            if isSpacious {
                Text(row.host)
                    .font(VelaTypography.caption.weight(.medium))
                    .foregroundStyle(ConnectionsDesignTokens.textPrimary)
                    .lineLimit(1)
                    .frame(width: 98, alignment: .leading)

                Text(row.destinationIP)
                    .font(.system(size: VelaTypeSize.caption, weight: .regular, design: .monospaced))
                    .foregroundStyle(ConnectionsDesignTokens.textSecondary)
                    .lineLimit(1)
                    .frame(width: 82, alignment: .leading)
            }

            Text(row.proxy)
                .font(VelaTypography.caption.weight(.medium))
                .foregroundStyle(ConnectionsDesignTokens.proxyText)
                .lineLimit(1)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(ConnectionsDesignTokens.proxyFill, in: Capsule())
                .frame(
                    width: isSpacious ? 70 : (layout.columnSet == .compact ? 78 : 96),
                    alignment: .leading
                )
                .help(row.chain)

            if layout.columnSet != .compact {
                Text(row.network.uppercased())
                    .font(VelaTypography.caption.weight(.medium))
                    .foregroundStyle(ConnectionsDesignTokens.textSecondary)
                    .lineLimit(1)
                    .frame(width: isSpacious ? 46 : 72, alignment: .leading)
            }

            Text(row.downloadText)
                .font(.system(size: VelaTypeSize.caption, weight: .medium, design: .monospaced))
                .foregroundStyle(ConnectionsDesignTokens.mint)
                .lineLimit(1)
                .frame(width: isSpacious ? 48 : 72, alignment: .trailing)

            if isSpacious {
                Text(row.uploadText)
                    .font(.system(size: VelaTypeSize.caption, weight: .medium, design: .monospaced))
                    .foregroundStyle(ConnectionsDesignTokens.violet)
                    .lineLimit(1)
                    .frame(width: 48, alignment: .trailing)
            }

            Text(row.durationText)
                .font(.system(size: VelaTypeSize.caption, weight: .medium, design: .monospaced))
                .foregroundStyle(ConnectionsDesignTokens.textPrimary)
                .lineLimit(1)
                .frame(width: isSpacious ? 54 : 72, alignment: .trailing)

            Circle()
                .fill(ConnectionsDesignTokens.mint)
                .frame(width: 7, height: 7)
                .shadow(color: ConnectionsDesignTokens.mint.opacity(0.28), radius: 4)
                .frame(width: isSpacious ? 30 : 38)
                .accessibilityLabel(
                    VelaL10n.string("connections.status.established", defaultValue: "Established")
                )
        }
        .padding(.horizontal, isSpacious ? 8 : 14)
        .frame(height: ConnectionsDesignTokens.rowHeight)
        .contentShape(.rect)
        .accessibilityIdentifier("connections.row.\(row.id)")
    }

    @ViewBuilder
    private func connectionEmptyState(
        model: Bindable<ConnectionsViewModel>,
        snapshot: ConnectionsPresentationSnapshot
    ) -> some View {
        let query = model.wrappedValue.searchText.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let isFiltered = !query.isEmpty || model.wrappedValue.hasActiveFilters

        if snapshot.phase == .loading {
            VelaLoadingState(
                title: VelaL10n.string(
                    "connections.phase.loading.title",
                    defaultValue: "Loading Connections"
                )
            )
        } else if isFiltered, model.wrappedValue.snapshot.connections.isEmpty == false {
            VelaEmptyState(
                title: VelaL10n.string(
                    "connections.empty.filtered.title",
                    defaultValue: "No Matching Connections"
                ),
                description: VelaL10n.string(
                    "connections.empty.filtered.description",
                    defaultValue: "Adjust the search or clear filters to show the current connection snapshot."
                ),
                systemImage: "line.3.horizontal.decrease.circle"
            ) {
                Button(VelaL10n.string("legacy.clearFilters", defaultValue: "Clear Filters")) {
                    model.wrappedValue.searchText = ""
                    viewModel.clearFilters()
                }
                .velaEmptyStateAction()
                .buttonStyle(.bordered)
            }
        } else if snapshot.phase == .empty {
            VelaEmptyState(
                title: VelaL10n.string(
                    "connections.empty.live.title",
                    defaultValue: "No Active Connections"
                ),
                description: VelaL10n.string(
                    "connections.empty.live.description",
                    defaultValue: "The live table is ready. New connections will appear automatically."
                ),
                systemImage: "network"
            )
        } else if snapshot.phase == .failure {
            VelaEmptyState(
                title: VelaL10n.string(
                    "connections.error.title",
                    defaultValue: "Connections Unavailable"
                ),
                description: snapshot.lastError.map(errorDescription) ?? VelaL10n.string(
                    "connections.phase.failure.detail",
                    defaultValue: "Vela could not load a connection snapshot."
                ),
                systemImage: "exclamationmark.triangle"
            ) {
                Button(VelaL10n.string("legacy.tryAgain", defaultValue: "Try Again")) {
                    Task { await viewModel.refreshSnapshot() }
                }
                .velaEmptyStateAction()
                .buttonStyle(.borderedProminent)
            }
        } else {
            VelaEmptyState(
                title: VelaL10n.string(
                    "connections.empty.offline.title",
                    defaultValue: "Controller Disconnected"
                ),
                description: VelaL10n.string(
                    "connections.empty.offline.description",
                    defaultValue: "The table and inspector remain ready. Start Mihomo or refresh after the controller reconnects."
                ),
                systemImage: "wifi.slash"
            ) {
                PageRecoveryActions(
                    primaryTitle: VelaL10n.string(
                        "legacy.reconnect",
                        defaultValue: "Reconnect"
                    ),
                    pendingTitle: VelaL10n.string(
                        "connections.action.reconnecting",
                        defaultValue: "Reconnecting…"
                    ),
                    primarySystemImage: "arrow.clockwise",
                    isPending: isReconnectPending,
                    isPrimaryEnabled: snapshot.actions.canRefresh,
                    primaryMinimumWidth: PageRecoveryActionMetrics.compactContentMinimumWidth,
                    primaryAccessibilityIdentifier: "connections.reconnect",
                    primaryAccessibilityHint: VelaL10n.string(
                        "connections.action.reconnect.hint",
                        defaultValue: "Request a new connection snapshot from the Controller."
                    ),
                    primaryAccessibilityValue: reconnectAttemptAccessibilityValue,
                    primaryAction: startReconnect,
                    secondaryAction: PageRecoveryActions.SecondaryAction(
                        title: VelaL10n.string(
                            "legacy.openDiagnostics",
                            defaultValue: "Open Diagnostics"
                        ),
                        systemImage: "chevron.right",
                        accessibilityIdentifier: "connections.openDiagnostics",
                        accessibilityHint: VelaL10n.string(
                            "connections.action.openDiagnostics.hint",
                            defaultValue: "Open guided checks for the disconnected Controller."
                        ),
                        action: {
                            SettingsMainNavigationRequest.navigateInCurrentWindow(.diagnostics)
                        }
                    )
                )
            }
#if DEBUG
            .overlay(alignment: .topLeading) {
                VisualReadyMarker(fixtureID: "connections.offline")
            }
#endif
        }
    }

    private func connectionInspector(
        snapshot: ConnectionsPresentationSnapshot
    ) -> some View {
        Group {
            if let inspector = snapshot.inspector {
                ConnectionInspector(
                    snapshot: inspector,
                    canClose: snapshot.actions.canCloseSelected,
                    copyRedactedSummary: { copyRedactedSummary(inspector) },
                    close: {
                        Task { await viewModel.closeConnection(id: inspector.id) }
                    },
                    dismiss: {
                        setInspectorPresented(false)
                    }
                )
            } else {
                VStack(spacing: 0) {
                    HStack {
                        Text(
                            VelaL10n.string(
                                "connections.inspector.title",
                                defaultValue: "Connection Details"
                            )
                        )
                        .font(.system(size: 14, weight: .semibold))
                        Spacer()
                        Button {
                            setInspectorPresented(false)
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 48)

                    Rectangle()
                        .fill(ConnectionsDesignTokens.divider)
                        .frame(height: 1)

                    VelaEmptyState(
                        title: VelaL10n.string(
                            "connections.inspector.empty.title",
                            defaultValue: "Connection Inspector"
                        ),
                        description: snapshot.rows.isEmpty
                            ? VelaL10n.string(
                                "connections.inspector.empty.noData.description",
                                defaultValue: "Connection summary and route evidence will appear here when data becomes available."
                            )
                            : VelaL10n.string(
                                "connections.inspector.empty.selection.description",
                                defaultValue: "Select a row to inspect endpoints, transfer totals, and why Mihomo chose its route."
                            ),
                        systemImage: "sidebar.right"
                    )
                    .accessibilityIdentifier("connections.inspector.empty")
                }
            }
        }
        .frame(maxHeight: .infinity)
        .connectionsGlassSurface(radius: 20, emphasized: true)
    }

    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
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
            .help(
                isInspectorPresented
                    ? VelaL10n.string(
                        "legacy.hideTheConnectionInspector",
                        defaultValue: "Hide the connection inspector"
                    )
                    : VelaL10n.string(
                        "legacy.showTheConnectionInspector",
                        defaultValue: "Show the connection inspector"
                    )
            )
            .accessibilityIdentifier("connections.inspector.toggle")
            .buttonStyle(.borderless)
            .controlSize(.regular)
        }
    }

    private func startReconnect() {
        let snapshot = viewModel.presentation
        guard showsCanonicalReconnect(snapshot),
              snapshot.actions.canRefresh,
              !isReconnectPending,
              !viewModel.isRefreshing
        else {
            return
        }

        isReconnectPending = true
#if DEBUG
        reconnectAttemptCount += 1
#endif
        Task { @MainActor in
            let minimumFeedback = Task {
                try? await Task.sleep(for: .milliseconds(750))
            }
            await viewModel.refreshSnapshot()
            await minimumFeedback.value
            isReconnectPending = false
        }
    }

    private var reconnectAttemptAccessibilityValue: String? {
#if DEBUG
        reconnectAttemptCount.formatted()
#else
        nil
#endif
    }

    private func showsCanonicalReconnect(
        _ snapshot: ConnectionsPresentationSnapshot
    ) -> Bool {
        snapshot.phase == .offlineWithoutSnapshot
    }

    private func canTogglePause(
        _ snapshot: ConnectionsPresentationSnapshot
    ) -> Bool {
        snapshot.phase != .offlineWithSnapshot
            && snapshot.phase != .offlineWithoutSnapshot
    }

    private func pauseActionHint(
        _ snapshot: ConnectionsPresentationSnapshot
    ) -> String {
        if !canTogglePause(snapshot) {
            return VelaL10n.string(
                "connections.action.pause.disabled.offline",
                defaultValue: "Unavailable while the Controller is disconnected."
            )
        }
        return snapshot.isPaused
            ? VelaL10n.string(
                "connections.action.resume.hint",
                defaultValue: "Resume live connection table updates."
            )
            : VelaL10n.string(
                "connections.action.pause.hint",
                defaultValue: "Pause live connection table updates."
            )
    }

    private func closeAllActionHint(
        _ snapshot: ConnectionsPresentationSnapshot
    ) -> String {
        if snapshot.actions.canCloseAll {
            return VelaL10n.string(
                "connections.action.closeAll.hint",
                defaultValue: "Disconnect every active connection."
            )
        }
        return VelaL10n.string(
            "connections.action.closeAll.disabled",
            defaultValue: "Available only when active connections can be safely disconnected."
        )
    }

    private var inspectorBinding: Binding<Bool> {
        Binding(
            get: { isInspectorPresented },
            set: { isPresented in
                setInspectorPresented(isPresented)
            }
        )
    }

    private func setInspectorPresented(_ isPresented: Bool) {
        guard isInspectorPresented != isPresented else { return }

        retainedColumnSet = ConnectionsLayoutMetrics.resolve(
            detailWidth: lastWorkspaceWidth,
            tableAvailableWidth: lastWorkspaceWidth
        ).columnSet
        inspectorTransitionGeneration &+= 1
        let generation = inspectorTransitionGeneration

        withAnimation(
            VelaMotion.animation(VelaMotion.slowSeconds, reduceMotion: reduceMotion)
        ) {
            isInspectorPresented = isPresented
        }

        guard !reduceMotion else {
            retainedColumnSet = nil
            return
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(VelaMotion.slowSeconds))
            guard generation == inspectorTransitionGeneration else { return }
            retainedColumnSet = nil
        }
    }

    private func connectionFilters(
        model: Bindable<ConnectionsViewModel>
    ) -> some View {
        Menu {
            filterPicker(
                VelaL10n.string("connections.filter.network", defaultValue: "Network"),
                selection: model.networkFilter,
                values: model.wrappedValue.availableNetworks
            )
            filterPicker(
                VelaL10n.string("connections.filter.process", defaultValue: "Process"),
                selection: model.processFilter,
                values: model.wrappedValue.availableProcesses
            )
            filterPicker(
                VelaL10n.string("connections.filter.rule", defaultValue: "Rule"),
                selection: model.ruleFilter,
                values: model.wrappedValue.availableRules
            )
            Divider()
            Button(VelaL10n.string("legacy.clearFilters", defaultValue: "Clear Filters")) {
                viewModel.clearFilters()
            }
            .disabled(!model.wrappedValue.hasActiveFilters)
        } label: {
            Label(
                model.wrappedValue.hasActiveFilters
                    ? VelaL10n.string("legacy.filtersActive", defaultValue: "Filters Active")
                    : VelaL10n.string("connections.filter.label", defaultValue: "Filter"),
                systemImage: "line.3.horizontal.decrease"
            )
        }
        .menuStyle(.borderlessButton)
        .labelStyle(.titleAndIcon)
    }

    private func connectionSort(
        model: Bindable<ConnectionsViewModel>
    ) -> some View {
        Menu {
            Picker(
                VelaL10n.string("legacy.sortBy", defaultValue: "Sort By"),
                selection: model.sortField
            ) {
                ForEach(ConnectionSortField.allCases) { field in
                    Text(field.title).tag(field)
                }
            }
            Divider()
            Picker(
                VelaL10n.string("legacy.direction", defaultValue: "Direction"),
                selection: model.sortAscending
            ) {
                Text(VelaL10n.string("legacy.ascending", defaultValue: "Ascending")).tag(true)
                Text(VelaL10n.string("legacy.descending", defaultValue: "Descending")).tag(false)
            }
        } label: {
            Label(
                VelaL10n.string("legacy.sort", defaultValue: "Sort"),
                systemImage: "arrow.up.arrow.down"
            )
        }
    }

    private func filterPicker(
        _ title: String,
        selection: Binding<String?>,
        values: [String]
    ) -> some View {
        Picker(title, selection: selection) {
            Text(
                VelaL10n.string(
                    "legacy.allSObjectFormat",
                    defaultValue: "All %@s",
                    arguments: title
                )
            )
            .tag(String?.none)
            ForEach(values, id: \.self) { value in
                Text(value).tag(Optional(value))
            }
        }
    }

    private func copyRedactedSummary(_ inspector: ConnectionInspectorSnapshot) {
        let row = inspector.row
        let text = [
            "connection=\(row.id)",
            "protocol=\(row.protocolText)",
            "rule=\(row.rule)",
            "proxy=\(row.proxy)",
            "outbound=\(row.finalOutbound)",
            "upload=\(row.uploadText)",
            "download=\(row.downloadText)",
            "duration=\(row.durationText)",
            "evidence=\(inspector.evidenceConfidence)",
        ].joined(separator: "\n")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func errorDescription(_ error: ConnectionsFailure) -> String {
        switch error {
        case .invalidControllerURL:
            VelaL10n.string(
                "connections.error.invalidControllerURL",
                defaultValue: "The Controller connections URL is invalid."
            )
        case .streamUnavailable:
            VelaL10n.string(
                "connections.error.streamUnavailable",
                defaultValue: "The live stream is unavailable. Refresh after the Controller reconnects."
            )
        case .snapshotDecodeFailed:
            VelaL10n.string(
                "connections.error.snapshotDecodeFailed",
                defaultValue: "Mihomo returned a connections snapshot Vela could not read."
            )
        case .closeFailed:
            VelaL10n.string(
                "connections.error.closeFailed",
                defaultValue: "The selected connection could not be disconnected."
            )
        case .closeAllFailed:
            VelaL10n.string(
                "connections.error.closeAllFailed",
                defaultValue: "Mihomo did not confirm that all connections were disconnected."
            )
        case .closeConfirmationTimedOut:
            VelaL10n.string(
                "connections.error.closeConfirmationTimedOut",
                defaultValue: "The disconnect request completed, but confirmation timed out. Refresh to verify the result."
            )
        }
    }
}

private struct ConnectionInspector: View {
    let snapshot: ConnectionInspectorSnapshot
    let canClose: Bool
    let copyRedactedSummary: () -> Void
    let close: () -> Void
    let dismiss: () -> Void

    private var row: ConnectionRowModel { snapshot.row }
    private var routeEvidence: ConnectionRouteEvidencePresentation {
        ConnectionRouteEvidencePresentation(confidence: snapshot.evidenceConfidence)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle()
                .fill(ConnectionsDesignTokens.divider)
                .frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    applicationCard
                    connectionInformation
                    transfer
                    routingEvidence
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
                .textSelection(.enabled)
            }
            .accessibilityIdentifier("connections.inspector.scroll")

            Rectangle()
                .fill(ConnectionsDesignTokens.divider)
                .frame(height: 1)
            actions
        }
#if DEBUG
        .overlay(alignment: .topLeading) {
            VisualSurfaceMarker(
                identifier: "connections.inspector.selected",
                label: VelaL10n.string(
                    "connections.accessibility.selectedInspector",
                    defaultValue: "Selected connection inspector"
                )
            )
        }
#endif
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text(
                VelaL10n.string(
                    "connections.inspector.title",
                    defaultValue: "Connection Details"
                )
            )
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(ConnectionsDesignTokens.textPrimary)

            Spacer()

            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ConnectionsDesignTokens.textSecondary)
                    .frame(width: 28, height: 28)
                    .background(Color.white.opacity(0.54), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                VelaL10n.string("legacy.hideInspector", defaultValue: "Hide Inspector")
            )
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
    }

    private var applicationCard: some View {
        HStack(spacing: 12) {
            ConnectionApplicationIcon(row: row, size: 40)

            VStack(alignment: .leading, spacing: 3) {
                Text(row.application)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(ConnectionsDesignTokens.textPrimary)
                Text(row.destination)
                    .font(.system(size: VelaTypeSize.caption, weight: .medium, design: .monospaced))
                    .foregroundStyle(ConnectionsDesignTokens.textSecondary)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Circle()
                        .fill(ConnectionsDesignTokens.mint)
                        .frame(width: 6, height: 6)
                    Text(
                        VelaL10n.string(
                            "connections.status.established",
                            defaultValue: "Established"
                        )
                    )
                    .font(VelaTypography.caption.weight(.semibold))
                    .foregroundStyle(ConnectionsDesignTokens.mint)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .connectionsGlassSurface(radius: 14)
        .padding(.top, 14)
        .padding(.bottom, 2)
    }

    private var connectionInformation: some View {
        ConnectionInspectorSection(
            title: VelaL10n.string(
                "connections.inspector.information.title",
                defaultValue: "Connection Information"
            ),
            subtitle: VelaL10n.string(
                "connections.inspector.summary.subtitle",
                defaultValue: "Live endpoint and process metadata"
            )
        ) {
            detail(
                VelaL10n.string("connections.inspector.field.destination", defaultValue: "Destination"),
                row.destination
            )
            detail(
                VelaL10n.string("connections.inspector.field.process", defaultValue: "Process"),
                row.process
            )
            sensitiveDetail(
                VelaL10n.string("connections.inspector.field.source", defaultValue: "Source"),
                row.source
            )
            sensitiveDetail(
                VelaL10n.string("connections.inspector.field.processPath", defaultValue: "Process Path"),
                row.connection.metadata.processPath
            )
            detail(
                VelaL10n.string("connections.inspector.field.inbound", defaultValue: "Inbound"),
                row.inbound
            )
            detail(
                VelaL10n.string("connections.inspector.field.protocol", defaultValue: "Protocol"),
                row.protocolText
            )
            detail(VelaL10n.string("legacy.started", defaultValue: "Started"), row.startedAtText)
            detail(VelaL10n.string("legacy.duration", defaultValue: "Duration"), row.durationText)
        }
    }

    private var transfer: some View {
        ConnectionInspectorSection(
            title: VelaL10n.string(
                "connections.inspector.transfer.title",
                defaultValue: "Traffic"
            )
        ) {
            detail(
                VelaL10n.string("legacy.uploaded", defaultValue: "Uploaded"),
                row.uploadText
            )
            detail(
                VelaL10n.string("legacy.downloaded", defaultValue: "Downloaded"),
                row.downloadText
            )
        }
    }

    private var routingEvidence: some View {
        ConnectionInspectorSection(
            title: VelaL10n.string(
                "connections.inspector.route.title",
                defaultValue: "Why This Route?"
            ),
            subtitle: VelaL10n.string(
                "connections.inspector.route.subtitle",
                defaultValue: "Runtime evidence reported by Mihomo"
            ),
            help: VelaL10n.string(
                "connections.inspector.route.help",
                defaultValue: "Vela displays Mihomo evidence and does not claim an offline route prediction."
            )
        ) {
            VelaStatusPill(
                status: routeEvidence.semanticStatus,
                label: routeEvidence.localizedLabel
            )
            detail(
                VelaL10n.string("connections.inspector.field.rule", defaultValue: "Rule"),
                row.rule
            )
            detail(
                VelaL10n.string("connections.inspector.field.rulePayload", defaultValue: "Rule Payload"),
                row.rulePayload
            )
            detail(
                VelaL10n.string("connections.inspector.field.proxy", defaultValue: "Selected Proxy"),
                row.proxy
            )
            detail(
                VelaL10n.string("connections.inspector.field.finalOutbound", defaultValue: "Final Outbound"),
                row.finalOutbound
            )
            detail(
                VelaL10n.string("connections.inspector.field.proxyChain", defaultValue: "Proxy Chain"),
                row.chain
            )
            detail(
                VelaL10n.string("connections.inspector.field.providerChain", defaultValue: "Provider Chain"),
                row.providerChain
            )
            detail(
                VelaL10n.string("connections.inspector.field.ruleIndex", defaultValue: "Runtime Rule Index"),
                VelaL10n.string("connections.value.unavailable", defaultValue: "Unavailable")
            )
            detail(
                VelaL10n.string("connections.inspector.field.ruleSource", defaultValue: "Rule Source"),
                VelaL10n.string("connections.value.unavailable", defaultValue: "Unavailable")
            )
        }
    }

    private var actions: some View {
        VStack(spacing: 9) {
            if let mutation = snapshot.pendingMutation {
                Label(
                    VelaL10n.string(
                        "connections.inspector.pending.target",
                        defaultValue: "Updating %@",
                        arguments: mutation.targetConnectionID
                    ),
                    systemImage: "progress.indicator"
                )
                .foregroundStyle(.secondary)
            }

            Button(
                VelaL10n.string(
                    "connections.inspector.closeConnection",
                    defaultValue: "Close Connection"
                ),
                systemImage: "xmark.circle",
                role: .destructive,
                action: close
            )
            .buttonStyle(.plain)
            .font(VelaTypography.caption.weight(.semibold))
            .foregroundStyle(ConnectionsDesignTokens.danger)
            .frame(maxWidth: .infinity, minHeight: 34)
            .background(ConnectionsDesignTokens.danger.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
            .disabled(!canClose)
            .accessibilityIdentifier("connections.inspector.disconnect")

            Button(
                VelaL10n.string(
                    "connections.inspector.copyRedactedSummary",
                    defaultValue: "Copy Redacted Summary"
                ),
                systemImage: "doc.on.doc",
                action: copyRedactedSummary
            )
            .buttonStyle(.plain)
            .font(VelaTypography.caption.weight(.medium))
            .foregroundStyle(ConnectionsDesignTokens.textPrimary)
            .frame(maxWidth: .infinity, minHeight: 32)
            .background(Color.white.opacity(0.42), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityIdentifier("connections.inspector.copyRedacted")
        }
        .padding(12)
    }

    @ViewBuilder
    private func detail(_ title: String, _ value: String?) -> some View {
        if let value, !value.isEmpty, value != "—" {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(VelaTypography.caption)
                    .foregroundStyle(ConnectionsDesignTokens.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(width: 74, alignment: .leading)

                Text(value)
                    .font(VelaTypography.caption.weight(.medium))
                    .foregroundStyle(ConnectionsDesignTokens.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .help(value)
            }
            .frame(minHeight: 22)
        }
    }

    @ViewBuilder
    private func sensitiveDetail(_ title: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(VelaTypography.caption)
                    .foregroundStyle(ConnectionsDesignTokens.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(width: 74, alignment: .leading)

                VelaSensitiveText(value: value)
                    .font(VelaTypography.caption.weight(.medium))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .frame(minHeight: 22)
        }
    }
}

private struct ConnectionInspectorSection<Content: View>: View {
    let title: String
    var subtitle: String?
    var help: String?
    private let content: Content

    init(
        title: String,
        subtitle: String? = nil,
        help: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.help = help
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(ConnectionsDesignTokens.textPrimary)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(VelaTypography.caption)
                            .foregroundStyle(ConnectionsDesignTokens.textSecondary)
                            .lineLimit(1)
                    }
                }

                if let help, !help.isEmpty {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 9))
                        .foregroundStyle(ConnectionsDesignTokens.textSecondary)
                        .help(help)
                }

                Spacer(minLength: 4)
            }

            VStack(alignment: .leading, spacing: 3) {
                content
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(ConnectionsDesignTokens.divider)
                .frame(height: 1)
        }
    }
}

private enum ConnectionsDesignTokens {
    static let textPrimary = Color(red: 22 / 255, green: 28 / 255, blue: 35 / 255)
    static let textSecondary = Color(red: 93 / 255, green: 107 / 255, blue: 124 / 255)
    static let mint = Color(red: 38 / 255, green: 194 / 255, blue: 145 / 255)
    static let blue = Color(red: 38 / 255, green: 139 / 255, blue: 1)
    static let violet = Color(red: 139 / 255, green: 87 / 255, blue: 1)
    static let warning = Color(red: 229 / 255, green: 157 / 255, blue: 56 / 255)
    static let danger = Color(red: 229 / 255, green: 69 / 255, blue: 76 / 255)
    static let proxyText = Color(red: 25 / 255, green: 137 / 255, blue: 103 / 255)
    static let proxyFill = Color(red: 39 / 255, green: 194 / 255, blue: 145 / 255).opacity(0.10)
    static let selectedRow = Color(red: 220 / 255, green: 244 / 255, blue: 237 / 255).opacity(0.48)
    static let divider = Color(red: 116 / 255, green: 138 / 255, blue: 158 / 255).opacity(0.16)

    static let rowHeight: CGFloat = 56
    static let columnSpacing: CGFloat = 10
}

private struct ConnectionsGlassSurfaceModifier: ViewModifier {
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
    func connectionsGlassSurface(
        radius: CGFloat,
        emphasized: Bool = false
    ) -> some View {
        modifier(
            ConnectionsGlassSurfaceModifier(
                radius: radius,
                emphasized: emphasized
            )
        )
    }
}

private struct ConnectionsGlassIconButtonStyle: ButtonStyle {
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    let size: CGFloat

    @ViewBuilder
    func makeBody(configuration: Configuration) -> some View {
        let label = configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(ConnectionsDesignTokens.textPrimary)
            .frame(width: size, height: size)

        if #available(macOS 26.0, *), !reduceTransparency, contrast != .increased {
            label
                .glassEffect(
                    .regular.interactive(),
                    in: .rect(cornerRadius: 12)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(0.66), lineWidth: 1)
                }
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
        } else {
            label
                .background(
                    Color.white.opacity(configuration.isPressed ? 0.50 : 0.68),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
                .background(
                    .ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(
                            Color.white.opacity(contrast == .increased ? 1 : 0.86),
                            lineWidth: 1
                        )
                }
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
        }
    }
}

@MainActor
private struct ConnectionApplicationIcon: View {
    let row: ConnectionRowModel
    let size: CGFloat

    private var presentation: (symbol: String, foreground: Color, background: Color) {
        let name = row.application.lowercased()
        if name.contains("safari") {
            return ("safari.fill", Color.white, Color(red: 33 / 255, green: 161 / 255, blue: 235 / 255))
        }
        if name.contains("mail") {
            return ("envelope.fill", Color.white, Color(red: 50 / 255, green: 133 / 255, blue: 239 / 255))
        }
        if name.contains("music") || name.contains("spotify") {
            return ("music.note", Color.white, Color(red: 235 / 255, green: 67 / 255, blue: 120 / 255))
        }
        if name.contains("vela") {
            return ("arrow.triangle.2.circlepath", Color.white, Color(red: 35 / 255, green: 177 / 255, blue: 196 / 255))
        }
        if name.contains("xcode") {
            return ("hammer.fill", Color.white, Color(red: 38 / 255, green: 139 / 255, blue: 1))
        }
        if name.contains("message") {
            return ("bubble.left.and.bubble.right.fill", Color.white, Color(red: 38 / 255, green: 194 / 255, blue: 105 / 255))
        }
        if name.contains("note") {
            return ("note.text", Color.white, Color(red: 236 / 255, green: 177 / 255, blue: 47 / 255))
        }
        if name.contains("calendar") {
            return ("calendar", Color.white, Color(red: 229 / 255, green: 69 / 255, blue: 76 / 255))
        }
        if name.contains("terminal") || name.contains("curl") {
            return ("terminal.fill", Color.white, Color(red: 46 / 255, green: 54 / 255, blue: 63 / 255))
        }
        if name.contains("software") {
            return ("arrow.down.circle.fill", Color.white, Color(red: 91 / 255, green: 106 / 255, blue: 122 / 255))
        }
        if name.contains("mdns") || name.contains("resolve") {
            return ("network", Color.white, Color(red: 91 / 255, green: 106 / 255, blue: 122 / 255))
        }
        return ("app.fill", Color.white, ConnectionsDesignTokens.blue)
    }

    var body: some View {
        if let icon = ConnectionApplicationIconProvider.icon(
            for: row.connection.metadata.processPath
        ) {
            Image(nsImage: icon)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.28))
                .accessibilityHidden(true)
        } else {
            fallbackIcon
        }
    }

    private var fallbackIcon: some View {
        let presentation = presentation
        return Image(systemName: presentation.symbol)
            .font(.system(size: size * 0.48, weight: .medium))
            .foregroundStyle(presentation.foreground)
            .frame(width: size, height: size)
            .background(presentation.background, in: RoundedRectangle(cornerRadius: size * 0.28))
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.28)
                    .stroke(Color.white.opacity(0.84), lineWidth: 1)
            }
            .shadow(color: presentation.background.opacity(0.18), radius: 5, y: 2)
            .accessibilityHidden(true)
    }
}
