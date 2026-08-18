import SwiftUI

struct UpdatesCoreRecoveryFeatureView: View {
    let engineStore: EngineStore
    let updateController: UpdateController
    let coreLifecycle: CoreLifecycleController
    let onBack: () -> Void

    @State private var activeAction: UpdatesCoreRecoveryAction?

    var body: some View {
        UpdatesCoreRecoveryWorkspace(
            snapshot: snapshot,
            initialSelectionID: snapshot.banner?.affectedComponentID ?? .application,
            onBack: onBack,
            onAction: perform
        )
        .overlay(alignment: .bottomTrailing) {
            if let activeAction {
                HStack(spacing: VelaSpacing.small) {
                    ProgressView().controlSize(.small)
                    Text(actionLabel(activeAction))
                        .font(VelaTypography.caption)
                }
                .padding(.horizontal, VelaSpacing.medium)
                .padding(.vertical, VelaSpacing.small)
                .background(.regularMaterial, in: Capsule())
                .padding(VelaSpacing.medium)
                .accessibilityIdentifier("updatesCore.actionProgress")
            }
        }
    }

    private var snapshot: UpdatesCoreRecoverySnapshot {
        UpdatesCoreRecoveryPresentation.snapshot(
            input: UpdatesCoreRecoveryLiveInput(
                updateController: updateController,
                coreLifecycle: coreLifecycle,
                engineStore: engineStore
            )
        )
    }

    private func perform(_ action: UpdatesCoreRecoveryAction) {
        guard activeAction == nil else { return }
        activeAction = action
        Task { @MainActor in
            switch action {
            case .checkApplicationUpdate:
                updateController.checkForUpdates()
            case .refreshCoreCatalog:
                await coreLifecycle.checkNow()
            case .verifyAll:
                await engineStore.checkCoreIntegrity()
                await coreLifecycle.refreshRootInventory()
                await coreLifecycle.checkNow()
                if updateController.state.canCheckForUpdates {
                    updateController.checkForUpdates()
                }
            case .downloadRecommendedCore:
                await coreLifecycle.downloadRecommended()
            case .activateRecommendedCore:
                if let recommended = coreLifecycle.recommendedEntry {
                    await coreLifecycle.activate(recommended.coreID)
                }
            case .rollbackCore:
                await coreLifecycle.rollback()
            case .repairInterruptedActivation:
                await coreLifecycle.repairInterruptedActivation()
            case .openRecovery:
                break
            }
            activeAction = nil
        }
    }

    private func actionLabel(_ action: UpdatesCoreRecoveryAction) -> String {
        switch action {
        case .checkApplicationUpdate: "Checking application update…"
        case .refreshCoreCatalog: "Refreshing Core Catalog…"
        case .verifyAll: "Verifying components…"
        case .downloadRecommendedCore: "Downloading Core…"
        case .activateRecommendedCore: "Activating Core…"
        case .rollbackCore: "Restoring recovery point…"
        case .repairInterruptedActivation: "Repairing recovery…"
        case .openRecovery: "Opening Recovery…"
        }
    }
}

struct UpdatesCoreRecoveryWorkspace: View {
    let snapshot: UpdatesCoreRecoverySnapshot
    let initialSelectionID: UpdatesCoreRecoveryComponentID
    let onBack: () -> Void
    let onAction: (UpdatesCoreRecoveryAction) -> Void

    @State private var selectedComponentID: UpdatesCoreRecoveryComponentID
    @Environment(\.locale) private var locale

    init(
        snapshot: UpdatesCoreRecoverySnapshot,
        initialSelectionID: UpdatesCoreRecoveryComponentID = .application,
        onBack: @escaping () -> Void = {},
        onAction: @escaping (UpdatesCoreRecoveryAction) -> Void = { _ in }
    ) {
        self.snapshot = snapshot
        self.initialSelectionID = initialSelectionID
        self.onBack = onBack
        self.onAction = onAction
        _selectedComponentID = State(initialValue: initialSelectionID)
    }

