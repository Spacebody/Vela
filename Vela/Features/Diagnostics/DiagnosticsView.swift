import AppKit
import SwiftUI
import VelaIPC
import UniformTypeIdentifiers

private struct DiagnosticsRunStep {
    let id: String
    let title: String
    let checkIDs: [String]
    let timeoutSeconds: Double
    let operation: @MainActor @Sendable () async -> DiagnosticsRunStepOutcome
}

private enum DiagnosticsRepairConfirmation: String, Identifiable {
    case cleanupPrivilegedRuntime
    case reinstallPrivilegedComponent

    var id: String { rawValue }
}

struct DiagnosticsView: View {
#if DEBUG
    @Environment(\.visualUITestConfiguration) private var visualTestConfiguration
#endif
    let engineStore: EngineStore
    let dailyDriver: DailyDriverFeatureHub
    let sceneController: SceneFeatureController?
    let coreLifecycle: CoreLifecycleController?
    let updateController: UpdateController
    let publicBetaEvidence: PublicBetaEvidenceController?
    let publicBetaSafeMode: PublicBetaSafeModeController?
    @State private var isRunningChecks = false
    @State private var exportError: String?
    @State private var exportPreview: DiagnosticsExportPreview?
    @State private var pendingRepairConfirmation: DiagnosticsRepairConfirmation?
    @State private var includePrivilegedStartupLogs = false
    @State private var showsGuidedSupport = false
    @State private var isExportingReliabilityEvidence = false
    @State private var diagnosticsRun: DiagnosticsRunPresentation?
    @State private var diagnosticsRunTask: Task<Void, Never>?
    @State private var diagnosticsExportTask: Task<Void, Never>?
    @State private var diagnosticsRunGate = DiagnosticsRunGenerationGate()
    @State private var recentRunHistory: [DiagnosticsRunHistoryEntry] = []
    @State private var showsUpdatesCoreRecovery = false

    init(
        engineStore: EngineStore,
        dailyDriver: DailyDriverFeatureHub,
        sceneController: SceneFeatureController? = nil,
        coreLifecycle: CoreLifecycleController? = nil,
        updateController: UpdateController,
        publicBetaEvidence: PublicBetaEvidenceController? = nil,
        publicBetaSafeMode: PublicBetaSafeModeController? = nil
    ) {
        self.engineStore = engineStore
        self.dailyDriver = dailyDriver
        self.sceneController = sceneController
        self.coreLifecycle = coreLifecycle
        self.updateController = updateController
        self.publicBetaEvidence = publicBetaEvidence
        self.publicBetaSafeMode = publicBetaSafeMode
    }

    var body: some View {
        Group {
            if showsUpdatesCoreRecovery, let coreLifecycle {
                UpdatesCoreRecoveryFeatureView(
                    engineStore: engineStore,
                    updateController: updateController,
                    coreLifecycle: coreLifecycle,
                    onBack: { showsUpdatesCoreRecovery = false }
                )
            } else {
                groupedDiagnosticsWorkspace
            }
        }
        .overlay {
            if let confirmation = pendingRepairConfirmation {
                repairConfirmationOverlay(confirmation)
            }
        }
        .toolbar {
            if !showsUpdatesCoreRecovery, coreLifecycle != nil {
                ToolbarItem {
                    Button {
                        showsUpdatesCoreRecovery = true
                    } label: {
                        Label(
                            VelaL10n.string(
                                "diagnostics.updatesCore.open",
                                defaultValue: "Updates & Core"
                            ),
                            systemImage: "arrow.triangle.2.circlepath.circle"
                        )
                    }
                    .help(
                        VelaL10n.string(
                            "diagnostics.updatesCore.open.help",
                            defaultValue: "Inspect application updates, Core trust, activation, and recovery readiness."
                        )
                    )
                    .accessibilityIdentifier("diagnostics.openUpdatesCore")
                }
            }
        }
        .navigationTitle(VelaL10n.string("legacy.diagnostics", defaultValue: "Diagnostics"))
#if DEBUG
        .overlay(alignment: .topLeading) {
            if !isRunningChecks,
                visualTestConfiguration?.state == .loaded
            {
                VisualReadyMarker(fixtureID: "diagnostics.loaded")
            }
        }
#endif
        .toolbar {
            if !showsUpdatesCoreRecovery {
                ToolbarItemGroup {
                    Button {
                        prepareDiagnosticsPreview()
                    } label: {
                        Label(VelaL10n.string("legacy.exportRedactedDiagnostics", defaultValue: "Export Redacted Diagnostics"), systemImage: "square.and.arrow.up")
                    }
                    .help(VelaL10n.string("legacy.exportCountsAndHealthStateWithoutUrlsCredentialsOrConnectionDetails", defaultValue: "Export counts and health state without URLs, credentials, or connection details"))
                    .accessibilityIdentifier("diagnostics.export")

                    Button {
                        showsGuidedSupport = true
                    } label: {
                        Label(
                            VelaL10n.string(
                                "support.guided.open",
                                defaultValue: "Guided Support"
                            ),
                            systemImage: "lifepreserver"
                        )
                    }
                    .help(
                        VelaL10n.string(
                            "support.guided.open.help",
                            defaultValue: "Run category-based diagnostics and preview a redacted support bundle"
                        )
                    )
                    .accessibilityIdentifier("diagnostics.guidedSupport")
                }
            }
        }
        .alert(VelaL10n.string("legacy.diagnosticsExportFailed", defaultValue: "Diagnostics Export Failed"), isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button(VelaL10n.string("legacy.ok", defaultValue: "OK")) { exportError = nil }
        } message: {
            Text(
                exportError ?? VelaL10n.string(
                    "diagnostics.export.writeFailed",
                    defaultValue: "The diagnostics file could not be written."
                )
            )
        }
        .sheet(item: $exportPreview) { preview in
            DiagnosticsExportPreviewView(
                preview: preview,
                cancel: {
                    exportPreview = nil
                    includePrivilegedStartupLogs = false
                },
                save: { saveDiagnostics(preview) }
            )
        }
        .sheet(isPresented: $showsGuidedSupport) {
            GuidedSupportView(
                adapter: SupportDiagnosticsAdapter(
                    engineStore: engineStore,
                    dailyDriver: dailyDriver,
                    updateController: updateController,
                    coreLifecycle: coreLifecycle,
                    sceneController: sceneController
                ),
                publicBetaEvidence: publicBetaEvidence,
                openHelpTopic: { topic in
                    NotificationCenter.default.post(
                        name: .velaOpenHelpTopic,
                        object: nil,
                        userInfo: ["topic": topic]
                    )
                }
            )
        }
        .task {
            await publicBetaEvidence?.refresh()
        }
        .onDisappear {
            abandonDiagnosticsRun()
            diagnosticsExportTask?.cancel()
            diagnosticsExportTask = nil
        }
    }

    private var groupedDiagnosticsWorkspace: some View {
        DiagnosticsWorkspaceView(
            snapshot: diagnosticsWorkspaceSnapshot,
            run: diagnosticsRun,
            repairProgress: diagnosticsRepairProgress,
            initialSelectionID: diagnosticsWorkspaceSnapshot.rows.first(where: {
                [.failed, .blocked, .warning].contains($0.result)
            })?.id,
            initialInspectorVisibility: true,
            runAll: startDiagnosticsRun,
            cancelRun: cancelDiagnosticsRun,
            runSelected: startSelectedDiagnostic,
            canRunSelected: canRunSelectedDiagnostic,
            runSelectedUnavailableReason: selectedRunUnavailableReason,
            repair: performRegisteredRepair,
            reviewPermission: { _ in
                engineStore.privilegedComponentManager?.openSystemSettings()
            },
            openSettings: openApplicationSettings,
            canOpenLogs: true,
            openLogsUnavailableReason: nil,
            openLogs: openApplicationLogs,
            copyRedactedSummary: copyRedactedSummary,
            exportRedactedReport: prepareDiagnosticsPreview
        )
    }

    private var diagnosticsWorkspaceSnapshot: DiagnosticsWorkspaceSnapshot {
        let report = engineStore.lastHealthReport
        let reportRunID = report.map {
            "\(String($0.sessionID.uuidString.prefix(8)).uppercased())-\($0.sequence)"
        }
        let reportDate = report?.completedAt
        let presentationRunID: String? = nil
        let presentationRunDate: Date? = nil

        var groups: [DiagnosticsCheckGroupModel] = []

        let coreRows = coreChecks.map {
            diagnosticsWorkspaceRow(
                $0,
                category: .updatesCore,
                source: VelaL10n.string(
                    "diagnostics.workspace.source.coreIntegrity",
                    defaultValue: "Bundled Core integrity preflight"
                ),
                runID: presentationRunID,
                capturedAt: presentationRunDate
            )
        } + (coreLifecycle.map { lifecycle in
            coreLifecycleChecks(lifecycle).map {
                diagnosticsWorkspaceRow(
                    $0,
                    category: .updatesCore,
                    source: VelaL10n.string(
                        "diagnostics.workspace.source.coreLifecycle",
                        defaultValue: "Signed Core lifecycle snapshot"
                    ),
                    runID: presentationRunID,
                    capturedAt: presentationRunDate
                )
            }
        } ?? [])
        if !coreRows.isEmpty {
            groups.append(DiagnosticsCheckGroupModel(category: .updatesCore, checks: coreRows))
        }

        let registrationRows = privilegedRegistrationChecks.map { check in
            diagnosticsWorkspaceRow(
                check,
                category: .networkPrivilege,
                source: VelaL10n.string(
                    "diagnostics.workspace.source.privilegedRegistration",
                    defaultValue: "Privileged component registration and authenticated handshake"
                ),
                runID: presentationRunID,
                capturedAt: presentationRunDate,
                permission: diagnosticsPermission(for: check),
                repairAction: check.id == "registration" ? .reinstallPrivilegedComponent : nil
            )
        }
        let privilegedRows = privilegedRuntimeChecks.map {
            diagnosticsWorkspaceRow(
                $0,
                category: .networkPrivilege,
                source: VelaL10n.string(
                    "diagnostics.workspace.source.privilegedRuntime",
                    defaultValue: "Authenticated privileged runtime health snapshot"
                ),
                runID: presentationRunID,
                capturedAt: presentationRunDate
            )
        }
        let cleanupRows = [
            diagnosticsWorkspaceRow(
                cleanupCheck,
                category: .networkPrivilege,
                source: VelaL10n.string(
                    "diagnostics.workspace.source.cleanup",
                    defaultValue: "Owned privileged-runtime cleanup state"
                ),
                runID: presentationRunID,
                capturedAt: presentationRunDate,
                repairAction: .cleanupPrivilegedRuntime
            ),
            diagnosticsWorkspaceRow(
                privilegedSigningCheck,
                category: .networkPrivilege,
                source: VelaL10n.string(
                    "diagnostics.workspace.source.signing",
                    defaultValue: "Privileged component signing snapshot"
                ),
                runID: presentationRunID,
                capturedAt: presentationRunDate
            ),
        ]
        groups.append(DiagnosticsCheckGroupModel(
            category: .networkPrivilege,
            checks: registrationRows + privilegedRows + cleanupRows
        ))

        let engineRows: [DiagnosticsCheckRowModel]
        if let report {
            engineRows = report.checks.map { check in
                diagnosticsWorkspaceRow(
                    check,
                    report: report,
                    runID: reportRunID
                )
            }
        } else {
            engineRows = EngineHealthComponent.allCases.map {
                diagnosticsNotRunRow(for: $0)
            }
        }
        let engineGroups = Dictionary(grouping: engineRows, by: \.category)
        for category in [
            DiagnosticsCheckCategory.runtimeConfiguration,
            .connectivityDNS,
        ] {
            if let rows = engineGroups[category], !rows.isEmpty {
                groups.append(DiagnosticsCheckGroupModel(category: category, checks: rows))
            }
        }

        groups.append(DiagnosticsCheckGroupModel(
            category: .supportEvidence,
            checks: [
                diagnosticsWorkspaceRow(
                    providerCheck,
                    category: .supportEvidence,
                    source: VelaL10n.string(
                        "diagnostics.workspace.source.providerCatalog",
                        defaultValue: "Mihomo Controller provider catalog"
                    ),
                    runID: presentationRunID,
                    capturedAt: presentationRunDate
                ),
            ]
        ))

        let stale = reportDate.map { Date.now.timeIntervalSince($0) >= 300 } ?? false
        if stale {
            groups = groups.map { group in
                DiagnosticsCheckGroupModel(
                    category: group.category,
                    checks: group.checks.map(markingStale)
                )
            }
        }

        let duplicateCheckIDs = Dictionary(grouping: groups.flatMap(\.checks), by: \.id)
            .filter { $0.value.count > 1 }
            .map(\.key)
            .sorted()
        let registryError = duplicateCheckIDs.isEmpty
            ? nil
            : VelaL10n.string(
                "diagnostics.workspace.registry.duplicateIDs",
                defaultValue: "The diagnostic registry contains duplicate check IDs: %@",
                arguments: duplicateCheckIDs.joined(separator: ", ")
            )
        return DiagnosticsWorkspaceSnapshot(
            registryRevision: "engine-health.v1+diagnostics-status.v1",
            groups: groups,
            registryError: registryError,
            isRegistryLoading: false,
            isStale: stale
        )
    }

