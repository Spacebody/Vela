import SwiftUI
import VelaIPC

enum OverviewDashboardAction {
    case primary(OverviewPrimaryAction)
    case selectProxy(group: String, proxy: String)
    case changeMode(MihomoMode)
    case setSystemProxyEnabled(Bool)
    case setTunEnabled(Bool)
    case openProxies
    case openConnections
    case openDiagnostics
    case openConfiguration
    case recovery(OverviewRecoveryAction)
}

struct OverviewDashboardView: View {
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @State private var routeSweepProgress: CGFloat = 0
    @State private var routeGlowProgress: CGFloat = 0
    @State private var isNodePickerPresented = false

    let snapshot: OverviewSnapshot
    let isRefreshing: Bool
    let action: (OverviewDashboardAction) -> Void

    private static let routeEndpointDiameter: CGFloat = 72

    private var strings: OverviewStrings { OverviewStrings(locale: locale) }

    var body: some View {
        ZStack {
            VelaPageCanvas()

            GeometryReader { proxy in
                let layout = OverviewLayoutMetrics.resolve(availableSize: proxy.size)
                let isStacked = proxy.size.width < 820
                let compactHeight = proxy.size.height < 780
                let spacing: CGFloat = compactHeight ? 16 : 22
                let topHeight = min(284, max(236, proxy.size.height * 0.34))
                let combinedTopHeight = isStacked ? topHeight * 2 : topHeight
                let routeHeight: CGFloat = compactHeight ? 188 : 212
                let metricsHeight: CGFloat = compactHeight ? 140 : 154
                let verticalInset: CGFloat = compactHeight ? 24 : 32

                ScrollView {
                    VStack(spacing: spacing) {
                        overviewControlPanel(layout: layout, isStacked: isStacked)
                            .frame(height: combinedTopHeight)

                        routePanel(layout: layout)
                            .frame(height: routeHeight)

                        metricStrip
                            .frame(height: metricsHeight)

                        if colorSchemeContrast == .increased {
                            Color.clear
                                .frame(height: 0)
                                .accessibilityIdentifier("overview.accessibility.increasedContrast")
                        }

                        if reduceMotion {
                            Color.clear
                                .frame(height: 0)
                                .accessibilityIdentifier("overview.accessibility.reduceMotion")
                        }
                    }
                    .frame(maxWidth: 1_120)
                    .padding(.horizontal, proxy.size.width < 900 ? 24 : 42)
                    .frame(maxWidth: .infinity)
                    .frame(
                        minHeight: max(0, proxy.size.height - (verticalInset * 2)),
                        alignment: .center
                    )
                    .padding(.vertical, verticalInset)
                }
                .accessibilityIdentifier("overview.root")
                .scrollBounceBehavior(.basedOnSize)
                .velaContainsNestedScrolling()
                .foregroundStyle(OverviewDesignTokens.ColorToken.textPrimary)
                .tint(OverviewDesignTokens.ColorToken.accent)
                .animation(
                    reduceMotion
                        ? nil
                        : .easeInOut(duration: OverviewDesignTokens.Motion.state),
                    value: snapshot.state
                )
            }
        }
        // The redesigned dashboard owns a deliberately light glass canvas.
        // Keep adaptive system materials and semantic foreground styles in the
        // same appearance even when macOS itself is using Dark Mode.
        .environment(\.colorScheme, .light)
    }

