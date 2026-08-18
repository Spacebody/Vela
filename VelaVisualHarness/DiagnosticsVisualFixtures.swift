#if DEBUG
import Foundation
import SwiftUI

nonisolated enum DiagnosticsVisualFixtureFactory {
    private static let runID = "D1A6905C"

    static func snapshot(
        configuration: VisualUITestConfiguration
    ) -> DiagnosticsWorkspaceSnapshot {
        if configuration.state == .loading {
            return DiagnosticsWorkspaceSnapshot(
                registryRevision: "engine-health.v1+diagnostics-status.v1",
                groups: [],
                registryError: nil,
                isRegistryLoading: true,
                isStale: false
            )
        }
        if configuration.state == .failure {
            return DiagnosticsWorkspaceSnapshot(
                registryRevision: "engine-health.v1+diagnostics-status.v1",
                groups: [],
                registryError: localized(
                    configuration,
                    english: "The existing local check registry could not be loaded.",
                    chinese: "无法载入现有的本地检查注册表。"
                ),
                isRegistryLoading: false,
                isStale: false
            )
        }

        let stale = configuration.state == .stale
        let capturedAt = configuration.fixedDate.addingTimeInterval(stale ? -900 : -38)
        let permissionBlocked = configuration.state == .permissionRequired
        let partialFailure = configuration.state == .partialFailure
        let repairFailed = configuration.state == .rollbackFailed

        let rows = [
            row(
                configuration,
                id: "engine.process",
                category: .runtimeConfiguration,
                title: "Mihomo Process",
                result: .passed,
                capturedAt: capturedAt,
                stale: stale
            ),
            row(
                configuration,
                id: "engine.controller",
                category: .runtimeConfiguration,
                title: "Controller API",
                result: partialFailure ? .failed : .passed,
                capturedAt: capturedAt,
                stale: stale,
                repairAction: partialFailure ? .restoreSystemProxy : nil
            ),
            row(
                configuration,
                id: "engine.configuration",
                category: .runtimeConfiguration,
                title: "Runtime Configuration",
                result: .passed,
                capturedAt: capturedAt,
                stale: stale
            ),
            row(
                configuration,
                id: "engine.mixedPort",
                category: .connectivityDNS,
                title: "Mixed Port",
                result: .skipped,
                capturedAt: capturedAt,
                stale: stale,
                skipReason: localized(
                    configuration,
                    english: "The active TUN backend does not require the mixed-port probe.",
                    chinese: "当前 TUN 后端不需要 mixed-port 探测。"
                )
            ),
            row(
                configuration,
                id: "engine.systemProxy",
                category: .networkPrivilege,
                title: "System Proxy Ownership",
                result: permissionBlocked ? .blocked : .passed,
                capturedAt: capturedAt,
                stale: stale,
                permission: permissionBlocked
                    ? .required(
                        name: localized(configuration, english: "Administrator approval", chinese: "管理员授权"),
                        purpose: localized(
                            configuration,
                            english: "Required only to inspect the privileged runtime owned by Vela.",
                            chinese: "仅用于检查 Vela 所拥有的特权运行时。"
                        ),
                        settingsTitle: "Login Items & Extensions"
                    )
                    : .notRequired,
                repairAction: repairFailed ? .cleanupPrivilegedRuntime : nil
            ),
            row(
                configuration,
                id: "engine.networkPath",
                category: .connectivityDNS,
                title: "Network Path",
                result: .passed,
                capturedAt: capturedAt,
                stale: stale
            ),
            row(
                configuration,
                id: "engine.internet",
                category: .connectivityDNS,
                title: "Internet Reachability",
                result: .notApplicable,
                capturedAt: capturedAt,
                stale: stale,
                skipReason: localized(
                    configuration,
                    english: "No remote reachability target is configured for this environment.",
                    chinese: "当前环境未配置远程可达性目标。"
                )
            ),
        ]

        let grouped = DiagnosticsCheckCategory.allCases.compactMap { category in
            let checks = rows.filter { $0.category == category }
            return checks.isEmpty ? nil : DiagnosticsCheckGroupModel(category: category, checks: checks)
        }
        return DiagnosticsWorkspaceSnapshot(
            registryRevision: "engine-health.v1+diagnostics-status.v1",
            groups: grouped,
            registryError: nil,
            isRegistryLoading: false,
            isStale: stale
        )
    }

    static func run(
        configuration: VisualUITestConfiguration
    ) -> DiagnosticsRunPresentation? {
        guard configuration.state == .refreshing else { return nil }
        return DiagnosticsRunPresentation(
            id: UUID(uuidString: "D1A6905C-77D2-4B49-912D-3DA623490CD1")!,
            registryRevision: "engine-health.v1+diagnostics-status.v1",
            phase: .running,
            completedStepCount: 3,
            totalStepCount: 7,
            currentStepID: "engine.mixedPort",
            currentStepTitle: localized(
                configuration,
                english: "Mixed Port",
                chinese: "混合端口"
            ),
            startedAt: configuration.fixedDate.addingTimeInterval(-4),
            finishedAt: nil,
            failureDescription: nil
        )
    }

    static func repair(
        configuration: VisualUITestConfiguration
    ) -> DiagnosticsRepairPresentation? {
        switch configuration.state {
        case .pendingMutation:
            DiagnosticsRepairPresentation(
                id: "fixture-cleanup-active",
                targetCheckID: "engine.systemProxy",
                action: .cleanupPrivilegedRuntime,
                phase: .verifying,
                privilege: "Authenticated VelaHelper",
                requestedState: "Owned privileged runtime stopped",
                cleanupOrRollback: "Owned interface, routes, and staging only",
                postcondition: "Stopped state verified twice",
                message: localized(
                    configuration,
                    english: "Cleanup completed; verifying the final stopped state.",
                    chinese: "清理已完成，正在验证最终停止状态。"
                )
            )
        case .rollbackFailed:
            DiagnosticsRepairPresentation(
                id: "fixture-cleanup-failed",
                targetCheckID: "engine.systemProxy",
                action: .cleanupPrivilegedRuntime,
                phase: .failed,
                privilege: "Authenticated VelaHelper",
                requestedState: "Owned privileged runtime stopped",
                cleanupOrRollback: "No unowned resource was changed",
                postcondition: "Stopped state was not verified",
                message: localized(
                    configuration,
                    english: "The owned runtime did not reach the verified stopped state.",
                    chinese: "所拥有的运行时未达到已验证的停止状态。"
                )
            )
        default:
            nil
        }
    }

    private static func row(
        _ configuration: VisualUITestConfiguration,
        id: String,
        category: DiagnosticsCheckCategory,
        title: String,
        result: DiagnosticsCheckResult,
        capturedAt: Date,
        stale: Bool,
        permission: DiagnosticsPermissionState = .notRequired,
        repairAction: DiagnosticsRepairAction? = nil,
        skipReason: String? = nil
    ) -> DiagnosticsCheckRowModel {
        let resultLabel = localizedResult(configuration, result)
        return DiagnosticsCheckRowModel(
            id: id,
            category: category,
            title: localized(configuration, english: title, chinese: chineseTitle(id)),
            result: result,
            resultLabel: resultLabel,
            detail: localized(
                configuration,
                english: detail(result, id: id),
                chinese: chineseDetail(result, id: id)
            ),
            evidence: DiagnosticsEvidencePresentation(
                state: stale ? .stale : (result == .failed ? .partial : .sufficient),
                source: "EngineHealthReport",
                capturedAt: capturedAt,
                summary: localized(
                    configuration,
                    english: detail(result, id: id),
                    chinese: chineseDetail(result, id: id)
                ),
                technicalDetails: "component=\(id) schema=engine-health.v1",
                confidence: localized(
                    configuration,
                    english: "Typed result from the deterministic Engine Health registry",
                    chinese: "来自确定性 Engine Health 注册表的类型化结果"
                ),
                skipReason: skipReason
            ),
            lastRunID: runID,
            lastRunAt: capturedAt,
            durationSeconds: 0.08,
            skippedCountsAsComplete: result == .skipped,
            applicability: localized(
                configuration,
                english: result == .notApplicable ? "Not applicable in this environment" : "Applicable to the current runtime",
                chinese: result == .notApplicable ? "不适用于当前环境" : "适用于当前运行时"
            ),
            permission: permission,
            repairAction: repairAction,
            timeoutSeconds: 5,
            evidenceSchema: "vela.diagnostics.engine-health.v1",
            dependencies: ["EngineHealthReport"],
            history: [
                DiagnosticsRunHistoryEntry(
                    id: "\(runID).\(id)",
                    checkID: id,
                    runID: runID,
                    result: result,
                    completedAt: capturedAt,
                    durationSeconds: 0.08
                ),
            ]
        )
    }

    private static func localizedResult(
        _ configuration: VisualUITestConfiguration,
        _ result: DiagnosticsCheckResult
    ) -> String {
        let english = result.rawValue
            .replacingOccurrences(of: "notApplicable", with: "Not Applicable")
            .replacingOccurrences(of: "notRun", with: "Not Run")
            .capitalized
        let chinese: String = switch result {
        case .passed: "通过"
        case .warning: "警告"
        case .failed: "失败"
        case .skipped: "已跳过"
        case .blocked: "受阻"
        case .notApplicable: "不适用"
        case .notRun: "未运行"
        case .running: "运行中"
        case .stale: "已过期"
        }
        return localized(configuration, english: english, chinese: chinese)
    }

    private static func localized(
        _ configuration: VisualUITestConfiguration,
        english: String,
        chinese: String
    ) -> String {
        configuration.localeIdentifier == .simplifiedChinese ? chinese : english
    }

    private static func detail(_ result: DiagnosticsCheckResult, id: String) -> String {
        switch result {
        case .failed: "The Controller did not respond within the bounded probe timeout."
        case .blocked: "This check needs explicit administrator approval."
        case .skipped: "The probe was skipped by the declared backend policy."
        case .notApplicable: "This check is outside the current environment's applicability rule."
        default: "The typed \(id) postcondition was verified."
        }
    }

    private static func chineseDetail(_ result: DiagnosticsCheckResult, id: String) -> String {
        switch result {
        case .failed: "Controller 未在有界探测超时内响应。"
        case .blocked: "此检查需要明确的管理员授权。"
        case .skipped: "该探测按已声明的后端策略跳过。"
        case .notApplicable: "此检查不在当前环境的适用规则内。"
        default: "已验证 \(id) 的类型化后置条件。"
        }
    }

    private static func chineseTitle(_ id: String) -> String {
        switch id {
        case "engine.process": "Mihomo 进程"
        case "engine.controller": "Controller API"
        case "engine.configuration": "运行时配置"
        case "engine.mixedPort": "混合端口"
        case "engine.systemProxy": "系统代理归属"
        case "engine.networkPath": "网络路径"
        case "engine.internet": "互联网可达性"
        default: id
        }
    }
}

struct DiagnosticsVisualFixtureView: View {
    let configuration: VisualUITestConfiguration

    var body: some View {
        DiagnosticsWorkspaceView(
            snapshot: DiagnosticsVisualFixtureFactory.snapshot(configuration: configuration),
            run: DiagnosticsVisualFixtureFactory.run(configuration: configuration),
            repairProgress: DiagnosticsVisualFixtureFactory.repair(configuration: configuration),
            initialSelectionID: "engine.controller",
            initialInspectorVisibility: configuration.inspector == .open,
            runAll: {},
            cancelRun: {},
            runSelected: { _ in },
            canRunSelected: { _ in true },
            runSelectedUnavailableReason: { _ in nil },
            repair: { _ in },
            reviewPermission: { _ in },
            openSettings: {},
            canOpenLogs: false,
            openLogsUnavailableReason: "Open Logs from the sidebar.",
            openLogs: {},
            copyRedactedSummary: { _ in },
            exportRedactedReport: {}
        )
        .overlay(alignment: .topLeading) {
            VisualReadyMarker(fixtureID: configuration.fixtureID)
        }
        .environment(\.visualUITestConfiguration, configuration)
        .environment(\.locale, configuration.locale)
    }
}
#endif