    private var diagnosticsRepairProgress: DiagnosticsRepairPresentation? {
        guard let manager = engineStore.privilegedComponentManager else { return nil }
        if manager.isCleaning {
            return DiagnosticsRepairPresentation(
                id: "privileged-cleanup-active",
                targetCheckID: "cleanup",
                action: .cleanupPrivilegedRuntime,
                phase: .applying,
                privilege: "Authenticated VelaHelper",
                requestedState: "Owned privileged runtime stopped and cleaned",
                cleanupOrRollback: "Bounded owned-resource cleanup",
                postcondition: "Stopped state verified twice",
                message: nil
            )
        }
        guard let result = manager.lastCleanupResult, !result.succeeded else { return nil }
        return DiagnosticsRepairPresentation(
            id: result.id.uuidString,
            targetCheckID: "cleanup",
            action: .cleanupPrivilegedRuntime,
            phase: .failed,
            privilege: "Authenticated VelaHelper",
            requestedState: "Owned privileged runtime stopped and cleaned",
            cleanupOrRollback: "Cleanup stopped without broadening ownership scope",
            postcondition: "Stopped state was not verified",
            message: result.message
        )
    }

    private func diagnosticsWorkspaceRow(
        _ check: DiagnosticCheck,
        category: DiagnosticsCheckCategory,
        source: String,
        runID: String?,
        capturedAt: Date?,
        permission: DiagnosticsPermissionState = .notRequired,
        repairAction: DiagnosticsRepairAction? = nil
    ) -> DiagnosticsCheckRowModel {
        let history = recentRunHistory.filter { $0.checkID == check.id }
        let latestHistory = history.first
        let currentResult = diagnosticsResult(check.indicator, permission: permission)
        let result = DiagnosticsRunHistoryPolicy.resolvedResult(
            current: currentResult,
            latestHistory: latestHistory
        )
        let resolvedRunID = latestHistory?.runID ?? runID
        let resolvedCapturedAt = latestHistory?.completedAt ?? capturedAt
        return DiagnosticsCheckRowModel(
            id: check.id,
            category: category,
            title: check.title,
            result: result,
            resultLabel: diagnosticsResultLabel(result, fallback: check.value),
            detail: check.detail,
            evidence: DiagnosticsEvidencePresentation(
                state: diagnosticsEvidenceState(for: result),
                source: source,
                capturedAt: resolvedCapturedAt,
                summary: check.detail ?? check.value,
                technicalDetails: check.detail.map(DiagnosticTextSanitizer.redact),
                confidence: VelaL10n.string(
                    "diagnostics.workspace.confidence.stateDerived",
                    defaultValue: "Derived from the current typed Vela state"
                ),
                skipReason: result == .skipped ? check.detail ?? check.value : nil
            ),
            lastRunID: resolvedRunID,
            lastRunAt: resolvedCapturedAt,
            durationSeconds: latestHistory?.durationSeconds,
            skippedCountsAsComplete: result == .skipped,
            applicability: VelaL10n.string(
                "diagnostics.workspace.applicability.currentMac",
                defaultValue: "Applicable to this Mac when the related feature is available"
            ),
            permission: permission,
            repairAction: repairAction,
            evidenceSchema: "vela.diagnostics.state.v1",
            dependencies: [source],
            history: history
        )
    }

    private func diagnosticsWorkspaceRow(
        _ check: EngineHealthCheck,
        report: EngineHealthReport,
        runID: String?
    ) -> DiagnosticsCheckRowModel {
        let id = "engine.\(check.component.rawValue)"
        let history = recentRunHistory.filter { $0.checkID == id }
        let latestHistory = history.first
        let result = DiagnosticsRunHistoryPolicy.resolvedResult(
            current: diagnosticsResult(check.state),
            latestHistory: latestHistory
        )
        let resolvedRunID = latestHistory?.runID ?? runID
        let resolvedCapturedAt = latestHistory?.completedAt ?? report.completedAt
        return DiagnosticsCheckRowModel(
            id: id,
            category: diagnosticsCategory(check.component),
            title: healthComponentTitle(check.component),
            result: result,
            resultLabel: diagnosticsResultLabel(result, fallback: healthCheckValue(check.state)),
            detail: check.summary,
            evidence: DiagnosticsEvidencePresentation(
                state: diagnosticsEvidenceState(for: result),
                source: VelaL10n.string(
                    "diagnostics.workspace.source.engineHealth",
                    defaultValue: "Engine health report"
                ),
                capturedAt: resolvedCapturedAt,
                summary: check.summary,
                technicalDetails: check.technicalDetails.map(DiagnosticTextSanitizer.redact),
                confidence: VelaL10n.string(
                    "diagnostics.workspace.confidence.directObservation",
                    defaultValue: "Direct bounded runtime observation"
                ),
                skipReason: check.state == .skipped ? check.summary : nil
            ),
            lastRunID: resolvedRunID,
            lastRunAt: resolvedCapturedAt,
            durationSeconds: latestHistory?.durationSeconds,
            skippedCountsAsComplete: check.state == .skipped,
            applicability: engineApplicability(check.component),
            repairAction: check.component == .systemProxy ? .restoreSystemProxy : nil,
            timeoutSeconds: check.component == .controller ? 1 : nil,
            evidenceSchema: "vela.engine-health.v1",
            dependencies: engineDependencies(check.component),
            history: history
        )
    }

    private func diagnosticsNotRunRow(
        for component: EngineHealthComponent
    ) -> DiagnosticsCheckRowModel {
        let title = healthComponentTitle(component)
        let id = "engine.\(component.rawValue)"
        let history = recentRunHistory.filter { $0.checkID == id }
        let latestHistory = history.first
        let result = DiagnosticsRunHistoryPolicy.resolvedResult(
            current: .notRun,
            latestHistory: latestHistory
        )
        return DiagnosticsCheckRowModel(
            id: id,
            category: diagnosticsCategory(component),
            title: title,
            result: result,
            resultLabel: diagnosticsResultLabel(
                result,
                fallback: VelaL10n.string(
                    "diagnostics.workspace.notRun",
                    defaultValue: "Not run"
                )
            ),
            detail: VelaL10n.string(
                "diagnostics.workspace.notRun.detail",
                defaultValue: "Run all checks to collect this evidence."
            ),
            evidence: DiagnosticsEvidencePresentation(
                state: diagnosticsEvidenceState(for: result),
                source: VelaL10n.string(
                    "diagnostics.workspace.source.engineHealth",
                    defaultValue: "Engine health report"
                ),
                capturedAt: latestHistory?.completedAt,
                summary: VelaL10n.string(
                    "diagnostics.workspace.evidence.notCollected",
                    defaultValue: "No evidence has been collected."
                ),
                confidence: VelaL10n.string(
                    "diagnostics.workspace.confidence.unavailable",
                    defaultValue: "Unavailable until the check runs"
                ),
                skipReason: result == .skipped
                    ? VelaL10n.string(
                        "diagnostics.workspace.skipped.noRuntime",
                        defaultValue: "The runtime prerequisite was not available."
                    )
                    : nil
            ),
            lastRunID: latestHistory?.runID,
            lastRunAt: latestHistory?.completedAt,
            durationSeconds: latestHistory?.durationSeconds,
            skippedCountsAsComplete: result == .skipped,
            applicability: engineApplicability(component),
            repairAction: component == .systemProxy ? .restoreSystemProxy : nil,
            timeoutSeconds: component == .controller ? 1 : nil,
            evidenceSchema: "vela.engine-health.v1",
            dependencies: engineDependencies(component),
            history: history
        )
    }