    @ViewBuilder
    private func overviewControlPanel(
        layout: OverviewLayoutMetrics,
        isStacked: Bool
    ) -> some View {
        Group {
            if isStacked {
                VStack(spacing: 0) {
                    connectionCore(layout: layout)

                    Divider()
                        .padding(.horizontal, 24)

                    networkControlsCard
                }
            } else {
                HStack(spacing: 0) {
                    connectionCore(layout: layout)
                        .frame(maxWidth: .infinity)

                    Divider()
                        .padding(.vertical, 24)

                    networkControlsCard
                        .frame(width: min(440, layout.contentWidth * 0.44))
                }
            }
        }
        .overviewGlass(
            cornerRadius: OverviewDesignTokens.Radius.core,
            elevated: true
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("overview.controlPanel")
    }

    private var networkControlsCard: some View {
        VStack(spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(strings.text("Network Controls", "网络控制"))
                        .font(.system(size: 16, weight: .semibold))
                    Text(strings.text("Choose how Vela takes over traffic.", "选择 Vela 接管流量的方式。"))
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(OverviewDesignTokens.ColorToken.textSecondary)
                }
                Spacer(minLength: 12)
            }
            .padding(.horizontal, 18)
            .frame(height: 48)

            networkToggleRow(
                title: strings.systemProxy,
                subtitle: strings.text("Use the macOS system proxy.", "使用 macOS 系统代理。"),
                systemImage: "network",
                isOn: snapshot.route.isSystemProxyEnabled,
                isEnabled: snapshot.route.systemProxyToggleIsEnabled,
                disabledReason: snapshot.route.systemProxyDisabledReason
            ) { action(.setSystemProxyEnabled($0)) }

            networkToggleRow(
                title: strings.text("System Adapter", "系统网卡"),
                subtitle: strings.text("Route traffic through the TUN adapter.", "通过 TUN 系统网卡路由流量。"),
                systemImage: "shield.lefthalf.filled",
                isOn: snapshot.route.isTunEnabled,
                isEnabled: snapshot.route.tunToggleIsEnabled,
                disabledReason: snapshot.route.tunDisabledReason
            ) { action(.setTunEnabled($0)) }

            HStack(spacing: 12) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(OverviewDesignTokens.ColorToken.accent)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text(strings.text("Routing Strategy", "路由策略"))
                        .font(.system(size: 13, weight: .semibold))
                    Text(strings.text("Rule, global, or direct routing.", "规则、全局或直连路由。"))
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(OverviewDesignTokens.ColorToken.textSecondary)
                }

