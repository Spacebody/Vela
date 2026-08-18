#if DEBUG
import SwiftUI

nonisolated enum MenuBarVisualScenario: String, CaseIterable, Sendable {
    case connectedSystemProxyLight
    case connectedSystemProxyDark
    case connectedTUNStatus
    case transitioningStatus
    case needsAttentionStatus
    case offStatus
    case recoveryStatus
    case increaseContrastStatus
    case voiceOverStatus
    case loadedSystemProxyDarkEnglish
    case loadedSystemProxyLightChinese
    case loadedTUNDarkEnglish
    case engineOnlyDarkChinese
    case noProfile
    case paused
    case longNames
    case trafficSummary
    case tunNotInstalled
    case tunNeedsApproval
    case helperConnecting
    case helperIncompatible
    case tunRecoveryRequired
    case switchSystemProxyToTUN
    case switchTUNToSystemProxy
    case partialFailure
    case stale
    case runtimeFailure
    case controllerOfflineLastGood
    case cleanupFailure
    case quitPending
    case diagnosticsAction
    case sceneSubmenu
    case proxySubmenu
    case pauseSubmenu
    case settingsSingleWindow
    case mainWindowReopen
    case englishMaxLabel
    case chineseMaxLabel
    case pseudo
    case doubleLength
    case menuWidthAX
    case keyboardDisabled

    static let launchArgument = "-VelaMenuBarScenario"

    static func resolved(fallbackState: VisualUITestConfiguration.State) -> Self {
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: launchArgument),
            arguments.indices.contains(index + 1),
            let scenario = Self(rawValue: arguments[index + 1])
        {
            return scenario
        }
        switch fallbackState {
        case .loaded:
            return .loadedSystemProxyDarkEnglish
        case .pendingMutation, .transitioning:
            return .switchSystemProxyToTUN
        case .partialFailure:
            return .partialFailure
        case .stale:
            return .stale
        case .failure, .rollbackFailed:
            return .runtimeFailure
        case .loading, .empty, .refreshing, .offline, .permissionRequired:
            return .offStatus
        }
    }

    var activeBackend: MenuBarBackend? {
        switch self {
        case .connectedTUNStatus, .loadedTUNDarkEnglish, .paused,
            .switchTUNToSystemProxy, .pauseSubmenu:
            return .tun
        case .engineOnlyDarkChinese, .offStatus, .noProfile, .tunNotInstalled,
            .tunNeedsApproval, .helperConnecting, .helperIncompatible,
            .tunRecoveryRequired, .recoveryStatus, .runtimeFailure, .cleanupFailure,
            .stale, .controllerOfflineLastGood:
            return self == .engineOnlyDarkChinese ? .engineOnly : nil
        default:
            return .systemProxy
        }
    }

    var requestedBackend: MenuBarBackend? {
        switch self {
        case .switchSystemProxyToTUN, .transitioningStatus, .keyboardDisabled:
            return .tun
        case .switchTUNToSystemProxy:
            return .systemProxy
        default:
            return nil
        }
    }

    var tunCapability: MenuBarTunCapability {
        switch self {
        case .tunNotInstalled: .notInstalled
        case .tunNeedsApproval: .needsApproval
        case .helperConnecting: .connecting
        case .helperIncompatible: .repairRequired
        case .tunRecoveryRequired, .recoveryStatus, .cleanupFailure: .recoveryRequired
        case .switchSystemProxyToTUN, .switchTUNToSystemProxy,
            .transitioningStatus, .keyboardDisabled: .transitioning
        default: .ready
        }
    }

    var showsSceneMenu: Bool { self == .sceneSubmenu }
    var showsProxyMenu: Bool { self == .proxySubmenu }
    var showsPauseMenu: Bool { self == .pauseSubmenu || self == .paused }
    var isQuitPending: Bool { self == .quitPending }
    var backendMutationsDisabled: Bool {
        requestedBackend != nil || isQuitPending
            || self == .noProfile || self == .runtimeFailure
            || self == .recoveryStatus || self == .tunRecoveryRequired
            || self == .cleanupFailure
    }
    var usesLongContext: Bool {
        switch self {
        case .longNames, .englishMaxLabel, .chineseMaxLabel, .pseudo,
            .doubleLength, .menuWidthAX:
            true
        default:
            false
        }
    }
}

struct MenuBarVisualFixtureStatusItem: View {
    let configuration: VisualUITestConfiguration

    private var scenario: MenuBarVisualScenario {
        .resolved(fallbackState: configuration.state)
    }

    var body: some View {
        Label("Vela", systemImage: systemImage)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityIdentifier("menubar.open")
    }

