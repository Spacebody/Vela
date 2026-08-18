import SwiftUI

struct DiagnosticsWorkspaceView: View {
    let snapshot: DiagnosticsWorkspaceSnapshot
    let run: DiagnosticsRunPresentation?
    let repairProgress: DiagnosticsRepairPresentation?
    let initialSelectionID: String?
    let initialInspectorVisibility: Bool
    let runAll: () -> Void
    let cancelRun: () -> Void
    let runSelected: (DiagnosticsCheckRowModel) -> Void
    let canRunSelected: (DiagnosticsCheckRowModel) -> Bool
    let runSelectedUnavailableReason: (DiagnosticsCheckRowModel) -> String?
    let repair: (DiagnosticsCheckRowModel) -> Void
    let reviewPermission: (DiagnosticsCheckRowModel) -> Void
    let openSettings: () -> Void
    let canOpenLogs: Bool
    let openLogsUnavailableReason: String?
    let openLogs: () -> Void
    let copyRedactedSummary: (DiagnosticsCheckRowModel) -> Void
    let exportRedactedReport: () -> Void

    @State private var selectedCheckID: String?
    @State private var searchText = ""
    @State private var filter: DiagnosticsFilter = .all
    @State private var showsInspector: Bool
    @FocusState private var tableFocused: Bool
    @FocusState private var searchFocused: Bool
    @Environment(\.locale) private var locale

    init(
        snapshot: DiagnosticsWorkspaceSnapshot,
        run: DiagnosticsRunPresentation?,
        repairProgress: DiagnosticsRepairPresentation? = nil,
        initialSelectionID: String? = nil,
        initialInspectorVisibility: Bool = true,
        runAll: @escaping () -> Void,
        cancelRun: @escaping () -> Void,
        runSelected: @escaping (DiagnosticsCheckRowModel) -> Void,
        canRunSelected: @escaping (DiagnosticsCheckRowModel) -> Bool,
        runSelectedUnavailableReason: @escaping (DiagnosticsCheckRowModel) -> String?,
        repair: @escaping (DiagnosticsCheckRowModel) -> Void,
        reviewPermission: @escaping (DiagnosticsCheckRowModel) -> Void,
        openSettings: @escaping () -> Void,
        canOpenLogs: Bool = false,
        openLogsUnavailableReason: String? = nil,
        openLogs: @escaping () -> Void,
        copyRedactedSummary: @escaping (DiagnosticsCheckRowModel) -> Void,
        exportRedactedReport: @escaping () -> Void
    ) {
        self.snapshot = snapshot
        self.run = run
        self.repairProgress = repairProgress
        self.initialSelectionID = initialSelectionID
        self.initialInspectorVisibility = initialInspectorVisibility
        self.runAll = runAll
        self.cancelRun = cancelRun
        self.runSelected = runSelected
        self.canRunSelected = canRunSelected
        self.runSelectedUnavailableReason = runSelectedUnavailableReason
        self.repair = repair
        self.reviewPermission = reviewPermission
        self.openSettings = openSettings
        self.canOpenLogs = canOpenLogs
        self.openLogsUnavailableReason = openLogsUnavailableReason
        self.openLogs = openLogs
        self.copyRedactedSummary = copyRedactedSummary
        self.exportRedactedReport = exportRedactedReport
        _selectedCheckID = State(initialValue: initialSelectionID)
        _showsInspector = State(initialValue: initialInspectorVisibility)
    }

