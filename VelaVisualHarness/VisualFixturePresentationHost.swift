#if DEBUG
import SwiftUI

/// Unified entry point for Debug-only visual presentations.
///
/// Root scene integration can use the boundary-specific hosts directly, or
/// this dispatcher when the capture boundary is already represented by the
/// containing scene.
struct VisualFixtureBoundaryHost: View {
    let configuration: VisualUITestConfiguration

    var body: some View {
        switch configuration.page {
        case .tunFlow:
            VisualFixtureTunFlowHost(configuration: configuration)
        case .menuBar:
            VisualFixtureMenuContent(configuration: configuration)
        case .overview, .proxies, .connections, .rules, .providers,
             .workbench, .diagnostics, .logs, .settings, .updateCoreRecovery,
             .helpSupport:
            VisualFixtureMainWindowHost(configuration: configuration)
        }
    }
}

/// Complete deterministic main-window shell for all main-window routes.
struct VisualFixtureMainWindowHost: View {
    let configuration: VisualUITestConfiguration
    @State private var selection: AppSection?

    init(configuration: VisualUITestConfiguration) {
        self.configuration = configuration
      _selection = State(
        initialValue: configuration.page.appSection
          ?? Self.fallbackSection(
            for: configuration.page
        ))
    }

    var body: some View {
      Group {
        if configuration.page == .helpSupport {
          HelpSupportVisualFixtureView(configuration: configuration)
        } else {
          HStack(spacing: 0) {
            SidebarView(
              selection: $selection,
              isServiceRunning: configuration.state != .offline
                && configuration.state != .failure,
              coreVersion: MihomoCoreDescriptor.requiredVersion
            )
            .frame(width: SidebarView.width)
            .clipped()
            .overlay(alignment: .topLeading) {
              VisualSurfaceMarker(
                identifier: "main.sidebar",
                label: "Vela main sidebar"
              )
            }

            detailDestination
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .topLeading) {
              VisualSurfaceMarker(
                identifier: "main.detail",
                label: "Vela main detail"
              )
              if overviewAccessibilityOverrides.reduceMotion == true {
                VisualSurfaceMarker(
                  identifier: "overview.accessibility.reduceMotion",
                  label: "Overview Reduce Motion"
                )
              }
              if overviewAccessibilityOverrides.increasedContrast == true {
                VisualSurfaceMarker(
                  identifier: "overview.accessibility.increasedContrast",
                  label: "Overview Increase Contrast"
                )
              }
            }
          }
          .ignoresSafeArea(.container, edges: .all)
        }
      }
        .overlay(alignment: .topLeading) {
            VisualReadyMarker(fixtureID: configuration.fixtureID)
            VisualScreenMarker(page: configuration.page.rawValue)
            VisualSurfaceMarker(identifier: "main.toolbar", label: "Vela main toolbar")
        }
        .environment(\.visualUITestConfiguration, configuration)
        .environment(\.locale, configuration.locale)
        .preferredColorScheme(configuration.colorScheme)
    }

    @ViewBuilder
    private var detailDestination: some View {
      if configuration.page == .overview {
        OverviewDashboardView(
          snapshot: OverviewVisualFixtureFactory.snapshot(for: configuration),
          isRefreshing: configuration.state == .loading,
          action: { _ in }
        )
        .environment(
          \.velaAccessibilityOverrides,
          overviewAccessibilityOverrides
        )
      } else if configuration.page == .proxies {
        ProxiesVisualFixtureView(configuration: configuration)
      } else if configuration.page == .connections {
        ConnectionsVisualFixtureView(configuration: configuration)
      } else if configuration.page == .rules {
        RulesVisualFixtureView(configuration: configuration)
      } else if configuration.page == .providers {
        ProvidersVisualFixtureView(configuration: configuration)
      } else if configuration.page == .workbench {
        ConfigurationWorkbenchVisualFixtureView(configuration: configuration)
      } else if configuration.page == .diagnostics {
        DiagnosticsVisualFixtureView(configuration: configuration)
      } else if configuration.page == .logs {
        LogsVisualFixtureView(configuration: configuration)
      } else if configuration.page == .settings {
        SettingsVisualFixtureView(configuration: configuration)
      } else if configuration.page == .updateCoreRecovery {
        UpdatesCoreRecoveryWorkspace(
          snapshot: UpdatesCoreRecoveryVisualFixtureFactory.snapshot(for: configuration),
          initialSelectionID: UpdatesCoreRecoveryVisualFixtureFactory.snapshot(
            for: configuration
          ).banner?.affectedComponentID ?? .application
        )
        .environment(
          \.velaAccessibilityOverrides,
          updatesCoreAccessibilityOverrides
        )
      } else {
        VisualFixturePageStateHost(configuration: configuration)
      }
    }

    private var overviewAccessibilityOverrides: VelaAccessibilityOverrides {
        VelaAccessibilityOverrides(
            reduceMotion: launchFlag("-VelaOverviewReduceMotion"),
            increasedContrast: launchFlag("-VelaOverviewIncreaseContrast")
        )
    }

    private var updatesCoreAccessibilityOverrides: VelaAccessibilityOverrides {
        VelaAccessibilityOverrides(
            reduceMotion: launchFlag("-VelaUpdatesCoreReduceMotion"),
            increasedContrast: launchFlag("-VelaUpdatesCoreIncreaseContrast")
        )
    }

    private func launchFlag(_ key: String) -> Bool? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.lastIndex(of: key) else { return nil }
        let valueIndex = arguments.index(after: index)
        guard valueIndex < arguments.endIndex else { return nil }
        return switch arguments[valueIndex].lowercased() {
        case "yes", "true", "1": true
        case "no", "false", "0": false
        default: nil
        }
    }

    private static func fallbackSection(
        for page: VisualUITestConfiguration.Page
    ) -> AppSection {
        switch page {
        case .updateCoreRecovery:
            .diagnostics
        case .helpSupport:
            .overview
        case .settings:
            .settings
        case .tunFlow, .menuBar:
            .overview
        case .overview, .proxies, .connections, .rules, .providers,
             .workbench, .diagnostics, .logs:
            page.appSection ?? .overview
        }
    }
}