                Spacer(minLength: 10)
                routeModeMenu
            }
            .padding(.horizontal, 18)
            .frame(height: 56)
            .background {
                networkControlRowBackground
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("overview.networkControls")
    }

    private var networkControlRowBackground: some View {
        RoundedRectangle(cornerRadius: 17, style: .continuous)
            .fill(Color.white.opacity(0.34))
            .overlay {
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .stroke(Color.white.opacity(0.70), lineWidth: 1)
            }
    }

    private func networkToggleRow(
        title: String,
        subtitle: String,
        systemImage: String,
        isOn: Bool,
        isEnabled: Bool,
        disabledReason: String?,
        action toggleAction: @escaping (Bool) -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(
                    isOn
                        ? OverviewDesignTokens.ColorToken.accent
                        : OverviewDesignTokens.ColorToken.textSecondary
                )
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(OverviewDesignTokens.ColorToken.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 10)

            Button {
                toggleAction(!isOn)
            } label: {
                ZStack(alignment: isOn ? .trailing : .leading) {
                    Capsule()
                        .fill(
                            isOn
                                ? OverviewDesignTokens.ColorToken.accent
                                : OverviewDesignTokens.ColorToken.textTertiary.opacity(0.34)
                        )
                        .frame(width: 34, height: 20)

                    Circle()
                        .fill(Color.white)
                        .frame(width: 16, height: 16)
                        .padding(2)
                        .shadow(color: Color.black.opacity(0.10), radius: 2, y: 1)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(!isEnabled)
            .help(disabledReason ?? title)
            .accessibilityLabel(title)
            .accessibilityValue(isOn ? strings.on : strings.off)
        }
        .padding(.horizontal, 18)
        .frame(height: 56)
        .background {
            networkControlRowBackground
        }
        .accessibilityElement(children: .contain)
    }

    private var displayedProxyGroup: OverviewNodeSnapshot? {
        if let currentGroup = snapshot.node,
            let matchingGroup = snapshot.proxyGroups.first(where: {
                $0.groupName == currentGroup.groupName
            })
        {
            return matchingGroup
        }
        return snapshot.proxyGroups.first ?? snapshot.node
    }

    private func connectionCore(layout: OverviewLayoutMetrics) -> some View {
        let interaction = coreInteraction
        let statusColor = OverviewDesignTokens.statusColor(for: snapshot.state)
        let density = CoreContentDensity.resolve(height: layout.coreFrameSize.height)

        return Button {
            interaction.perform()
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 24) {
                    OverviewStatusBeacon(
                        state: snapshot.state,
                        isBusy: isRefreshing,
                        reduceMotion: reduceMotion
                    )
                    .scaleEffect(density.beaconScale)
                    .frame(width: 104, height: density.beaconHeight)

                    VStack(alignment: .leading, spacing: density.detailTopPadding) {
                        Text(
                            snapshot.state.isOperational
                                ? strings.text("Connected", "已连接")
                                : snapshot.core.statusTitle
                        )
                        .font(
                            .system(
                                size: density.titleSize,
                                weight: .semibold,
                                design: .rounded
                            )
                        )
                        .foregroundStyle(statusColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)

                        Group {
                            if let recovery = snapshot.recovery,
                               snapshot.state == .error || snapshot.state == .degraded
                            {
                                Text(recovery.detail)
                            } else if snapshot.state.isOperational {
                                Text(strings.text(
                                    "Vela is currently managing network traffic.",
                                    "Vela 当前正在接管网络流量"
                                ))
                            } else {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(strings.text(
                                        "Vela is not currently managing network traffic.",
                                        "Vela 当前未接管网络流量"
                                    ))
                                    Text(strings.text(
                                        "Enable System Proxy or System Adapter to begin.",
                                        "开启系统代理或系统网卡以开始"
                                    ))
                                }
                            }
                        }
                        .font(.system(size: density.detailSize, weight: .medium))
                        .foregroundStyle(OverviewDesignTokens.ColorToken.textSecondary)
                        .lineLimit(density.detailLineLimit)
                        .multilineTextAlignment(.leading)
                    }
                }
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: .center
                )

                HStack(spacing: density.rateSpacing) {
                    rateValue(
                        icon: "arrow.down",
                        title: strings.download,
                        value: snapshot.core.download
                    )

                    Rectangle()
                        .fill(OverviewDesignTokens.ColorToken.divider)
                        .frame(width: 1, height: density.rateDividerHeight)

                    rateValue(
                        icon: "arrow.up",
                        title: strings.upload,
                        value: snapshot.core.upload
                    )
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, max(16, density.topPadding))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(OverviewPressButtonStyle())
        .disabled(!interaction.isEnabled)
        .keyboardShortcut(.defaultAction)
        .help(interaction.disabledReason ?? strings.statusHelp)
        .accessibilityIdentifier("overview.connectionCore")
        .accessibilityLabel(snapshot.core.statusTitle)
        .accessibilityValue(snapshot.core.primaryValue)
        .accessibilityHint(interaction.disabledReason ?? strings.statusHelp)
    }

    private func rateValue(icon: String, title: String, value: String) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                Text(value)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(OverviewDesignTokens.ColorToken.textPrimary)

            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(OverviewDesignTokens.ColorToken.textTertiary)
        }
        .frame(minWidth: 112)
    }

    private func routePanel(layout: OverviewLayoutMetrics) -> some View {
        let endpointCircleDiameter = min(
            Self.routeEndpointDiameter,
            max(48, layout.endpointSize.width * 0.44)
        )
        let widthProgress = min(
            1,
            max(0, (layout.routeSize.width - 752) / (1_100 - 752))
        )
        let endpointHorizontalPadding = 96 - 48 * widthProgress
        let routeLineGap = 18 + 6 * widthProgress
        let routeLineInset = min(
            layout.routeSize.width / 2 - 8,
            endpointHorizontalPadding
                + layout.endpointSize.width / 2
                + endpointCircleDiameter / 2
                + routeLineGap
        )
        let endpointTitleHeight: CGFloat = 20
        let endpointFooterHeight: CGFloat = 27
        let endpointContentHeight =
            endpointCircleDiameter
            + 7
            + endpointTitleHeight
            + endpointFooterHeight
        let routeAxisOffset = -endpointContentHeight / 2 + endpointCircleDiameter / 2
        let mapWidth = min(880, layout.routeSize.width * 0.80)

        return ZStack {
            Image("OverviewWorldMap")
                .resizable()
                .scaledToFit()
                .frame(
                    width: mapWidth,
                    height: min(layout.routeSize.height, mapWidth / 2)
                )
                .foregroundStyle(OverviewDesignTokens.ColorToken.map)
                .opacity(snapshot.route.isAvailable ? 0.42 : 0.22)
                .accessibilityHidden(true)

            ZStack {
                Rectangle()
                    .fill(
                        snapshot.route.isAvailable
                            ? OverviewDesignTokens.ColorToken.connected
                            : OverviewDesignTokens.ColorToken.textTertiary
                    )
                    .frame(height: 1)

                if snapshot.route.isAvailable, !reduceMotion {
                    GeometryReader { lineProxy in
                        let sweepWidth = min(
                            180,
                            max(96, lineProxy.size.width * 0.16)
                        )

                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        .clear,
                                        OverviewDesignTokens.ColorToken.connected.opacity(0.22),
                                        Color.white.opacity(0.94),
                                        OverviewDesignTokens.ColorToken.connected.opacity(0.68),
                                        .clear
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: sweepWidth, height: 3)
                            .shadow(
                                color: OverviewDesignTokens.ColorToken.connected.opacity(0.48),
                                radius: 6
                            )
                            .offset(
                                x: -sweepWidth
                                    + (lineProxy.size.width + sweepWidth) * routeSweepProgress,
                                y: (lineProxy.size.height - 3) / 2
                            )
                    }
                    .clipped()
                }
            }
            .frame(height: 12)
            .padding(.horizontal, routeLineInset)
            .offset(y: routeAxisOffset)
            .accessibilityHidden(true)

            HStack {
                Circle()
                    .fill(
                        snapshot.route.isAvailable
                            ? OverviewDesignTokens.ColorToken.connected
                            : OverviewDesignTokens.ColorToken.textTertiary
                    )
                    .frame(width: 6, height: 6)
                Spacer(minLength: 0)
                Circle()
                    .fill(
                        snapshot.route.isAvailable
                            ? OverviewDesignTokens.ColorToken.connected
                            : OverviewDesignTokens.ColorToken.textTertiary
                    )
                    .frame(width: 6, height: 6)
            }
            .padding(.horizontal, routeLineInset)
            .offset(y: routeAxisOffset)
            .accessibilityHidden(true)

            HStack(alignment: .center, spacing: 0) {
                routeEndpoint(
                    systemImage: "desktopcomputer",
                    title: snapshot.route.sourceTitle,
                    detail: snapshot.route.sourceDetail,
                    status: nil,
                    isDestination: false,
                    diameter: endpointCircleDiameter
                )
                .frame(
                    width: layout.endpointSize.width,
                    height: endpointContentHeight,
                    alignment: .top
                )

                Spacer(minLength: 0)

                routeEndpoint(
                    systemImage: "antenna.radiowaves.left.and.right",
                    title: displayedProxyGroup?.name ?? snapshot.route.destinationTitle,
                    detail: displayedProxyGroup?.latency ?? "",
                    status: snapshot.route.isAvailable
                        ? strings.text("Active", "活跃")
                        : strings.text("Disconnected", "未连接"),
                    isDestination: true,
                    diameter: endpointCircleDiameter
                )
                .frame(
                    width: layout.endpointSize.width,
                    height: endpointContentHeight,
                    alignment: .top
                )
            }
            .padding(.horizontal, endpointHorizontalPadding)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .overviewGlass(cornerRadius: OverviewDesignTokens.Radius.route)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("overview.route")
        .accessibilityLabel(
            snapshot.route.isAvailable ? strings.connectedRoute : strings.routeUnavailable
        )
        .task(id: snapshot.route.isAvailable && !reduceMotion) {
            routeSweepProgress = 0
            routeGlowProgress = 0

            guard snapshot.route.isAvailable, !reduceMotion else { return }

            do {
                while !Task.isCancelled {
                    routeSweepProgress = 0

                    withAnimation(
                        .linear(duration: OverviewDesignTokens.Motion.routeSweep)
                    ) {
                        routeSweepProgress = 1
                    }
                    withAnimation(
                        .easeInOut(duration: OverviewDesignTokens.Motion.routeGlow)
                    ) {
                        routeGlowProgress = 1
                    }

                    try await Task.sleep(for: .milliseconds(1_200))

                    withAnimation(
                        .easeInOut(duration: OverviewDesignTokens.Motion.routeGlow)
                    ) {
                        routeGlowProgress = 0
                    }

                    try await Task.sleep(for: .milliseconds(1_800))
                }
            } catch {
                routeSweepProgress = 0
                routeGlowProgress = 0
            }
        }
    }

    private var routeModeMenu: some View {
        Menu {
            routeModeButton(.rule)
            routeModeButton(.global)
            routeModeButton(.direct)
        } label: {
            routeModeMenuLabel
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(OverviewGlassButtonStyle())
        .disabled(!snapshot.route.modeIsEnabled)
        .help(snapshot.route.modeDisabledReason ?? strings.selectMode)
        .accessibilityIdentifier("overview.route.modeMenu")
        .accessibilityLabel(strings.selectMode)
        .accessibilityValue(snapshot.route.modeTitle)
        .accessibilityHint(snapshot.route.modeDisabledReason ?? strings.selectMode)
    }

    private var routeModeMenuLabel: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(OverviewDesignTokens.ColorToken.accent)

            Text(snapshot.route.modeTitle)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)

            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(OverviewDesignTokens.ColorToken.textSecondary)
        }
        .padding(.horizontal, 13)
        .frame(minWidth: 104)
        .frame(height: 38)
        .contentShape(.rect)
    }

    private func routeModeButton(_ mode: MihomoMode) -> some View {
        Button {
            action(.changeMode(mode))
        } label: {
            Label(
                strings.modeTitle(mode),
                systemImage: snapshot.route.mode == mode ? "checkmark" : "circle"
            )
        }
        .disabled(snapshot.route.mode == mode)
        .accessibilityIdentifier("overview.modeOption.\(mode.rawValue)")
    }

    @ViewBuilder
    private func routeEndpoint(
        systemImage: String,
        title: String,
        detail: String,
        status: String?,
        isDestination: Bool,
        diameter: CGFloat
    ) -> some View {
        let ringColor =
            snapshot.route.isAvailable
                ? OverviewDesignTokens.ColorToken.connected
                : OverviewDesignTokens.ColorToken.textTertiary
        let endpointGlowProgress =
            isDestination
                ? 1 - routeGlowProgress
                : routeGlowProgress

        let content = VStack(spacing: 7) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.76))
                    .overlay {
                        Circle()
                            .stroke(
                                ringColor.opacity(
                                    snapshot.route.isAvailable ? 0.30 : 0.18
                                ),
                                lineWidth: 1.25
                            )
                    }
                    .background {
                        ZStack {
                            Circle()
                                .stroke(
                                    ringColor.opacity(
                                        snapshot.route.isAvailable ? 0.24 : 0.10
                                ),
                                lineWidth: 4
                            )
                            .blur(radius: 6)
                            .scaleEffect(1.08)

                            if snapshot.route.isAvailable, !reduceMotion {
                                Circle()
                                    .fill(
                                        ringColor.opacity(
                                            0.045
                                                + 0.035
                                                * Double(endpointGlowProgress)
                                        )
                                    )
                                    .blur(
                                        radius: 11
                                            + 3 * endpointGlowProgress
                                    )
                                    .scaleEffect(
                                        1.08
                                            + 0.045 * endpointGlowProgress
                                    )

                                Circle()
                                    .stroke(
                                        ringColor.opacity(
                                            0.08
                                                + 0.05
                                                * Double(endpointGlowProgress)
                                        ),
                                        lineWidth: 1.5
                                    )
                                    .blur(radius: 3)
                                    .scaleEffect(
                                        1.025
                                            + 0.025 * endpointGlowProgress
                                    )
                            }
                        }
                    }
                    .shadow(
                        color: ringColor.opacity(
                            snapshot.route.isAvailable
                                ? 0.18
                                    + 0.06
                                    * Double(endpointGlowProgress)
                                : 0.09
                        ),
                        radius: 14 + 3 * endpointGlowProgress
                    )
                    .shadow(color: Color.black.opacity(0.07), radius: 12, y: 5)

                Image(systemName: systemImage)
                    .font(
                        .system(
                            size: min(21, max(17, diameter * 0.30)),
                            weight: .light
                        )
                    )
                    .foregroundStyle(OverviewDesignTokens.ColorToken.textPrimary)
            }
            .frame(width: diameter, height: diameter)

            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .lineLimit(1)
                .frame(height: 20)

            Group {
                if !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(OverviewDesignTokens.ColorToken.textSecondary)
                        .lineLimit(1)
                } else if let status {
                    Text(status)
                        .font(VelaTypography.caption.weight(.semibold))
                        .foregroundStyle(
                            snapshot.route.isAvailable
                                ? OverviewDesignTokens.ColorToken.connected
                                : OverviewDesignTokens.ColorToken.textTertiary
                        )
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(
                            (
                                snapshot.route.isAvailable
                                    ? OverviewDesignTokens.ColorToken.connected
                                    : OverviewDesignTokens.ColorToken.textTertiary
                            ).opacity(0.1),
                            in: Capsule()
                        )
                } else {
                    Color.clear
                }
            }
            .frame(height: 27)
        }
        .frame(maxWidth: .infinity)

        if isDestination {
            Button {
                isNodePickerPresented.toggle()
            } label: {
                content
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(displayedProxyGroup?.candidates.isEmpty ?? true)
            .popover(isPresented: $isNodePickerPresented, arrowEdge: .top) {
                if let node = displayedProxyGroup {
                    OverviewNodePickerPopover(
                        groupName: node.groupName,
                        candidates: node.candidates,
                        isRefreshing: isRefreshing
                    ) { candidate in
                        isNodePickerPresented = false
                        action(
                            .selectProxy(
                                group: node.groupName,
                                proxy: candidate.selectionName
                            )
                        )
                    }
                }
            }
            .accessibilityIdentifier("overview.route.nodeMenu")
        } else {
            content
        }
    }

    private var metricStrip: some View {
        HStack(spacing: 0) {
            metricCell(
                icon: "arrow.down.circle",
                title: strings.download,
                value: snapshot.metrics.download,
                detail: nil,
                accent: OverviewDesignTokens.ColorToken.accent,
                sparkline: downloadValues
            )

            metricDivider

            metricCell(
                icon: "arrow.up.circle",
                title: strings.upload,
                value: snapshot.metrics.upload,
                detail: nil,
                accent: OverviewDesignTokens.ColorToken.accentViolet,
                sparkline: uploadValues
            )

            metricDivider

            Button {
                action(.openConnections)
            } label: {
                metricCell(
                    icon: "person.2",
                    title: strings.connections,
                    value: snapshot.metrics.activeConnections,
                    detail: snapshot.state.isOperational
                        ? strings.text("Active", "活跃")
                        : strings.disconnected,
                    accent: OverviewDesignTokens.ColorToken.accent,
                    sparkline: []
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("overview.metrics.connections")
            .accessibilityLabel(strings.openConnections)

            metricDivider

            metricCell(
                icon: "clock",
                title: strings.runtime,
                value: snapshot.metrics.runtime,
                detail: snapshot.state.isOperational ? strings.connected : strings.disconnected,
                accent: OverviewDesignTokens.ColorToken.accentViolet,
                sparkline: []
            )
        }
        .overviewGlass(cornerRadius: OverviewDesignTokens.Radius.metrics)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("overview.metrics")
    }

    private var metricDivider: some View {
        Rectangle()
            .fill(OverviewDesignTokens.ColorToken.divider)
            .frame(width: 1)
            .padding(.vertical, 22)
    }

    private func metricCell(
        icon: String,
        title: String,
        value: String,
        detail: String?,
        accent: Color,
        sparkline: [CGFloat]
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(accent)
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(OverviewDesignTokens.ColorToken.textSecondary)
            }

            Text(value)
                .font(.system(size: 29, weight: .medium, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            if !sparkline.isEmpty {
                OverviewSparkline(values: sparkline)
                    .stroke(
                        accent,
                        style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round)
                    )
                    .frame(width: 108, height: 22)
                    .accessibilityHidden(true)
            } else if let detail {
                Text(detail)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(OverviewDesignTokens.statusColor(for: snapshot.state))
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        OverviewDesignTokens.statusColor(for: snapshot.state).opacity(0.1),
                        in: Capsule()
                    )
            } else {
                Spacer()
                    .frame(height: 20)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.horizontal, 28)
        .padding(.vertical, 23)
        .contentShape(.rect)
    }

    private var downloadValues: [CGFloat] {
        snapshot.metrics.trafficPoints.map {
            CGFloat(max(0, $0.downloadBytesPerSecond))
        }
    }

    private var uploadValues: [CGFloat] {
        snapshot.metrics.trafficPoints.map {
            CGFloat(max(0, $0.uploadBytesPerSecond))
        }
    }

    private var coreInteraction: CoreInteraction {
        if let recovery = snapshot.recovery,
           snapshot.state == .error || snapshot.state == .degraded
        {
            return CoreInteraction(
                isEnabled: recovery.isEnabled && !isRefreshing,
                disabledReason: recovery.disabledReason,
                perform: { action(.recovery(recovery.action)) }
            )
        }

        let decision = snapshot.core.primaryAction
        return CoreInteraction(
            isEnabled: decision.isEnabled && !isRefreshing,
            disabledReason: decision.disabledReason,
            perform: { action(.primary(decision.action)) }
        )
    }
}