    private func diagnosticsPermission(
        for check: DiagnosticCheck
    ) -> DiagnosticsPermissionState {
        guard check.id == "registration",
            let manager = engineStore.privilegedComponentManager
        else { return .notRequired }
        switch manager.state {
        case .needsApproval:
            return .required(
                name: VelaL10n.string(
                    "diagnostics.workspace.permission.privilegedComponent",
                    defaultValue: "Privileged component approval"
                ),
                purpose: VelaL10n.string(
                    "diagnostics.workspace.permission.privilegedComponent.purpose",
                    defaultValue: "macOS approval is required before Vela can authenticate and inspect the privileged TUN runtime."
                ),
                settingsTitle: VelaL10n.string(
                    "legacy.openSystemSettings",
                    defaultValue: "Open System Settings"
                )
            )
        case .incompatible, .damaged, .failed:
            return .denied(
                name: VelaL10n.string(
                    "diagnostics.workspace.permission.privilegedComponent",
                    defaultValue: "Privileged component approval"
                ),
                purpose: VelaRuntimeStatusPresentation.helperDetail(manager.state)
                    ?? VelaL10n.string(
                        "diagnostics.workspace.permission.privilegedComponent.unavailable",
                        defaultValue: "The privileged component cannot be inspected until its registration is repaired."
                    ),
                settingsTitle: VelaL10n.string(
                    "legacy.openSystemSettings",
                    defaultValue: "Open System Settings"
                )
            )
        case .notInstalled, .registering, .connecting, .ready, .uninstalling:
            return .notRequired
        }
    }

    private func diagnosticsResult(
        _ indicator: DiagnosticIndicator,
        permission: DiagnosticsPermissionState = .notRequired
    ) -> DiagnosticsCheckResult {
        switch permission {
        case .required, .denied, .restricted:
            return .blocked
        case .notRequired:
            break
        }
        return switch indicator {
        case .success: .passed
        case .failure: .failed
        case .warning: .warning
        case .progress: .running
        case .inactive: .notRun
        case .notApplicable: .notApplicable
        }
    }

    private func diagnosticsResult(_ state: HealthCheckState) -> DiagnosticsCheckResult {
        switch state {
        case .passing: .passed
        case .degraded: .warning
        case .failing: .failed
        case .unknown: .notRun
        case .skipped: .skipped
        }
    }

    private func diagnosticsResultLabel(
        _ result: DiagnosticsCheckResult,
        fallback: String
    ) -> String {
        switch result {
        case .passed, .warning, .failed, .running:
            fallback
        case .skipped:
            VelaL10n.string("diagnostics.workspace.skipped", defaultValue: "Skipped")
        case .blocked:
            VelaL10n.string("diagnostics.workspace.blocked", defaultValue: "Blocked")
        case .notApplicable:
            VelaL10n.string("diagnostics.workspace.notApplicable", defaultValue: "Not applicable")
        case .notRun:
            VelaL10n.string("diagnostics.workspace.notRun", defaultValue: "Not run")
        case .stale:
            VelaL10n.string("diagnostics.workspace.stale", defaultValue: "Stale")
        }
    }

    private func diagnosticsEvidenceState(
        for result: DiagnosticsCheckResult
    ) -> DiagnosticsEvidenceState {
        switch result {
        case .passed: .sufficient
        case .warning, .failed, .skipped: .partial
        case .blocked, .notRun, .running: .unavailable
        case .notApplicable: .insufficient
        case .stale: .stale
        }
    }

    private func diagnosticsCategory(
        _ component: EngineHealthComponent
    ) -> DiagnosticsCheckCategory {
        switch component {
        case .networkPath, .internet:
            .connectivityDNS
        case .process, .controller, .configuration, .mixedPort, .systemProxy:
            .runtimeConfiguration
        }
    }

    private func engineApplicability(_ component: EngineHealthComponent) -> String {
        switch component {
        case .process, .systemProxy, .networkPath:
            VelaL10n.string(
                "diagnostics.workspace.applicability.always",
                defaultValue: "Always applicable on macOS"
            )
        case .controller, .configuration, .mixedPort, .internet:
            VelaL10n.string(
                "diagnostics.workspace.applicability.running",
                defaultValue: "Applicable while Mihomo is expected to be running"
            )
        }
    }

    private func engineDependencies(_ component: EngineHealthComponent) -> [String] {
        switch component {
        case .process: ["MihomoProcessManaging"]
        case .controller: ["ControllerHealthProbing"]
        case .configuration: ["RuntimeConfigurationInspecting"]
        case .mixedPort: ["ConnectivityProbing", "mixed-port"]
        case .systemProxy: ["SystemProxyManaging"]
        case .networkPath: ["NWPath"]
        case .internet: ["ConnectivityProbing", "NWPath"]
        }
    }

    private func markingStale(
        _ row: DiagnosticsCheckRowModel
    ) -> DiagnosticsCheckRowModel {
        DiagnosticsCheckRowModel(
            id: row.id,
            category: row.category,
            title: row.title,
            result: row.result,
            resultLabel: row.resultLabel,
            detail: row.detail,
            evidence: DiagnosticsEvidencePresentation(
                state: row.evidence.capturedAt == nil ? row.evidence.state : .stale,
                source: row.evidence.source,
                capturedAt: row.evidence.capturedAt,
                summary: row.evidence.summary,
                technicalDetails: row.evidence.technicalDetails,
                confidence: row.evidence.confidence,
                skipReason: row.evidence.skipReason
            ),
            lastRunID: row.lastRunID,
            lastRunAt: row.lastRunAt,
            durationSeconds: row.durationSeconds,
            skippedCountsAsComplete: row.skippedCountsAsComplete,
            applicability: row.applicability,
            permission: row.permission,
            repairAction: row.repairAction,
            timeoutSeconds: row.timeoutSeconds,
            evidenceSchema: row.evidenceSchema,
            dependencies: row.dependencies,
            supportedBackends: row.supportedBackends,
            history: row.history
        )
    }

    private func performRegisteredRepair(_ row: DiagnosticsCheckRowModel) {
        switch row.repairAction {
        case .restoreSystemProxy:
            Task {
                if engineStore.isTunActive {
                    await engineStore.setTunEnabled(false)
                } else if engineStore.systemProxyNeedsRestore {
                    await engineStore.setSystemProxyEnabled(false)
                } else {
                    // The row can become stale between presentation and activation.
                    // Refreshing converges the UI instead of leaving a no-op click.
                    await engineStore.refreshHealth()
                }
            }
        case .cleanupPrivilegedRuntime:
            pendingRepairConfirmation = .cleanupPrivilegedRuntime
        case .reinstallPrivilegedComponent:
            pendingRepairConfirmation = .reinstallPrivilegedComponent
        case nil:
            break
        }
    }

    @ViewBuilder
    private func repairConfirmationOverlay(
        _ confirmation: DiagnosticsRepairConfirmation
    ) -> some View {
        ZStack {
            Color.black.opacity(0.16)
                .ignoresSafeArea()
                .onTapGesture { pendingRepairConfirmation = nil }

            repairConfirmationContent(confirmation)
                .background(
                    .regularMaterial,
                    in: RoundedRectangle(cornerRadius: VelaRadius.onboarding, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: VelaRadius.onboarding, style: .continuous)
                        .stroke(Color.white.opacity(0.62), lineWidth: 1)
                }
                .shadow(color: Color.black.opacity(0.18), radius: 28, y: 12)
                .padding(VelaSpacing.large)
        }
        .accessibilityIdentifier("diagnostics.repairConfirmation")
        .transition(.opacity.combined(with: .scale(scale: 0.98)))
        .zIndex(10)
    }

    @ViewBuilder
    private func repairConfirmationContent(
        _ confirmation: DiagnosticsRepairConfirmation
    ) -> some View {
        switch confirmation {
        case .cleanupPrivilegedRuntime:
            VelaConfirmationSheet(
                title: VelaL10n.string(
                    "legacy.runPrivilegedCleanupQuestion",
                    defaultValue: "Run Privileged Cleanup?"
                ),
                message: VelaL10n.string(
                    "diagnostics.cleanup.confirmation.detail",
                    defaultValue: "Vela will authenticate the privileged component, stop only its verified owned instance if needed, clean owned interface/routes/staging, and verify the stopped state twice. The component remains registered; current and previous root configurations are retained until uninstall."
                ),
                confirmTitle: VelaL10n.string(
                    "legacy.stopOwnedRuntimeAndClean",
                    defaultValue: "Stop Owned Runtime and Clean"
                ),
                onConfirm: {
                    pendingRepairConfirmation = nil
                    Task { await engineStore.runPrivilegedCleanup(userConfirmed: true) }
                },
                onCancel: { pendingRepairConfirmation = nil }
            )
        case .reinstallPrivilegedComponent:
            VelaConfirmationSheet(
                title: VelaL10n.string(
                    "legacy.reinstallPrivilegedComponentQuestion",
                    defaultValue: "Reinstall Privileged Component?"
                ),
                message: VelaL10n.string(
                    "legacy.tunMustBeOffMacosMayRequireApprovalAgain",
                    defaultValue: "TUN must be off. macOS may require approval again."
                ),
                confirmTitle: VelaL10n.string(
                    "legacy.reinstall",
                    defaultValue: "Reinstall"
                ),
                confirmRole: nil,
                onConfirm: {
                    pendingRepairConfirmation = nil
                    Task { await engineStore.reinstallPrivilegedComponent(userConfirmed: true) }
                },
                onCancel: { pendingRepairConfirmation = nil }
            )
        }
    }