    private var systemImage: String {
        switch scenario {
        case .transitioningStatus, .switchSystemProxyToTUN, .switchTUNToSystemProxy,
            .keyboardDisabled:
            "arrow.triangle.2.circlepath"
        case .needsAttentionStatus, .partialFailure, .cleanupFailure:
            "exclamationmark.triangle.fill"
        case .offStatus, .noProfile, .tunNotInstalled:
            "circle"
        case .recoveryStatus, .tunRecoveryRequired:
            "wrench.and.screwdriver.fill"
        case .paused, .pauseSubmenu:
            "pause.circle.fill"
        case .runtimeFailure:
            "xmark.circle"
        case .stale, .controllerOfflineLastGood:
            "clock.badge.exclamationmark"
        case .connectedTUNStatus, .loadedTUNDarkEnglish:
            "shield.fill"
        case .engineOnlyDarkChinese:
            "circle.lefthalf.filled"
        default:
            "checkmark.circle.fill"
        }
    }

    private var accessibilityLabel: String {
        let copy = VisualFixtureLocalizedCopy(locale: configuration.localeIdentifier)
        return copy.text(
            "Vela, \(MenuBarVisualFixtureCopy.status(scenario, copy: copy))",
            "Vela，\(MenuBarVisualFixtureCopy.status(scenario, copy: copy))"
        )
    }
}

struct MenuBarVisualFixtureView: View {
    let configuration: VisualUITestConfiguration

    private var scenario: MenuBarVisualScenario {
        .resolved(fallbackState: configuration.state)
    }

    private var copy: VisualFixtureLocalizedCopy {
        VisualFixtureLocalizedCopy(locale: configuration.localeIdentifier)
    }

    var body: some View {
        Group {
            Button {} label: {
                Label(
                    MenuBarVisualFixtureCopy.status(scenario, copy: copy),
                    systemImage: MenuBarVisualFixtureCopy.statusImage(scenario)
                )
            }
            .accessibilityIdentifier("menu.status")

            contextRows
            refreshAction

            Divider()

            backendRows
            optionalSubmenus

            Divider()

            Button(copy.text("Open Vela", "打开 Vela")) {}
            Button(copy.text("Open Diagnostics…", "打开诊断…")) {}
            Button(copy.text("Settings…", "设置…")) {}
            Button(
                scenario.isQuitPending
                    ? copy.text("Stopping and Quitting…", "正在停止并退出…")
                    : copy.text("Quit Vela", "退出 Vela")
            ) {}
            .disabled(scenario.isQuitPending)

            VisualReadyMarker(fixtureID: configuration.fixtureID)
        }
        .environment(\.visualUITestConfiguration, configuration)
        .environment(\.locale, configuration.locale)
        .preferredColorScheme(configuration.colorScheme)
    }

    @ViewBuilder
    private var contextRows: some View {
        if scenario.usesLongContext {
            Text(
                copy.text(
                    "Daily Driver International… · Rule",
                    "家庭日常超长配置名称… · 规则"
                )
            )
            Text(copy.text("Scene · Home Office…", "场景 · 家庭办公室…"))
            Text(copy.text("Proxy · Edge Singapore…", "代理 · 新加坡边缘节点…"))
        } else if scenario != .offStatus && scenario != .noProfile {
            Text(copy.text("Daily Driver · Rule", "日常使用 · 规则"))
            Text(copy.text("Scene · Home Wi-Fi", "场景 · 家庭 Wi-Fi"))
            Text(copy.text("Proxy · Edge 01", "代理 · 边缘 01"))
        }

        if scenario == .partialFailure || scenario == .needsAttentionStatus {
            Text(copy.text("2 checks need attention", "2 项检查需要处理"))
        }
        if scenario == .stale || scenario == .controllerOfflineLastGood {
            Text(copy.text("Last known · System Proxy", "上次状态 · 系统代理"))
        }
        if scenario == .trafficSummary {
            Text("↓ 12.3 MB/s · ↑ 3.2 MB/s")
        }
    }