private struct CoreInteraction {
    let isEnabled: Bool
    let disabledReason: String?
    let perform: () -> Void
}

private struct CoreContentDensity {
    let beaconScale: CGFloat
    let beaconHeight: CGFloat
    let topPadding: CGFloat
    let titleSize: CGFloat
    let detailSize: CGFloat
    let detailLineLimit: Int
    let detailTopPadding: CGFloat
    let lowerSpacing: CGFloat
    let rateSpacing: CGFloat
    let rateDividerHeight: CGFloat

    static func resolve(height: CGFloat) -> Self {
        let progress = min(1, max(0, (height - 160) / 76))
        return Self(
            beaconScale: interpolate(from: 0.68, to: 1, progress: progress),
            beaconHeight: interpolate(from: 52, to: 76, progress: progress),
            topPadding: interpolate(from: 8, to: 24, progress: progress),
            titleSize: interpolate(from: 24, to: 30, progress: progress),
            detailSize: interpolate(from: 10, to: 12, progress: progress),
            detailLineLimit: height < 210 ? 1 : 2,
            detailTopPadding: interpolate(from: 2, to: 6, progress: progress),
            lowerSpacing: interpolate(from: 2, to: 10, progress: progress),
            rateSpacing: interpolate(from: 18, to: 24, progress: progress),
            rateDividerHeight: interpolate(from: 28, to: 38, progress: progress)
        )
    }

