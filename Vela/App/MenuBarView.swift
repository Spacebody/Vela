import AppKit
import SwiftUI

struct MenuBarView: View {
    let engineStore: EngineStore
    let sceneController: SceneFeatureController?
    @Environment(\.openWindow) private var openWindow

    private var snapshot: MenuBarPresentationSnapshot {
        .live(engineStore: engineStore, sceneController: sceneController)
    }

    var body: some View {
        statusSummary
        contextSummary

        if snapshot.refreshAction != .none {
            Button(refreshActionTitle) {
                Task {
                    if snapshot.refreshAction == .retryStatus {
                        await engineStore.ensureInfrastructureRunning()
                    }
                    await engineStore.refreshHealth()
                }
            }
            .disabled(snapshot.overallState == .quitPending)
            .accessibilityIdentifier("menu.refreshStatus")
        }

        Divider()

        backendControls

        if sceneController?.scenes.isEmpty == false {
            sceneMenu
        }
        if !engineStore.availableRecentProxies.isEmpty {
            proxyMenu
        }
        pauseControl

        Divider()

        Button(VelaL10n.string("menu.action.openVela", defaultValue: "Open Vela")) {
            openMainWindow()
        }
        .keyboardShortcut("o")
        .accessibilityIdentifier("menu.openVela")

        Button(
            VelaL10n.string(
                "menu.action.openDiagnostics",
                defaultValue: "Open Diagnostics…"
            )
        ) {
            openDiagnostics()
        }
        .accessibilityIdentifier("menu.openDiagnostics")

        Button {
            SettingsMainNavigationRequest.open(.settings)
        } label: {
            Label(
                VelaL10n.string("menu.action.settings", defaultValue: "Settings…"),
                systemImage: "gearshape"
            )
        }
        .accessibilityIdentifier("menu.settings")

        Divider()

        Button(quitTitle) {
            // NSApp.terminate converges with Command-Q and Dock Quit inside
            // AppDelegate's bounded stop, cleanup, lease, and recovery path.
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
        .disabled(snapshot.overallState == .quitPending)
        .accessibilityIdentifier("menu.quit")
    }

    private var statusSummary: some View {
        Button(action: openMainWindow) {
            Label(statusTitle, systemImage: statusSystemImage)
        }
        .help(statusAccessibilityLabel)
        .accessibilityLabel(statusAccessibilityLabel)
        .accessibilityIdentifier("menu.status")
    }

    @ViewBuilder
    private var contextSummary: some View {
        if let profile = snapshot.profile {
            Text(
                VelaL10n.string(
                    "menu.context.profileMode.format",
                    defaultValue: "%@ · %@",
                    arguments: profile.displayName,
                    snapshot.mode ?? VelaL10n.string(
                        "menu.context.modeUnavailable",
                        defaultValue: "Mode unavailable"
                    )
                )
            )
            .help(profile.fullName)
            .accessibilityLabel(
                VelaL10n.string(
                    "menu.accessibility.profileMode.format",
                    defaultValue: "Profile %@, %@ mode",
                    arguments: profile.fullName,
                    snapshot.mode ?? VelaL10n.string(
                        "menu.context.modeUnavailable",
                        defaultValue: "Mode unavailable"
                    )
                )
            )
        }

        if let scene = snapshot.scene {
            Text(
                VelaL10n.string(
                    "menu.context.scene.format",
                    defaultValue: "Scene · %@",
                    arguments: scene.displayName
                )
            )
            .help(scene.fullName)
        }

        if let proxy = snapshot.proxy {
            Text(
                VelaL10n.string(
                    "menu.context.proxy.format",
                    defaultValue: "Proxy · %@",
                    arguments: proxy.displayName
                )
            )
            .help(proxy.fullName)
        }

    }

    @ViewBuilder
    private var backendControls: some View {
        Text(VelaL10n.string("menu.section.backend", defaultValue: "Traffic Routing"))

        Toggle(
            backendMenuTitle(.systemProxy),
            isOn: Binding(
                get: { snapshot.activeBackend == .systemProxy },
                set: { _ in
                    Task {
                        await engineStore.setTrafficTakeoverEnabled(
                            snapshot.activeBackend != .systemProxy
                        )
                    }
                }
            )
        )
        .disabled(!snapshot.actions.canSelectSystemProxy)
        .help(disabledReasonTitle(snapshot.actions.backendDisabledReason))
        .accessibilityIdentifier("menu.backend.systemProxy")

        switch snapshot.tunCapability {
        case .ready, .transitioning:
            Toggle(
                backendMenuTitle(.tun),
                isOn: Binding(
                    get: { snapshot.activeBackend == .tun },
                    set: { _ in
                        Task {
                            if snapshot.activeBackend == .tun {
                                await engineStore.setTrafficTakeoverEnabled(false)
                            } else {
                                await engineStore.setTunEnabled(true)
                            }
                        }
                    }
                )
            )
            .disabled(!snapshot.actions.canSelectTun)
            .help(disabledReasonTitle(snapshot.actions.backendDisabledReason))
            .accessibilityIdentifier("menu.backend.tun")

        case .notInstalled:
            tunRouteButton(
                VelaL10n.string("menu.tun.setup", defaultValue: "Set Up TUN…")
            )
        case .needsApproval:
            tunRouteButton(
                VelaL10n.string("menu.tun.approve", defaultValue: "Approve TUN…")
            )
        case .connecting:
            Text(
                VelaL10n.string(
                    "menu.tun.connecting",
                    defaultValue: "Connecting TUN…"
                )
            )
        case .repairRequired:
            tunRouteButton(
                VelaL10n.string("menu.tun.repair", defaultValue: "Repair TUN…")
            )
        case .recoveryRequired:
            tunRouteButton(
                VelaL10n.string(
                    "menu.tun.openRecovery",
                    defaultValue: "Open TUN Recovery…"
                )
            )
        }

    }

    private func tunRouteButton(_ title: String) -> some View {
        Button(title) {
            SettingsNavigationRequest(category: .tun).open()
        }
        .disabled(snapshot.requestedBackend != nil || snapshot.overallState == .quitPending)
        .accessibilityIdentifier("menu.tun.route")
    }

    private var sceneMenu: some View {
        Menu(
            VelaL10n.string(
                "menu.scene.title",
                defaultValue: "Scene · %@",
                arguments: snapshot.scene?.displayName
                    ?? VelaL10n.string("menu.value.none", defaultValue: "None")
            )
        ) {
            ForEach(Array((sceneController?.scenes ?? []).prefix(5))) { scene in
                Toggle(
                    MenuBarNamedValue(scene.name).displayName,
                    isOn: Binding(
                        get: { sceneController?.activeScene?.id == scene.id },
                        set: { _ in
                            Task {
                                await sceneController?.activate(scene, origin: .manual)
                            }
                        }
                    )
                )
                .disabled(!scene.enabled || !snapshot.actions.canSelectScene)
                .help(scene.name)
            }
            Divider()
            Button(VelaL10n.string("menu.action.openScenes", defaultValue: "Open Scenes…")) {
                openMainWindow()
            }
        }
        .disabled(!snapshot.actions.canSelectScene)
        .help(disabledReasonTitle(snapshot.actions.sceneDisabledReason))
        .accessibilityIdentifier("menu.scene")
    }

    private var proxyMenu: some View {
        Menu(
            VelaL10n.string(
                "menu.proxy.title",
                defaultValue: "Proxy · %@",
                arguments: snapshot.proxy?.displayName
                    ?? VelaL10n.string("menu.value.none", defaultValue: "None")
            )
        ) {
            ForEach(
                Array(engineStore.availableRecentProxies.prefix(5).enumerated()),
                id: \.offset
            ) { _, record in
                Toggle(
                    MenuBarNamedValue(record.proxyName).displayName,
                    isOn: Binding(
                        get: { selectionIsConfirmed(record) },
                        set: { _ in
                            Task {
                                await engineStore.selectProxy(
                                    group: record.groupName,
                                    proxy: record.proxyName
                                )
                            }
                        }
                    )
                )
                .disabled(
                    !snapshot.actions.canSelectProxy || selectionIsConfirmed(record)
                )
                .help([record.proxyName, record.groupName].joined(separator: " — "))
            }
            Divider()
            Button(VelaL10n.string("menu.action.openProxies", defaultValue: "Open Proxies…")) {
                openMainWindow()
            }
        }
        .disabled(!snapshot.actions.canSelectProxy)
        .help(disabledReasonTitle(snapshot.actions.proxyDisabledReason))
        .accessibilityIdentifier("menu.proxy")
    }

    @ViewBuilder
    private var pauseControl: some View {
        if snapshot.actions.canPause {
            Menu(VelaL10n.string("menu.pause.title", defaultValue: "Pause TUN")) {
                pauseButton(minutes: 5)
                pauseButton(minutes: 15)
                pauseButton(minutes: 30)
            }
            .accessibilityIdentifier("menu.pause")
        } else if snapshot.actions.canResume {
            Button(VelaL10n.string("menu.pause.resume", defaultValue: "Resume TUN")) {
                Task { await engineStore.resumeTun() }
            }
            .accessibilityIdentifier("menu.resume")
        }
    }

    private func pauseButton(minutes: Int) -> some View {
        Button(
            VelaL10n.string(
                "menu.pause.minutes.format",
                defaultValue: "%lld Minutes",
                arguments: Int64(minutes)
            )
        ) {
            Task { await engineStore.pauseTun(for: .seconds(minutes * 60)) }
        }
    }

    private var refreshActionTitle: String {
        switch snapshot.refreshAction {
        case .none:
            return ""
        case .refreshStatus:
            return VelaL10n.string(
                "menu.action.refreshStatus",
                defaultValue: "Refresh Status"
            )
        case .reconnect:
            return VelaL10n.string("menu.action.reconnect", defaultValue: "Reconnect")
        case .retryStatus:
            return VelaL10n.string(
                "menu.action.retryStatus",
                defaultValue: "Retry Status"
            )
        }
    }

    private var quitTitle: String {
        snapshot.overallState == .quitPending
            ? VelaL10n.string(
                "menu.quit.pending",
                defaultValue: "Stopping and Quitting…"
            )
            : VelaL10n.string("menu.action.quit", defaultValue: "Quit Vela")
    }

    private var statusTitle: String {
        switch snapshot.overallState {
        case let .connected(backend):
            return VelaL10n.string(
                "menu.status.connectedBackend.format",
                defaultValue: "Connected · %@",
                arguments: backendTitle(backend)
            )
        case .engineOnly:
            return VelaL10n.string("menu.status.engineOnly", defaultValue: "Disconnected")
        case .off:
            return VelaL10n.string("menu.status.off", defaultValue: "Disconnected")
        case .noProfile:
            return VelaL10n.string(
                "menu.status.noProfile",
                defaultValue: "No Profile Selected"
            )
        case .partialFailure:
            return VelaL10n.string(
                "menu.status.needsAttention",
                defaultValue: "Needs Attention"
            )
        case let .stale(ageSeconds):
            return VelaL10n.string(
                "menu.status.stale.format",
                defaultValue: "Status Stale · %@",
                arguments: ageTitle(ageSeconds)
            )
        case .runtimeFailure:
            return VelaL10n.string(
                "menu.status.runtimeUnavailable",
                defaultValue: "Connection Unavailable"
            )
        case let .transitioning(_, requested):
            if requested == .engineOnly {
                return VelaL10n.string(
                    "menu.status.disconnecting",
                    defaultValue: "Disconnecting…"
                )
            }
            return VelaL10n.string(
                "menu.status.switching.format",
                defaultValue: "Switching to %@…",
                arguments: backendTitle(requested)
            )
        case let .paused(remainingSeconds):
            return VelaL10n.string(
                "menu.status.paused.format",
                defaultValue: "Paused · %@",
                arguments: ageTitle(remainingSeconds)
            )
        case .recoveryRequired:
            return VelaL10n.string(
                "menu.status.recoveryRequired",
                defaultValue: "Recovery Required"
            )
        case .quitPending:
            return VelaL10n.string(
                "menu.quit.pending",
                defaultValue: "Stopping and Quitting…"
            )
        }
    }

    private var statusSystemImage: String {
        switch snapshot.overallState {
        case .connected(.systemProxy): "checkmark.circle.fill"
        case .connected(.tun): "shield.fill"
        case .connected(.engineOnly), .engineOnly: "circle"
        case .transitioning: "arrow.triangle.2.circlepath"
        case .partialFailure: "exclamationmark.triangle.fill"
        case .stale: "clock.badge.exclamationmark"
        case .runtimeFailure: "xmark.circle"
        case .recoveryRequired: "wrench.and.screwdriver.fill"
        case .paused: "pause.circle.fill"
        case .off, .noProfile: "circle"
        case .quitPending: "hourglass"
        }
    }

    private var statusAccessibilityLabel: String {
        VelaL10n.string(
            "menu.accessibility.status.format",
            defaultValue: "Vela, %@",
            arguments: statusTitle
        )
    }

    private func backendMenuTitle(_ backend: MenuBarBackend) -> String {
        if snapshot.requestedBackend == backend {
            return VelaL10n.string(
                "menu.backend.switching.format",
                defaultValue: "%@ — Switching…",
                arguments: backendTitle(backend)
            )
        }
        return backendTitle(backend)
    }

    private func backendTitle(_ backend: MenuBarBackend) -> String {
        switch backend {
        case .systemProxy:
            VelaL10n.string("menu.backend.systemProxy", defaultValue: "System Proxy")
        case .tun:
            "TUN"
        case .engineOnly:
            VelaL10n.string("menu.backend.engineOnly", defaultValue: "Engine Only")
        }
    }

    private var freshnessDetail: String {
        switch snapshot.freshness {
        case let .live(verifiedAt, generation):
            return verificationDetail(date: verifiedAt, generation: generation)
        case let .stale(lastVerifiedAt, _, generation):
            return verificationDetail(date: lastVerifiedAt, generation: generation)
        case .unknown:
            return VelaL10n.string(
                "menu.freshness.unknown",
                defaultValue: "No verified runtime snapshot is available."
            )
        }
    }

    private func verificationDetail(date: Date?, generation: UInt64) -> String {
        guard let date else { return "" }
        return VelaL10n.string(
            "menu.freshness.detail.format",
            defaultValue: "Last verified %@ · generation %llu",
            arguments: date.formatted(date: .omitted, time: .shortened),
            generation
        )
    }

    private func ageTitle(_ seconds: Int) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3_600 ? [.hour, .minute] : [.minute]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 1
        return formatter.string(from: TimeInterval(max(60, seconds))) ?? "1m"
    }