    @ViewBuilder
    private var refreshAction: some View {
        switch scenario {
        case .stale:
            Button(copy.text("Refresh Status", "刷新状态")) {}
        case .controllerOfflineLastGood:
            Button(copy.text("Reconnect", "重新连接")) {}
        case .runtimeFailure:
            Button(copy.text("Retry Status", "重试状态")) {}
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var backendRows: some View {
        Text(copy.text("Backend", "后端"))
        Toggle(
            backendTitle(.systemProxy),
            isOn: .constant(scenario.activeBackend == .systemProxy)
        )
        .disabled(scenario.backendMutationsDisabled)

        switch scenario.tunCapability {
        case .ready, .transitioning:
            Toggle(
                backendTitle(.tun),
                isOn: .constant(scenario.activeBackend == .tun)
            )
            .disabled(scenario.backendMutationsDisabled)
        case .notInstalled:
            Button(copy.text("Set Up TUN…", "设置 TUN…")) {}
        case .needsApproval:
            Button(copy.text("Approve TUN…", "批准 TUN…")) {}
        case .connecting:
            Text(copy.text("Connecting TUN…", "正在连接 TUN…"))
        case .repairRequired:
            Button(copy.text("Repair TUN…", "修复 TUN…")) {}
        case .recoveryRequired:
            Button(copy.text("Open TUN Recovery…", "打开 TUN 恢复…")) {}
        }

        if scenario.activeBackend == .engineOnly {
            Toggle(copy.text("Engine Only", "仅内核"), isOn: .constant(true))
                .disabled(true)
        }
    }

    @ViewBuilder
    private var optionalSubmenus: some View {
        if scenario.showsSceneMenu {
            Menu(copy.text("Scene · Home Wi-Fi", "场景 · 家庭 Wi-Fi")) {
                Toggle(copy.text("Home Wi-Fi", "家庭 Wi-Fi"), isOn: .constant(true))
                Toggle(copy.text("Office", "办公室"), isOn: .constant(false))
                Button(copy.text("Open Scenes…", "打开场景…")) {}
            }
        }
        if scenario.showsProxyMenu {
            Menu(copy.text("Proxy · Edge 01", "代理 · 边缘 01")) {
                Toggle(copy.text("Edge 01", "边缘 01"), isOn: .constant(true))
                Toggle(copy.text("Edge 02", "边缘 02"), isOn: .constant(false))
                Button(copy.text("Open Proxies…", "打开代理…")) {}
            }
        }
        if scenario.showsPauseMenu {
            Menu(copy.text("Pause TUN", "暂停 TUN")) {
                Button(copy.text("5 Minutes", "5 分钟")) {}
                Button(copy.text("15 Minutes", "15 分钟")) {}
                Button(copy.text("30 Minutes", "30 分钟")) {}
            }
        }
    }

    private func backendTitle(_ backend: MenuBarBackend) -> String {
        let base = switch backend {
        case .systemProxy: copy.text("System Proxy", "系统代理")
        case .tun: "TUN"
        case .engineOnly: copy.text("Engine Only", "仅内核")
        }
        return scenario.requestedBackend == backend
            ? copy.text("\(base) — Switching…", "\(base) — 切换中…")
            : base
    }
}

private enum MenuBarVisualFixtureCopy {
    static func status(
        _ scenario: MenuBarVisualScenario,
        copy: VisualFixtureLocalizedCopy
    ) -> String {
        switch scenario {
        case .connectedTUNStatus, .loadedTUNDarkEnglish:
            copy.text("Connected · TUN", "已连接 · TUN")
        case .engineOnlyDarkChinese:
            copy.text("Engine Only", "仅内核")
        case .transitioningStatus, .switchSystemProxyToTUN, .keyboardDisabled:
            copy.text("Switching to TUN…", "正在切换到 TUN…")
        case .switchTUNToSystemProxy:
            copy.text("Switching to System Proxy…", "正在切换到系统代理…")
        case .needsAttentionStatus, .partialFailure, .diagnosticsAction:
            copy.text("Needs Attention", "需要处理")
        case .offStatus:
            copy.text("Vela is Off", "Vela 已关闭")
        case .recoveryStatus, .tunRecoveryRequired, .cleanupFailure:
            copy.text("Recovery Required", "需要恢复")
        case .noProfile:
            copy.text("No Profile Selected", "未选择配置")
        case .paused, .pauseSubmenu:
            copy.text("Paused · 12m", "已暂停 · 12 分钟")
        case .stale, .controllerOfflineLastGood:
            copy.text("Status Stale · 12m", "状态已过期 · 12 分钟")
        case .runtimeFailure:
            copy.text("Runtime Unavailable", "运行时不可用")
        case .quitPending:
            copy.text("Stopping and Quitting…", "正在停止并退出…")
        case .tunNotInstalled:
            copy.text("Set Up TUN", "设置 TUN")
        case .tunNeedsApproval:
            copy.text("Approve TUN", "批准 TUN")
        case .helperConnecting:
            copy.text("Connecting TUN…", "正在连接 TUN…")
        case .helperIncompatible:
            copy.text("TUN Component Incompatible", "TUN 组件不兼容")
        default:
            copy.text("Connected · System Proxy", "已连接 · 系统代理")
        }
    }

    static func statusImage(_ scenario: MenuBarVisualScenario) -> String {
        switch scenario {
        case .transitioningStatus, .switchSystemProxyToTUN, .switchTUNToSystemProxy,
            .keyboardDisabled:
            "arrow.triangle.2.circlepath"
        case .needsAttentionStatus, .partialFailure, .cleanupFailure:
            "exclamationmark.triangle.fill"
        case .runtimeFailure:
            "xmark.circle"
        case .stale, .controllerOfflineLastGood:
            "clock.badge.exclamationmark"
        case .recoveryStatus, .tunRecoveryRequired:
            "wrench.and.screwdriver.fill"
        case .paused, .pauseSubmenu:
            "pause.circle.fill"
        case .offStatus, .noProfile:
            "circle"
        case .quitPending:
            "hourglass"
        case .connectedTUNStatus, .loadedTUNDarkEnglish:
            "shield.fill"
        case .engineOnlyDarkChinese:
            "circle.lefthalf.filled"
        default:
            "checkmark.circle.fill"
        }
    }
}
#endif