    private func copyRedactedSummary(_ row: DiagnosticsCheckRowModel) {
        let text = [
            "check=\(row.id)",
            "result=\(row.result.rawValue)",
            "evidence=\(row.evidence.state.rawValue)",
            "run=\(row.lastRunID ?? "none")",
            "summary=\(DiagnosticTextSanitizer.redact(row.evidence.summary))",
        ].joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func openApplicationSettings() {
        SettingsMainNavigationRequest.navigateInCurrentWindow(.settings)
        Task { @MainActor in
            await Task.yield()
            NotificationCenter.default.post(
                name: .velaOpenSettingsCategory,
                object: nil,
                userInfo: [
                    SettingsNavigationRequest.categoryUserInfoKey:
                        SettingsCategory.betaDiagnostics.rawValue
                ]
            )
        }
    }

    private func openApplicationLogs() {
        SettingsMainNavigationRequest.navigateInCurrentWindow(.logs)
    }

    private func canRunSelectedDiagnostic(_ row: DiagnosticsCheckRowModel) -> Bool {
        switch row.category {
        case .updatesCore, .runtimeConfiguration, .connectivityDNS:
            return true
        case .networkPrivilege:
            return engineStore.privilegedComponentManager != nil
        case .supportEvidence:
            return row.id == "provider"
                && engineStore.isRunning
                && engineStore.controllerState == .connected
        }
    }

    private func selectedRunUnavailableReason(_ row: DiagnosticsCheckRowModel) -> String? {
        guard !canRunSelectedDiagnostic(row) else { return nil }
        if row.id == "provider" {
            return VelaL10n.string(
                "diagnostics.workspace.provider.requiresController",
                defaultValue: "Start Mihomo and wait for the Controller to connect before refreshing provider diagnostics."
            )
        }
        if row.category == .networkPrivilege,
            engineStore.privilegedComponentManager == nil
        {
            return VelaL10n.string(
                "diagnostics.workspace.privileged.unavailable",
                defaultValue: "Privileged component diagnostics are unavailable in this launch mode."
            )
        }
        return VelaL10n.string(
            "diagnostics.workspace.rerunUnavailable",
            defaultValue: "This check cannot be refreshed in the current application state."
        )
    }

    private func startSelectedDiagnostic(_ row: DiagnosticsCheckRowModel) {
        guard canRunSelectedDiagnostic(row), diagnosticsRunTask == nil else { return }
        let operation: @MainActor @Sendable () async -> DiagnosticsRunStepOutcome
        let timeoutSeconds: Double
        switch row.category {
        case .updatesCore:
            timeoutSeconds = 20
            operation = {
                await engineStore.checkCoreIntegrity()
                return .completed
            }
        case .networkPrivilege:
            timeoutSeconds = 15
            operation = {
                await engineStore.refreshPrivilegedComponent()
                return .completed
            }
        case .runtimeConfiguration, .connectivityDNS:
            timeoutSeconds = 10
            operation = {
                await engineStore.refreshHealth()
                return .completed
            }
        case .supportEvidence:
            timeoutSeconds = 10
            operation = {
                guard engineStore.controllerState == .connected else {
                    return .skipped(reason: "Mihomo Controller is not connected.")
                }
                await engineStore.refreshProxies()
                return .completed
            }
        }
        startDiagnosticsRun(steps: [
            DiagnosticsRunStep(
                id: row.id,
                title: row.title,
                checkIDs: [row.id],
                timeoutSeconds: timeoutSeconds,
                operation: operation
            ),
        ])
    }

    private func exportReliabilityEvidence(
        _ evidence: PublicBetaEvidenceController
    ) async {
        guard !isExportingReliabilityEvidence else { return }
        isExportingReliabilityEvidence = true
        defer { isExportingReliabilityEvidence = false }
        do {
            let data = try await evidence.redactedExportData()
            guard !Task.isCancelled else { return }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "Vela-Beta-Evidence.json"
            panel.allowedContentTypes = [.json]
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let destination = panel.url else { return }
            try await DiagnosticsExportWriter.shared.write(data, to: destination)
        } catch {
            exportError = VelaL10n.string(
                "beta.evidence.export.failed",
                defaultValue: "The redacted reliability evidence could not be exported."
            )
        }
    }

    private func healthComponentTitle(_ component: EngineHealthComponent) -> String {
        switch component {
        case .process:
            VelaL10n.string(
                "diagnostics.component.mihomoProcess",
                defaultValue: "Mihomo Process"
            )
        case .controller:
            VelaL10n.string(
                "diagnostics.component.controller",
                defaultValue: "Controller"
            )
        case .configuration:
            VelaL10n.string(
                "diagnostics.component.configuration",
                defaultValue: "Configuration"
            )
        case .mixedPort:
            VelaL10n.string(
                "diagnostics.component.mixedPort",
                defaultValue: "Mixed Port"
            )
        case .systemProxy:
            VelaL10n.string(
                "diagnostics.component.systemProxy",
                defaultValue: "System Proxy"
            )
        case .networkPath:
            VelaL10n.string(
                "diagnostics.component.network",
                defaultValue: "Network"
            )
        case .internet:
            VelaL10n.string(
                "diagnostics.component.internet",
                defaultValue: "Internet"
            )
        }
    }

    private func healthCheckValue(_ state: HealthCheckState) -> String {
        switch state {
        case .passing:
            VelaL10n.string(
                "diagnostics.checkState.passed",
                defaultValue: "Passed"
            )
        case .degraded:
            VelaL10n.string(
                "diagnostics.checkState.needsAttention",
                defaultValue: "Needs attention"
            )
        case .failing:
            VelaL10n.string(
                "diagnostics.checkState.failed",
                defaultValue: "Failed"
            )
        case .unknown:
            VelaL10n.string(
                "diagnostics.summary.notEvaluated",
                defaultValue: "Not evaluated"
            )
        case .skipped:
            VelaL10n.string(
                "diagnostics.checkState.notRequired",
                defaultValue: "Not required"
            )
        }
    }

    private var privilegedRegistrationChecks: [DiagnosticCheck] {
        guard let manager = engineStore.privilegedComponentManager else {
            return [
                DiagnosticCheck(
                    id: "registration",
                    title: VelaL10n.string(
                        "diagnostics.registration.title",
                        defaultValue: "Registration"
                    ),
                    value: VelaL10n.string(
                        "diagnostics.registration.unavailableInLaunchMode",
                        defaultValue: "Unavailable in this launch mode"
                    ),
                    indicator: .inactive
                ),
            ]
        }
        let registrationIndicator: DiagnosticIndicator = switch manager.state {
        case .ready: .success
        case .registering, .connecting, .uninstalling: .progress
        case .needsApproval, .incompatible: .warning
        case .damaged, .failed: .failure
        case .notInstalled: .inactive
        }
        let handshake = manager.lastHandshake
        let bundle = manager.snapshot?.bundle
        return [
            DiagnosticCheck(
                id: "registration",
                title: VelaL10n.string(
                    "diagnostics.registration.smAppService.title",
                    defaultValue: "SMAppService Registration"
                ),
                value: VelaRuntimeStatusPresentation.helperTitle(manager.state),
                detail: VelaRuntimeStatusPresentation.helperDetail(manager.state)
                    .map(DiagnosticTextSanitizer.redact),
                indicator: registrationIndicator
            ),
            DiagnosticCheck(
                id: "xpc",
                title: VelaL10n.string(
                    "diagnostics.registration.xpcAuthentication.title",
                    defaultValue: "XPC Authentication"
                ),
                value: handshake == nil
                    ? VelaL10n.string(
                        "diagnostics.registration.xpcAuthentication.notConnected",
                        defaultValue: "Not connected"
                    )
                    : VelaL10n.string(
                        "diagnostics.registration.xpcAuthentication.authenticated",
                        defaultValue: "Authenticated"
                    ),
                indicator: handshake == nil ? .inactive : .success
            ),
            DiagnosticCheck(
                id: "launchDaemonPlist",
                title: VelaL10n.string(
                    "diagnostics.registration.launchDaemonPlist.title",
                    defaultValue: "LaunchDaemon Plist"
                ),
                value: bundle == nil
                    ? VelaL10n.string(
                        "diagnostics.value.notChecked",
                        defaultValue: "Not checked"
                    )
                    : VelaL10n.string(
                        "diagnostics.registration.bundleLayoutVerified",
                        defaultValue: "Bundle layout verified"
                    ),
                indicator: bundle == nil ? .inactive : .success
            ),
            DiagnosticCheck(
                id: "helperSignature",
                title: VelaL10n.string(
                    "diagnostics.registration.componentSignature.title",
                    defaultValue: "Privileged Component Signature"
                ),
                value: bundle.map {
                    VelaL10n.string(
                        "diagnostics.registration.componentSignature.valueFormat",
                        defaultValue: "%@ · Team %@",
                        arguments: $0.helperSigningIdentifier,
                        $0.teamIdentifier
                    )
                } ?? VelaL10n.string(
                    "diagnostics.value.notChecked",
                    defaultValue: "Not checked"
                ),
                indicator: bundle == nil ? .inactive : .success
            ),
            DiagnosticCheck(
                id: "helper",
                title: VelaL10n.string(
                    "diagnostics.registration.component.title",
                    defaultValue: "Privileged Component"
                ),
                value: handshake.map {
                    VelaL10n.string(
                        "diagnostics.registration.component.versionBuildFormat",
                        defaultValue: "%@ (%@)",
                        arguments: $0.helperVersion,
                        $0.helperBuild
                    )
                } ?? VelaL10n.string(
                    "diagnostics.value.notChecked",
                    defaultValue: "Not checked"
                ),
                indicator: handshake?.hasCompatibleProtocol == true ? .success : .inactive
            ),
            DiagnosticCheck(
                id: "helperProtocol",
                title: VelaL10n.string(
                    "diagnostics.registration.helperProtocol.title",
                    defaultValue: "Helper Protocol"
                ),
                value: handshake.map {
                    VelaL10n.string(
                        "diagnostics.registration.helperProtocol.rangeFormat",
                        defaultValue: "%lld–%lld",
                        arguments: Int64($0.helperProtocolMinimum),
                        Int64($0.helperProtocolMaximum)
                    )
                } ?? VelaL10n.string(
                    "diagnostics.value.notChecked",
                    defaultValue: "Not checked"
                ),
                indicator: handshake?.hasCompatibleProtocol == true ? .success : .warning
            ),
            DiagnosticCheck(
                id: "rootDirectory",
                title: VelaL10n.string(
                    "diagnostics.registration.rootDirectory.title",
                    defaultValue: "Root Directory"
                ),
                value: handshake == nil
                    ? VelaL10n.string(
                        "diagnostics.value.notChecked",
                        defaultValue: "Not checked"
                    )
                    : VelaL10n.string(
                        "diagnostics.registration.rootDirectory.verified",
                        defaultValue: "Ownership, permissions, and no-symlink policy verified at Helper bootstrap"
                    ),
                indicator: handshake == nil ? .inactive : .success
            ),
            DiagnosticCheck(
                id: "staleJournal",
                title: VelaL10n.string(
                    "diagnostics.registration.startupJournalRecovery.title",
                    defaultValue: "Startup Journal Recovery"
                ),
                value: handshake == nil
                    ? VelaL10n.string(
                        "diagnostics.value.notChecked",
                        defaultValue: "Not checked"
                    )
                    : VelaL10n.string(
                        "diagnostics.registration.startupJournalRecovery.completed",
                        defaultValue: "Completed before XPC was exposed"
                    ),
                indicator: handshake == nil ? .inactive : .success
            ),
        ]
    }

    private var privilegedRuntimeChecks: [DiagnosticCheck] {
        let health = engineStore.privilegedHealth
        let dnsHijackEnabled = engineStore.tunSettings.dnsHijack
        let runtimeIsRunning = health?.processRunning == true
        let dnsValue: String
        let dnsIndicator: DiagnosticIndicator
        if !dnsHijackEnabled {
            dnsValue = VelaL10n.string(
                "diagnostics.value.notRequested",
                defaultValue: "Not requested"
            )
            dnsIndicator = .inactive
        } else if !runtimeIsRunning {
            dnsValue = VelaL10n.string(
                "diagnostics.value.stopped",
                defaultValue: "Stopped"
            )
            dnsIndicator = .inactive
        } else if health?.dnsReady == true {
            dnsValue = VelaL10n.string(
                "diagnostics.value.ready",
                defaultValue: "Ready"
            )
            dnsIndicator = .success
        } else {
            dnsValue = VelaL10n.string(
                "diagnostics.value.notReady",
                defaultValue: "Not ready"
            )
            dnsIndicator = .warning
        }

        return [
            DiagnosticCheck(
                id: "rootRuntime",
                title: VelaL10n.string(
                    "diagnostics.runtime.privilegedRuntime.title",
                    defaultValue: "Privileged Runtime"
                ),
                value: health?.processRunning == true
                    ? VelaL10n.string("diagnostics.value.running", defaultValue: "Running")
                    : VelaL10n.string("diagnostics.value.stopped", defaultValue: "Stopped"),
                indicator: health?.processRunning == true ? .success : .inactive
            ),
            DiagnosticCheck(
                id: "processIdentity",
                title: VelaL10n.string(
                    "diagnostics.runtime.processIdentity.title",
                    defaultValue: "Process Identity"
                ),
                value: health?.processRunning == true
                    ? VelaL10n.string(
                        "diagnostics.runtime.processIdentity.verified",
                        defaultValue: "Verified at launch; revalidated before any signal"
                    )
                    : VelaL10n.string(
                        "diagnostics.runtime.processIdentity.noOwnedProcess",
                        defaultValue: "No running owned process"
                    ),
                indicator: health?.processRunning == true ? .success : .inactive
            ),
            DiagnosticCheck(
                id: "controllerLoopback",
                title: VelaL10n.string(
                    "diagnostics.runtime.controllerLoopback.title",
                    defaultValue: "Controller Loopback"
                ),
                value: health?.controllerReachable == true
                    ? VelaL10n.string(
                        "diagnostics.runtime.controllerLoopback.reachable",
                        defaultValue: "127.0.0.1 reachable with per-start secret"
                    )
                    : VelaL10n.string(
                        "diagnostics.runtime.controllerLoopback.notReachable",
                        defaultValue: "Not reachable"
                    ),
                indicator: health?.controllerReachable == true
                    ? .success
                    : (health?.processRunning == true ? .warning : .inactive)
            ),
            DiagnosticCheck(
                id: "tunConfiguration",
                title: VelaL10n.string(
                    "diagnostics.runtime.tunConfiguration.title",
                    defaultValue: "TUN Configuration"
                ),
                value: health?.tunEnabledInController == true
                    ? VelaL10n.string("diagnostics.value.enabled", defaultValue: "Enabled")
                    : VelaL10n.string(
                        "diagnostics.value.notEnabled",
                        defaultValue: "Not enabled"
                    ),
                indicator: health?.tunEnabledInController == true
                    ? .success
                    : (health?.processRunning == true ? .warning : .inactive)
            ),
            DiagnosticCheck(
                id: "configurationHash",
                title: VelaL10n.string(
                    "diagnostics.runtime.configurationIntegrity.title",
                    defaultValue: "Configuration Integrity"
                ),
                value: health?.configurationHashMatches == true
                    ? VelaL10n.string("diagnostics.value.matches", defaultValue: "Matches")
                    : VelaL10n.string(
                        "diagnostics.value.notVerified",
                        defaultValue: "Not verified"
                    ),
                indicator: health?.configurationHashMatches == true
                    ? .success
                    : (health?.processRunning == true ? .warning : .inactive)
            ),
            DiagnosticCheck(
                id: "tunInterface",
                title: VelaL10n.string(
                    "diagnostics.runtime.tunInterface.title",
                    defaultValue: "TUN Interface"
                ),
                value: health?.tunInterfacePresent == true
                    ? (health?.tunInterface ?? VelaL10n.string(
                        "diagnostics.value.present",
                        defaultValue: "Present"
                    ))
                    : VelaL10n.string(
                        "diagnostics.value.notPresent",
                        defaultValue: "Not present"
                    ),
                indicator: health?.tunInterfacePresent == true ? .success : .inactive
            ),
            DiagnosticCheck(
                id: "routes",
                title: VelaL10n.string(
                    "diagnostics.runtime.routes.title",
                    defaultValue: "Routes"
                ),
                value: health?.routeApplied == true
                    ? VelaL10n.string("diagnostics.value.applied", defaultValue: "Applied")
                    : VelaL10n.string(
                        "diagnostics.value.notApplied",
                        defaultValue: "Not applied"
                    ),
                indicator: health?.routeApplied == true ? .success : .inactive
            ),
            DiagnosticCheck(
                id: "dns",
                title: VelaL10n.string(
                    "diagnostics.runtime.dns.title",
                    defaultValue: "DNS"
                ),
                value: dnsValue,
                indicator: dnsIndicator
            ),
            DiagnosticCheck(
                id: "lease",
                title: VelaL10n.string(
                    "diagnostics.runtime.ownerLease.title",
                    defaultValue: "Owner Lease"
                ),
                value: health?.ownerLeaseValid == true
                    ? VelaL10n.string("diagnostics.value.active", defaultValue: "Active")
                    : VelaL10n.string("diagnostics.value.inactive", defaultValue: "Inactive"),
                detail: engineStore.lastLeaseErrorCode.map {
                    VelaL10n.string(
                        "diagnostics.runtime.ownerLease.stableErrorFormat",
                        defaultValue: "Stable error: %@",
                        arguments: $0.rawValue
                    )
                },
                indicator: health?.ownerLeaseValid == true ? .success : .inactive
            ),
        ]
    }

    private var cleanupCheck: DiagnosticCheck {
        DiagnosticCheck(
            id: "cleanup",
            title: VelaL10n.string(
                "diagnostics.cleanup.title",
                defaultValue: "Cleanup"
            ),
            value: engineStore.privilegedRuntimeMayBeActive
                ? VelaL10n.string(
                    "diagnostics.cleanup.runtimeMayBeActive",
                    defaultValue: "Privileged runtime may still be active"
                )
                : VelaL10n.string(
                    "diagnostics.cleanup.noActiveTunRuntime",
                    defaultValue: "No active TUN runtime"
                ),
            indicator: engineStore.privilegedRuntimeMayBeActive ? .warning : .success
        )
    }

    private var privilegedSigningCheck: DiagnosticCheck {
        #if DEBUG
            let value = VelaL10n.string(
                "diagnostics.workspace.notApplicable",
                defaultValue: "Not applicable"
            )
            let indicator = DiagnosticIndicator.notApplicable
        #else
            let team = engineStore.privilegedComponentManager?.snapshot?.bundle.teamIdentifier
            let value = team.map {
                VelaL10n.string(
                    "diagnostics.signing.verifiedTeamFormat",
                    defaultValue: "Signing verified (Team %@) · Notarization not checked",
                    arguments: $0
                )
            } ?? VelaL10n.string(
                "diagnostics.signing.notVerified",
                defaultValue: "Signing not verified · Notarization not checked"
            )
            let indicator = team != nil
                ? DiagnosticIndicator.warning
                : DiagnosticIndicator.inactive
        #endif
        return DiagnosticCheck(
            id: "privilegedSigning",
            title: VelaL10n.string(
                "diagnostics.signing.title",
                defaultValue: "Signing / Notarization"
            ),
            value: value,
            detail: VelaL10n.string(
                "diagnostics.signing.notarizationRequirement",
                defaultValue: "An Accepted notarization result and successful staple validation are required before distribution can claim notarization."
            ),
            indicator: indicator
        )
    }

    private var coreChecks: [DiagnosticCheck] {
        if engineStore.isCheckingCoreIntegrity {
            return coreCheckDefinitions.map { definition in
                DiagnosticCheck(
                    id: definition.id,
                    title: definition.title,
                    value: VelaL10n.string(
                        "diagnostics.value.checking",
                        defaultValue: "Checking…"
                    ),
                    indicator: .progress
                )
            }
        }

        guard let result = engineStore.corePreflightResult else {
            let unavailableChecks = coreCheckDefinitions.map { definition in
                DiagnosticCheck(
                    id: definition.id,
                    title: definition.title,
                    value: engineStore.coreLifecycleIntegrityVerified
                        ? VelaL10n.string(
                            "diagnostics.core.signedLifecycleVerified",
                            defaultValue: "Signed lifecycle verified"
                        )
                        : (engineStore.corePreflightError == nil
                            ? VelaL10n.string(
                                "diagnostics.value.notChecked",
                                defaultValue: "Not checked"
                            )
                            : VelaL10n.string(
                                "diagnostics.value.unavailable",
                                defaultValue: "Unavailable"
                            )),
                    indicator: engineStore.coreLifecycleIntegrityVerified
                        ? .success : .inactive
                )
            }
            guard let error = engineStore.corePreflightError else {
                return unavailableChecks
            }
            return [
                DiagnosticCheck(
                    id: "coreIntegrity",
                    title: VelaL10n.string(
                        "legacy.coreIntegrity",
                        defaultValue: "Core Integrity"
                    ),
                    value: VelaL10n.string(
                        "legacy.failed",
                        defaultValue: "Failed"
                    ),
                    detail: DiagnosticTextSanitizer.redact(error),
                    indicator: .failure
                ),
            ] + unavailableChecks
        }

        return [
            DiagnosticCheck(
                id: "manifest",
                title: VelaL10n.string(
                    "diagnostics.core.manifest.title",
                    defaultValue: "Manifest"
                ),
                value: VelaL10n.string(
                    "diagnostics.core.manifest.valueFormat",
                    defaultValue: "%@ · schema %@",
                    arguments: result.descriptor.version,
                    String(result.descriptor.schemaVersion)
                ),
                indicator: .success
            ),
            DiagnosticCheck(
                id: "file",
                title: VelaL10n.string(
                    "diagnostics.core.fileType.title",
                    defaultValue: "File Type"
                ),
                value: VelaL10n.string(
                    "diagnostics.core.fileType.regular",
                    defaultValue: "Regular file"
                ),
                indicator: .success
            ),
            DiagnosticCheck(
                id: "symlink",
                title: VelaL10n.string(
                    "diagnostics.core.symbolicLink.title",
                    defaultValue: "Symbolic Link"
                ),
                value: VelaL10n.string(
                    "diagnostics.value.notPresent",
                    defaultValue: "Not present"
                ),
                indicator: .success
            ),
            DiagnosticCheck(
                id: "executable",
                title: VelaL10n.string(
                    "diagnostics.core.executable.title",
                    defaultValue: "Executable"
                ),
                value: VelaL10n.string(
                    "diagnostics.core.executable.modeFormat",
                    defaultValue: "Mode %@",
                    arguments: String(format: "%04o", result.file.permissions)
                ),
                indicator: .success
            ),
            DiagnosticCheck(
                id: "architecture",
                title: VelaL10n.string(
                    "diagnostics.core.architecture.title",
                    defaultValue: "Architecture"
                ),
                value: architectureDescription(result.machO),
                indicator: .success
            ),
            DiagnosticCheck(
                id: "signature",
                title: VelaL10n.string(
                    "diagnostics.core.codeSignature.title",
                    defaultValue: "Code Signature"
                ),
                value: VelaL10n.string(
                    "diagnostics.core.codeSignature.appAndComponentValid",
                    defaultValue: "App and privileged component valid"
                ),
                indicator: .success
            ),
            DiagnosticCheck(
                id: "team",
                title: VelaL10n.string(
                    "diagnostics.core.team.title",
                    defaultValue: "Team"
                ),
                value: result.signature.teamIdentifier ?? VelaL10n.string(
                    "diagnostics.core.team.adHocDevelopment",
                    defaultValue: "Ad hoc development"
                ),
                indicator: .success
            ),
            DiagnosticCheck(
                id: "version",
                title: VelaL10n.string(
                    "diagnostics.core.versionProbe.title",
                    defaultValue: "Version Probe"
                ),
                value: VelaL10n.string(
                    "diagnostics.core.versionProbe.valueFormat",
                    defaultValue: "%@ · %@ %@",
                    arguments: result.version.version,
                    result.version.platform,
                    result.version.architecture
                ),
                indicator: .success
            ),
        ]
    }

    private func coreLifecycleChecks(
        _ lifecycle: CoreLifecycleController
    ) -> [DiagnosticCheck] {
        let catalog: DiagnosticCheck = switch lifecycle.catalogState {
        case let .verified(sequence, expiresAt, keys):
            DiagnosticCheck(
                id: "coreCatalog",
                title: VelaL10n.string(
                    "diagnostics.coreLifecycle.catalog.title",
                    defaultValue: "Catalog Signature / Sequence / Expiry"
                ),
                value: VelaL10n.string(
                    "settings.core.catalog.verifiedSequenceIntegerFormat",
                    defaultValue: "Verified · sequence %llu",
                    arguments: sequence
                ),
                detail: VelaL10n.string(
                    "diagnostics.coreLifecycle.catalog.keysExpiryFormat",
                    defaultValue: "Keys: %@ · expires %@",
                    arguments: keys.joined(separator: ", "),
                    expiresAt.formatted()
                ),
                indicator: .success
            )
        case let .stale(sequence, expiredAt, keys):
            DiagnosticCheck(
                id: "coreCatalog",
                title: VelaL10n.string(
                    "diagnostics.coreLifecycle.catalog.title",
                    defaultValue: "Catalog Signature / Sequence / Expiry"
                ),
                value: VelaL10n.string(
                    "settings.core.catalog.expiredSequenceIntegerFormat",
                    defaultValue: "Expired · sequence %llu",
                    arguments: sequence
                ),
                detail: VelaL10n.string(
                    "diagnostics.coreLifecycle.catalog.expiredDetailFormat",
                    defaultValue: "Keys: %@ · expired %@. Installed Cores remain usable, but new installs are blocked.",
                    arguments: keys.joined(separator: ", "),
                    expiredAt.formatted()
                ),
                indicator: .warning
            )
        case .staleUncached:
            DiagnosticCheck(
                id: "coreCatalog",
                title: VelaL10n.string(
                    "diagnostics.coreLifecycle.catalog.title",
                    defaultValue: "Catalog Signature / Sequence / Expiry"
                ),
                value: VelaL10n.string(
                    "settings.core.catalog.expiredNotAccepted",
                    defaultValue: "Expired · not accepted"
                ),
                detail: VelaL10n.string(
                    "diagnostics.coreLifecycle.catalog.expiredResponseDetail",
                    defaultValue: "The signed response was expired. Installed Cores remain usable, but new installs are blocked until a fresh Catalog is available."
                ),
                indicator: .warning
            )
        case let .clockSkew(message):
            DiagnosticCheck(
                id: "coreCatalogClock",
                title: VelaL10n.string(
                    "diagnostics.coreLifecycle.catalogClock.title",
                    defaultValue: "System Clock / Catalog Freshness"
                ),
                value: VelaL10n.string(
                    "settings.core.catalog.checkSystemClock",
                    defaultValue: "Check system clock"
                ),
                detail: message,
                indicator: .failure
            )
        case .checking:
            DiagnosticCheck(
                id: "coreCatalog",
                title: VelaL10n.string(
                    "diagnostics.coreLifecycle.catalog.title",
                    defaultValue: "Catalog Signature / Sequence / Expiry"
                ),
                value: VelaL10n.string(
                    "diagnostics.value.checking",
                    defaultValue: "Checking…"
                ),
                indicator: .progress
            )
        case .unconfigured:
            DiagnosticCheck(
                id: "coreCatalog",
                title: VelaL10n.string(
                    "diagnostics.coreLifecycle.catalog.title",
                    defaultValue: "Catalog Signature / Sequence / Expiry"
                ),
                value: VelaL10n.string(
                    "diagnostics.coreLifecycle.catalog.productionFeedGated",
                    defaultValue: "Production feed gated"
                ),
                detail: VelaL10n.string(
                    "diagnostics.coreLifecycle.catalog.productionFeedGatedDetail",
                    defaultValue: "No external Core can be downloaded until an HTTPS feed and production trust roots ship in a signed app update."
                ),
                indicator: .inactive
            )
        case .idle:
            DiagnosticCheck(
                id: "coreCatalog",
                title: VelaL10n.string(
                    "diagnostics.coreLifecycle.catalog.title",
                    defaultValue: "Catalog Signature / Sequence / Expiry"
                ),
                value: VelaL10n.string(
                    "diagnostics.value.notChecked",
                    defaultValue: "Not checked"
                ),
                indicator: .inactive
            )
        case let .failed(message):
            DiagnosticCheck(
                id: "coreCatalog",
                title: VelaL10n.string(
                    "diagnostics.coreLifecycle.catalog.title",
                    defaultValue: "Catalog Signature / Sequence / Expiry"
                ),
                value: VelaL10n.string(
                    "diagnostics.coreLifecycle.catalog.rejected",
                    defaultValue: "Rejected"
                ),
                detail: message,
                indicator: .failure
            )
        }

        let parity: DiagnosticCheck = switch lifecycle.userRootStoreInParity {
        case true:
            DiagnosticCheck(
                id: "coreParity",
                title: VelaL10n.string(
                    "diagnostics.coreLifecycle.storeParity.title",
                    defaultValue: "User / Privileged Store Parity"
                ),
                value: VelaL10n.string(
                    "settings.core.parity.userPrivileged",
                    defaultValue: "User / Privileged"
                ),
                indicator: .success
            )
        case false:
            DiagnosticCheck(
                id: "coreParity",
                title: VelaL10n.string(
                    "diagnostics.coreLifecycle.storeParity.title",
                    defaultValue: "User / Privileged Store Parity"
                ),
                value: VelaL10n.string(
                    "settings.core.parity.userOnly",
                    defaultValue: "User only"
                ),
                indicator: .warning
            )
        case nil:
            DiagnosticCheck(
                id: "coreParity",
                title: VelaL10n.string(
                    "diagnostics.coreLifecycle.storeParity.title",
                    defaultValue: "User / Privileged Store Parity"
                ),
                value: VelaL10n.string(
                    "settings.core.parity.helperUnavailable",
                    defaultValue: "Privileged component unavailable"
                ),
                indicator: lifecycle.activeCoreID.isFactory ? .inactive : .warning
            )
        }

        let previousAvailable = lifecycle.snapshot?.previousKnownGoodDescriptor != nil
        let activeBlocked = lifecycle.activeRecord?.status == .blocked
        let probationActive: Bool
        if case .probation = lifecycle.activationState {
            probationActive = true
        } else {
            probationActive = false
        }
        return [
            catalog,
            parity,
            DiagnosticCheck(
                id: "activeCoreVerification",
                title: VelaL10n.string(
                    "diagnostics.coreLifecycle.activeCoreVerification.title",
                    defaultValue: "Active Core Signature / Version"
                ),
                value: engineStore.coreLifecycleIntegrityVerified
                    ? VelaL10n.string(
                        "settings.core.verification.verified",
                        defaultValue: "Verified"
                    )
                    : VelaL10n.string(
                        "diagnostics.coreLifecycle.pendingRuntimePreflight",
                        defaultValue: "Pending runtime preflight"
                    ),
                indicator: engineStore.coreLifecycleIntegrityVerified ? .success : .inactive
            ),
            DiagnosticCheck(
                id: "coreHelperProtocol",
                title: VelaL10n.string(
                    "diagnostics.coreLifecycle.componentCoreProtocol.title",
                    defaultValue: "Privileged Component Core Protocol"
                ),
                value: engineStore.privilegedComponentManager?.lastHandshake
                    .map {
                        $0.hasCompatibleProtocol
                            ? VelaL10n.string(
                                "diagnostics.coreLifecycle.protocolV2",
                                defaultValue: "Protocol v2"
                            )
                            : VelaL10n.string(
                                "diagnostics.value.incompatible",
                                defaultValue: "Incompatible"
                            )
                    }
                    ?? VelaL10n.string(
                        "diagnostics.value.unavailable",
                        defaultValue: "Unavailable"
                    ),
                indicator: engineStore.privilegedComponentManager?.lastHandshake?
                    .hasCompatibleProtocol == true ? .success : .inactive
            ),
            DiagnosticCheck(
                id: "coreHelperCatalogPolicy",
                title: VelaL10n.string(
                    "settings.core.verification.privilegedComponentCatalogPolicy",
                    defaultValue: "Privileged Component Catalog Policy"
                ),
                value: lifecycle.helperCatalogPolicySyncError == nil
                    ? lifecycle.helperCatalogPolicySequence.map {
                        VelaL10n.string(
                            "settings.core.verification.syncedSequenceIntegerFormat",
                            defaultValue: "Synced · sequence %llu",
                            arguments: $0
                        )
                    } ?? VelaL10n.string(
                        "settings.core.verification.notSynchronized",
                        defaultValue: "Not synchronized in this privileged component session"
                    )
                    : VelaL10n.string(
                        "diagnostics.coreLifecycle.synchronizationRequired",
                        defaultValue: "Synchronization required"
                    ),
                detail: lifecycle.helperCatalogPolicySyncError,
                indicator: lifecycle.helperCatalogPolicySyncError == nil
                    ? (lifecycle.helperCatalogPolicySequence == nil ? .inactive : .success)
                    : .failure
            ),
            DiagnosticCheck(
                id: "factoryCore",
                title: VelaL10n.string(
                    "diagnostics.coreLifecycle.factoryCore.title",
                    defaultValue: "Factory Core"
                ),
                value: lifecycle.factoryDescriptor.coreID.rawValue,
                indicator: .success
            ),
            DiagnosticCheck(
                id: "previousCore",
                title: VelaL10n.string(
                    "diagnostics.coreLifecycle.previousKnownGood.title",
                    defaultValue: "Previous Known Good"
                ),
                value: previousAvailable
                    ? VelaL10n.string(
                        "diagnostics.value.available",
                        defaultValue: "Available"
                    )
                    : VelaL10n.string(
                        "diagnostics.coreLifecycle.factoryFallback",
                        defaultValue: "Factory fallback"
                    ),
                indicator: .success
            ),
            DiagnosticCheck(
                id: "coreProbation",
                title: VelaL10n.string(
                    "diagnostics.coreLifecycle.probation.title",
                    defaultValue: "Probation"
                ),
                value: probationActive
                    ? VelaL10n.string("diagnostics.value.active", defaultValue: "Active")
                    : VelaL10n.string(
                        "diagnostics.value.notActive",
                        defaultValue: "Not active"
                    ),
                indicator: probationActive ? .warning : .success
            ),
            DiagnosticCheck(
                id: "coreBlocked",
                title: VelaL10n.string(
                    "diagnostics.coreLifecycle.blockedStatus.title",
                    defaultValue: "Blocked Status"
                ),
                value: activeBlocked
                    ? VelaL10n.string(
                        "diagnostics.coreLifecycle.activeCoreBlocked",
                        defaultValue: "Active Core is blocked"
                    )
                    : VelaL10n.string(
                        "diagnostics.value.notBlocked",
                        defaultValue: "Not blocked"
                    ),
                indicator: activeBlocked ? .failure : .success
            ),
            DiagnosticCheck(
                id: "coreTransaction",
                title: VelaL10n.string(
                    "diagnostics.coreLifecycle.activationTransaction.title",
                    defaultValue: "Activation Transaction"
                ),
                value: lifecycle.manualRepairRequired
                    ? VelaL10n.string(
                        "diagnostics.coreLifecycle.activationTransaction.manualRepairFormat",
                        defaultValue: "Manual repair required · %@",
                        arguments: lifecycle.activationJournal?.phase.rawValue
                            ?? VelaL10n.string(
                                "diagnostics.value.unknown",
                                defaultValue: "unknown"
                            )
                    )
                    : lifecycle.activationJournal.map {
                        VelaL10n.string(
                            "diagnostics.coreLifecycle.activationTransaction.retainedFormat",
                            defaultValue: "Retained · %@ · %@",
                            arguments: $0.phase.rawValue,
                            $0.transactionID.uuidString
                        )
                    } ?? VelaL10n.string(
                        "diagnostics.value.clean",
                        defaultValue: "Clean"
                    ),
                indicator: lifecycle.manualRepairRequired
                    ? .failure
                    : (lifecycle.activationJournal == nil ? .success : .warning)
            ),
        ]
    }

    private var providerCheck: DiagnosticCheck {
        let catalog = engineStore.proxyCatalog
        let title = VelaL10n.string(
            "diagnostics.providers.catalog.title",
            defaultValue: "Provider Catalog"
        )
        if engineStore.isLoadingProxies {
            return DiagnosticCheck(
                id: "provider",
                title: title,
                value: VelaL10n.string(
                    "diagnostics.value.refreshing",
                    defaultValue: "Refreshing…"
                ),
                indicator: .progress
            )
        }
        if !catalog.fetchErrors.isEmpty || engineStore.proxyCatalogError != nil {
            let errorCount = max(catalog.fetchErrors.count, 1)
            return DiagnosticCheck(
                id: "provider",
                title: title,
                value: VelaL10n.string(
                    "diagnostics.providers.fetchErrors.countIntegerFormat",
                    defaultValue: "Fetch errors: %lld",
                    arguments: Int64(errorCount)
                ),
                indicator: .warning
            )
        }
        if engineStore.controllerState != .connected || catalog.updatedAt == nil {
            return DiagnosticCheck(
                id: "provider",
                title: title,
                value: VelaL10n.string(
                    "diagnostics.value.notChecked",
                    defaultValue: "Not checked"
                ),
                indicator: .inactive
            )
        }
        return DiagnosticCheck(
            id: "provider",
            title: title,
            value: catalog.providers.isEmpty
                ? VelaL10n.string(
                    "diagnostics.providers.noneReported",
                    defaultValue: "No providers reported"
                )
                : VelaL10n.string(
                    "diagnostics.providers.loaded.countIntegerFormat",
                    defaultValue: "%lld providers loaded",
                    arguments: Int64(catalog.providers.count)
                ),
            indicator: .success
        )
    }

    private func architectureDescription(_ inspection: MachOInspection) -> String {
        let width = inspection.is64Bit
            ? VelaL10n.string(
                "diagnostics.core.architecture.width64",
                defaultValue: "64-bit"
            )
            : VelaL10n.string(
                "diagnostics.core.architecture.width32",
                defaultValue: "32-bit"
            )
        let shape = inspection.isThin
            ? VelaL10n.string(
                "diagnostics.core.architecture.thin",
                defaultValue: "thin"
            )
            : VelaL10n.string(
                "diagnostics.core.architecture.universal",
                defaultValue: "universal"
            )
        return VelaL10n.string(
            "diagnostics.core.architecture.valueFormat",
            defaultValue: "%@ %@ · %@",
            arguments: shape,
            inspection.architecture.rawValue,
            width
        )
    }

    private func startDiagnosticsRun() {
        let snapshot = diagnosticsWorkspaceSnapshot
        guard snapshot.registryError == nil else { return }
        let coreCheckIDs = snapshot.groups
            .filter { $0.category == .updatesCore }
            .flatMap(\.checks)
            .map(\.id)
        let privilegedCheckIDs = snapshot.groups
            .filter { $0.category == .networkPrivilege }
            .flatMap(\.checks)
            .map(\.id)
        let engineCheckIDs = snapshot.rows
            .filter { $0.id.hasPrefix("engine.") }
            .map(\.id)
        let providerCheckIDs = snapshot.rows
            .filter { $0.id == "provider" }
            .map(\.id)

        let steps = [
            DiagnosticsRunStep(
                id: "coreIntegrity",
                title: VelaL10n.string("legacy.coreIntegrity", defaultValue: "Core Integrity"),
                checkIDs: coreCheckIDs,
                timeoutSeconds: 20,
                operation: {
                    await engineStore.checkCoreIntegrity()
                    return .completed
                }
            ),
            DiagnosticsRunStep(
                id: "privilegedComponent",
                title: VelaL10n.string(
                    "diagnostics.registration.component.title",
                    defaultValue: "Privileged Component"
                ),
                checkIDs: privilegedCheckIDs,
                timeoutSeconds: 15,
                operation: {
                    guard engineStore.privilegedComponentManager != nil else {
                        return .skipped(
                            reason: "Privileged component diagnostics are unavailable in this launch mode."
                        )
                    }
                    await engineStore.refreshPrivilegedComponent()
                    return .completed
                }
            ),
            DiagnosticsRunStep(
                id: "engineHealth",
                title: VelaL10n.string(
                    "diagnostics.summary.systemHealth",
                    defaultValue: "System Health"
                ),
                checkIDs: engineCheckIDs,
                timeoutSeconds: 10,
                operation: {
                    await engineStore.refreshHealth()
                    return .completed
                }
            ),
            DiagnosticsRunStep(
                id: "provider",
                title: VelaL10n.string(
                    "diagnostics.providers.catalog.title",
                    defaultValue: "Provider Catalog"
                ),
                checkIDs: providerCheckIDs,
                timeoutSeconds: 10,
                operation: {
                    guard engineStore.controllerState == .connected else {
                        return .skipped(reason: "Mihomo Controller is not connected.")
                    }
                    await engineStore.refreshProxies()
                    return .completed
                }
            ),
        ].filter { !$0.checkIDs.isEmpty }
        startDiagnosticsRun(steps: steps)
    }

    private func startDiagnosticsRun(
        steps: [DiagnosticsRunStep]
    ) {
        guard diagnosticsRunTask == nil, !steps.isEmpty else { return }
        let runID = UUID()
        guard diagnosticsRunGate.begin(runID) else { return }

        diagnosticsRun = DiagnosticsRunPresentation(
            id: runID,
            registryRevision: diagnosticsWorkspaceSnapshot.registryRevision,
            phase: .preparing,
            completedStepCount: 0,
            totalStepCount: steps.reduce(0) { $0 + $1.checkIDs.count },
            currentStepID: nil,
            currentStepTitle: nil,
            startedAt: .now,
            finishedAt: nil,
            failureDescription: nil
        )
        isRunningChecks = true

        diagnosticsRunTask = Task { @MainActor in
            await performDiagnosticsRun(runID: runID, steps: steps)
        }
    }

    private func performDiagnosticsRun(
        runID: UUID,
        steps: [DiagnosticsRunStep]
    ) async {
        var encounteredExecutionFailure = false
        for step in steps {
            guard diagnosticsRunGate.accepts(runID), !Task.isCancelled else {
                finishDiagnosticsRun(runID: runID, phase: .cancelled)
                return
            }
            diagnosticsRun?.phase = .running
            diagnosticsRun?.currentStepID = step.id
            diagnosticsRun?.currentStepTitle = step.title
            let startedAt = Date.now
            let outcome = await DiagnosticsRunOperationExecutor.execute(
                timeoutSeconds: step.timeoutSeconds,
                operation: step.operation
            )
            guard diagnosticsRunGate.accepts(runID), !Task.isCancelled else {
                finishDiagnosticsRun(runID: runID, phase: .cancelled)
                return
            }
            if outcome == .cancelled {
                finishDiagnosticsRun(runID: runID, phase: .cancelled)
                return
            }

            let completedAt = Date.now
            recordDiagnosticsHistory(
                runID: runID,
                step: step,
                outcome: outcome,
                completedAt: completedAt,
                durationSeconds: completedAt.timeIntervalSince(startedAt)
            )
            diagnosticsRun?.completedStepCount += step.checkIDs.count
            if let failure = diagnosticsStepFailureDescription(outcome) {
                encounteredExecutionFailure = true
                let entry = "\(step.title): \(failure)"
                diagnosticsRun?.failureDescription = [
                    diagnosticsRun?.failureDescription,
                    entry,
                ]
                .compactMap { $0 }
                .joined(separator: "\n")
            }
        }
        finishDiagnosticsRun(
            runID: runID,
            phase: encounteredExecutionFailure ? .failed : .completed
        )
    }

    private func cancelDiagnosticsRun() {
        guard let runID = diagnosticsRun?.id,
            diagnosticsRunGate.accepts(runID),
            diagnosticsRun?.isActive == true
        else { return }
        diagnosticsRun?.phase = .cancelling
        diagnosticsRunTask?.cancel()
    }

    private func abandonDiagnosticsRun() {
        guard let runID = diagnosticsRun?.id,
            diagnosticsRunGate.accepts(runID),
            diagnosticsRun?.isActive == true
        else {
            diagnosticsRunTask?.cancel()
            diagnosticsRunTask = nil
            isRunningChecks = false
            return
        }
        diagnosticsRunTask?.cancel()
        finishDiagnosticsRun(runID: runID, phase: .cancelled)
    }

    private func recordDiagnosticsHistory(
        runID: UUID,
        step: DiagnosticsRunStep,
        outcome: DiagnosticsRunStepOutcome,
        completedAt: Date,
        durationSeconds: Double
    ) {
        let additions = DiagnosticsRunHistoryPolicy.entries(
            runID: String(runID.uuidString.prefix(8)).uppercased(),
            rows: diagnosticsWorkspaceSnapshot.rows,
            attemptedCheckIDs: step.checkIDs,
            outcome: outcome,
            completedAt: completedAt,
            durationSeconds: durationSeconds
        )
        recentRunHistory = Array((additions + recentRunHistory).prefix(400))
    }

    private func diagnosticsStepFailureDescription(
        _ outcome: DiagnosticsRunStepOutcome
    ) -> String? {
        switch outcome {
        case .completed, .skipped, .cancelled:
            nil
        case let .failed(message):
            DiagnosticTextSanitizer.redact(message)
        case let .timedOut(seconds):
            VelaL10n.string(
                "diagnostics.workspace.runStepTimedOut",
                defaultValue: "Timed out after %@ seconds.",
                arguments: seconds.formatted(.number.precision(.fractionLength(0...1)))
            )
        }
    }

    private func finishDiagnosticsRun(
        runID: UUID,
        phase: DiagnosticsRunPhase
    ) {
        guard diagnosticsRunGate.finish(runID) else { return }
        let finishedAt = Date.now
        diagnosticsRun?.phase = phase
        diagnosticsRun?.finishedAt = finishedAt
        diagnosticsRun?.currentStepID = nil
        diagnosticsRun?.currentStepTitle = nil
        isRunningChecks = false
        diagnosticsRunTask = nil
    }

    private func prepareDiagnosticsPreview() {
        let snapshot = RedactedDiagnosticsSnapshot(
            generatedAt: .now,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            engineState: redactedEngineState,
            controllerState: redactedControllerState,
            controllerVersion: engineStore.controllerVersion,
            selectedProfileOpaqueID: engineStore.selectedProfileID.map {
                String($0.uuidString.prefix(8))
            },
            localProfileCount: engineStore.profiles.filter { $0.sourceKind == .localFile }.count,
            remoteProfileCount: engineStore.profiles.filter {
                $0.sourceKind == .remoteSubscription
            }.count,
            proxyProviderCount: dailyDriver.providers.snapshot.proxyProviders.count,
            ruleProviderCount: dailyDriver.providers.snapshot.ruleProviders.count,
            activeConnectionCount: dailyDriver.connections.snapshot.connections.count,
            ruleCount: dailyDriver.rules.rules.count,
            launchAtLoginStatus: dailyDriver.dataSettings.launchAtLoginStatus.rawValue,
            geoUpdateState: String(describing: dailyDriver.dataSettings.geoState),
            activeBackend: engineStore.activeBackendKind.rawValue,
            privilegedRegistration: engineStore.privilegedComponentManager?.registrationStatus.rawValue,
            helperProtocolCompatible: engineStore.privilegedComponentManager?
                .lastHandshake?.hasCompatibleProtocol,
            tunProcessRunning: engineStore.privilegedHealth?.processRunning,
            tunInterfacePresent: engineStore.privilegedHealth?.tunInterfacePresent,
            tunRouteApplied: engineStore.privilegedHealth?.routeApplied,
            tunDNSReady: engineStore.privilegedHealth?.dnsReady,
            tunOwnerLeaseValid: engineStore.privilegedHealth?.ownerLeaseValid,
            activeCoreID: coreLifecycle?.activeCoreID.rawValue,
            activeCoreVersion: coreLifecycle?.activeDescriptor.upstreamVersion,
            activeCoreSource: coreLifecycle?.activeDescriptor.source.rawValue,
            activeCoreStatus: coreLifecycle?.activeRecord?.status.rawValue,
            coreCatalogSequence: coreLifecycle?.catalogSnapshot?.catalog.sequence,
            coreCatalogSHA256: coreLifecycle?.catalogSnapshot?.rawSHA256,
            coreCompatibilityReportSHA256: engineStore.resolvedExecutable?
                .verificationEvidence?.compatibilityReportSHA256
                ?? coreLifecycle?.activeCatalogEntry?.vela.compatibilityReportSHA256,
            coreProbationActive: coreLifecycle.map {
                if case .probation = $0.activationState { return true }
                return false
            },
            privilegedStartupLogs: DiagnosticsPrivilegedLogExport.make(
                entries: engineStore.privilegedStartupLogEntries,
                include: includePrivilegedStartupLogs
            )
        )
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(snapshot)
            guard let text = String(data: data, encoding: .utf8) else {
                exportError = VelaL10n.string(
                    "diagnostics.export.invalidUtf8",
                    defaultValue: "The redacted diagnostics preview is not valid UTF-8."
                )
                return
            }
            exportPreview = DiagnosticsExportPreview(
                text: text,
                includesPrivilegedStartupLogs: includePrivilegedStartupLogs
                    && !engineStore.privilegedStartupLogEntries.isEmpty
            )
        } catch {
            exportError = DiagnosticTextSanitizer.redact(error.localizedDescription)
        }
    }

