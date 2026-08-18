import Foundation
import VelaIPC

nonisolated struct OverviewStrings {
    let locale: Locale

    private var isChinese: Bool { locale.language.languageCode?.identifier == "zh" }

    func text(_ english: String, _ chinese: String) -> String { isChinese ? chinese : english }

    var overview: String { text("Overview", "概览") }
    var connected: String { text("CONNECTED", "已连接") }
    var connecting: String { text("CONNECTING", "正在连接") }
    var disconnected: String { text("DISCONNECTED", "未连接") }
    var degraded: String { text("DEGRADED", "连接受限") }
    var error: String { text("ERROR", "连接异常") }
    var noConfiguration: String { text("NO CONFIGURATION", "尚无配置") }
    var download: String { text("Download", "下载") }
    var upload: String { text("Upload", "上传") }
    var connections: String { text("Connections", "连接数") }
    var runtime: String { text("Runtime", "运行时间") }
    var thisMac: String { text("This Mac", "这台 Mac") }
    var device: String { text("Device", "本机设备") }
    var internet: String { text("Internet", "互联网") }
    var direct: String { text("Direct", "直连") }
    var noNode: String { text("No proxy selected", "未选择代理节点") }
    var noGroup: String { text("Proxy group unavailable", "代理组不可用") }
    var noLatency: String { text("Latency unavailable", "延迟不可用") }
    var selectNode: String { text("Select proxy node", "选择代理节点") }
    var selectGroup: String { text("Select proxy group", "选择代理组") }
    var searchNodes: String { text("Search nodes", "搜索节点") }
    var noMatchingNodes: String { text("No matching nodes", "没有匹配的节点") }
    var otherNodes: String { text("Other", "其他") }
    var selectMode: String { text("Select proxy mode", "选择代理模式") }
    var systemProxy: String { text("System Proxy", "系统代理") }
    var tun: String { "TUN" }
    var on: String { text("On", "已开启") }
    var off: String { text("Off", "已关闭") }
    var controllerUnavailable: String { text("The Controller is still connecting.", "Controller 仍在连接。") }
    var tunUnavailable: String { text("Finish setting up the privileged component before enabling TUN.", "请先完成特权组件设置，再启用 TUN。") }
    var openConnections: String { text("Open Connections", "打开连接详情") }
    var openProxies: String { text("Open Proxies", "打开代理节点") }
    var start: String { text("Connect", "连接") }
    var pause: String { text("Disconnect", "断开") }
    var chooseConfiguration: String { text("Add Configuration", "添加配置") }
    var retry: String { text("Try Again", "重试") }
    var openDiagnostics: String { text("Open Diagnostics", "打开诊断") }
    var operationInProgress: String { text("A connection operation is already in progress.", "连接操作正在进行。") }
    var startUnavailable: String { text("Wait for Vela to finish preparing the connection.", "请等待 Vela 完成连接准备。") }
    var modeUnavailable: String { text("Connection services are still preparing. Try again shortly.", "连接服务仍在准备，请稍后重试。") }
    var noConfigurationTitle: String { text("Choose a route to begin", "选择配置，开始航行") }
    var noConfigurationDetail: String { text("Add or select a Mihomo configuration. Vela will never invent a node or traffic value.", "添加或选择 Mihomo 配置。Vela 不会用虚假节点或流量填充此页面。") }
    var disconnectedTitle: String { text("Ready when you are", "准备就绪") }
    var disconnectedDetail: String { text("Your configuration is ready. Connect when you want Vela to take over system traffic.", "配置已就绪，需要时连接即可让 Vela 接管系统流量。") }
    var controllerErrorTitle: String { text("Connection service is unavailable", "连接服务暂不可用") }
    var controllerErrorDetail: String { text("Vela could not prepare traffic routing. Try again or open Diagnostics for details.", "Vela 暂时无法准备流量路由，请重试或打开诊断查看详情。") }
    var degradedTitle: String { text("Connection needs attention", "连接需要关注") }
    var degradedDetail: String { text("Traffic continues while one or more health checks need review.", "流量仍在传输，但有健康检查需要处理。") }
    var statusHelp: String { text("Connection status. Activate to connect or disconnect.", "连接状态。按下可连接或断开。") }
    var configuration: String { text("Configuration", "配置") }
    var unconfigured: String { text("Not configured", "未配置") }
    var notTested: String { text("Not tested", "未测试") }
    var unavailable: String { text("Unavailable", "不可用") }
    var connectedRoute: String { text("Protected route", "受保护路由") }
    var lastKnownRoute: String { text("Last selected route", "上次选择的路由") }
    var routeReady: String { text("Ready", "已就绪") }
    var routeUnavailable: String { text("Route unavailable", "路由不可用") }

    func availableNodeCount(_ count: Int) -> String {
        text("\(count) nodes", "\(count) 个节点")
    }

    func modeTitle(_ mode: MihomoMode) -> String {
        switch mode {
        case .rule: text("Rule", "规则")
        case .global: text("Global", "全局")
        case .direct: text("Direct", "直连")
        }
    }

    func regionCode(for nodeName: String) -> String? {
        let lowered = nodeName.lowercased()
        if lowered.contains("tokyo") || lowered.contains("japan") || lowered.contains("日本") || lowered.contains("东京") { return "JP" }
        if lowered.contains("singapore") || lowered.contains("新加坡") { return "SG" }
        if lowered.contains("seattle") || lowered.contains("united states") || lowered.contains("美国") { return "US" }
        if lowered.contains("hong kong") || lowered.contains("香港") { return "HK" }
        if lowered.contains("taiwan") || lowered.contains("台湾") { return "TW" }
        if lowered.contains("germany") || lowered.contains("frankfurt") || lowered.contains("德国") { return "DE" }
        return nil
    }
}
