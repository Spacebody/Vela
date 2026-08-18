#if DEBUG
import Foundation

/// Pure presentation metadata used by the visual fixture hosts.
///
/// The values are deliberately synthetic and contain no host names, live
/// addresses, profile contents, or persisted user data. Every string has an
/// explicit English and Simplified Chinese fixture translation so locale
/// captures remain deterministic even when a production catalog changes.
nonisolated struct VisualFixtureLocalizedCopy: Equatable, Sendable {
    let locale: VisualUITestConfiguration.LocaleIdentifier

    func text(_ english: String, _ simplifiedChinese: String) -> String {
        switch locale {
        case .english:
            english
        case .simplifiedChinese:
            simplifiedChinese
        }
    }
}

nonisolated struct VisualFixtureRowSpec: Identifiable, Equatable, Sendable {
    let id: String
    let cells: [String]
    let status: VelaSemanticStatus?
}

nonisolated struct VisualFixtureInspectorSpec: Equatable, Sendable {
    let title: String
    let sections: [(title: String, values: [(label: String, value: String)])]

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.title == rhs.title
            && lhs.sections.elementsEqual(rhs.sections) { lhsSection, rhsSection in
                lhsSection.title == rhsSection.title
                    && lhsSection.values.elementsEqual(rhsSection.values) { lhsValue, rhsValue in
                        lhsValue.label == rhsValue.label && lhsValue.value == rhsValue.value
                    }
            }
    }
}

nonisolated struct VisualFixturePageSpec: Equatable, Sendable {
    let title: String
    let subtitle: String
    let systemImage: String
    let primaryAction: String
    let emptyTitle: String
    let emptyDetail: String
    let columns: [String]
    let rows: [VisualFixtureRowSpec]
    let inspector: VisualFixtureInspectorSpec?
}