    private func saveDiagnostics(_ preview: DiagnosticsExportPreview) {
        guard diagnosticsExportTask == nil else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Vela-Diagnostics.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        diagnosticsExportTask = Task { @MainActor in
            defer { diagnosticsExportTask = nil }
            do {
                try await DiagnosticsExportWriter.shared.writeUTF8(preview.text, to: url)
                try Task.checkCancellation()
                exportPreview = nil
                includePrivilegedStartupLogs = false
            } catch is CancellationError {
                return
            } catch {
                exportError = DiagnosticTextSanitizer.redact(error.localizedDescription)
            }
        }
    }

    private var redactedEngineState: String {
        switch engineStore.state {
        case .stopped: "stopped"
        case .validating: "validating"
        case .starting: "starting"
        case .running: "running"
        case .stopping: "stopping"
        case .recovering: "recovering"
        case .failed: "failed"
        }
    }

    private var redactedControllerState: String {
        switch engineStore.controllerState {
        case .disconnected: "disconnected"
        case .connecting: "connecting"
        case .connected: "connected"
        case .unavailable: "unavailable"
        }
    }

    private var coreCheckDefinitions: [(id: String, title: String)] {
        [
            (
                "manifest",
                VelaL10n.string(
                    "diagnostics.core.manifest.title",
                    defaultValue: "Manifest"
                )
            ),
            (
                "file",
                VelaL10n.string(
                    "diagnostics.core.fileType.title",
                    defaultValue: "File Type"
                )
            ),
            (
                "symlink",
                VelaL10n.string(
                    "diagnostics.core.symbolicLink.title",
                    defaultValue: "Symbolic Link"
                )
            ),
            (
                "executable",
                VelaL10n.string(
                    "diagnostics.core.executable.title",
                    defaultValue: "Executable"
                )
            ),
            (
                "architecture",
                VelaL10n.string(
                    "diagnostics.core.architecture.title",
                    defaultValue: "Architecture"
                )
            ),
            (
                "signature",
                VelaL10n.string(
                    "diagnostics.core.codeSignature.title",
                    defaultValue: "Code Signature"
                )
            ),
            (
                "team",
                VelaL10n.string(
                    "diagnostics.core.team.title",
                    defaultValue: "Team"
                )
            ),
            (
                "version",
                VelaL10n.string(
                    "diagnostics.core.versionProbe.title",
                    defaultValue: "Version Probe"
                )
            ),
        ]
    }
}