    private func disabledReasonTitle(_ reason: MenuBarDisabledReason?) -> String {
        switch reason {
        case .none:
            return ""
        case .transitionInProgress:
            return VelaL10n.string(
                "menu.disabled.transition",
                defaultValue: "Wait for the current network transition to finish."
            )
        case .operationInProgress:
            return VelaL10n.string(
                "menu.disabled.operation",
                defaultValue: "Another runtime operation is in progress."
            )
        case .profileRequired:
            return VelaL10n.string(
                "menu.disabled.profile",
                defaultValue: "Choose a Profile first."
            )
        case .controllerUnavailable:
            return VelaL10n.string(
                "menu.disabled.controller",
                defaultValue: "Reconnect the Controller first."
            )
        case .privilegedComponentUnavailable:
            return VelaL10n.string(
                "menu.disabled.component",
                defaultValue: "Set up the privileged component first."
            )
        case .currentBackendMustStop:
            return VelaL10n.string(
                "menu.disabled.backend",
                defaultValue: "Stop the current backend first."
            )
        case .alreadyActive:
            return VelaL10n.string(
                "menu.disabled.active",
                defaultValue: "This backend is already active."
            )
        case .quitInProgress:
            return VelaL10n.string(
                "menu.disabled.quit",
                defaultValue: "Vela is already stopping and quitting."
            )
        }
    }