/// A single source of truth for the synthetic presentation supported by the
/// Debug harness. Coverage is derived from the strict route catalog rather
/// than maintained as a second list that could silently drift.
nonisolated enum VisualFixturePresentationCatalog {
    static var coveredFixtureIDs: Set<String> {
        Set(VisualFixtureRouteCatalog.all.map(\.fixtureID))
    }

    static func supports(
        _ configuration: VisualUITestConfiguration,
        captureBoundary: VisualFixtureRouteDescriptor.CaptureBoundary? = nil
    ) -> Bool {
        guard let route = VisualFixtureRouteCatalog.route(
                page: configuration.page,
                state: configuration.state
            ),
            configuration.fixtureID == route.fixtureID,
            route.supports(inspector: configuration.inspector),
            coveredFixtureIDs.contains(configuration.fixtureID)
        else {
            return false
        }
        return captureBoundary.map { route.captureBoundary == $0 } ?? true
    }

    static func pageSpec(
        for configuration: VisualUITestConfiguration
    ) -> VisualFixturePageSpec {
        let copy = VisualFixtureLocalizedCopy(locale: configuration.localeIdentifier)
        switch configuration.page {
        case .overview:
            return VisualFixturePageSpec(
                title: copy.text("Overview", "概览"),
                subtitle: copy.text(
                    "Runtime health and the currently selected network path",
                    "运行状态与当前选择的网络路径"
                ),
                systemImage: "gauge.with.dots.needle.50percent",
                primaryAction: copy.text("Refresh Health", "刷新健康状态"),
                emptyTitle: copy.text("Vela is stopped", "Vela 已停止"),
                emptyDetail: copy.text(
                    "Choose a configuration, then start the runtime when you are ready.",
                    "选择配置，准备好后再启动运行时。"
                ),
                columns: [
                    copy.text("Component", "组件"),
                    copy.text("State", "状态"),
                    copy.text("Details", "详情"),
                ],
                rows: [
                    row("runtime", [copy.text("Mihomo runtime", "Mihomo 运行时"), copy.text("Running", "运行中"), "mihomo 1.19.28"], .success),
                    row("controller", [copy.text("Controller", "控制器"), copy.text("Connected", "已连接"), "127.0.0.1:9090"], .success),
                    row("profile", [copy.text("Configuration", "配置"), copy.text("Active", "已激活"), copy.text("Daily Driver", "日常使用")], .success),
                    row("system-proxy", [copy.text("System Proxy", "系统代理"), copy.text("Enabled", "已启用"), copy.text("Mixed port 7890", "混合端口 7890")], .info),
                ],
                inspector: nil
            )
        case .proxies:
            return VisualFixturePageSpec(
                title: copy.text("Proxies", "代理节点"),
                subtitle: copy.text("Select routes and compare recent latency", "选择路由并比较最近延迟"),
                systemImage: "point.3.connected.trianglepath.dotted",
                primaryAction: copy.text("Test Latency", "测试延迟"),
                emptyTitle: copy.text("No proxy groups", "没有代理组"),
                emptyDetail: copy.text("The active configuration does not expose selectable proxy groups.", "当前配置未提供可选择的代理组。"),
                columns: [copy.text("Group", "代理组"), copy.text("Selected Proxy", "已选节点"), copy.text("Latency", "延迟")],
                rows: [
                    row("automatic", [copy.text("Automatic", "自动选择"), copy.text("Seattle · Edge 01", "西雅图 · Edge 01"), "42 ms"], .success),
                    row("streaming", [copy.text("Streaming", "流媒体"), copy.text("Tokyo · Media", "东京 · Media"), "68 ms"], .success),
                    row("work", [copy.text("Work", "工作"), copy.text("Singapore · Core", "新加坡 · Core"), "91 ms"], .warning),
                    row("fallback", [copy.text("Fallback", "故障转移"), copy.text("Direct", "直连"), "—"], .neutral),
                ],
                inspector: inspector(
                    title: copy.text("Proxy Inspector", "节点检查器"),
                    copy: copy,
                    identity: [(copy.text("Type", "类型"), "Selector"), (copy.text("Current", "当前"), copy.text("Seattle · Edge 01", "西雅图 · Edge 01"))],
                    evidence: [(copy.text("Last test", "上次测试"), copy.text("10:42 AM", "10:42")), (copy.text("Samples", "样本"), "8")]
                )
            )
        case .connections:
            return VisualFixturePageSpec(
                title: copy.text("Connections", "连接"),
                subtitle: copy.text("Live application traffic and route evidence", "实时应用流量与路由证据"),
                systemImage: "network",
                primaryAction: copy.text("Close Selected", "关闭所选连接"),
                emptyTitle: copy.text("No active connections", "没有活动连接"),
                emptyDetail: copy.text("New connections will appear here while the runtime is active.", "运行时处于活动状态时，新连接会显示在这里。"),
                columns: [copy.text("Application", "应用"), copy.text("Destination", "目标"), copy.text("Route", "路由")],
                rows: [
                    row("browser", ["Safari", "docs.example.test:443", copy.text("Automatic", "自动选择")], .success),
                    row("mail", ["Mail", "mail.example.test:993", copy.text("Work", "工作")], .success),
                    row("sync", [copy.text("Cloud Sync", "云同步"), "sync.example.test:443", copy.text("Direct", "直连")], .info),
                    row("music", ["Music", "media.example.test:443", copy.text("Streaming", "流媒体")], .success),
                ],
                inspector: inspector(
                    title: copy.text("Connection Inspector", "连接检查器"),
                    copy: copy,
                    identity: [(copy.text("Process", "进程"), "Safari"), (copy.text("Network", "网络"), "TCP · TLS")],
                    evidence: [(copy.text("Rule", "规则"), "DomainSuffix"), (copy.text("Chain", "链路"), copy.text("Automatic → Edge 01", "自动选择 → Edge 01"))]
                )
            )
        case .rules:
            return VisualFixturePageSpec(
                title: copy.text("Rules", "规则"),
                subtitle: copy.text("Effective routing rules from the active configuration", "当前配置中的有效路由规则"),
                systemImage: "list.bullet.rectangle",
                primaryAction: copy.text("Search Rules", "搜索规则"),
                emptyTitle: copy.text("No rules found", "未找到规则"),
                emptyDetail: copy.text("Adjust the filter or choose a configuration with routing rules.", "调整筛选条件，或选择包含路由规则的配置。"),
                columns: [copy.text("Type", "类型"), copy.text("Payload", "内容"), copy.text("Policy", "策略")],
                rows: [
                    row("domain", ["DOMAIN-SUFFIX", "example.test", copy.text("Automatic", "自动选择")], .success),
                    row("process", ["PROCESS-NAME", "Mail", copy.text("Work", "工作")], .success),
                    row("private", ["IP-CIDR", "192.0.2.0/24", copy.text("Direct", "直连")], .info),
                    row("match", ["MATCH", "—", copy.text("Fallback", "故障转移")], .neutral),
                ],
                inspector: inspector(
                    title: copy.text("Rule Inspector", "规则检查器"),
                    copy: copy,
                    identity: [(copy.text("Index", "序号"), "148"), (copy.text("Source", "来源"), copy.text("Daily Driver", "日常使用"))],
                    evidence: [(copy.text("Matches", "匹配数"), "24"), (copy.text("Provider", "提供器"), copy.text("Built in", "内置"))]
                )
            )
        case .providers:
            return VisualFixturePageSpec(
                title: copy.text("Providers", "提供器"),
                subtitle: copy.text("Proxy and rule provider freshness", "代理与规则提供器的新鲜度"),
                systemImage: "shippingbox",
                primaryAction: copy.text("Update All", "全部更新"),
                emptyTitle: copy.text("No providers", "没有提供器"),
                emptyDetail: copy.text("The active configuration does not define proxy or rule providers.", "当前配置未定义代理或规则提供器。"),
                columns: [copy.text("Provider", "提供器"), copy.text("Kind", "类型"), copy.text("Status", "状态")],
                rows: [
                    row("edge", [copy.text("Edge Nodes", "边缘节点"), copy.text("Proxy", "代理"), copy.text("Healthy · 24 items", "正常 · 24 项")], .success),
                    row("private", [copy.text("Private Networks", "私有网络"), copy.text("Rule", "规则"), copy.text("Healthy · 18 items", "正常 · 18 项")], .success),
                    row("media", [copy.text("Media Rules", "流媒体规则"), copy.text("Rule", "规则"), copy.text("Update available", "有可用更新")], .warning),
                ],
                inspector: inspector(
                    title: copy.text("Provider Inspector", "提供器检查器"),
                    copy: copy,
                    identity: [(copy.text("Format", "格式"), "YAML"), (copy.text("Vehicle", "载体"), "HTTP")],
                    evidence: [(copy.text("Last update", "上次更新"), copy.text("10:36 AM", "10:36")), (copy.text("Next update", "下次更新"), copy.text("In 54 minutes", "54 分钟后"))]
                )
            )
        case .workbench:
            return VisualFixturePageSpec(
                title: copy.text("Configuration Workbench", "配置工作台"),
                subtitle: copy.text("Review effective layers before applying them", "应用前检查有效配置层"),
                systemImage: "slider.horizontal.3",
                primaryAction: copy.text("Apply Changes", "应用更改"),
                emptyTitle: copy.text("No configuration selected", "未选择配置"),
                emptyDetail: copy.text("Choose a configuration to inspect its effective runtime output.", "选择配置以检查其有效运行时输出。"),
                columns: [copy.text("Layer", "配置层"), copy.text("Source", "来源"), copy.text("Changes", "更改")],
                rows: [
                    row("global", [copy.text("Global defaults", "全局默认值"), copy.text("Vela", "Vela"), "3"], .success),
                    row("profile", [copy.text("Configuration", "配置"), copy.text("Daily Driver", "日常使用"), "18"], .success),
                    row("scene", [copy.text("Scene", "场景"), copy.text("Office", "办公室"), "4"], .info),
                    row("forced", [copy.text("Runtime safety", "运行时安全"), copy.text("Vela", "Vela"), "2"], .success),
                ],
                inspector: inspector(
                    title: copy.text("Change Inspector", "更改检查器"),
                    copy: copy,
                    identity: [(copy.text("Path", "路径"), "/mode"), (copy.text("Operation", "操作"), copy.text("Change", "更改"))],
                    evidence: [(copy.text("Source", "来源"), copy.text("Scene", "场景")), (copy.text("Effective value", "有效值"), "rule")]
                )
            )
        case .diagnostics:
            return VisualFixturePageSpec(
                title: copy.text("Diagnostics", "诊断"),
                subtitle: copy.text("Evidence-based checks for runtime and network health", "基于证据检查运行时与网络健康状态"),
                systemImage: "stethoscope",
                primaryAction: copy.text("Run Checks", "运行检查"),
                emptyTitle: copy.text("No diagnostic evidence", "没有诊断证据"),
                emptyDetail: copy.text("Run checks to collect a local, redacted health snapshot.", "运行检查以收集本地脱敏健康快照。"),
                columns: [copy.text("Check", "检查项"), copy.text("Result", "结果"), copy.text("Evidence", "证据")],
                rows: [
                    row("configuration", [copy.text("Configuration", "配置"), copy.text("Passed", "已通过"), copy.text("Validated YAML", "YAML 已验证")], .success),
                    row("runtime", [copy.text("Mihomo process", "Mihomo 进程"), copy.text("Passed", "已通过"), copy.text("Responsive", "响应正常")], .success),
                    row("controller", [copy.text("Controller", "控制器"), copy.text("Passed", "已通过"), copy.text("API connected", "API 已连接")], .success),
                    row("network", [copy.text("Internet", "互联网"), copy.text("Needs attention", "需要处理"), copy.text("One probe skipped", "跳过了一个探测")], .warning),
                ],
                inspector: nil
            )
        case .logs:
            return VisualFixturePageSpec(
                title: copy.text("Logs", "日志"),
                subtitle: copy.text("Local redacted application and Mihomo events", "本地脱敏应用与 Mihomo 事件"),
                systemImage: "text.alignleft",
                primaryAction: copy.text("Export Visible", "导出可见日志"),
                emptyTitle: copy.text("No log entries", "没有日志条目"),
                emptyDetail: copy.text("Events from this Vela session will appear here.", "本次 Vela 会话中的事件会显示在这里。"),
                columns: [copy.text("Time", "时间"), copy.text("Level", "级别"), copy.text("Message", "消息")],
                rows: [
                    row("ready", ["10:42:16", "INFO", copy.text("Controller session ready", "控制器会话已就绪")], .success),
                    row("profile", ["10:42:12", "INFO", copy.text("Configuration validated", "配置已验证")], .success),
                    row("provider", ["10:41:58", "WARN", copy.text("Provider refresh deferred", "提供器刷新已推迟")], .warning),
                    row("launch", ["10:41:44", "INFO", copy.text("Runtime started", "运行时已启动")], .success),
                ],
                inspector: nil
            )
        case .settings:
            return VisualFixturePageSpec(
                title: copy.text("Settings", "设置"),
                subtitle: copy.text("General behavior, network integration, and updates", "常规行为、网络集成与更新"),
                systemImage: "gearshape",
                primaryAction: copy.text("Check for Updates", "检查更新"),
                emptyTitle: copy.text("Settings unavailable", "设置不可用"),
                emptyDetail: copy.text("Close and reopen Settings to try again.", "关闭并重新打开设置，然后重试。"),
                columns: [copy.text("Setting", "设置项"), copy.text("Value", "值"), copy.text("Policy", "策略")],
                rows: [
                    row("launch", [copy.text("Launch at Login", "登录时启动"), copy.text("Off", "关闭"), copy.text("Optional", "可选")], .neutral),
                    row("menubar", [copy.text("Menu Bar", "菜单栏"), copy.text("Always available", "始终可用"), copy.text("Recommended", "推荐")], .success),
                    row("updates", [copy.text("Update Channel", "更新通道"), copy.text("Stable", "稳定版"), copy.text("Signed releases", "签名版本")], .success),
                    row("privacy", [copy.text("Diagnostics", "诊断"), copy.text("Local only", "仅本地"), copy.text("Never uploaded automatically", "绝不自动上传")], .success),
                ],
                inspector: nil
            )
        case .tunFlow:
            return VisualFixturePageSpec(
                title: copy.text("Set Up TUN", "设置 TUN"),
                subtitle: copy.text("Install, authorize, start, and verify the privileged backend", "安装、授权、启动并验证特权后端"),
                systemImage: "network.badge.shield.half.filled",
                primaryAction: copy.text("Continue", "继续"),
                emptyTitle: copy.text("TUN setup unavailable", "TUN 设置不可用"),
                emptyDetail: copy.text("Select and validate a configuration before enabling TUN.", "启用 TUN 前，请选择并验证配置。"),
                columns: [copy.text("Milestone", "里程碑"), copy.text("Status", "状态"), copy.text("Detail", "详情")],
                rows: [
                    row("prepare", [copy.text("Prepare configuration", "准备配置"), copy.text("Complete", "已完成"), copy.text("Validation passed", "验证已通过")], .success),
                    row("stop", [copy.text("Stop current backend", "停止当前后端"), copy.text("Complete", "已完成"), copy.text("Ownership released", "所有权已释放")], .success),
                    row("start", [copy.text("Start privileged backend", "启动特权后端"), copy.text("In progress", "进行中"), copy.text("Waiting for handshake", "正在等待握手")], .pending),
                    row("verify", [copy.text("Verify network", "验证网络"), copy.text("Pending", "等待中"), "—"], .neutral),
                ],
                inspector: nil
            )
        case .menuBar:
            return VisualFixturePageSpec(
                title: "Vela",
                subtitle: copy.text("Quick runtime controls", "快速运行时控制"),
                systemImage: "paperplane.circle.fill",
                primaryAction: copy.text("Open Vela", "打开 Vela"),
                emptyTitle: copy.text("Menu unavailable", "菜单不可用"),
                emptyDetail: copy.text("Open the main Vela window to continue.", "打开 Vela 主窗口以继续。"),
                columns: [copy.text("Control", "控制项"), copy.text("State", "状态"), copy.text("Shortcut", "快捷键")],
                rows: [
                    row("runtime", [copy.text("Runtime", "运行时"), copy.text("Running", "运行中"), "⌘R"], .success),
                    row("proxy", [copy.text("System Proxy", "系统代理"), copy.text("On", "开启"), "—"], .success),
                    row("tun", ["TUN", copy.text("Off", "关闭"), "—"], .neutral),
                    row("settings", [copy.text("Settings", "设置"), copy.text("Available", "可用"), "⌘,"] , .info),
                ],
                inspector: nil
            )
        case .updateCoreRecovery:
            return VisualFixturePageSpec(
                title: copy.text("Updates & Core Recovery", "更新与内核恢复"),
                subtitle: copy.text("Signed release verification and recoverable core activation", "签名版本验证与可恢复内核激活"),
                systemImage: "arrow.triangle.2.circlepath.circle",
                primaryAction: copy.text("Check Again", "再次检查"),
                emptyTitle: copy.text("No recovery records", "没有恢复记录"),
                emptyDetail: copy.text("Verified core and update activity will appear here.", "已验证的内核与更新活动会显示在这里。"),
                columns: [copy.text("Component", "组件"), copy.text("Version", "版本"), copy.text("Verification", "验证")],
                rows: [
                    row("app", [copy.text("Vela application", "Vela 应用"), "0.9.0 (1090)", copy.text("Signed · Current", "已签名 · 当前版本")], .success),
                    row("active", [copy.text("Active Mihomo", "当前 Mihomo"), "1.19.28", copy.text("Known good", "已知可用")], .success),
                    row("previous", [copy.text("Previous Mihomo", "上一版 Mihomo"), "1.19.27", copy.text("Recovery ready", "可用于恢复")], .info),
                    row("catalog", [copy.text("Signed catalog", "签名目录"), "Sequence 42", copy.text("Verified", "已验证")], .success),
                ],
                inspector: nil
            )
        case .helpSupport:
            return VisualFixturePageSpec(
                title: copy.text("Help & Support", "帮助与支持"),
                subtitle: copy.text("Product guidance, troubleshooting, and private support export", "产品指南、故障排除与隐私支持导出"),
                systemImage: "questionmark.circle",
                primaryAction: copy.text("Search Help", "搜索帮助"),
                emptyTitle: copy.text("No help articles found", "未找到帮助文章"),
                emptyDetail: copy.text("Try a broader search or choose another category.", "尝试更宽泛的搜索，或选择其他分类。"),
                columns: [copy.text("Article", "文章"), copy.text("Category", "分类"), copy.text("Availability", "可用性")],
                rows: [
                    row("getting-started", [copy.text("Getting Started", "开始使用"), copy.text("Basics", "基础"), copy.text("Available offline", "可离线使用")], .success),
                    row("routing", [copy.text("Connections & Routing", "连接与路由"), copy.text("Networking", "网络"), copy.text("Available offline", "可离线使用")], .success),
                    row("automation", [copy.text("Scenes & Automation", "场景与自动化"), copy.text("Automation", "自动化"), copy.text("Available offline", "可离线使用")], .success),
                    row("support", [copy.text("Diagnostics & Support", "诊断与支持"), copy.text("Troubleshooting", "故障排除"), copy.text("Available offline", "可离线使用")], .success),
                ],
                inspector: nil
            )
        }
    }

    private static func row(
        _ id: String,
        _ cells: [String],
        _ status: VelaSemanticStatus?
    ) -> VisualFixtureRowSpec {
        VisualFixtureRowSpec(id: id, cells: cells, status: status)
    }

    private static func inspector(
        title: String,
        copy: VisualFixtureLocalizedCopy,
        identity: [(String, String)],
        evidence: [(String, String)]
    ) -> VisualFixtureInspectorSpec {
        VisualFixtureInspectorSpec(
            title: title,
            sections: [
                (copy.text("Identity", "标识"), identity.map { (label: $0.0, value: $0.1) }),
                (copy.text("Evidence", "证据"), evidence.map { (label: $0.0, value: $0.1) }),
            ]
        )
    }
}
#endif