private struct DiagnosticsExportPreview: Identifiable {
    let id = UUID()
    let text: String
    let includesPrivilegedStartupLogs: Bool
}

private struct DiagnosticsExportPreviewView: View {
    let preview: DiagnosticsExportPreview
    let cancel: () -> Void
    let save: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(VelaL10n.string("legacy.previewRedactedDiagnostics", defaultValue: "Preview Redacted Diagnostics"))
                    .font(.title3.bold())
                Text(preview.includesPrivilegedStartupLogs
                    ? VelaL10n.string("legacy.warningThisPreviewIncludesRedactedPrivilegedMihomoStartupLogsReviewEveryLineBeforeSavingOrSharing", defaultValue: "Warning: this preview includes redacted privileged Mihomo startup logs. Review every line before saving or sharing.")
                    : VelaL10n.string("legacy.reviewTheExactCountsAndStateThatWillBeSavedPrivilegedMihomoStartupLogsUrlsCredentialsConnectionContentAndProcessPathsAreExcluded", defaultValue: "Review the exact counts and state that will be saved. Privileged Mihomo startup logs, URLs, credentials, connection content, and process paths are excluded."))
                    .font(.caption)
                    .foregroundStyle(
                        preview.includesPrivilegedStartupLogs ? .orange : .secondary
                    )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            Divider()