    private static func interpolate(
        from start: CGFloat,
        to end: CGFloat,
        progress: CGFloat
    ) -> CGFloat {
        start + (end - start) * progress
    }
}

private struct OverviewRegionBadge: View {
    let regionCode: String?

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.white.opacity(0.9))
                .overlay {
                    Circle()
                        .stroke(Color.black.opacity(0.05), lineWidth: 1)
                }
                .shadow(color: Color.black.opacity(0.08), radius: 8, y: 3)

            if regionCode == "JP" {
                Circle()
                    .fill(Color(red: 223 / 255, green: 48 / 255, blue: 64 / 255))
                    .frame(width: 11, height: 11)
            } else if let regionCode {
                Text(regionCode)
                    .font(.system(size: VelaTypeSize.dense, weight: .bold, design: .rounded))
                    .foregroundStyle(OverviewDesignTokens.ColorToken.textPrimary)
            } else {
                Circle()
                    .fill(OverviewDesignTokens.ColorToken.accent)
                    .frame(width: 10, height: 10)
            }
        }
        .frame(width: 30, height: 30)
        .accessibilityHidden(true)
    }
}

private struct OverviewStatusBeacon: View {
    let state: OverviewConnectionState
    let isBusy: Bool
    let reduceMotion: Bool

    @State private var pulse = false