/// Standalone deterministic TUN sheet for every registered TUN state.
struct VisualFixtureTunFlowHost: View {
    let configuration: VisualUITestConfiguration

    var body: some View {
        TunFlowVisualFixtureView(configuration: configuration)
    }
}

/// MenuBarExtra-compatible fixture content. It deliberately uses native menu
/// primitives so AppKit can bridge the rows to NSMenuItems for AX capture.
struct VisualFixtureMenuContent: View {
    let configuration: VisualUITestConfiguration

    var body: some View {
        MenuBarVisualFixtureView(configuration: configuration)
    }
}

private struct VisualFixturePageStateHost: View {
    let configuration: VisualUITestConfiguration
    var compactHeader = false

    private var spec: VisualFixturePageSpec {
        VisualFixturePresentationCatalog.pageSpec(for: configuration)
    }

    private var copy: VisualFixtureLocalizedCopy {
        VisualFixtureLocalizedCopy(locale: configuration.localeIdentifier)
    }

    var body: some View {
        switch configuration.state {
        case .loading:
            readyBranch {
                shell {
                    fixtureLoading
                    if preservesTableHeaderDuringUnavailableStates {
                        VisualFixtureSkeletonTable(columns: spec.columns)
                    }
                }
            }
        case .loaded:
            readyBranch {
                shell {
                    loadedContent(alternatingRows: true)
                }
            }
        case .empty:
            readyBranch {
                shell {
                    if preservesTableHeaderDuringUnavailableStates {
                        emptyDataTable
                    }
                    VelaEmptyState(
                        title: spec.emptyTitle,
                        description: spec.emptyDetail,
                        systemImage: spec.systemImage
                    ) {
                        Button(spec.primaryAction) {}
                    }
                }
            }
        case .refreshing:
            readyBranch {
                shell {
                    stateBanner(
                        kind: .info,
                        title: copy.text("Refreshing", "正在刷新"),
              detail: copy.text(
                "Showing the last complete snapshot while new evidence is collected.",
                "收集新证据时，继续显示上一个完整快照。")
                    )
                    loadedContent(alternatingRows: false)
                }
            }
        case .pendingMutation:
            readyBranch {
                shell {
                    stateBanner(
                        kind: .info,
                        title: copy.text("Change in progress", "正在更改"),
              detail: copy.text(
                "Vela is applying the requested change as one recoverable transaction.",
                "Vela 正在以单个可恢复事务应用所请求的更改。")
                    )
                    loadedContent(alternatingRows: false, disabled: true)
                }
            }
        case .partialFailure:
            readyBranch {
                shell {
                    stateBanner(
                        kind: .warning,
                        title: copy.text("Some information needs attention", "部分信息需要处理"),
              detail: copy.text(
                "Available results remain visible. Review the highlighted item before retrying.",
                "可用结果仍会显示。重试前请检查突出显示的项目。")
                    )
                    loadedContent(alternatingRows: false)
                }
            }
        case .failure:
            readyBranch {
                shell {
                    stateBanner(
                        kind: .error,
                        title: copy.text("Could not load this page", "无法载入此页面"),
              detail: copy.text(
                "The fixture failed safely without changing the active network configuration.",
                "夹具已安全失败，且未更改当前网络配置。"),
                        action: copy.text("Try Again", "重试")
                    )
                    if preservesTableHeaderDuringUnavailableStates {
                        emptyDataTable
                    }
                    VelaEmptyState(
                        title: copy.text("No results available", "没有可用结果"),
              description: copy.text(
                "Resolve the error above, then retry the operation.", "解决上方错误后重试操作。"),
                        systemImage: "exclamationmark.triangle"
                    )
                }
            }
        case .offline:
            readyBranch {
                shell {
                    stateBanner(
                        kind: .warning,
                        title: copy.text("Offline", "离线"),
              detail: copy.text(
                "Live runtime data is unavailable. Local, previously verified information remains visible.",
                "实时运行数据不可用。本地已验证信息仍会显示。")
                    )
                    if configuration.page == .helpSupport {
                        loadedContent(alternatingRows: false)
                    } else {
                        if preservesTableHeaderDuringUnavailableStates {
                            emptyDataTable
                        }
                        VelaEmptyState(
                            title: copy.text("Live data unavailable", "实时数据不可用"),
                description: copy.text(
                  "Reconnect the runtime, then refresh this page.", "重新连接运行时，然后刷新此页面。"),
                            systemImage: "network.slash"
                        )
                    }
                }
            }
        case .stale:
            readyBranch {
                shell {
                    stateBanner(
                        kind: .stale,
                        title: copy.text("Snapshot may be out of date", "快照可能已过期"),
              detail: copy.text(
                "Values below came from the last successful refresh.", "下方数值来自上次成功刷新。"),
                        action: copy.text("Refresh", "刷新")
                    )
                    loadedContent(alternatingRows: false)
                }
            }
        case .permissionRequired:
            readyBranch {
                shell {
                    stateBanner(
                        kind: .permission,
                        title: copy.text("Permission required", "需要权限"),
                        detail: permissionDetail,
                        action: copy.text("Review Permission", "检查权限")
                    )
                    permissionChecklist
                }
            }
        case .transitioning:
            readyBranch {
                shell {
                    stateBanner(
                        kind: .info,
                        title: copy.text("Transition in progress", "正在切换"),
              detail: copy.text(
                "The previous working state is retained until verification succeeds.",
                "验证成功前会保留先前的可用状态。")
                    )
                    transitionProgress
                }
            }
        case .rollbackFailed:
            readyBranch {
                shell {
                    stateBanner(
                        kind: .recovery,
                        title: copy.text("Manual recovery required", "需要手动恢复"),
              detail: copy.text(
                "The requested change and automatic rollback both failed. Automatic changes are paused.",
                "请求的更改与自动回滚均失败。自动更改已暂停。"),
                        action: copy.text("Open Recovery", "打开恢复")
                    )
                    rollbackSummary
                }
            }
        }
    }