    var body: some View {
        GeometryReader { geometry in
            let layout = DiagnosticsWorkspaceLayout.forContentWidth(geometry.size.width)

            ZStack {
                VelaPageCanvas()

                VStack(alignment: .leading, spacing: DiagnosticsWorkspaceStyle.panelGap) {
                    summaryStrip

                    if let run, run.isActive {
                        runStrip(run)
                            .diagnosticsPanelSurface(
                                tint: VelaSemanticStatus.pending.tint
                            )
                    } else if let run, run.phase == .failed {
                        runFailureStrip(run)
                            .diagnosticsPanelSurface(
                                tint: VelaSemanticStatus.error.tint
                            )
                    } else if let repairProgress {
                        repairStrip(repairProgress)
                            .diagnosticsPanelSurface(
                                tint: repairProgress.phase == .failed ? .red : .orange
                            )
                    } else if snapshot.isStale {
                        staleStrip
                            .diagnosticsPanelSurface(
                                tint: VelaSemanticStatus.stale.tint
                            )
                    }

                    controls(layout: layout)

                    HStack(alignment: .top, spacing: DiagnosticsWorkspaceStyle.panelGap) {
                        table(layout: layout)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .diagnosticsPanelSurface(usesGlassEffect: false)

                        if showsInspector {
                            inspector
                                .frame(width: layout.inspectorWidth)
                                .frame(maxHeight: .infinity, alignment: .topLeading)
                                .diagnosticsPanelSurface()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .padding(DiagnosticsWorkspaceStyle.pagePadding)
            }
        }
        .velaPageRoot()
        .task {
            selectInitialRowIfNeeded()
        }
        .onChange(of: snapshot.registryRevision) { _, _ in
            selectInitialRowIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: .velaFocusSearch)) { _ in
            searchFocused = true
        }
    }

    private var summaryStrip: some View {
        let summary = snapshot.summary(isRunning: run?.isActive == true)

        return VStack(alignment: .leading, spacing: VelaSpacing.medium) {
            HStack(alignment: .center, spacing: VelaSpacing.medium) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.accentColor.opacity(0.12))
                    Image(systemName: "stethoscope")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                .frame(width: 42, height: 42)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: VelaSpacing.micro) {
                    Text(text("diagnostics.workspace.title", "Diagnostics", "诊断"))
                        .font(VelaTypography.mainPageTitle)
                        .accessibilityAddTraits(.isHeader)
                    Text(
                        text(
                            "diagnostics.workspace.subtitle",
                            "Inspect runtime health, evidence, and recovery options.",
                            "检查运行状态、诊断证据与恢复选项。"
                        )
                    )
                    .font(VelaTypography.pageSubtitle)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }

                Spacer(minLength: VelaSpacing.medium)

                summaryValue(
                    title: text("diagnostics.workspace.overall", "Overall", "总体"),
                    value: overallLabel(summary.overall),
                    status: overallStatus(summary.overall)
                )

                Divider().frame(height: 36)

                VStack(alignment: .trailing, spacing: VelaSpacing.micro) {
                    Text(text("diagnostics.workspace.lastRun", "Last Run", "上次运行"))
                        .font(VelaTypography.caption)
                        .foregroundStyle(.secondary)
                    Text(lastRunLabel(summary))
                        .font(VelaTypography.caption)
                        .monospacedDigit()
                    Text(verbatim: summary.lastRunID.map { "Run \($0)" } ?? "—")
                        .font(.system(size: VelaTypeSize.caption, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Divider()

            HStack(spacing: VelaSpacing.large) {
                VStack(alignment: .leading, spacing: VelaSpacing.micro) {
                    Text(text("diagnostics.workspace.distribution", "Results", "结果分布"))
                        .font(VelaTypography.caption)
                        .foregroundStyle(.secondary)
                    Text(distributionLabel(summary))
                        .font(VelaTypography.body.weight(.medium))
                        .lineLimit(1)
                        .accessibilityIdentifier("diagnostics.summary.distribution")
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Divider().frame(height: 32)

                VStack(alignment: .leading, spacing: VelaSpacing.micro) {
                    HStack(spacing: VelaSpacing.small) {
                        Text(text("diagnostics.summary.completion", "Completion", "完成度"))
                            .font(VelaTypography.caption)
                            .foregroundStyle(.secondary)
                        Text(summary.completionFraction, format: .percent.precision(.fractionLength(0)))
                            .font(VelaTypography.caption.weight(.semibold))
                            .monospacedDigit()
                    }
                    ProgressView(value: summary.completionFraction)
                        .frame(width: 150)
                        .accessibilityIdentifier("diagnostics.summary.completion")
                }

                Divider().frame(height: 32)

                summaryValue(
                    title: text("diagnostics.workspace.evidence", "Evidence", "证据"),
                    value: evidenceLabel(summary.evidence),
                    status: evidenceStatus(summary.evidence)
                )
            }
        }
        .padding(.horizontal, VelaSpacing.section)
        .padding(.vertical, VelaSpacing.section)
        .diagnosticsPanelSurface()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("diagnostics.summary")
    }

    private func summaryValue(
        title: String,
        value: String,
        status: VelaSemanticStatus
    ) -> some View {
        VStack(alignment: .leading, spacing: VelaSpacing.micro) {
            Text(title)
                .font(VelaTypography.caption)
                .foregroundStyle(.secondary)
            VelaStatusPill(status: status, label: value)
        }
    }

    private func runStrip(_ run: DiagnosticsRunPresentation) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: VelaSpacing.medium) {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: VelaSpacing.micro) {
                    Text(text("diagnostics.workspace.running", "Running checks", "正在运行检查"))
                        .font(VelaTypography.sectionTitle)
                        .accessibilityIdentifier("diagnostics.runProgress")
                    Text(
                        DiagnosticsRunProgressPresentation.summary(
                            format: text(
                                "diagnostics.workspace.run.progressFormat",
                                "Run %@ · %lld / %lld · %@ · %@",
                                "运行 %@ · %lld / %lld · %@ · %@"
                            ),
                            locale: locale,
                            runID: run.shortID,
                            completedStepCount: run.completedStepCount,
                            totalStepCount: run.totalStepCount,
                            duration: durationLabel(
                                max(0, context.date.timeIntervalSince(run.startedAt))
                            ),
                            currentStep: run.currentStepTitle
                                ?? text(
                                    "diagnostics.workspace.preparing",
                                    "Preparing",
                                    "正在准备"
                                )
                        )
                    )
                    .font(VelaTypography.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                }
                Spacer()
                Button(text("legacy.cancel", "Cancel", "取消"), action: cancelRun)
                    .controlSize(.regular)
                    .disabled(run.phase == .cancelling)
                    .accessibilityIdentifier("diagnostics.cancelRun")
            }
            .padding(.horizontal, VelaSpacing.section)
            .padding(.vertical, VelaSpacing.medium)
        }
    }

    private func runFailureStrip(_ run: DiagnosticsRunPresentation) -> some View {
        HStack(spacing: VelaSpacing.medium) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: VelaSpacing.micro) {
                Text(text(
                    "diagnostics.workspace.runFailed",
                    "Diagnostic run did not finish",
                    "诊断运行未完成"
                ))
                .font(VelaTypography.sectionTitle)
                .accessibilityIdentifier("diagnostics.runFailed")
                Text(run.failureDescription ?? text(
                    "diagnostics.workspace.runFailed.detail",
                    "One or more diagnostic stages failed or timed out. Previous evidence remains available.",
                    "一个或多个诊断阶段失败或超时，之前的证据仍然保留。"
                ))
                .font(VelaTypography.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            }
            Spacer()
            Button(text(
                "diagnostics.workspace.runAll",
                "Run All Checks",
                "运行全部检查"
            ), action: runAll)
                .controlSize(.regular)
        }
        .padding(.horizontal, VelaSpacing.section)
        .padding(.vertical, VelaSpacing.medium)
    }