    private var color: Color {
        OverviewDesignTokens.statusColor(for: state)
    }

    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .stroke(color.opacity(0.55 - Double(index) * 0.12), lineWidth: 1.5)
                    .frame(
                        width: CGFloat(34 + index * 13),
                        height: CGFloat(34 + index * 13)
                    )
            }

            Circle()
                .fill(color.opacity(0.22))
                .frame(width: 30, height: 30)

            if isBusy || state == .connecting {
                ProgressView()
                    .controlSize(.small)
                    .tint(color)
            } else {
                Circle()
                    .fill(color)
                    .frame(width: 13, height: 13)
                    .shadow(color: color.opacity(0.58), radius: 8)
            }
        }
        .frame(width: 76, height: 76)
        .scaleEffect(pulse ? 1.03 : 0.97)
        .task(id: state) {
            guard !reduceMotion, state == .connecting else {
                pulse = false
                return
            }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
        .accessibilityHidden(true)
    }
}

private struct OverviewSparkline: Shape {
    let values: [CGFloat]

    func path(in rect: CGRect) -> Path {
        guard values.count > 1 else { return Path() }

        let bucketCount = min(18, values.count)
        let bucketSize = max(1, Int(ceil(Double(values.count) / Double(bucketCount))))
        let smoothedValues = stride(from: 0, to: values.count, by: bucketSize).map { start in
            let end = min(start + bucketSize, values.count)
            let bucket = values[start..<end]
            return bucket.reduce(0, +) / CGFloat(bucket.count)
        }

        guard smoothedValues.count > 1,
              let smoothedMinimum = smoothedValues.min(),
              let smoothedMaximum = smoothedValues.max()
        else { return Path() }

        let span = max(1, smoothedMaximum - smoothedMinimum)
        let points = smoothedValues.enumerated().map { index, value in
            let x = rect.minX + rect.width * CGFloat(index) / CGFloat(smoothedValues.count - 1)
            let normalized = (value - smoothedMinimum) / span
            let y = rect.maxY - rect.height * normalized
            return CGPoint(x: x, y: y)
        }

        var path = Path()
        path.move(to: points[0])
        for index in 1..<points.count {
            let previous = points[index - 1]
            let current = points[index]
            let midpointX = (previous.x + current.x) / 2
            path.addCurve(
                to: current,
                control1: CGPoint(x: midpointX, y: previous.y),
                control2: CGPoint(x: midpointX, y: current.y)
            )
        }

        return path
    }
}

