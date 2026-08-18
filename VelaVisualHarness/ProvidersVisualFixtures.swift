#if DEBUG
import SwiftUI

nonisolated enum ProvidersVisualScenario: String, Sendable {
    case automatic
    case refreshingSelected
    case refreshingAll
    case partialFailureSelected
    case updateAllPartialResult
    case proxySelected
    case ruleSelected

    static let argumentKey = "-VelaProvidersScenario"

    static func resolve(arguments: [String] = ProcessInfo.processInfo.arguments) -> Self {
        guard let index = arguments.lastIndex(of: argumentKey) else { return .automatic }
        let valueIndex = arguments.index(after: index)
        guard valueIndex < arguments.endIndex,
            let value = Self(rawValue: arguments[valueIndex])
        else { return .automatic }
        return value
    }
}

nonisolated struct ProvidersVisualSnapshot: Equatable, Sendable {
    let rows: [ProviderRowModel]
    let selectedID: ProviderIdentity?
    let contentState: ProvidersContentState
    let message: String?
    let messageStatus: VelaSemanticStatus?
    let progress: String?
    let actionsEnabled: Bool
}

enum ProvidersVisualFixtureFactory {
    private static let profileID = UUID(uuidString: "40000000-0000-0000-0000-000000000001")!
    private static let generation = UUID(uuidString: "50000000-0000-0000-0000-000000000001")!

    static func snapshot(
        configuration: VisualUITestConfiguration,
        scenario explicitScenario: ProvidersVisualScenario = .resolve()
    ) -> ProvidersVisualSnapshot {
        let zh = configuration.localeIdentifier == .simplifiedChinese
        let scenario = resolvedScenario(explicitScenario, state: configuration.state)
        let catalog = loadedCatalog()
        var running: Set<ProviderOperationKey> = []
        var outcomes: [ProviderOperationKey: ProviderBatchOutcome] = [:]
        var message: String?
        var messageStatus: VelaSemanticStatus?
        var progress: String?
        var contentState: ProvidersContentState = .loaded
        var actionsEnabled = true

        switch configuration.state {
        case .loading:
            contentState = .loading
            actionsEnabled = false
        case .empty:
            contentState = .globalEmpty
            actionsEnabled = false
        case .failure:
            contentState = .failure
            message = zh ? "无法读取提供器目录。请重试或打开诊断。" : "The provider catalog is unavailable. Retry or open Diagnostics."
            messageStatus = .error
            actionsEnabled = false
        case .pendingMutation:
            message = zh ? "正在应用配置；继续显示已提交的提供器代际。" : "Applying configuration; the committed provider generation remains visible."
            messageStatus = .pending
            actionsEnabled = false
        case .refreshing:
            break
        case .partialFailure:
            let failed = ProviderOperationKey(kind: .rule, name: "Media Rules")
            outcomes[failed] = ProviderBatchOutcome(operation: .update, result: .failure(.updateFailed))
            message = zh ? "Media Rules 更新失败；其他提供器已完成。" : "Media Rules failed to update; other providers completed."
            messageStatus = .warning
        case .loaded:
            break
        case .offline, .stale, .permissionRequired, .transitioning, .rollbackFailed:
            break
        }

        switch scenario {
        case .automatic:
            break
        case .refreshingSelected:
            running = [ProviderOperationKey(kind: .proxy, name: "Edge Nodes")]
            progress = zh ? "正在更新 Edge Nodes" : "Updating Edge Nodes"
        case .refreshingAll:
            running = Set(allKeys(in: catalog))
            progress = zh ? "正在更新提供器 · 2 / 3" : "Updating providers · 2 of 3"
        case .partialFailureSelected:
            let failed = ProviderOperationKey(kind: .rule, name: "Media Rules")
            outcomes = [
                failed: ProviderBatchOutcome(operation: .update, result: .failure(.updateFailed)),
            ]
            message = zh ? "Media Rules 更新失败；可重试该提供器。" : "Media Rules failed to update; retry this provider."
            messageStatus = .warning
        case .updateAllPartialResult:
            outcomes = [
                ProviderOperationKey(kind: .proxy, name: "Edge Nodes"): ProviderBatchOutcome(operation: .update, result: .success(())),
                ProviderOperationKey(kind: .rule, name: "Private Networks"): ProviderBatchOutcome(operation: .update, result: .success(())),
                ProviderOperationKey(kind: .rule, name: "Media Rules"): ProviderBatchOutcome(operation: .update, result: .failure(.updateFailed)),
            ]
            message = zh ? "2 个成功 · 1 个失败；每个提供器独立提交。" : "2 succeeded · 1 failed; each provider commits independently."
            messageStatus = .warning
        case .proxySelected, .ruleSelected:
            break
        }

        let rows: [ProviderRowModel]
        if contentState == .loaded {
            rows = ProvidersTablePresentation.rows(
                snapshot: catalog,
                activeProfileID: profileID,
                runtimeGeneration: generation,
                runningOperations: running,
                outcomes: outcomes
            )
        } else {
            rows = []
        }
        let selectedID: ProviderIdentity?
        if scenario == .ruleSelected || scenario == .partialFailureSelected
            || configuration.state == .partialFailure
            || scenario == .updateAllPartialResult
        {
            selectedID = rows.first { $0.kind == .rule && $0.rawName == "Media Rules" }?.id
        } else {
            selectedID = rows.first { $0.kind == .proxy }?.id
        }

        return ProvidersVisualSnapshot(
            rows: rows,
            selectedID: selectedID,
            contentState: contentState,
            message: message,
            messageStatus: messageStatus,
            progress: progress,
            actionsEnabled: actionsEnabled && running.isEmpty
        )
    }