    private var staleStrip: some View {
        VelaStateBanner(
            kind: .stale,
            title: text("diagnostics.workspace.stale.title", "Diagnostic evidence is stale", "诊断证据已过期"),
            detail: text(
                "diagnostics.workspace.stale.detail",
                "Results remain visible with their original Run ID and capture time. Run all checks to replace them.",
                "结果会保留原始运行 ID 和采集时间。运行全部检查以更新结果。"
            )
        ) {
            Button(text("diagnostics.workspace.runAll", "Run All Checks", "运行全部检查"), action: runAll)
                .accessibilityIdentifier("diagnostics.stale.runAll")
        }
        .padding(.horizontal, VelaSpacing.section)
        .padding(.vertical, VelaSpacing.small)
    }

    private func controls(layout: DiagnosticsWorkspaceLayout) -> some View {
        HStack(spacing: VelaSpacing.small) {
            HStack(spacing: VelaSpacing.small) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField(
                    text("diagnostics.workspace.search", "Search checks", "搜索检查"),
                    text: $searchText
                )
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .accessibilityIdentifier("diagnostics.search")
            }
            .padding(.horizontal, VelaSpacing.medium)
            .frame(height: 34)
            .frame(width: layout.searchWidth)
            .background(
                Color.primary.opacity(0.045),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            }

            Picker(text("diagnostics.workspace.filter", "Filter", "筛选"), selection: $filter) {
                ForEach(DiagnosticsFilter.allCases, id: \.self) { filter in
                    Text(filterLabel(filter)).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: layout.filterWidth)
            .accessibilityIdentifier("diagnostics.filter")

            Spacer()

            Image(systemName: "info.circle")
                .foregroundStyle(.tertiary)
                .help(
                    "\(text("diagnostics.workspace.registryRevision", "Registry revision", "注册表版本")): "
                        + snapshot.registryRevision
                )
                .accessibilityLabel(
                    text("diagnostics.workspace.registryRevision", "Registry revision", "注册表版本")
                )
                .accessibilityValue(snapshot.registryRevision)

            if !showsInspector {
                Button {
                    showsInspector = true
                } label: {
                    Label(
                        text("diagnostics.workspace.showInspector", "Show Inspector", "显示检查器"),
                        systemImage: "sidebar.trailing"
                    )
                }
                .labelStyle(.iconOnly)
                .help(text("diagnostics.workspace.showInspector", "Show Inspector", "显示检查器"))
                .accessibilityIdentifier("diagnostics.showInspector")
            }

            Button(action: runAll) {
                Label(
                    text("diagnostics.workspace.runAll", "Run All Checks", "运行全部检查"),
                    systemImage: "play.fill"
                )
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(run?.isActive == true || isRepairing || snapshot.isRegistryLoading)
            .accessibilityIdentifier("diagnostics.runChecks")
        }
        .padding(.horizontal, VelaSpacing.section)
        .padding(.vertical, VelaSpacing.medium)
        .diagnosticsPanelSurface()
    }

    private func repairStrip(_ progress: DiagnosticsRepairPresentation) -> some View {
        let isFailure = progress.phase == .failed
        return HStack(spacing: VelaSpacing.medium) {
            Image(systemName: isFailure ? "exclamationmark.triangle.fill" : "wrench.and.screwdriver.fill")
                .foregroundStyle(isFailure ? Color.red : Color.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: VelaSpacing.micro) {
                Text(
                    isFailure
                        ? text("diagnostics.workspace.repairFailed", "Repair failed", "修复失败")
                        : text("diagnostics.workspace.repairing", "Repair in progress", "正在修复")
                )
                .font(VelaTypography.sectionTitle)
                .accessibilityIdentifier(isFailure ? "diagnostics.repairFailed" : "diagnostics.repairProgress")
                Text(verbatim:
                    "\(progress.targetCheckID) · \(progress.action.rawValue) · \(repairPhaseLabel(progress.phase))"
                )
                .font(VelaTypography.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                if let message = progress.message {
                    Text(message)
                        .font(VelaTypography.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            Text(progress.postcondition)
                .font(VelaTypography.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: 300, alignment: .trailing)
        }
        .padding(.horizontal, VelaSpacing.section)
        .padding(.vertical, VelaSpacing.medium)
    }

    @ViewBuilder
    private func table(layout: DiagnosticsWorkspaceLayout) -> some View {
        if snapshot.isRegistryLoading {
            VStack(spacing: 0) {
                tableHeader(layout: layout)
                Divider()
                VelaLoadingState(
                    title: text("diagnostics.workspace.loadingRegistry", "Loading check registry", "正在载入检查注册表"),
                    detail: text("diagnostics.workspace.loadingRegistry.detail", "Preparing the existing local check catalog.", "正在准备现有的本地检查目录。")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .accessibilityIdentifier("diagnostics.registry.loading")
        } else if let registryError = snapshot.registryError {
            VStack(spacing: 0) {
                tableHeader(layout: layout)
                Divider()
                VelaEmptyState(
                    title: text("diagnostics.workspace.registryUnavailable", "Check registry unavailable", "检查注册表不可用"),
                    description: registryError,
                    systemImage: "exclamationmark.triangle"
                ) {
                    Button(text("diagnostics.workspace.retryRegistry", "Retry Registry Load", "重试载入注册表"), action: runAll)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .accessibilityIdentifier("diagnostics.registry.failure")
        } else {
            VStack(spacing: 0) {
                tableHeader(layout: layout)
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(filteredGroups) { group in
                            Section {
                                ForEach(group.checks) { row in
                                    tableRow(row, layout: layout)
                                    Divider()
                                }
                            } header: {
                                Text(categoryLabel(group.category))
                                    .font(VelaTypography.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .textCase(.uppercase)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, VelaSpacing.medium)
                                    .padding(.vertical, VelaSpacing.xSmall)
                                    .background(.regularMaterial)
                            }
                        }
                    }
                }
                .focusable()
                .focusEffectDisabled()
                .focused($tableFocused)
                .onMoveCommand(perform: moveSelection)
                .accessibilityIdentifier("diagnostics.checkTable")
            }
        }
    }

    private func tableHeader(layout: DiagnosticsWorkspaceLayout) -> some View {
        HStack(spacing: VelaSpacing.small) {
            columnHeader(text("diagnostics.workspace.check", "Check", "检查"))
                .frame(minWidth: 150, maxWidth: .infinity, alignment: .leading)
            columnHeader(text("diagnostics.workspace.result", "Result", "结果"))
                .frame(width: 108, alignment: .leading)
            if layout.showsCategoryColumn {
                columnHeader(text("diagnostics.workspace.category", "Category", "类别"))
                    .frame(width: 128, alignment: .leading)
            }
            if layout.showsEvidenceColumn {
                columnHeader(text("diagnostics.workspace.evidence", "Evidence", "证据"))
                    .frame(width: 126, alignment: .leading)
            }
            columnHeader(text("diagnostics.workspace.lastRun", "Last Run", "上次运行"))
                .frame(width: 104, alignment: .leading)
            if layout.showsDurationColumn {
                columnHeader(text("legacy.duration", "Duration", "耗时"))
                    .frame(width: 70, alignment: .trailing)
            }
        }
        .padding(.horizontal, VelaSpacing.medium)
        .frame(height: 38)
        .background(Color.primary.opacity(0.035))
        .accessibilityIdentifier("diagnostics.tableHeader")
    }

    private func columnHeader(_ title: String) -> some View {
        Text(title)
            .font(VelaTypography.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    private func tableRow(
        _ row: DiagnosticsCheckRowModel,
        layout: DiagnosticsWorkspaceLayout
    ) -> some View {
        let status = resultStatus(row.result)
        return Button {
            selectedCheckID = row.id
            showsInspector = true
        } label: {
            HStack(spacing: VelaSpacing.small) {
                VStack(alignment: .leading, spacing: VelaSpacing.micro) {
                    Text(row.title)
                        .font(VelaTypography.table)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if !layout.showsCategoryColumn {
                        Text(categoryLabel(row.category))
                            .font(VelaTypography.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .help(row.id)
                .frame(minWidth: 150, maxWidth: .infinity, alignment: .leading)

                HStack(spacing: VelaSpacing.xSmall) {
                    Image(systemName: status.systemImage)
                        .foregroundStyle(status.tint)
                        .accessibilityHidden(true)
                    Text(row.resultLabel)
                        .font(VelaTypography.caption.weight(.medium))
                        .foregroundStyle(status.tint)
                        .lineLimit(1)
                }
                .padding(.horizontal, VelaSpacing.small)
                .padding(.vertical, VelaSpacing.xSmall)
                .background(
                    status.tint.opacity(0.10),
                    in: Capsule()
                )
                .frame(width: 108, alignment: .leading)

                if layout.showsCategoryColumn {
                    Text(categoryLabel(row.category))
                        .font(VelaTypography.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(width: 128, alignment: .leading)
                }

                if layout.showsEvidenceColumn {
                    Text(evidenceLabel(row.evidence.state))
                        .font(VelaTypography.caption)
                        .foregroundStyle(evidenceStatus(row.evidence.state).tint)
                        .lineLimit(1)
                        .frame(width: 126, alignment: .leading)
                }

                Text(row.lastRunAt.map(relativeDate) ?? "—")
                    .font(VelaTypography.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .frame(width: 104, alignment: .leading)

                if layout.showsDurationColumn {
                    Text(row.durationSeconds.map(durationLabel) ?? "—")
                        .font(VelaTypography.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 70, alignment: .trailing)
                }
            }
            .padding(.horizontal, VelaSpacing.medium)
            .frame(minHeight: 48)
            .contentShape(Rectangle())
            .background {
                if selectedCheckID == row.id {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.accentColor.opacity(0.12))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 3)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: "\(row.title), \(row.resultLabel)"))
        .accessibilityValue(row.evidence.summary)
        .accessibilityIdentifier("diagnostics.check.\(row.id)")
    }

    private var inspector: some View {
        ScrollView {
            if let row = selectedRow {
                VStack(alignment: .leading, spacing: 0) {
                    inspectorHeader(row)
                    VelaInspectorSection(
                        title: text("diagnostics.workspace.overview", "Overview", "概览"),
                        subtitle: row.id
                    ) {
                        inspectorValue(text("diagnostics.workspace.result", "Result", "结果"), row.resultLabel)
                        inspectorValue(text("diagnostics.workspace.applicability", "Applicability", "适用条件"), row.applicability)
                        inspectorValue(text("diagnostics.workspace.backends", "Backends", "后端"), row.supportedBackends.joined(separator: ", "))
                        if let detail = row.detail {
                            Text(detail)
                                .font(VelaTypography.body)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }

                    VelaInspectorSection(
                        title: text("diagnostics.workspace.evidence", "Evidence", "证据")
                    ) {
                        inspectorValue(text("diagnostics.workspace.source", "Source", "来源"), row.evidence.source)
                        inspectorValue(text("diagnostics.workspace.captured", "Captured", "采集时间"), row.evidence.capturedAt.map(exactDate) ?? "—")
                        inspectorValue(text("diagnostics.workspace.confidence", "Confidence", "置信说明"), row.evidence.confidence)
                        inspectorValue(text("diagnostics.workspace.schema", "Schema", "结构"), row.evidenceSchema)
                        Text(row.evidence.summary)
                            .font(VelaTypography.body)
                            .textSelection(.enabled)
                        if let technicalDetails = row.evidence.technicalDetails {
                            Text(technicalDetails)
                                .font(VelaTypography.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        if let skipReason = row.evidence.skipReason {
                            inspectorValue(text("diagnostics.workspace.skipReason", "Skip reason", "跳过原因"), skipReason)
                        }
                    }

                    permissionSection(row)

                    VelaInspectorSection(
                        title: text("diagnostics.workspace.recovery", "Recovery", "恢复")
                    ) {
                        if let repairAction = row.repairAction {
                            inspectorValue(text("diagnostics.workspace.allowlistedAction", "Allowlisted action", "允许的操作"), repairAction.rawValue)
                            Text(repairDescription(repairAction))
                                .font(VelaTypography.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text(text("diagnostics.workspace.noRepair", "No mutating repair is registered for this check.", "此检查没有注册会改变系统状态的修复操作。"))
                                .font(VelaTypography.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    VelaInspectorSection(
                        title: text("diagnostics.workspace.history", "History", "历史")
                    ) {
                        if row.history.isEmpty {
                            Text(text("diagnostics.workspace.noHistory", "No bounded run history is available for this check.", "此检查暂无有界运行历史。"))
                                .font(VelaTypography.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(row.history) { entry in
                                HStack {
                                    Text(verbatim: entry.runID)
                                        .font(.system(size: VelaTypeSize.caption, design: .monospaced))
                                    Spacer()
                                    Text(exactDate(entry.completedAt))
                                        .font(VelaTypography.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    VelaInspectorSection(
                        title: text("diagnostics.workspace.actions", "Actions", "操作"),
                        showsDivider: false
                    ) {
                        inspectorActions(row)
                    }
                }
                .padding(.horizontal, VelaSpacing.medium)
                .padding(.bottom, VelaSpacing.medium)
            } else {
                VelaEmptyState(
                    title: text("diagnostics.workspace.selectCheck", "Select a check", "选择检查"),
                    description: text("diagnostics.workspace.selectCheck.detail", "Choose a row to inspect its evidence and recovery options.", "选择一行以检查其证据和恢复选项。"),
                    systemImage: "sidebar.trailing"
                )
                .frame(maxWidth: .infinity, minHeight: 320)
            }
        }
        .accessibilityIdentifier("diagnostics.inspector")
    }

    private func inspectorHeader(_ row: DiagnosticsCheckRowModel) -> some View {
        HStack(alignment: .top, spacing: VelaSpacing.small) {
            VStack(alignment: .leading, spacing: VelaSpacing.xSmall) {
                Text(row.title)
                    .font(.system(size: 20, weight: .bold))
                    .accessibilityAddTraits(.isHeader)
                Text(verbatim: row.id)
                    .font(.system(size: VelaTypeSize.caption, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                HStack(spacing: VelaSpacing.xSmall) {
                    VelaStatusPill(status: resultStatus(row.result), label: row.resultLabel)
                    Text(row.lastRunAt.map(relativeDate) ?? text("diagnostics.summary.notChecked", "Not checked", "尚未检查"))
                        .font(VelaTypography.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                showsInspector = false
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help(text("diagnostics.workspace.hideInspector", "Hide Inspector", "隐藏检查器"))
            .accessibilityIdentifier("diagnostics.hideInspector")
        }
        .padding(.vertical, VelaSpacing.medium)
    }

    @ViewBuilder
    private func permissionSection(_ row: DiagnosticsCheckRowModel) -> some View {
        VelaInspectorSection(
            title: text("diagnostics.workspace.permission", "Prerequisites / Permission", "前置条件 / 权限")
        ) {
            switch row.permission {
            case .notRequired:
                Label(
                    text("diagnostics.workspace.permission.none", "No additional permission required", "无需额外权限"),
                    systemImage: "checkmark.circle.fill"
                )
                .foregroundStyle(.green)
            case let .required(name, purpose, _):
                inspectorValue(text("diagnostics.workspace.permission.required", "Required", "需要"), name)
                Text(purpose).font(VelaTypography.caption).foregroundStyle(.secondary)
                Button(text("diagnostics.workspace.reviewPermission", "Review Permission", "检查权限")) {
                    reviewPermission(row)
                }
                .accessibilityIdentifier("diagnostics.reviewPermission")
            case let .denied(name, purpose, _):
                inspectorValue(text("diagnostics.workspace.permission.denied", "Denied", "已拒绝"), name)
                Text(purpose).font(VelaTypography.caption).foregroundStyle(.secondary)
                Button(text("legacy.openSystemSettings", "Open System Settings", "打开系统设置")) {
                    reviewPermission(row)
                }
            case let .restricted(name, purpose):
                inspectorValue(text("diagnostics.workspace.permission.restricted", "Restricted", "受限"), name)
                Text(purpose).font(VelaTypography.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func inspectorActions(_ row: DiagnosticsCheckRowModel) -> some View {
        VStack(alignment: .leading, spacing: VelaSpacing.medium) {
            VStack(spacing: VelaSpacing.small) {
                Button {
                    runSelected(row)
                } label: {
                    actionLabel(
                        text("diagnostics.workspace.rerunCheck", "Re-run This Check", "重新运行此检查"),
                        systemImage: "arrow.clockwise"
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canRunSelected(row) || run?.isActive == true || isRepairing)
                .help(runSelectedUnavailableReason(row) ?? "")
                .accessibilityIdentifier("diagnostics.runSelected")

                Button(action: runAll) {
                    actionLabel(
                        text("diagnostics.workspace.runAll", "Run All Checks", "运行全部检查"),
                        systemImage: "play.fill"
                    )
                }
                .disabled(run?.isActive == true || isRepairing)
            }

            if row.offersRepair {
                Divider()
                Button {
                    repair(row)
                } label: {
                    actionLabel(
                        text("diagnostics.workspace.repair", "Repair", "修复"),
                        systemImage: "wrench.and.screwdriver"
                    )
                }
                .disabled(run?.isActive == true || isRepairing)
                .accessibilityIdentifier("diagnostics.repair")
            }

            Divider()

            VStack(spacing: VelaSpacing.small) {
                Button(action: openSettings) {
                    actionLabel(
                        text("legacy.openSystemSettings", "Open Settings", "打开设置"),
                        systemImage: "gearshape"
                    )
                }
                Button(action: openLogs) {
                    actionLabel(
                        text("diagnostics.workspace.openLogs", "Open Logs", "打开日志"),
                        systemImage: "list.bullet.rectangle"
                    )
                }
                .disabled(!canOpenLogs)
                .help(openLogsUnavailableReason ?? "")
            }

            Divider()

            VStack(spacing: VelaSpacing.small) {
                Button {
                    copyRedactedSummary(row)
                } label: {
                    actionLabel(
                        text("legacy.copyRedactedDetails", "Copy Redacted Summary", "复制脱敏摘要"),
                        systemImage: "doc.on.doc"
                    )
                }
                Button(action: exportRedactedReport) {
                    actionLabel(
                        text("legacy.exportRedactedDiagnostics", "Export Redacted Report", "导出脱敏报告"),
                        systemImage: "square.and.arrow.up"
                    )
                }
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
    }

    private func actionLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
    }

    private func inspectorValue(_ label: String, _ value: String) -> some View {
        LabeledContent(label) {
            Text(value)
                .font(VelaTypography.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }

    private var selectedRow: DiagnosticsCheckRowModel? {
        snapshot.rows.first { $0.id == selectedCheckID }
    }

    private var isRepairing: Bool {
        repairProgress?.phase.isActive == true
    }

    private var filteredGroups: [DiagnosticsCheckGroupModel] {
        snapshot.groups.compactMap { group in
            let checks = group.checks.filter { row in
                filter.includes(row) && matchesSearch(row)
            }
            return checks.isEmpty ? nil : DiagnosticsCheckGroupModel(category: group.category, checks: checks)
        }
    }

    private var filteredRows: [DiagnosticsCheckRowModel] {
        filteredGroups.flatMap(\.checks)
    }

    private func matchesSearch(_ row: DiagnosticsCheckRowModel) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        return row.title.localizedCaseInsensitiveContains(query)
            || row.id.localizedCaseInsensitiveContains(query)
            || row.evidence.summary.localizedCaseInsensitiveContains(query)
    }

    private func selectInitialRowIfNeeded() {
        if let selectedCheckID,
            snapshot.rows.contains(where: { $0.id == selectedCheckID })
        {
            return
        }
        selectedCheckID = initialSelectionID.flatMap { requested in
            snapshot.rows.contains(where: { $0.id == requested }) ? requested : nil
        } ?? snapshot.rows.first?.id
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        guard !filteredRows.isEmpty else { return }
        let currentIndex = selectedCheckID.flatMap { selected in
            filteredRows.firstIndex { $0.id == selected }
        } ?? 0
        let nextIndex: Int
        switch direction {
        case .up:
            nextIndex = max(0, currentIndex - 1)
        case .down:
            nextIndex = min(filteredRows.count - 1, currentIndex + 1)
        default:
            return
        }
        selectedCheckID = filteredRows[nextIndex].id
    }

    private func overallLabel(_ state: DiagnosticsOverallState) -> String {
        switch state {
        case .healthy: text("diagnostics.health.healthy", "Healthy", "健康")
        case .needsAttention: text("diagnostics.health.needsAttention", "Needs Attention", "需要处理")
        case .critical: text("diagnostics.health.critical", "Critical", "严重")
        case .incomplete: text("diagnostics.workspace.incomplete", "Incomplete", "未完成")
        case .notEvaluated: text("diagnostics.summary.notEvaluated", "Not Evaluated", "尚未评估")
        case .running: text("diagnostics.workspace.running", "Running", "运行中")
        case .stale: text("diagnostics.workspace.stale", "Stale", "已过期")
        }
    }

    private func overallStatus(_ state: DiagnosticsOverallState) -> VelaSemanticStatus {
        switch state {
        case .healthy: .success
        case .needsAttention: .warning
        case .critical: .error
        case .incomplete: .warning
        case .notEvaluated: .neutral
        case .running: .pending
        case .stale: .stale
        }
    }

    private func resultStatus(_ result: DiagnosticsCheckResult) -> VelaSemanticStatus {
        switch result {
        case .passed: .success
        case .warning, .skipped: .warning
        case .failed: .error
        case .blocked: .permission
        case .notApplicable, .notRun: .neutral
        case .running: .pending
        case .stale: .stale
        }
    }

    private func evidenceStatus(_ state: DiagnosticsEvidenceState) -> VelaSemanticStatus {
        switch state {
        case .sufficient: .success
        case .partial, .insufficient: .warning
        case .stale: .stale
        case .unavailable: .neutral
        }
    }

    private func evidenceLabel(_ state: DiagnosticsEvidenceState) -> String {
        switch state {
        case .sufficient: text("diagnostics.workspace.evidence.sufficient", "Sufficient", "充分")
        case .partial: text("diagnostics.workspace.evidence.partial", "Partial", "部分")
        case .insufficient: text("diagnostics.workspace.evidence.insufficient", "Insufficient", "不足")
        case .stale: text("diagnostics.workspace.evidence.stale", "Stale", "已过期")
        case .unavailable: text("diagnostics.workspace.evidence.unavailable", "Unavailable", "不可用")
        }
    }

    private func categoryLabel(_ category: DiagnosticsCheckCategory) -> String {
        switch category {
        case .runtimeConfiguration:
            text("diagnostics.workspace.category.runtime", "Runtime & Configuration", "运行时与配置")
        case .networkPrivilege:
            text("diagnostics.workspace.category.privilege", "Network & Privilege", "网络与权限")
        case .connectivityDNS:
            text("diagnostics.workspace.category.connectivity", "Connectivity & DNS", "连接与 DNS")
        case .updatesCore:
            text("diagnostics.workspace.category.core", "Updates & Core", "更新与内核")
        case .supportEvidence:
            text("diagnostics.workspace.category.support", "Support Evidence", "支持证据")
        }
    }

    private func filterLabel(_ filter: DiagnosticsFilter) -> String {
        switch filter {
        case .all: text("legacy.all", "All", "全部")
        case .attention: text("diagnostics.workspace.filter.attention", "Attention", "需处理")
        case .failed: text("diagnostics.workspace.filter.failed", "Failed", "失败")
        case .blocked: text("diagnostics.workspace.filter.blocked", "Blocked", "受阻")
        }
    }

    private func distributionLabel(_ summary: DiagnosticsWorkspaceSummary) -> String {
        let ordered: [DiagnosticsCheckResult] = [
            .passed, .warning, .failed, .blocked, .skipped, .notApplicable, .notRun, .stale,
        ]
        let values = ordered.compactMap { result -> String? in
            guard let count = summary.distribution[result], count > 0 else { return nil }
            return "\(count) \(distributionName(result))"
        }
        return values.isEmpty ? "—" : values.joined(separator: " · ")
    }

    private func distributionName(_ result: DiagnosticsCheckResult) -> String {
        switch result {
        case .passed: text("diagnostics.workspace.passed", "passed", "通过")
        case .warning: text("diagnostics.workspace.warnings", "warning", "警告")
        case .failed: text("diagnostics.workspace.failed", "failed", "失败")
        case .blocked: text("diagnostics.workspace.blocked", "blocked", "受阻")
        case .skipped: text("diagnostics.workspace.skipped", "skipped", "已跳过")
        case .notApplicable: text("diagnostics.workspace.notApplicable", "not applicable", "不适用")
        case .notRun: text("diagnostics.workspace.notRun", "not run", "未运行")
        case .running: text("diagnostics.workspace.running", "running", "运行中")
        case .stale: text("diagnostics.workspace.stale", "stale", "已过期")
        }
    }

    private func lastRunLabel(_ summary: DiagnosticsWorkspaceSummary) -> String {
        summary.lastRunAt.map(exactDate)
            ?? text("diagnostics.summary.notChecked", "Not checked yet", "尚未检查")
    }

    private func relativeDate(_ date: Date) -> String {
        date.formatted(.relative(presentation: .named))
    }

    private func exactDate(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .standard)
    }

    private func durationLabel(_ seconds: Double) -> String {
        seconds < 1
            ? String(format: "%.0f ms", seconds * 1_000)
            : String(format: "%.1f s", seconds)
    }

    private func repairDescription(_ action: DiagnosticsRepairAction) -> String {
        switch action {
        case .restoreSystemProxy:
            text("diagnostics.workspace.repair.proxy", "Uses the existing System Proxy restore transaction and verifies the resulting state.", "使用现有系统代理恢复事务，并验证最终状态。")
        case .cleanupPrivilegedRuntime:
            text("diagnostics.workspace.repair.cleanup", "Stops only the verified owned runtime, runs bounded cleanup, and verifies the stopped state.", "仅停止已验证归属的运行时，执行有界清理，并验证停止状态。")
        case .reinstallPrivilegedComponent:
            text("diagnostics.workspace.repair.reinstall", "Uses the existing signed privileged-component reinstall flow after explicit confirmation.", "明确确认后，使用现有已签名特权组件重装流程。")
        }
    }

    private func repairPhaseLabel(_ phase: DiagnosticsRepairPhase) -> String {
        switch phase {
        case .preparing: text("diagnostics.workspace.preparing", "Preparing", "正在准备")
        case .requestingPrivilege: text("diagnostics.workspace.requestingPrivilege", "Requesting privilege", "正在请求权限")
        case .applying: text("diagnostics.workspace.applyingRepair", "Applying", "正在应用")
        case .verifying: text("diagnostics.workspace.verifyingRepair", "Verifying", "正在验证")
        case .completed: text("diagnostics.workspace.repairCompleted", "Completed", "已完成")
        case .failed: text("diagnostics.workspace.failed", "Failed", "失败")
        }
    }

    private func text(_ key: String, _ english: String, _ chinese: String) -> String {
        if VelaSupportedLocale.resolve(locale) == .simplifiedChinese {
            return chinese
        }
        return VelaL10n.string(key, defaultValue: english)
    }

}

private enum DiagnosticsWorkspaceStyle {
    static let pagePadding: CGFloat = 18
    static let panelGap: CGFloat = 12
    static let panelRadius: CGFloat = 16
}

private extension View {
    @ViewBuilder
    func diagnosticsPanelSurface(
        emphasized: Bool = false,
        tint: Color? = nil,
        usesGlassEffect: Bool = true
    ) -> some View {
        if usesGlassEffect {
            background {
                RoundedRectangle(
                    cornerRadius: DiagnosticsWorkspaceStyle.panelRadius,
                    style: .continuous
                )
                .fill((tint ?? .clear).opacity(tint == nil ? 0 : 0.08))
            }
            .velaPanelSurface(
                radius: DiagnosticsWorkspaceStyle.panelRadius,
                emphasized: emphasized
            )
            // Clip after the material and border have been composed. Clipping
            // content first can leave fragments at rounded scrolling edges.
            .clipShape(panelShape)
            .shadow(
                color: Color.black.opacity(emphasized ? 0.055 : 0.035),
                radius: emphasized ? 18 : 14,
                y: emphasized ? 8 : 6
            )
        } else {
            // The data table scrolls beneath a pinned header and an overlay
            // scroller. macOS glass can refract that combination into a small
            // accent-coloured triangle at the trailing corners, so keep this
            // dense reading surface opaque while retaining the same border,
            // radius, and elevation as the surrounding glass panels.
            background {
                panelShape
                    .fill(VelaAppearance.controlBackground)
                    .overlay {
                        if let tint {
                            panelShape.fill(tint.opacity(0.08))
                        }
                    }
            }
            .overlay {
                panelShape
                    .stroke(VelaAppearance.separator.opacity(0.58), lineWidth: 1)
            }
            .clipShape(panelShape)
            .shadow(
                color: Color.black.opacity(0.035),
                radius: 14,
                y: 6
            )
        }
    }

    private var panelShape: RoundedRectangle {
        RoundedRectangle(
            cornerRadius: DiagnosticsWorkspaceStyle.panelRadius,
            style: .continuous
        )
    }
}