    private func openMainWindow() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }

    private func openDiagnostics() {
        SettingsMainNavigationRequest.open(.diagnostics)
    }

    private func selectionIsConfirmed(_ record: RecentProxyRecord) -> Bool {
        guard let group = engineStore.proxyCatalog.group(named: record.groupName) else {
            return false
        }
        switch group.type {
        case "URLTest", "Fallback":
            return group.fixed.flatMap { $0.isEmpty ? nil : $0 } == record.proxyName
        case "Selector":
            return group.now == record.proxyName
        default:
            return false
        }
    }
}

struct MenuBarLabel: View {
    let engineStore: EngineStore
    let sceneController: SceneFeatureController?
    @Environment(\.openWindow) private var openWindow

    private var snapshot: MenuBarPresentationSnapshot {
        .live(engineStore: engineStore, sceneController: sceneController)
    }

    var body: some View {
        Label(VelaL10n.string("legacy.vela", defaultValue: "Vela"), systemImage: systemImage)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityIdentifier("menubar.open")
            .onReceive(NotificationCenter.default.publisher(for: .velaOpenMainWindow)) { _ in
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
    }

    private var systemImage: String {
        switch snapshot.overallState {
        case .connected: "sailboat.fill"
        case .transitioning: "arrow.triangle.2.circlepath"
        case .partialFailure: "exclamationmark.triangle.fill"
        case .stale: "clock.badge.exclamationmark"
        case .runtimeFailure: "xmark.circle"
        case .recoveryRequired: "wrench.and.screwdriver.fill"
        case .paused: "pause.circle.fill"
        case .engineOnly, .off, .noProfile: "sailboat"
        case .quitPending: "hourglass"
        }
    }

    private var accessibilityLabel: String {
        let state: String
        switch snapshot.overallState {
        case let .connected(backend):
            state = VelaL10n.string(
                "menu.accessibility.connectedBackend.format",
                defaultValue: "connected using %@",
                arguments: backendAccessibilityTitle(backend)
            )
        case .engineOnly:
            state = VelaL10n.string(
                "menu.accessibility.engineOnly",
                defaultValue: "disconnected"
            )
        case let .transitioning(_, requested):
            state = VelaL10n.string(
                "menu.accessibility.switching.format",
                defaultValue: "switching to %@",
                arguments: backendAccessibilityTitle(requested)
            )
        case .partialFailure:
            state = VelaL10n.string(
                "menu.accessibility.needsAttention",
                defaultValue: "needs attention"
            )
        case .stale:
            state = VelaL10n.string(
                "menu.accessibility.stale",
                defaultValue: "status stale"
            )
        case .runtimeFailure:
            state = VelaL10n.string(
                "menu.accessibility.runtimeUnavailable",
                defaultValue: "connection unavailable"
            )
        case .recoveryRequired:
            state = VelaL10n.string(
                "menu.accessibility.recovery",
                defaultValue: "recovery required"
            )
        case .paused:
            state = VelaL10n.string("menu.accessibility.paused", defaultValue: "paused")
        case .off:
            state = VelaL10n.string(
                "menu.accessibility.off",
                defaultValue: "disconnected"
            )
        case .noProfile:
            state = VelaL10n.string(
                "menu.accessibility.noProfile",
                defaultValue: "no Profile selected"
            )
        case .quitPending:
            state = VelaL10n.string(
                "menu.accessibility.quitting",
                defaultValue: "stopping and quitting"
            )
        }
        return VelaL10n.string(
            "menu.accessibility.status.format",
            defaultValue: "Vela, %@",
            arguments: state
        )
    }

    private func backendAccessibilityTitle(_ backend: MenuBarBackend) -> String {
        switch backend {
        case .systemProxy:
            VelaL10n.string("menu.backend.systemProxy", defaultValue: "System Proxy")
        case .tun:
            "TUN"
        case .engineOnly:
            VelaL10n.string("menu.backend.engineOnly", defaultValue: "Engine Only")
        }
    }
}