    private static func resolvedScenario(
        _ scenario: ProvidersVisualScenario,
        state: VisualUITestConfiguration.State
    ) -> ProvidersVisualScenario {
        guard scenario == .automatic else { return scenario }
        return switch state {
        case .refreshing: .refreshingSelected
        case .partialFailure: .partialFailureSelected
        default: .automatic
        }
    }

    private static func loadedCatalog() -> ProviderCatalogSnapshot {
        let nodes = [
            proxy(name: "Edge 01", alive: true, delay: 42),
            proxy(name: "Edge 02", alive: true, delay: 68),
            proxy(name: "Edge 03", alive: false, delay: 0),
            proxy(name: "Edge 04", alive: nil, delay: nil),
        ]
        return ProviderCatalogSnapshot(
            proxyProviders: [
                "Edge Nodes": MihomoProxyProvider(
                    name: "Edge Nodes",
                    type: "Proxy",
                    vehicleType: "HTTP",
                    proxies: nodes,
                    testURL: "https://example.invalid/check?token=redacted",
                    expectedStatus: "204",
                    updatedAt: "2026-07-18 10:36",
                    subscriptionInfo: MihomoSubscriptionInfo(
                        upload: 1_024_000,
                        download: 8_192_000,
                        total: 107_374_182_400,
                        expire: 1_798_761_600
                    )
                ),
            ],
            ruleProviders: [
                "Private Networks": MihomoRuleProvider(
                    behavior: "domain",
                    format: "yaml",
                    name: "Private Networks",
                    ruleCount: 18,
                    type: "Rule",
                    vehicleType: "HTTP",
                    updatedAt: "2026-07-18 10:32",
                    payload: nil
                ),
                "Media Rules": MihomoRuleProvider(
                    behavior: "classical",
                    format: "mrs",
                    name: "Media Rules",
                    ruleCount: 42,
                    type: "Rule",
                    vehicleType: "HTTP",
                    updatedAt: "2026-07-18 09:58",
                    payload: nil
                ),
            ]
        )
    }

    private static func allKeys(in snapshot: ProviderCatalogSnapshot) -> [ProviderOperationKey] {
        snapshot.proxyProviders.keys.map { ProviderOperationKey(kind: .proxy, name: $0) }
            + snapshot.ruleProviders.keys.map { ProviderOperationKey(kind: .rule, name: $0) }
    }