    private func readyBranch<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        Group {
            if VisualFixturePresentationCatalog.supports(configuration) {
                content()
                    .overlay(alignment: .topLeading) {
                        VisualReadyMarker(fixtureID: configuration.fixtureID)
                    }
                    .environment(\.visualUITestConfiguration, configuration)
            } else {
                Text("Unsupported visual fixture")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func shell<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if !compactHeader {
                pageHeader
                Divider()
            }

            HStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: VelaSpacing.standard) {
                        content()
                    }
                    .padding(VelaSpacing.section)
                    .frame(maxWidth: .infinity, minHeight: 420, alignment: .topLeading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                inspectorColumn
            }
        }
        .background(VelaAppearance.contentBackground)
        .velaPageRoot()
    }

    private var pageHeader: some View {
        HStack(spacing: VelaSpacing.medium) {
            Image(systemName: spec.systemImage)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 26)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: VelaSpacing.micro) {
                Text(spec.title)
                    .font(VelaTypography.pageTitle)
                    .accessibilityAddTraits(.isHeader)
                Text(spec.subtitle)
                    .font(VelaTypography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: VelaSpacing.medium)

            VelaStatusPill(
                status: stateStatus,
                label: stateLabel
            )

            Button(spec.primaryAction) {}
                .controlSize(.small)
                .disabled(configuration.state == .loading || configuration.state == .transitioning)
        }
        .padding(.horizontal, VelaSpacing.section)
        .padding(.vertical, VelaSpacing.medium)
        .background(.bar)
    }

    @ViewBuilder
    private var inspectorColumn: some View {
        switch configuration.inspector {
        case .open:
            if let inspector = spec.inspector {
                Divider()
                VisualFixtureInspectorPanel(inspector: inspector)
                    .frame(
                        minWidth: VelaMetrics.inspectorMinimumWidth,
                        idealWidth: VelaMetrics.inspectorIdealWidth,
                        maxWidth: VelaMetrics.inspectorMaximumWidth,
                        maxHeight: .infinity,
                        alignment: .topLeading
                    )
                VisualSurfaceMarker(identifier: "visual.inspector.open", label: "Inspector open")
            }
        case .closed:
            VisualSurfaceMarker(identifier: "visual.inspector.closed", label: "Inspector closed")
        case .notApplicable:
            EmptyView()
        }
    }

    private var fixtureLoading: some View {
        VelaLoadingState(
            title: copy.text("Loading %@…", "正在载入%@…").replacingOccurrences(of: "%@", with: spec.title),
            detail: copy.text("Reading deterministic fixture data", "正在读取确定性夹具数据")
        )
        .velaPanelSurface()
    }

    @ViewBuilder
    private func loadedContent(alternatingRows: Bool, disabled: Bool = false) -> some View {
        switch configuration.page {
        case .overview:
            VisualFixtureOverviewSummary(copy: copy)
            dataTable(alternatingRows: alternatingRows)
        case .diagnostics:
            VisualFixtureDiagnosticsSummary(copy: copy)
            dataTable(alternatingRows: alternatingRows)
        case .helpSupport:
            VisualFixtureHelpSummary(copy: copy, spec: spec)
        case .updateCoreRecovery:
            VisualFixtureUpdateSummary(copy: copy)
            dataTable(alternatingRows: alternatingRows)
        case .settings:
            VisualFixtureSettingsSummary(copy: copy)
            dataTable(alternatingRows: alternatingRows)
        case .tunFlow:
            VisualFixtureTunSummary(copy: copy)
            dataTable(alternatingRows: alternatingRows)
        case .menuBar:
            dataTable(alternatingRows: alternatingRows)
        case .proxies, .connections, .rules, .providers,
             .workbench, .logs:
            dataTable(alternatingRows: alternatingRows)
        }
        if disabled {
        Text(
          copy.text(
            "Controls are temporarily disabled until the transaction completes.", "事务完成前，控制项暂时不可用。")
        )
                .font(VelaTypography.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func dataTable(alternatingRows: Bool) -> some View {
        VisualFixtureDataTable(
            columns: spec.columns,
            rows: spec.rows,
            usesAlternatingRows: alternatingRows
        )
    }

    private var emptyDataTable: some View {
        VisualFixtureDataTable(
            columns: spec.columns,
            rows: [],
            usesAlternatingRows: false
        )
    }

    private var preservesTableHeaderDuringUnavailableStates: Bool {
        configuration.page == .connections || configuration.page == .rules
    }

    private func stateBanner(
        kind: VelaStateBannerKind,
        title: String,
        detail: String,
        action: String? = nil
    ) -> some View {
        VelaStateBanner(kind: kind, title: title, detail: detail) {
            if let action {
                Button(action) {}
            }
        }
    }

    private var permissionDetail: String {
        switch configuration.page {
        case .tunFlow:
        copy.text(
          "Approve the Privileged Component in macOS, then return to Vela to verify it.",
          "请在 macOS 中批准特权组件，然后返回 Vela 进行验证。")
        case .diagnostics:
        copy.text(
          "Allow the requested local check before collecting its evidence.", "收集证据前，请允许所请求的本地检查。")
        default:
            copy.text("Review the macOS permission before continuing.", "继续前请检查 macOS 权限。")
        }
    }

    private var permissionChecklist: some View {
        VStack(alignment: .leading, spacing: VelaSpacing.medium) {
            VelaSectionHeader(copy.text("Before continuing", "继续之前"))
            permissionRow(copy.text("The action is initiated explicitly", "操作由你明确发起"), complete: true)
            permissionRow(copy.text("No terminal commands are required", "无需终端命令"), complete: true)
        permissionRow(
          copy.text("macOS approval is still pending", "仍在等待 macOS 批准"), complete: false)
        }
        .padding(VelaSpacing.standard)
        .velaPanelSurface()
    }

    private func permissionRow(_ title: String, complete: Bool) -> some View {
        Label(title, systemImage: complete ? "checkmark.circle.fill" : "circle")
            .font(VelaTypography.body)
            .foregroundStyle(complete ? Color.green : Color.secondary)
    }

    private var transitionProgress: some View {
        VStack(alignment: .leading, spacing: VelaSpacing.medium) {
            VelaSectionHeader(copy.text("Transaction progress", "事务进度"))
            transitionRow(copy.text("Prepare and validate", "准备并验证"), status: .success)
            transitionRow(copy.text("Apply requested state", "应用请求的状态"), status: .pending)
            transitionRow(copy.text("Verify runtime health", "验证运行时健康状态"), status: .neutral)
            transitionRow(copy.text("Commit active state", "提交活动状态"), status: .neutral)
        }
        .padding(VelaSpacing.standard)
        .velaPanelSurface()
    }

    private func transitionRow(_ title: String, status: VelaSemanticStatus) -> some View {
        HStack(spacing: VelaSpacing.small) {
            if status == .pending {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: status.systemImage)
                    .foregroundStyle(status.tint)
            }
            Text(title).font(VelaTypography.body)
            Spacer()
            Text(status.accessibilityValue)
                .font(VelaTypography.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var rollbackSummary: some View {
        VelaResultSummary(
            title: copy.text("Recovery result", "恢复结果"),
            items: [
          VelaResultItem(
            id: "requested", title: copy.text("Requested transition", "请求的切换"),
            detail: copy.text("Verification failed", "验证失败"), status: .error),
          VelaResultItem(
            id: "rollback", title: copy.text("Automatic rollback", "自动回滚"),
            detail: copy.text("Could not restore runtime ownership", "无法恢复运行时所有权"), status: .error),
          VelaResultItem(
            id: "automation", title: copy.text("Automatic changes", "自动更改"),
            detail: copy.text("Paused for safety", "已为安全暂停"), status: .warning),
            ],
            retryTitle: copy.text("Retry Recovery", "重试恢复"),
            retryFailed: {}
        )
    }

    private var stateStatus: VelaSemanticStatus {
        switch configuration.state {
        case .loaded: .success
        case .loading, .refreshing, .pendingMutation, .transitioning: .pending
        case .empty: .neutral
        case .partialFailure: .warning
        case .failure, .rollbackFailed: .error
        case .offline, .stale: .stale
        case .permissionRequired: .permission
        }
    }

    private var stateLabel: String {
        switch configuration.state {
        case .loading: copy.text("Loading", "载入中")
        case .loaded: copy.text("Ready", "就绪")
        case .empty: copy.text("Empty", "空")
        case .refreshing: copy.text("Refreshing", "刷新中")
        case .pendingMutation: copy.text("Applying", "应用中")
        case .partialFailure: copy.text("Needs attention", "需要处理")
        case .failure: copy.text("Failed", "失败")
        case .offline: copy.text("Offline", "离线")
        case .stale: copy.text("Stale", "已过期")
        case .permissionRequired: copy.text("Permission required", "需要权限")
        case .transitioning: copy.text("Transitioning", "切换中")
        case .rollbackFailed: copy.text("Recovery required", "需要恢复")
        }
    }
}

/// Skeleton rows exist only in the loading branch. Empty, offline, failure,
/// and stale fixtures render either a true empty table or real cached rows.
private struct VisualFixtureSkeletonTable: View {
    let columns: [String]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: VelaSpacing.small) {
                ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                    Text(column)
                        .font(VelaTypography.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, VelaSpacing.medium)
            .frame(height: VelaMetrics.tableRowHeight)
            .background(VelaAppearance.secondarySurface)

            Divider()

            ForEach(0..<4, id: \.self) { row in
                HStack(spacing: VelaSpacing.small) {
                    ForEach(columns.indices, id: \.self) { column in
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Color.secondary.opacity(0.13))
                            .frame(
                                width: column == 0 ? 112 : 86,
                                height: 8
                            )
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, VelaSpacing.medium)
                .frame(height: VelaMetrics.tableRowHeight)
                .accessibilityLabel("Loading row \(row + 1)")

                if row < 3 {
                    Divider().opacity(0.4)
                }
            }
        }
        .velaPanelSurface()
        .accessibilityElement(children: .contain)
    }
}

private struct VisualFixtureDataTable: View {
    let columns: [String]
    let rows: [VisualFixtureRowSpec]
    let usesAlternatingRows: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: VelaSpacing.small) {
                ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                    Text(column)
                        .font(VelaTypography.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, VelaSpacing.medium)
            .frame(height: VelaMetrics.tableRowHeight)
            .background(VelaAppearance.secondarySurface)

            Divider()

            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                HStack(spacing: VelaSpacing.small) {
                    ForEach(Array(row.cells.enumerated()), id: \.offset) { cellIndex, cell in
                        HStack(spacing: VelaSpacing.xSmall) {
                            if cellIndex == row.cells.count - 1, let status = row.status {
                                Image(systemName: status.systemImage)
                                    .imageScale(.small)
                                    .foregroundStyle(status.tint)
                                    .accessibilityHidden(true)
                            }
                            Text(cell)
                                .font(VelaTypography.table)
                                .lineLimit(1)
                                .truncationMode(cellIndex == 0 ? .tail : .middle)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, VelaSpacing.medium)
                .frame(height: VelaMetrics.tableRowHeight)
                .background(
                    usesAlternatingRows && index.isMultiple(of: 2)
                        ? VelaAppearance.secondarySurface.opacity(0.46)
                        : Color.clear
                )
                .accessibilityElement(children: .combine)

                if index != rows.indices.last {
                    Divider().opacity(0.55)
                }
            }
        }
        .velaPanelSurface()
    }
}

private struct VisualFixtureInspectorPanel: View {
    let inspector: VisualFixtureInspectorSpec

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(inspector.title)
                        .font(VelaTypography.pageTitle)
                    Spacer()
            Button {
            } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close inspector")
                }
                .padding(.bottom, VelaSpacing.standard)

                ForEach(Array(inspector.sections.enumerated()), id: \.offset) { index, section in
                    VelaInspectorSection(
                        title: section.title,
                        showsDivider: index != inspector.sections.indices.last
                    ) {
                        VStack(spacing: VelaSpacing.small) {
                            ForEach(Array(section.values.enumerated()), id: \.offset) { _, item in
                                LabeledContent(item.label) {
                                    Text(item.value)
                                        .font(VelaTypography.table)
                                        .foregroundStyle(.secondary)
                                        .multilineTextAlignment(.trailing)
                                }
                            }
                        }
                    }
                }
            }
            .padding(VelaSpacing.standard)
        }
        .background(VelaAppearance.controlBackground)
    }
}