            ScrollView([.horizontal, .vertical]) {
                Text(preview.text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }

            Divider()
            HStack {
                Button(VelaL10n.string("legacy.cancel", defaultValue: "Cancel"), role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(VelaL10n.string("legacy.saveRedactedDiagnosticsDialog", defaultValue: "Save Redacted Diagnostics…"), action: save)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(minWidth: 680, minHeight: 520)
        .accessibilityIdentifier("diagnostics.exportPreview")
    }
}

private nonisolated struct RedactedDiagnosticsSnapshot: Codable, Sendable {
    let generatedAt: Date
    let appVersion: String?
    let engineState: String
    let controllerState: String
    let controllerVersion: String?
    let selectedProfileOpaqueID: String?
    let localProfileCount: Int
    let remoteProfileCount: Int
    let proxyProviderCount: Int
    let ruleProviderCount: Int
    let activeConnectionCount: Int
    let ruleCount: Int
    let launchAtLoginStatus: String
    let geoUpdateState: String
    let activeBackend: String
    let privilegedRegistration: String?
    let helperProtocolCompatible: Bool?
    let tunProcessRunning: Bool?
    let tunInterfacePresent: Bool?
    let tunRouteApplied: Bool?
    let tunDNSReady: Bool?
    let tunOwnerLeaseValid: Bool?
    let activeCoreID: String?
    let activeCoreVersion: String?
    let activeCoreSource: String?
    let activeCoreStatus: String?
    let coreCatalogSequence: UInt64?
    let coreCatalogSHA256: String?
    let coreCompatibilityReportSHA256: String?
    let coreProbationActive: Bool?
    let privilegedStartupLogs: [RedactedPrivilegedStartupLog]?
}

private struct DiagnosticCheck: Identifiable {
    let id: String
    let title: String
    let value: String
    var detail: String?
    let indicator: DiagnosticIndicator
}

private enum DiagnosticIndicator {
    case success
    case failure
    case warning
    case progress
    case inactive
    case notApplicable
}