private struct OverviewGlassButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder
    func makeBody(configuration: Configuration) -> some View {
        let label = configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(
                reduceMotion
                    ? nil
                    : .easeOut(duration: OverviewDesignTokens.Motion.hover),
                value: configuration.isPressed
            )

        if #available(macOS 26.0, *), !reduceTransparency, contrast != .increased {
            label
                .glassEffect(
                    .regular.interactive(),
                    in: .capsule
                )
                .overlay {
                    Capsule()
                        .stroke(Color.white.opacity(0.68), lineWidth: 1)
                }
                .shadow(color: Color.black.opacity(0.035), radius: 12, y: 5)
        } else {
            label
                .background(
                    Color(red: 246 / 255, green: 250 / 255, blue: 254 / 255).opacity(0.74),
                    in: Capsule()
                )
                .background(.ultraThinMaterial, in: Capsule())
                .overlay {
                    Capsule()
                        .stroke(
                            Color.white.opacity(contrast == .increased ? 1 : 0.86),
                            lineWidth: 1
                        )
                }
                .shadow(color: Color.black.opacity(0.05), radius: 14, y: 6)
        }
    }
}

private struct OverviewPressButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.992 : 1)
            .opacity(configuration.isPressed ? 0.96 : 1)
            .animation(
                reduceMotion
                    ? nil
                    : .easeOut(duration: OverviewDesignTokens.Motion.hover),
                value: configuration.isPressed
            )
    }
}

private struct OverviewGlassSurfaceModifier: ViewModifier {
    let cornerRadius: CGFloat
    let elevated: Bool

    func body(content: Content) -> some View {
        content.velaWorkspaceGlassSurface(
            radius: cornerRadius,
            emphasized: elevated
        )
    }
}

private extension View {
    func overviewGlass(cornerRadius: CGFloat, elevated: Bool = false) -> some View {
        modifier(
            OverviewGlassSurfaceModifier(
                cornerRadius: cornerRadius,
                elevated: elevated
            )
        )
    }
}