private struct VisualFixtureOverviewSummary: View {
    let copy: VisualFixtureLocalizedCopy

    var body: some View {
        HStack(alignment: .top, spacing: VelaSpacing.medium) {
        VelaMetricCard(
          title: copy.text("System health", "系统健康"), value: copy.text("Healthy", "正常"),
          secondaryText: copy.text("4 verified components", "4 个已验证组件"), status: .success,
          statusLabel: copy.text("Ready", "就绪"), density: .compact)
        VelaMetricCard(
          title: copy.text("Selected backend", "所选后端"), value: copy.text("System Proxy", "系统代理"),
          secondaryText: copy.text("Active and verified", "已激活并验证"), status: .info,
          statusLabel: copy.text("Active", "活动"), density: .compact)
        VelaMetricCard(
          title: copy.text("Traffic", "流量"), value: "38.4 Mbps",
          secondaryText: copy.text("12 active connections", "12 个活动连接"), density: .compact)
        }
    }
}

private struct VisualFixtureDiagnosticsSummary: View {
    let copy: VisualFixtureLocalizedCopy

    var body: some View {
        HStack(alignment: .top, spacing: VelaSpacing.medium) {
        VelaMetricCard(
          title: copy.text("System health", "系统健康"), value: copy.text("Needs attention", "需要处理"),
          secondaryText: copy.text("3 of 4 checks passed", "4 项检查中 3 项通过"), status: .warning,
          statusLabel: copy.text("Review", "检查"), density: .compact)
        VelaMetricCard(
          title: copy.text("Completion", "完成度"), value: "100%",
          secondaryText: copy.text("4 checks evaluated", "已评估 4 项检查"), density: .compact)
        VelaMetricCard(
          title: copy.text("Evidence quality", "证据质量"), value: copy.text("Sufficient", "充分"),
          secondaryText: copy.text("Minimum sample reached", "已达到最少样本数"), status: .success,
          statusLabel: copy.text("Ready", "就绪"), density: .compact)
        }
    }
}