    private static func proxy(name: String, alive: Bool?, delay: UInt16?) -> MihomoProxy {
        let delayJSON = delay.map { #", "history": [{"time":"2026-07-18T10:36:00Z","delay":\#($0)}]"# } ?? ""
        let aliveJSON = alive.map(String.init) ?? "null"
        let data = Data(#"{"name":"\#(name)","type":"ss","alive":\#(aliveJSON)\#(delayJSON)}"#.utf8)
        do {
            return try JSONDecoder().decode(MihomoProxy.self, from: data)
        } catch {
            preconditionFailure("The deterministic provider fixture must decode: \(error)")
        }
    }
}

struct ProvidersVisualFixtureView: View {
    let configuration: VisualUITestConfiguration
    let snapshot: ProvidersVisualSnapshot
    @State private var selectedID: ProviderIdentity?
    @State private var isInspectorPresented: Bool
    @State private var filter: ProviderFilter = .all
    @State private var searchText = ""

    init(configuration: VisualUITestConfiguration) {
        self.configuration = configuration
        let snapshot = ProvidersVisualFixtureFactory.snapshot(configuration: configuration)
        self.snapshot = snapshot
        _selectedID = State(initialValue: snapshot.selectedID)
        _isInspectorPresented = State(initialValue: configuration.inspector == .open)
    }

    var body: some View {
        ZStack {
            VelaPageCanvas()

            VStack(alignment: .leading, spacing: VelaSpacing.medium) {
                pageHeader

                HStack(alignment: .top, spacing: VelaSpacing.medium) {
                    VStack(spacing: 0) {
                        if let message = snapshot.message, let status = snapshot.messageStatus {
                            VelaStateBanner(
                                kind: status == .error ? .error : (status == .warning ? .warning : .info),
                                title: status == .error
                                    ? copy.text("Provider Catalog Unavailable", "提供器目录不可用")
                                    : copy.text("Provider Status", "提供器状态"),
                                detail: message
                            )
                            .padding(.horizontal, VelaSpacing.standard)
                            .padding(.top, VelaSpacing.medium)
                        }

                        toolbar
                        Divider()
                        content
                        if snapshot.contentState == .loaded {
                            Divider()
                            HStack {
                                Text(selectedRow?.rawName ?? copy.text("No Provider Selected", "未选择提供器"))
                                    .font(VelaTypography.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button(copy.text("Update", "更新")) {}
                                    .disabled(!snapshot.actionsEnabled || selectedRow == nil)
                                if selectedRow?.kind == .proxy {
                                    Button(copy.text("Health Check", "健康检查")) {}
                                        .disabled(!snapshot.actionsEnabled)
                                }
                            }
                            .controlSize(.small)
                            .padding(.horizontal, VelaSpacing.standard)
                            .padding(.vertical, VelaSpacing.small)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .velaPanelSurface()

                    if isInspectorPresented {
                        Group {
                            if let selectedRow {
                                ProviderDetailInspector(
                                    row: selectedRow,
                                    activeProfileID: selectedRow.id.activeProfileID,
                                    update: {},
                                    healthCheck: selectedRow.kind == .proxy ? {} : nil,
                                    openRelatedPage: {},
                                    openConfiguration: {}
                                )
                            } else {
                                ProviderInspectorPlaceholder(state: snapshot.contentState)
                            }
                        }
                        .frame(width: VelaMetrics.inspectorIdealWidth)
                        .frame(maxHeight: .infinity, alignment: .topLeading)
                        .velaPanelSurface()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(VelaSpacing.standard)
        }
        .velaPageRoot()
        .navigationTitle(copy.text("Providers", "提供器"))
        .overlay(alignment: .topLeading) {
            VisualReadyMarker(fixtureID: configuration.fixtureID)
            VisualSurfaceMarker(identifier: "providers.tableInspector", label: "Providers table and inspector")
            if reduceMotionRequested {
                VisualSurfaceMarker(
                    identifier: "providers.accessibility.reduceMotion",
                    label: "Providers Reduce Motion"
                )
            }
            if increasedContrastRequested {
                VisualSurfaceMarker(
                    identifier: "providers.accessibility.increasedContrast",
                    label: "Providers Increase Contrast"
                )
            }
        }
        .environment(
            \.velaAccessibilityOverrides,
            VelaAccessibilityOverrides(
                reduceMotion: reduceMotionRequested,
                increasedContrast: increasedContrastRequested
            )
        )
    }

    private var pageHeader: some View {
        HStack(alignment: .center, spacing: VelaSpacing.medium) {
            VStack(alignment: .leading, spacing: VelaSpacing.micro) {
                Text(copy.text("Providers", "提供器"))
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                Text(copy.text(
                    "Review proxy and rule provider freshness.",
                    "检查代理与规则提供器的新鲜度。"
                ))
                .font(VelaTypography.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: VelaSpacing.large)

            HStack(spacing: VelaSpacing.small) {
                HStack(spacing: VelaSpacing.small) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField(
                        copy.text("Name, kind, source, or status", "名称、类型、来源或状态"),
                        text: $searchText
                    )
                    .textFieldStyle(.plain)
                }
                .padding(.horizontal, VelaSpacing.medium)
                .frame(width: 260, height: 40)
                .velaPanelSurface(radius: 14)

                Button(copy.text("Refresh", "刷新"), systemImage: "arrow.clockwise") {}
                    .buttonStyle(.bordered)

                Button(copy.text("Inspector", "检查器"), systemImage: "sidebar.trailing") {
                    isInspectorPresented.toggle()
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: VelaSpacing.medium) {
            Picker(copy.text("Provider Type", "提供器类型"), selection: $filter) {
                Text(copy.text("All", "全部")).tag(ProviderFilter.all)
                Text(copy.text("Proxy", "代理")).tag(ProviderFilter.proxy)
                Text(copy.text("Rule", "规则")).tag(ProviderFilter.rule)
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .frame(width: 230)
            Text(copy.text("\(visibleRows.count) of \(snapshot.rows.count) providers", "\(visibleRows.count) / \(snapshot.rows.count) 个提供器"))
                .font(VelaTypography.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
            if let progress = snapshot.progress {
                VelaStatusPill(status: .pending, label: progress)
            }
            if snapshot.actionsEnabled, !snapshot.rows.isEmpty {
                Button(copy.text("Update All", "全部更新")) {}
            }
        }
        .controlSize(.small)
        .padding(.horizontal, VelaSpacing.standard)
        .padding(.vertical, VelaSpacing.small)
    }

    @ViewBuilder
    private var content: some View {
        switch snapshot.contentState {
        case .loading:
            ProviderTableLoadingView()
        case .loaded:
            GeometryReader { proxy in
                switch ProviderTableDensity.resolve(availableWidth: proxy.size.width) {
                case .compact: compactTable
                case .regular: regularTable
                case .spacious: spaciousTable
                }
            }
        case .globalEmpty:
            fixtureEmpty(
                title: copy.text("No Providers", "没有提供器"),
                description: copy.text("The active configuration does not define any providers.", "当前配置未定义任何提供器。"),
                action: copy.text("Open Configuration", "打开配置")
            )
        case .failure:
            fixtureEmpty(
                title: copy.text("Provider Catalog Unavailable", "提供器目录不可用"),
                description: copy.text("Retry or open Diagnostics for controller evidence.", "重试或打开诊断查看控制器证据。"),
                action: copy.text("Try Again", "重试")
            )
        case .kindEmpty, .filteredEmpty:
            fixtureEmpty(
                title: copy.text("No Matching Providers", "没有匹配的提供器"),
                description: copy.text("Adjust the local filter or search.", "调整本地筛选或搜索。"),
                action: copy.text("Show All", "显示全部")
            )
        }
    }

    private var compactTable: some View {
        Table(visibleRows, selection: $selectedID) {
            TableColumn(copy.text("Provider", "提供器")) { row in nameCell(row) }
            TableColumn(copy.text("Kind", "类型")) { row in kindCell(row) }.width(70)
            TableColumn(copy.text("Items", "项目")) { row in itemsCell(row) }.width(54)
            TableColumn(copy.text("Status", "状态")) { row in statusCell(row) }.width(min: 90, ideal: 116)
        }
        .scrollContentBackground(.hidden)
    }

    private var regularTable: some View {
        Table(visibleRows, selection: $selectedID) {
            TableColumn(copy.text("Provider", "提供器")) { row in nameCell(row) }
            TableColumn(copy.text("Kind", "类型")) { row in kindCell(row) }.width(70)
            TableColumn(copy.text("Items", "项目")) { row in itemsCell(row) }.width(54)
            TableColumn(copy.text("Last Update", "上次更新")) { row in updatedCell(row) }.width(min: 100, ideal: 126)
            TableColumn(copy.text("Status", "状态")) { row in statusCell(row) }.width(min: 90, ideal: 116)
        }
        .scrollContentBackground(.hidden)
    }

    private var spaciousTable: some View {
        Table(visibleRows, selection: $selectedID) {
            TableColumn(copy.text("Provider", "提供器")) { row in nameCell(row) }
            TableColumn(copy.text("Kind", "类型")) { row in kindCell(row) }.width(70)
            TableColumn(copy.text("Source / Vehicle", "来源 / 载体")) { row in Text(row.vehicle ?? "—") }.width(110)
            TableColumn(copy.text("Items", "项目")) { row in itemsCell(row) }.width(54)
            TableColumn(copy.text("Last Update", "上次更新")) { row in updatedCell(row) }.width(126)
            TableColumn(copy.text("Next Update", "下次更新")) { _ in Text(copy.text("Not Reported", "未报告")).foregroundStyle(.secondary) }.width(110)
            TableColumn(copy.text("Status", "状态")) { row in statusCell(row) }.width(min: 90, ideal: 116)
        }
        .scrollContentBackground(.hidden)
    }

    private func nameCell(_ row: ProviderRowModel) -> some View {
        Text(verbatim: row.rawName).font(VelaTypography.table.weight(.medium)).padding(.vertical, 3)
    }

    private func kindCell(_ row: ProviderRowModel) -> some View {
        Text(row.kind == .proxy ? copy.text("Proxy", "代理") : copy.text("Rule", "规则"))
            .font(VelaTypography.table)
    }

    private func itemsCell(_ row: ProviderRowModel) -> some View {
        Text(row.itemCount, format: .number).font(VelaTypography.table.monospacedDigit())
    }

    private func updatedCell(_ row: ProviderRowModel) -> some View {
        Text(row.updatedAt ?? copy.text("Not Reported", "未报告")).font(VelaTypography.table)
    }

    private func statusCell(_ row: ProviderRowModel) -> some View {
        let status = ProviderRowStatusPresentation.resolve(row)
        return VelaStatusPill(status: status.status, label: status.label, detail: status.detail)
    }

    private func fixtureEmpty(title: String, description: String, action: String) -> some View {
        VelaEmptyState(title: title, description: description, systemImage: "shippingbox") {
            Button(action) {}
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var visibleRows: [ProviderRowModel] {
        ProvidersTablePresentation.filter(snapshot.rows, kind: filter, query: searchText)
    }

    private var selectedRow: ProviderRowModel? {
        guard let selectedID else { return nil }
        return snapshot.rows.first { $0.id == selectedID }
    }

    private var copy: VisualFixtureLocalizedCopy {
        VisualFixtureLocalizedCopy(locale: configuration.localeIdentifier)
    }

    private var reduceMotionRequested: Bool {
        launchFlag("-VelaProvidersReduceMotion")
    }

    private var increasedContrastRequested: Bool {
        launchFlag("-VelaProvidersIncreaseContrast")
    }

    private func launchFlag(_ key: String) -> Bool {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.lastIndex(of: key) else { return false }
        let valueIndex = arguments.index(after: index)
        guard valueIndex < arguments.endIndex else { return false }
        return ["yes", "true", "1"].contains(arguments[valueIndex].lowercased())
    }
}
#endif