    var body: some View {
        GeometryReader { geometry in
            let layout = UpdatesCoreRecoveryLayoutMetrics.resolve(
                contentWidth: geometry.size.width
            )
            VStack(spacing: 0) {
                header
                if let banner = snapshot.banner {
                    bannerView(banner)
                        .padding(.horizontal, layout.contentPadding)
                        .padding(.vertical, VelaSpacing.small)
                }
                HStack(spacing: VelaSpacing.medium) {
                    componentList
                        .frame(width: layout.listWidth)
                        .frame(maxHeight: .infinity)
                        .velaPanelSurface()
                    detail(layout: layout)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .velaPanelSurface()
                }
                .padding(.horizontal, layout.contentPadding)
                .padding(.bottom, layout.contentPadding)
            }
            .background(VelaPageCanvas())
        }
        .velaPageRoot()
        .onChange(of: snapshot.components.map(\.id)) { _, componentIDs in
            if !componentIDs.contains(selectedComponentID) {
                selectedComponentID = componentIDs.first ?? initialSelectionID
            }
            if let affected = snapshot.banner?.affectedComponentID {
                selectedComponentID = affected
            }
        }
        .accessibilityIdentifier("updatesCore.workspace")
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            wideHeader
            compactHeader
        }
        .padding(.horizontal, VelaSpacing.section)
        .padding(.vertical, VelaSpacing.medium)
        .background(.ultraThinMaterial)
        .accessibilityIdentifier("updatesCore.header")
    }

    private var wideHeader: some View {
        HStack(spacing: VelaSpacing.medium) {
            backButton(compact: false)

            Divider().frame(height: 20)

            VStack(alignment: .leading, spacing: VelaSpacing.micro) {
                Text(text("Diagnostics / Updates & Core", "诊断 / 更新与内核"))
                    .font(VelaTypography.caption)
                    .foregroundStyle(.secondary)
                Text(text("Updates & Core Recovery", "更新与内核恢复"))
                    .font(VelaTypography.pageTitle)
                    .accessibilityAddTraits(.isHeader)
            }

            Spacer(minLength: VelaSpacing.medium)

            VStack(alignment: .trailing, spacing: VelaSpacing.micro) {
                Text(text("Overall status", "总体状态"))
                    .font(VelaTypography.caption)
                    .foregroundStyle(.secondary)
                VelaStatusPill(
                    status: snapshot.overallState.semanticStatus,
                    label: overallLabel(snapshot.overallState)
                )
                .accessibilityIdentifier("updatesCore.overallStatus")
            }

            VStack(alignment: .trailing, spacing: VelaSpacing.micro) {
                Text(text("Last verified", "上次验证"))
                    .font(VelaTypography.caption)
                    .foregroundStyle(.secondary)
                Text(snapshot.lastVerifiedAt.map(exactDate) ?? text("Not verified", "尚未验证"))
                    .font(VelaTypography.caption.monospacedDigit())
                    .lineLimit(1)
            }

            verifyAllButton(compact: false)
        }
    }

    private var compactHeader: some View {
        HStack(spacing: VelaSpacing.small) {
            backButton(compact: true)

            VStack(alignment: .leading, spacing: VelaSpacing.micro) {
                Text(text("Updates & Core Recovery", "更新与内核恢复"))
                    .font(VelaTypography.pageTitle)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .accessibilityAddTraits(.isHeader)
                Text(snapshot.lastVerifiedAt.map(exactDate) ?? text("Not verified", "尚未验证"))
                    .font(VelaTypography.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: VelaSpacing.xSmall)

            VelaStatusPill(
                status: snapshot.overallState.semanticStatus,
                label: overallLabel(snapshot.overallState)
            )
            .accessibilityIdentifier("updatesCore.overallStatus")

            verifyAllButton(compact: true)
        }
    }

    @ViewBuilder
    private func backButton(compact: Bool) -> some View {
        Button(action: onBack) {
            if compact {
                Image(systemName: "chevron.backward")
            } else {
                Label(
                    text("Back to Diagnostics", "返回诊断"),
                    systemImage: "chevron.backward"
                )
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(text("Back to Diagnostics", "返回诊断"))
        .accessibilityLabel(text("Back to Diagnostics", "返回诊断"))
        .accessibilityIdentifier("updatesCore.back")
    }

    @ViewBuilder
    private func verifyAllButton(compact: Bool) -> some View {
        Button {
            onAction(.verifyAll)
        } label: {
            if compact {
                Image(systemName: "checkmark.shield")
            } else {
                Label(text("Verify All", "全部验证"), systemImage: "checkmark.shield")
            }
        }
        .controlSize(.regular)
        .disabled(!snapshot.canVerifyAll)
        .help(
            snapshot.verifyAllUnavailableReason.map(localizedPresentationText)
                ?? text("Verify all components", "验证全部组件")
        )
        .accessibilityLabel(text("Verify All", "全部验证"))
        .accessibilityIdentifier("updatesCore.verifyAll")
    }

    private var componentList: some View {
        List(selection: $selectedComponentID) {
            Section(text("Lifecycle components", "生命周期组件")) {
                ForEach(snapshot.components) { component in
                    componentRow(component)
                        .tag(component.id)
                }
            }
            if let runtimeSummary = snapshot.runtimeSummary {
                Section(text("Runtime", "运行时")) {
                    Text(localizedPresentationText(runtimeSummary))
                        .font(VelaTypography.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("updatesCore.runtimeSummary")
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .controlSize(.regular)
        .accessibilityIdentifier("updatesCore.componentList")
    }

    private func componentRow(
        _ component: UpdatesCoreRecoveryComponentRowModel
    ) -> some View {
        VStack(alignment: .leading, spacing: VelaSpacing.xSmall) {
            HStack(spacing: VelaSpacing.small) {
                Label(componentTitle(component.id), systemImage: componentSymbol(component.id))
                    .font(VelaTypography.body.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: VelaSpacing.xSmall)
                if component.isAffected {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(component.trust.semanticStatus.tint)
                        .accessibilityLabel(text("Affected component", "受影响组件"))
                }
            }
            Text(localizedPresentationText(component.version))
                .font(VelaTypography.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack(spacing: VelaSpacing.xSmall) {
                statusDot(component.trust.semanticStatus)
                Text(trustLabel(component.trust))
                Text(verbatim: "·").foregroundStyle(.tertiary)
                Text(availabilityLabel(component.availability))
            }
            .font(VelaTypography.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .padding(.vertical, VelaSpacing.xSmall)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("updatesCore.component.\(component.id.rawValue)")
    }

    private func detail(layout: UpdatesCoreRecoveryLayoutMetrics) -> some View {
        ScrollView {
            if let component = selectedComponent {
                VStack(alignment: .leading, spacing: VelaSpacing.standard) {
                    detailHeader(component)
                    if snapshot.operation?.componentID == component.id,
                        !snapshot.pipeline.isEmpty
                    {
                        operationSection
                    }
                    if let permission = snapshot.permission,
                        permission.operation.componentID == component.id
                    {
                        permissionSection(permission)
                    }
                    dimensions(component, columns: layout.detailColumns)
                    actions(component)
                }
                .padding(layout.contentPadding)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .accessibilityIdentifier("updatesCore.detail")
    }

    private func detailHeader(
        _ component: UpdatesCoreRecoveryComponentRowModel
    ) -> some View {
        HStack(alignment: .top, spacing: VelaSpacing.medium) {
            Image(systemName: componentSymbol(component.id))
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(component.trust.semanticStatus.tint)
                .frame(width: 34)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: VelaSpacing.xSmall) {
                Text(componentTitle(component.id))
                    .font(VelaTypography.pageTitle)
                    .accessibilityAddTraits(.isHeader)
                Text(localizedPresentationText(component.version))
                    .font(VelaTypography.body.monospacedDigit())
                Text(localizedPresentationText(component.summary))
                    .font(VelaTypography.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: VelaSpacing.small) {
                VelaStatusPill(
                    status: component.trust.semanticStatus,
                    label: trustLabel(component.trust)
                )
                VelaStatusPill(
                    status: component.availability.semanticStatus,
                    label: availabilityLabel(component.availability)
                )
            }
        }
        .padding(VelaSpacing.standard)
        .velaPanelSurface(emphasized: component.isAffected)
        .accessibilityIdentifier("updatesCore.detailHeader")
    }

    private var operationSection: some View {
        VStack(alignment: .leading, spacing: VelaSpacing.medium) {
            HStack {
                Label(
                    operationLabel(snapshot.operation),
                    systemImage: "arrow.triangle.2.circlepath"
                )
                .font(VelaTypography.sectionTitle)
                Spacer()
                ProgressView().controlSize(.small)
            }
            ForEach(snapshot.pipeline) { step in
                HStack(alignment: .top, spacing: VelaSpacing.small) {
                    pipelineSymbol(step.state)
                    VStack(alignment: .leading, spacing: VelaSpacing.micro) {
                        Text(localizedPresentationText(step.title)).font(VelaTypography.body)
                        if let detail = step.detail {
                            Text(localizedPresentationText(detail))
                                .font(VelaTypography.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Text(pipelineStateLabel(step.state))
                        .font(VelaTypography.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(VelaSpacing.standard)
        .velaPanelSurface(emphasized: true)
        .accessibilityIdentifier("updatesCore.pipeline")
    }

    private func permissionSection(
        _ permission: UpdatesCoreRecoveryPermission
    ) -> some View {
        VelaStateBanner(
            kind: .permission,
            title: localizedPresentationText(permission.title),
            detail: localizedPresentationText(permission.detail)
        )
        .accessibilityIdentifier("updatesCore.permission.\(permission.kind.rawValue)")
    }

    @ViewBuilder
    private func dimensions(
        _ component: UpdatesCoreRecoveryComponentRowModel,
        columns: Int
    ) -> some View {
        VStack(alignment: .leading, spacing: VelaSpacing.small) {
            Text(text("Trust & Availability", "信任与可用性"))
                .font(VelaTypography.sectionTitle)
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(), spacing: VelaSpacing.medium, alignment: .top),
                    count: columns
                ),
                alignment: .leading,
                spacing: VelaSpacing.medium
            ) {
                ForEach(component.dimensions) { dimension in
                    dimensionCard(dimension)
                }
            }
        }
        .accessibilityIdentifier("updatesCore.dimensions")
    }

    private func dimensionCard(
        _ dimension: UpdatesCoreRecoveryDimension
    ) -> some View {
        VStack(alignment: .leading, spacing: VelaSpacing.small) {
            HStack(alignment: .firstTextBaseline) {
                Text(localizedPresentationText(dimension.label))
                    .font(VelaTypography.sectionTitle)
                    .foregroundStyle(.secondary)
                Spacer()
                statusDot(dimension.status)
            }
            Text(localizedPresentationText(dimension.value))
                .font(VelaTypography.body.weight(.medium))
                .textSelection(.enabled)
            if let detail = dimension.detail {
                Text(localizedPresentationText(detail))
                    .font(VelaTypography.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(VelaSpacing.medium)
        .frame(maxWidth: .infinity, minHeight: 88, alignment: .topLeading)
        .velaPanelSurface()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("updatesCore.dimension.\(dimension.id)")
    }

    private func actions(
        _ component: UpdatesCoreRecoveryComponentRowModel
    ) -> some View {
        VStack(alignment: .leading, spacing: VelaSpacing.small) {
            HStack {
                Text(text("Available actions", "可用操作"))
                    .font(VelaTypography.sectionTitle)
                Spacer()
                if let code = component.stableErrorCode {
                    Text(verbatim: code)
                        .font(.system(size: VelaTypeSize.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            if component.actions.isEmpty {
                Text(text(
                    "No action is currently required or safely available for this component.",
                    "当前无需操作，或没有可安全执行的操作。"
                ))
                .font(VelaTypography.body)
                .foregroundStyle(.secondary)
            } else {
                HStack(spacing: VelaSpacing.small) {
                    ForEach(component.actions, id: \.self) { action in
                        actionButton(action)
                    }
                }
            }
        }
        .padding(VelaSpacing.standard)
        .velaPanelSurface()
        .accessibilityIdentifier("updatesCore.actions")
    }

    @ViewBuilder
    private func bannerView(_ banner: UpdatesCoreRecoveryBanner) -> some View {
        VelaStateBanner(
            kind: bannerKind(banner.status),
            title: localizedPresentationText(banner.title),
            detail: localizedPresentationText(banner.detail)
        ) {
            if let affected = banner.affectedComponentID {
                Button(text("Review", "查看")) {
                    selectedComponentID = affected
                }
                .accessibilityIdentifier("updatesCore.banner.review")
            }
        }
        .accessibilityIdentifier("updatesCore.banner")
    }

    private var selectedComponent: UpdatesCoreRecoveryComponentRowModel? {
        snapshot.component(selectedComponentID) ?? snapshot.components.first
    }

    private func statusDot(_ status: VelaSemanticStatus) -> some View {
        Image(systemName: status.systemImage)
            .imageScale(.small)
            .foregroundStyle(status.tint)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func pipelineSymbol(_ state: UpdatesCoreRecoveryPipelineStep.State) -> some View {
        switch state {
        case .complete:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .active:
            ProgressView().controlSize(.small)
        case .pending:
            Image(systemName: "circle").foregroundStyle(.secondary)
        case .failed:
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }

    private func bannerKind(_ status: VelaSemanticStatus) -> VelaStateBannerKind {
        switch status {
        case .error: .error
        case .warning: .warning
        case .permission: .permission
        case .stale: .stale
        case .info, .success, .neutral, .pending: .info
        }
    }

    private func componentTitle(_ id: UpdatesCoreRecoveryComponentID) -> String {
        switch id {
        case .application: text("Application", "应用")
        case .activeCore: text("Active Core", "当前内核")
        case .recoveryPoint: text("Recovery Point", "恢复点")
        case .coreCatalog: text("Core Catalog", "内核目录")
        }
    }

    private func componentSymbol(_ id: UpdatesCoreRecoveryComponentID) -> String {
        switch id {
        case .application: "app.badge.checkmark"
        case .activeCore: "cpu"
        case .recoveryPoint: "arrow.counterclockwise.circle"
        case .coreCatalog: "checkmark.seal"
        }
    }

    private func overallLabel(_ state: UpdatesCoreRecoveryOverallState) -> String {
        switch state {
        case .allVerified: text("All Verified", "全部已验证")
        case .updateAvailable: text("Update Available", "有可用更新")
        case .attentionRequired: text("Attention Required", "需要处理")
        case .verificationIncomplete: text("Verification Incomplete", "验证未完成")
        case .operationInProgress: text("Operation in Progress", "操作进行中")
        case .recoveryRequired: text("Recovery Required", "需要恢复")
        case .unavailable: text("Unavailable", "不可用")
        }
    }

    private func trustLabel(_ state: UpdatesCoreRecoveryTrustState) -> String {
        switch state {
        case .verified: text("Verified", "已验证")
        case .verificationIncomplete: text("Verification incomplete", "验证未完成")
        case .stale: text("Stale", "已过期")
        case .failed: text("Failed", "失败")
        case .unavailable: text("Unavailable", "不可用")
        }
    }

    private func availabilityLabel(_ state: UpdatesCoreRecoveryAvailabilityState) -> String {
        switch state {
        case .current: text("Current", "当前")
        case .updateAvailable: text("Update available", "有可用更新")
        case .downloaded: text("Downloaded", "已下载")
        case .ready: text("Ready", "就绪")
        case .available: text("Available", "可用")
        case .checking: text("Checking", "正在检查")
        case .transitioning: text("Transitioning", "正在切换")
        case .unavailable: text("Unavailable", "不可用")
        case .unknown: text("Not checked", "尚未检查")
        }
    }

    private func operationLabel(_ operation: UpdatesCoreRecoveryOperation?) -> String {
        guard let operation else { return text("Operation", "操作") }
        return switch operation {
        case .checkingAppUpdate: text("Checking application update", "正在检查应用更新")
        case .installingAppUpdate: text("Installing application update", "正在安装应用更新")
        case .refreshingCoreCatalog: text("Refreshing Core Catalog", "正在刷新内核目录")
        case .downloadingCore: text("Downloading Core", "正在下载内核")
        case .stagingCore: text("Staging Core", "正在暂存内核")
        case .activatingCore: text("Activating Core", "正在激活内核")
        case .verifyingRecoveryPoint: text("Verifying recovery point", "正在验证恢复点")
        case .restoringRecoveryPoint: text("Restoring recovery point", "正在恢复恢复点")
        }
    }

    private func pipelineStateLabel(_ state: UpdatesCoreRecoveryPipelineStep.State) -> String {
        switch state {
        case .complete: text("Complete", "已完成")
        case .active: text("In progress", "进行中")
        case .pending: text("Pending", "等待中")
        case .failed: text("Failed", "失败")
        }
    }

    private func actionLabel(_ action: UpdatesCoreRecoveryAction) -> String {
        switch action {
        case .checkApplicationUpdate: text("Check App Update", "检查应用更新")
        case .refreshCoreCatalog: text("Refresh Core Catalog", "刷新内核目录")
        case .verifyAll: text("Verify All", "全部验证")
        case .downloadRecommendedCore: text("Download Recommended Core", "下载推荐内核")
        case .activateRecommendedCore: text("Activate Recommended Core", "激活推荐内核")
        case .rollbackCore: text("Restore Previous Core", "恢复上一内核")
        case .repairInterruptedActivation: text("Repair & Verify Rollback", "修复并验证回滚")
        case .openRecovery: text("Open Recovery", "打开恢复")
        }
    }

    private func actionSymbol(_ action: UpdatesCoreRecoveryAction) -> String {
        switch action {
        case .checkApplicationUpdate, .refreshCoreCatalog, .verifyAll: "arrow.clockwise"
        case .downloadRecommendedCore: "arrow.down.circle"
        case .activateRecommendedCore: "bolt.shield"
        case .rollbackCore: "arrow.uturn.backward.circle"
        case .repairInterruptedActivation: "wrench.and.screwdriver"
        case .openRecovery: "lifepreserver"
        }
    }

    @ViewBuilder
    private func actionButton(_ action: UpdatesCoreRecoveryAction) -> some View {
        if action == .openRecovery {
            Button {
                performAction(action)
            } label: {
                Label(actionLabel(action), systemImage: actionSymbol(action))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .accessibilityIdentifier("updatesCore.action.\(action.rawValue)")
        } else {
            Button {
                performAction(action)
            } label: {
                Label(actionLabel(action), systemImage: actionSymbol(action))
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .accessibilityIdentifier("updatesCore.action.\(action.rawValue)")
        }
    }

    private func performAction(_ action: UpdatesCoreRecoveryAction) {
        if action == .openRecovery {
            selectedComponentID = .recoveryPoint
        }
        onAction(action)
    }

    private func exactDate(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    /// Presentation snapshots intentionally keep stable English evidence text
    /// so diagnostics and fixtures remain deterministic. Translate that bounded
    /// vocabulary only at the UI boundary; stable error codes stay untouched.
    private func localizedPresentationText(_ value: String) -> String {
        guard VelaSupportedLocale.resolve(locale) == .simplifiedChinese else {
            return value
        }
        if let translated = Self.chinesePresentationCopy[value] {
            return translated
        }
        if value.hasSuffix(" needs attention") {
            let component = String(value.dropLast(" needs attention".count))
            return "\(localizedPresentationText(component))需要处理"
        }
        if value.hasPrefix("Channel: ") {
            return "通道：\(value.dropFirst("Channel: ".count))"
        }
        if value.hasPrefix("Core ID ") {
            return "内核 ID \(value.dropFirst("Core ID ".count))"
        }
        if value.hasPrefix("Last checked ") {
            return "上次检查：\(value.dropFirst("Last checked ".count))"
        }
        if value.hasPrefix("Expires ") {
            return "过期时间：\(value.dropFirst("Expires ".count))"
        }
        if value.hasPrefix("Recommended ") {
            return "推荐 \(value.dropFirst("Recommended ".count))"
        }
        if value.hasSuffix(" entries"), let count = value.split(separator: " ").first {
            return "\(count) 个条目"
        }
        return value
    }

    private static let chinesePresentationCopy: [String: String] = [
        "A signed application update is available.": "有一个已签名的应用更新可用。",
        "A stopped runtime does not invalidate artifact trust.": "运行时停止不会影响文件信任状态。",
        "Accepted sequence": "已接受序列",
        "Accepted": "已接受",
        "Activating and verifying the Core": "正在激活并验证内核",
        "Active Core": "当前内核",
        "Application and Core update services are unavailable in this build.": "此构建中的应用与内核更新服务不可用。",
        "Application update checking is unavailable.": "应用更新检查不可用。",
        "Application update recovery is required before another update.": "继续更新前需要先完成应用更新恢复。",
        "Application update recovery owns the runtime barrier.": "应用更新恢复当前占用运行时屏障。",
        "Application": "应用",
        "Artifact readability": "文件可读性",
        "Artifact verification": "文件验证",
        "Authorize installer": "授权安装程序",
        "Automatic Core changes are paused. Open Recovery to inspect the retained artifact, runtime state, trust evidence, and ownership before repairing the interrupted activation.": "自动内核变更已暂停。请先打开恢复，检查保留文件、运行状态、信任证据与归属，再修复中断的激活。",
        "Available": "可用",
        "Blocked": "已阻止",
        "Build signed bundle": "生成已签名包",
        "Bundled Factory Core": "内置出厂内核",
        "Capture runtime state": "记录运行状态",
        "Capture working state": "记录当前可用状态",
        "Catalog digest": "目录摘要",
        "Catalog time validation failed. Check this Mac's clock.": "目录时间验证失败，请检查这台 Mac 的系统时间。",
        "Catalog verification has not completed.": "内核目录验证尚未完成。",
        "Check compatibility": "检查兼容性",
        "Check sequence and freshness": "检查序列与时效性",
        "Checking for an application update": "正在检查应用更新",
        "Checking the configured signed update feed.": "正在检查已配置的签名更新源。",
        "Checking": "正在检查",
        "Commit installation record": "提交安装记录",
        "Commit known-good state": "提交已知良好状态",
        "Commit recovered state": "提交恢复后的状态",
        "Compatibility": "兼容性",
        "Compatible": "兼容",
        "Complete Core recovery before running all checks.": "运行全部检查前，请先完成内核恢复。",
        "Configured": "已配置",
        "Confirm coordinator readiness": "确认协调器就绪",
        "Controller health is evaluated separately.": "Controller 健康状态会单独评估。",
        "Core Catalog": "内核目录",
        "Core recovery is required": "需要恢复内核",
        "Current": "当前",
        "Download Catalog and envelope": "下载目录与签名封装",
        "Download fixed-role artifacts": "下载固定用途文件",
        "Downloaded": "已下载",
        "Downloading and verifying a Core": "正在下载并验证内核",
        "Expired": "已过期",
        "Factory compatibility": "出厂兼容性",
        "Failed": "失败",
        "Fetch signed appcast": "获取已签名更新清单",
        "Fresh": "有效",
        "Freshness": "时效性",
        "Hand off to Sparkle": "交由 Sparkle 安装",
        "Incompatible": "不兼容",
        "Installed User Core": "已安装的用户内核",
        "Installed version is known; update availability has not been confirmed.": "已识别当前安装版本，但尚未确认是否有可用更新。",
        "Known good metadata": "已知良好元数据",
        "Last known trust": "上次已知信任状态",
        "Local application trust": "本地应用信任",
        "Lock automatic changes": "锁定自动变更",
        "Locked": "已锁定",
        "Mihomo is running and the Controller is connected.": "Mihomo 正在运行，Controller 已连接。",
        "Mihomo is running, but the Controller is not connected.": "Mihomo 正在运行，但 Controller 未连接。",
        "Mihomo is stopped. No runtime health is claimed.": "Mihomo 已停止，当前不判断运行时健康状态。",
        "Missing": "缺失",
        "Move services to safe stop": "安全停止服务",
        "No live local-signature verdict is exposed by the current update service.": "当前更新服务未提供实时本地签名验证结果。",
        "No previous known-good Core is retained.": "未保留上一个已知良好的内核。",
        "No recommendation": "暂无推荐",
        "No trusted Catalog snapshot is available.": "没有可用的可信目录快照。",
        "None": "无",
        "Not applicable": "不适用",
        "Not checked": "尚未检查",
        "Not exposed": "未提供",
        "Not verified": "未验证",
        "Observe probation": "观察试运行",
        "Prepare runtime switch": "准备切换运行时",
        "Preparing the application update": "正在准备应用更新",
        "Publish availability": "发布可用状态",
        "Quarantined": "已隔离",
        "Read retained artifact": "读取保留文件",
        "Ready": "就绪",
        "Recommended Core": "推荐内核",
        "Recovery Point": "恢复点",
        "Recovery artifact": "恢复文件",
        "Recovery coordinator": "恢复协调器",
        "Recovery metadata": "恢复元数据",
        "Refreshing the signed Core Catalog": "正在刷新已签名内核目录",
        "Refreshing through the existing signed Catalog service.": "正在通过现有的签名目录服务刷新。",
        "Required store": "必要存储",
        "Restore trusted Core": "恢复可信内核",
        "Restoring the recovery point": "正在恢复恢复点",
        "Retain trusted checkpoint": "保留可信检查点",
        "Retained metadata exists; live artifact readability and compatibility still require verification.": "已保留元数据；仍需验证文件的实时可读性与兼容性。",
        "Retention alone is not treated as recovery readiness.": "仅有保留记录不足以证明恢复已就绪。",
        "Running · Connected": "运行中 · 已连接",
        "Running · Controller offline": "运行中 · Controller 离线",
        "Runtime health": "运行时健康",
        "Signature": "签名",
        "Signature, sequence, digest, and freshness are tracked separately.": "签名、序列、摘要和时效性会分别跟踪。",
        "Stage activation journal": "暂存激活日志",
        "Staging a Core activation": "正在暂存内核激活",
        "Stale": "已过期",
        "Start candidate": "启动候选内核",
        "Stopped": "已停止",
        "The active Core needs recovery or verification.": "当前内核需要恢复或验证。",
        "The application update service is not available in this build.": "此构建中的应用更新服务不可用。",
        "The existing safe installation coordinator owns this operation.": "此操作由现有安全安装协调器负责。",
        "The last application update operation failed.": "上一次应用更新操作失败。",
        "The last trusted Catalog checkpoint is retained.": "已保留上一个可信目录检查点。",
        "The last trusted Catalog remains visible after refresh failure.": "刷新失败后仍保留并显示上一个可信目录。",
        "The previously committed working state remains authoritative until verification and commit succeed.": "验证和提交成功前，之前已提交的可用状态仍是当前有效状态。",
        "The production Core Catalog is unavailable.": "生产内核目录不可用。",
        "The production signed Core Catalog is not configured.": "尚未配置生产签名内核目录。",
        "The retained rollback could not be verified; manual recovery is required.": "无法验证保留的回滚点，需要手动恢复。",
        "The signed update is downloaded and awaiting installation.": "已下载签名更新，正在等待安装。",
        "The trusted Catalog checkpoint is stale; new downloads remain blocked.": "可信目录检查点已过期，新的下载仍会被阻止。",
        "Transitioning": "正在切换",
        "Trust, compatibility, activation, and runtime are reported independently.": "信任、兼容性、激活和运行状态会分别报告。",
        "Unavailable": "不可用",
        "Update availability": "更新可用性",
        "Update available": "有可用更新",
        "Update feed checked; local signature verification is not exposed.": "已检查更新源；当前未提供本地签名验证结果。",
        "Update feed": "更新源",
        "Use the retained interrupted-activation repair.": "使用已保留的中断激活修复。",
        "Validate candidate": "验证候选内核",
        "Validate feed configuration": "验证更新源配置",
        "Verification incomplete": "验证未完成",
        "Verification required": "需要验证",
        "Verified": "已验证",
        "Verify Controller and runtime": "验证 Controller 与运行时",
        "Verify digests": "验证摘要",
        "Verify release": "验证发布版本",
        "Verify runtime and ownership": "验证运行时与归属",
        "Verify signatures": "验证签名",
        "Verify trust and digest": "验证信任与摘要",
        "Verifying the recovery point": "正在验证恢复点",
        "Wait for the current operation to finish.": "请等待当前操作完成。",
    ]

    private func text(_ english: String, _ chinese: String) -> String {
        VelaSupportedLocale.resolve(locale) == .simplifiedChinese ? chinese : english
    }
}