private struct VisualFixtureHelpSummary: View {
    let copy: VisualFixtureLocalizedCopy
    let spec: VisualFixturePageSpec

    var body: some View {
        HStack(alignment: .top, spacing: VelaSpacing.standard) {
            VisualFixtureDataTable(columns: spec.columns, rows: spec.rows, usesAlternatingRows: true)
                .frame(maxWidth: 520)

            VStack(alignment: .leading, spacing: VelaSpacing.medium) {
                Label(copy.text("Getting Started", "开始使用"), systemImage: "book.pages")
                    .font(VelaTypography.pageTitle)
          Text(
            copy.text(
                    "Vela keeps network changes explicit. Start by adding a configuration, reviewing its validation result, and choosing System Proxy or TUN only when you are ready.",
                    "Vela 会让网络更改保持明确。首先添加配置并检查验证结果，准备好后再选择系统代理或 TUN。"
            )
          )
                .font(VelaTypography.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                Divider()
                Label(copy.text("Available offline", "可离线使用"), systemImage: "checkmark.circle.fill")
                    .font(VelaTypography.caption)
                    .foregroundStyle(.green)
                Button(copy.text("Open Guided Support", "打开引导式支持")) {}
                    .controlSize(.small)
            }
            .padding(VelaSpacing.standard)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .velaPanelSurface()
        }
    }
}

private struct VisualFixtureUpdateSummary: View {
    let copy: VisualFixtureLocalizedCopy

    var body: some View {
        HStack(alignment: .top, spacing: VelaSpacing.medium) {
        VelaMetricCard(
          title: copy.text("Application", "应用"), value: copy.text("Up to date", "已是最新"),
          secondaryText: "0.9.0 (1090)", status: .success, statusLabel: copy.text("Signed", "已签名"),
          density: .compact)
        VelaMetricCard(
          title: copy.text("Active core", "当前内核"), value: "Mihomo 1.19.28",
          secondaryText: copy.text("Known-good activation", "已知可用激活"), status: .success,
          statusLabel: copy.text("Verified", "已验证"), density: .compact)
        VelaMetricCard(
          title: copy.text("Recovery point", "恢复点"), value: "1.19.27",
          secondaryText: copy.text("Retained locally", "保留在本地"), status: .info,
          statusLabel: copy.text("Ready", "就绪"), density: .compact)
        }
    }
}

private struct VisualFixtureSettingsSummary: View {
    let copy: VisualFixtureLocalizedCopy

    var body: some View {
        VelaStateBanner(
            kind: .info,
            title: copy.text("Privacy by default", "默认保护隐私"),
        detail: copy.text(
          "Diagnostics and reliability evidence stay on this Mac unless you explicitly export them.",
          "除非你明确导出，否则诊断与可靠性证据只保留在此 Mac 上。")
        )
    }
}

private struct VisualFixtureTunSummary: View {
    let copy: VisualFixtureLocalizedCopy

    var body: some View {
        VelaStateBanner(
            kind: .info,
            title: copy.text("Starting TUN", "正在启动 TUN"),
        detail: copy.text(
          "Vela keeps the previous working backend until the new TUN interface is verified.",
          "新 TUN 接口验证成功前，Vela 会保留先前可用的后端。")
        )
    }
}
#endif
