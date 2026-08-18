#if DEBUG
import Foundation

nonisolated enum UpdatesCoreRecoveryVisualFixtureFactory {
    static func snapshot(
        for configuration: VisualUITestConfiguration
    ) -> UpdatesCoreRecoverySnapshot {
        let copy = VisualFixtureLocalizedCopy(locale: configuration.localeIdentifier)
        let base = loadedComponents(copy)
        let lastVerifiedAt = configuration.fixedDate.addingTimeInterval(-1_800)

        if let scenario = launchValue("-VelaUpdatesCoreScenario"),
            let snapshot = scenarioSnapshot(
                scenario,
                copy: copy,
                base: base,
                lastVerifiedAt: lastVerifiedAt
            )
        {
            return snapshot
        }

        switch configuration.state {
        case .loaded:
            return UpdatesCoreRecoverySnapshot(
                overallState: .allVerified,
                lastVerifiedAt: lastVerifiedAt,
                components: base,
                operation: nil,
                pipeline: [],
                permission: nil,
                banner: nil,
                runtimeSummary: copy.text(
                    "Mihomo is running and the Controller is connected.",
                    "Mihomo 正在运行，Controller 已连接。"
                ),
                canVerifyAll: true,
                verifyAllUnavailableReason: nil
            )
        case .partialFailure:
            let active = component(
                id: .activeCore,
                version: "Mihomo 1.19.28",
                summary: copy.text(
                    "The artifact remains trusted, but runtime health verification failed.",
                    "内核文件仍受信任，但运行时健康验证失败。"
                ),
                trust: .verified,
                availability: .unavailable,
                dimensions: activeCoreDimensions(copy, runtimeHealthy: false),
                errorCode: "CORE_RUNTIME_HEALTH_FAILED",
                affected: true,
                actions: [.rollbackCore]
            )
            return stateSnapshot(
                overall: .attentionRequired,
                copy: copy,
                components: replacing(base, with: active),
                lastVerifiedAt: lastVerifiedAt,
                banner: .init(
                    title: copy.text("Active Core needs attention", "当前内核需要处理"),
                    detail: active.summary,
                    status: .warning,
                    affectedComponentID: .activeCore,
                    stableErrorCode: active.stableErrorCode
                )
            )
        case .failure:
            let application = component(
                id: .application,
                version: "0.9.0 (1090)",
                summary: copy.text(
                    "The application update feed could not be verified. No trusted update snapshot is available.",
                    "无法验证应用更新源，当前没有可信的更新快照。"
                ),
                trust: .failed,
                availability: .unavailable,
                dimensions: [
                    dimension("local", copy.text("Local application trust", "本地应用信任"), copy.text("Verified", "已验证"), .success),
                    dimension("feed", copy.text("Update feed", "更新源"), copy.text("Verification failed", "验证失败"), .error),
                    dimension("availability", copy.text("Update availability", "更新可用性"), copy.text("Unavailable", "不可用"), .error),
                ],
                errorCode: "APP_UPDATE_FEED_UNAVAILABLE",
                affected: true,
                actions: [.checkApplicationUpdate]
            )
            return stateSnapshot(
                overall: .unavailable,
                copy: copy,
                components: replacing(base, with: application),
                lastVerifiedAt: nil,
                banner: .init(
                    title: copy.text("Application update verification failed", "应用更新验证失败"),
                    detail: application.summary,
                    status: .error,
                    affectedComponentID: .application,
                    stableErrorCode: application.stableErrorCode
                ),
                canVerifyAll: false,
                reason: copy.text("Retry the affected application update check.", "请重试受影响的应用更新检查。")
            )
        case .pendingMutation:
            let catalog = component(
                id: .coreCatalog,
                version: copy.text("Recommended 1.19.29", "推荐 1.19.29"),
                summary: copy.text(
                    "The existing Core downloader is fetching fixed-role artifacts before digest verification.",
                    "现有内核下载器正在获取固定角色文件，随后会验证摘要。"
                ),
                trust: .verified,
                availability: .transitioning,
                dimensions: catalogDimensions(copy),
                actions: []
            )
            let operation: UpdatesCoreRecoveryOperation = .downloadingCore
            return stateSnapshot(
                overall: .operationInProgress,
                copy: copy,
                components: replacing(base, with: catalog),
                lastVerifiedAt: lastVerifiedAt,
                operation: operation,
                pipeline: pipeline(operation, active: 0, copy: copy),
                banner: operationBanner(operation, copy: copy),
                canVerifyAll: false,
                reason: copy.text("Wait for the Core download to finish.", "请等待内核下载完成。")
            )
        case .permissionRequired:
            let operation: UpdatesCoreRecoveryOperation = .installingAppUpdate
            let application = component(
                id: .application,
                version: "0.10.0 (1100)",
                summary: copy.text(
                    "The signed update is ready; macOS installer authorization is required for this operation.",
                    "签名更新已就绪；此操作需要 macOS 安装器授权。"
                ),
                trust: .verified,
                availability: .transitioning,
                dimensions: applicationDimensions(copy, availability: copy.text("Ready to install", "可安装")),
                actions: []
            )
            return stateSnapshot(
                overall: .operationInProgress,
                copy: copy,
                components: replacing(base, with: application),
                lastVerifiedAt: lastVerifiedAt,
                operation: operation,
                pipeline: pipeline(operation, active: 2, copy: copy),
                permission: .init(
                    kind: .installerAuthorization,
                    operation: operation,
                    title: copy.text("Installer authorization required", "需要安装器授权"),
                    detail: copy.text(
                        "Authorize only the signed Vela application update. No terminal command or Core trust-root change is requested.",
                        "仅授权已签名的 Vela 应用更新；无需终端命令，也不会更改内核信任根。"
                    )
                ),
                banner: .init(
                    title: copy.text("Installer authorization required", "需要安装器授权"),
                    detail: copy.text(
                        "The previously committed runtime state is retained until the installer handoff succeeds.",
                        "安装器移交成功前会保留先前已提交的运行状态。"
                    ),
                    status: .permission,
                    affectedComponentID: .application,
                    stableErrorCode: nil
                ),
                canVerifyAll: false,
                reason: copy.text("Complete or cancel installer authorization first.", "请先完成或取消安装器授权。")
            )
        case .transitioning:
            let operation: UpdatesCoreRecoveryOperation = .activatingCore
            let active = component(
                id: .activeCore,
                version: copy.text("Mihomo 1.19.28 → 1.19.29", "Mihomo 1.19.28 → 1.19.29"),
                summary: copy.text(
                    "The candidate is in bounded probation; 1.19.28 remains the committed recovery point.",
                    "候选内核正在进行有界试运行；1.19.28 仍是已提交的恢复点。"
                ),
                trust: .verified,
                availability: .transitioning,
                dimensions: [
                    dimension("candidate", copy.text("Candidate artifact", "候选文件"), copy.text("Signature and digest verified", "签名与摘要已验证"), .success),
                    dimension("compatibility", copy.text("Compatibility", "兼容性"), copy.text("Compatible", "兼容"), .success),
                    dimension("runtime", copy.text("Runtime health", "运行时健康"), copy.text("Probation", "试运行中"), .pending),
                    dimension("commit", copy.text("Committed active Core", "已提交的当前内核"), "1.19.28", .success),
                ],
                actions: []
            )
            return stateSnapshot(
                overall: .operationInProgress,
                copy: copy,
                components: replacing(base, with: active),
                lastVerifiedAt: lastVerifiedAt,
                operation: operation,
                pipeline: pipeline(operation, active: 2, copy: copy),
                banner: operationBanner(operation, copy: copy),
                canVerifyAll: false,
                reason: copy.text("Wait for activation verification and commit.", "请等待激活验证并提交。")
            )
        case .rollbackFailed:
            let operation: UpdatesCoreRecoveryOperation = .restoringRecoveryPoint
            let recovery = component(
                id: .recoveryPoint,
                version: "Mihomo 1.19.27",
                summary: copy.text(
                    "Automatic rollback could not verify the retained artifact, runtime health, and ownership. Automatic Core changes are paused.",
                    "自动回滚无法验证保留文件、运行时健康和所有权。自动内核更改已暂停。"
                ),
                trust: .failed,
                availability: .unavailable,
                dimensions: [
                    dimension("artifact", copy.text("Recovery artifact", "恢复文件"), copy.text("Readable · digest mismatch", "可读 · 摘要不匹配"), .error),
                    dimension("runtime", copy.text("Current runtime", "当前运行时"), copy.text("Candidate stopped", "候选内核已停止"), .warning),
                    dimension("ownership", copy.text("Runtime ownership", "运行时所有权"), copy.text("Not verified", "未验证"), .error),
                    dimension("automation", copy.text("Automatic changes", "自动更改"), copy.text("Paused", "已暂停"), .warning),
                ],
                errorCode: "CORE_ROLLBACK_VERIFICATION_FAILED",
                affected: true,
                actions: [.openRecovery]
            )
            return stateSnapshot(
                overall: .recoveryRequired,
                copy: copy,
                components: replacing(base, with: recovery),
                lastVerifiedAt: lastVerifiedAt,
                operation: operation,
                pipeline: failedRecoveryPipeline(copy),
                banner: .init(
                    title: copy.text("Core recovery is required", "需要内核恢复"),
                    detail: recovery.summary,
                    status: .error,
                    affectedComponentID: .recoveryPoint,
                    stableErrorCode: recovery.stableErrorCode
                ),
                canVerifyAll: false,
                reason: copy.text("Open Recovery before running other lifecycle operations.", "运行其他生命周期操作前请打开恢复。")
            )
        case .loading, .empty, .refreshing, .offline, .stale:
            // These states are intentionally not registered for this page.
            return snapshot(
                for: VisualUITestConfiguration(
                    fixtureID: "updateCoreRecovery.loaded",
                    page: .updateCoreRecovery,
                    state: .loaded,
                    appearance: configuration.appearance,
                    localeIdentifier: configuration.localeIdentifier,
                    windowSize: configuration.windowSize,
                    inspector: .notApplicable,
                    fixedDate: configuration.fixedDate,
                    uuidSeed: configuration.uuidSeed,
                    usesProductionFeatureViews: configuration.usesProductionFeatureViews
                )
            )
        }
    }

    private static func stateSnapshot(
        overall: UpdatesCoreRecoveryOverallState,
        copy: VisualFixtureLocalizedCopy,
        components: [UpdatesCoreRecoveryComponentRowModel],
        lastVerifiedAt: Date?,
        operation: UpdatesCoreRecoveryOperation? = nil,
        pipeline: [UpdatesCoreRecoveryPipelineStep] = [],
        permission: UpdatesCoreRecoveryPermission? = nil,
        banner: UpdatesCoreRecoveryBanner? = nil,
        canVerifyAll: Bool = true,
        reason: String? = nil
    ) -> UpdatesCoreRecoverySnapshot {
        UpdatesCoreRecoverySnapshot(
            overallState: overall,
            lastVerifiedAt: lastVerifiedAt,
            components: components,
            operation: operation,
            pipeline: pipeline,
            permission: permission,
            banner: banner,
            runtimeSummary: copy.text(
                "Mihomo is running and the Controller is connected.",
                "Mihomo 正在运行，Controller 已连接。"
            ),
            canVerifyAll: canVerifyAll,
            verifyAllUnavailableReason: reason
        )
    }

    private static func scenarioSnapshot(
        _ scenario: String,
        copy: VisualFixtureLocalizedCopy,
        base: [UpdatesCoreRecoveryComponentRowModel],
        lastVerifiedAt: Date
    ) -> UpdatesCoreRecoverySnapshot? {
        switch scenario {
        case "applicationUpdateAvailable":
            let application = component(
                id: .application,
                version: "0.9.0 (1090) → 0.10.0 (1100)",
                summary: copy.text(
                    "The signed Stable feed offers a newer application build. Local trust remains independent and verified.",
                    "已签名的稳定版更新源提供了更新的应用构建；本地信任仍独立且已验证。"
                ),
                trust: .verified,
                availability: .updateAvailable,
                dimensions: applicationDimensions(
                    copy,
                    availability: copy.text("0.10.0 available", "0.10.0 可用")
                ),
                actions: [.checkApplicationUpdate]
            )
            return stateSnapshot(
                overall: .updateAvailable,
                copy: copy,
                components: replacing(base, with: application),
                lastVerifiedAt: lastVerifiedAt
            )
        case "coreUpdateAvailable":
            let catalog = component(
                id: .coreCatalog,
                version: copy.text("Recommended 1.19.29", "推荐 1.19.29"),
                summary: copy.text(
                    "The signed Catalog recommends a compatible newer Core. The active Core remains committed.",
                    "已签名的内核目录推荐了兼容的新版内核；当前内核仍保持已提交状态。"
                ),
                trust: .verified,
                availability: .updateAvailable,
                dimensions: [
                    dimension("signature", copy.text("Signature", "签名"), copy.text("Verified", "已验证"), .success),
                    dimension("sequence", copy.text("Accepted sequence", "已接受序列"), "43", .success),
                    dimension("freshness", copy.text("Freshness", "有效期"), copy.text("Fresh", "有效"), .success),
                    dimension("recommended", copy.text("Recommended Core", "推荐内核"), "1.19.29 · arm64", .info),
                ],
                actions: [.downloadRecommendedCore]
            )
            return stateSnapshot(
                overall: .updateAvailable,
                copy: copy,
                components: replacing(base, with: catalog),
                lastVerifiedAt: lastVerifiedAt
            )
        case "catalogInvalid":
            let catalog = component(
                id: .coreCatalog,
                version: copy.text("Catalog unavailable", "内核目录不可用"),
                summary: copy.text(
                    "Catalog signature verification failed. No recommendation is accepted.",
                    "内核目录签名验证失败，未接受任何推荐。"
                ),
                trust: .failed,
                availability: .unavailable,
                dimensions: [
                    dimension("signature", copy.text("Signature", "签名"), copy.text("Verification failed", "验证失败"), .error),
                    dimension("sequence", copy.text("Accepted sequence", "已接受序列"), "42", .success),
                    dimension("freshness", copy.text("Freshness", "有效期"), copy.text("Unknown", "未知"), .neutral),
                    dimension("recommended", copy.text("Recommended Core", "推荐内核"), copy.text("Not accepted", "未接受"), .error),
                ],
                errorCode: "CORE_CATALOG_SIGNATURE_INVALID",
                affected: true,
                actions: [.refreshCoreCatalog]
            )
            return stateSnapshot(
                overall: .attentionRequired,
                copy: copy,
                components: replacing(base, with: catalog),
                lastVerifiedAt: lastVerifiedAt,
                banner: .init(
                    title: copy.text("Core Catalog verification failed", "内核目录验证失败"),
                    detail: catalog.summary,
                    status: .error,
                    affectedComponentID: .coreCatalog,
                    stableErrorCode: catalog.stableErrorCode
                )
            )
        case "checking":
            return operationScenario(
                operation: .checkingAppUpdate,
                componentID: .application,
                copy: copy,
                base: base,
                lastVerifiedAt: lastVerifiedAt,
                activeStep: 1
            )
        case "appUpdating":
            return operationScenario(
                operation: .installingAppUpdate,
                componentID: .application,
                copy: copy,
                base: base,
                lastVerifiedAt: lastVerifiedAt,
                activeStep: 3
            )
        case "coreStaging":
            return operationScenario(
                operation: .stagingCore,
                componentID: .activeCore,
                copy: copy,
                base: base,
                lastVerifiedAt: lastVerifiedAt,
                activeStep: 1
            )
        case "recoveryRequired":
            let recovery = recoveryComponent(copy, trust: .failed, availability: .unavailable)
            return stateSnapshot(
                overall: .recoveryRequired,
                copy: copy,
                components: replacing(base, with: recovery),
                lastVerifiedAt: lastVerifiedAt,
                banner: .init(
                    title: copy.text("Core recovery is required", "需要内核恢复"),
                    detail: recovery.summary,
                    status: .error,
                    affectedComponentID: .recoveryPoint,
                    stableErrorCode: recovery.stableErrorCode
                ),
                canVerifyAll: false,
                reason: copy.text("Open Recovery to run the existing preflight.", "打开恢复以运行现有预检。")
            )
        case "recovering":
            let operation: UpdatesCoreRecoveryOperation = .restoringRecoveryPoint
            let recovery = recoveryComponent(copy, trust: .verified, availability: .transitioning)
            return stateSnapshot(
                overall: .operationInProgress,
                copy: copy,
                components: replacing(base, with: recovery),
                lastVerifiedAt: lastVerifiedAt,
                operation: operation,
                pipeline: pipeline(operation, active: 2, copy: copy),
                banner: operationBanner(operation, copy: copy),
                canVerifyAll: false,
                reason: copy.text("Wait for recovery verification and commit.", "请等待恢复验证并提交。")
            )
        default:
            return nil
        }
    }

    private static func operationScenario(
        operation: UpdatesCoreRecoveryOperation,
        componentID: UpdatesCoreRecoveryComponentID,
        copy: VisualFixtureLocalizedCopy,
        base: [UpdatesCoreRecoveryComponentRowModel],
        lastVerifiedAt: Date,
        activeStep: Int
    ) -> UpdatesCoreRecoverySnapshot {
        let original = base.first { $0.id == componentID }!
        let affected = component(
            id: componentID,
            version: original.version,
            summary: copy.text(
                "The existing lifecycle coordinator is executing this bounded operation.",
                "现有生命周期协调器正在执行该有界操作。"
            ),
            trust: original.trust,
            availability: .transitioning,
            dimensions: original.dimensions,
            affected: true,
            actions: []
        )
        return stateSnapshot(
            overall: .operationInProgress,
            copy: copy,
            components: replacing(base, with: affected),
            lastVerifiedAt: lastVerifiedAt,
            operation: operation,
            pipeline: pipeline(operation, active: activeStep, copy: copy),
            banner: operationBanner(operation, copy: copy),
            canVerifyAll: false,
            reason: copy.text("Wait for the current operation to finish.", "请等待当前操作完成。")
        )
    }

    private static func recoveryComponent(
        _ copy: VisualFixtureLocalizedCopy,
        trust: UpdatesCoreRecoveryTrustState,
        availability: UpdatesCoreRecoveryAvailabilityState
    ) -> UpdatesCoreRecoveryComponentRowModel {
        component(
            id: .recoveryPoint,
            version: "Mihomo 1.19.27",
            summary: copy.text(
                "The retained recovery point requires coordinator preflight before any restore is attempted.",
                "执行任何恢复前，保留的恢复点都需通过协调器预检。"
            ),
            trust: trust,
            availability: availability,
            dimensions: [
                dimension("artifact", copy.text("Recovery artifact", "恢复文件"), copy.text("Retained", "已保留"), .warning),
                dimension("trust", copy.text("Signature and digest", "签名与摘要"), copy.text("Preflight required", "需要预检"), .warning),
                dimension("runtime", copy.text("Runtime health", "运行时健康"), copy.text("Safe stop", "安全停止"), .neutral),
                dimension("automation", copy.text("Automatic changes", "自动更改"), copy.text("Paused", "已暂停"), .warning),
            ],
            errorCode: "CORE_RECOVERY_PREFLIGHT_REQUIRED",
            affected: true,
            actions: [.openRecovery]
        )
    }

    private static func launchValue(_ key: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.lastIndex(of: key) else { return nil }
        let valueIndex = arguments.index(after: index)
        guard valueIndex < arguments.endIndex else { return nil }
        return arguments[valueIndex]
    }

    private static func loadedComponents(
        _ copy: VisualFixtureLocalizedCopy
    ) -> [UpdatesCoreRecoveryComponentRowModel] {
        [
            component(
                id: .application,
                version: "0.9.0 (1090)",
                summary: copy.text(
                    "Local signature trust, feed trust, and update availability are verified independently.",
                    "本地签名信任、更新源信任和更新可用性均独立验证。"
                ),
                trust: .verified,
                availability: .current,
                dimensions: applicationDimensions(copy, availability: copy.text("Current", "当前")),
                actions: [.checkApplicationUpdate]
            ),
            component(
                id: .activeCore,
                version: "Mihomo 1.19.28",
                summary: copy.text(
                    "Artifact, digest, compatibility, activation, and runtime health are verified.",
                    "文件、摘要、兼容性、激活和运行时健康均已验证。"
                ),
                trust: .verified,
                availability: .current,
                dimensions: activeCoreDimensions(copy, runtimeHealthy: true),
                actions: [.rollbackCore]
            ),
            component(
                id: .recoveryPoint,
                version: "Mihomo 1.19.27",
                summary: copy.text(
                    "The retained artifact is readable, trusted, compatible, and available to the recovery coordinator.",
                    "保留文件可读、可信、兼容，并可由恢复协调器使用。"
                ),
                trust: .verified,
                availability: .ready,
                dimensions: [
                    dimension("artifact", copy.text("Artifact readability", "文件可读性"), copy.text("Verified", "已验证"), .success),
                    dimension("trust", copy.text("Signature and digest", "签名与摘要"), copy.text("Verified", "已验证"), .success),
                    dimension("compatibility", copy.text("Compatibility", "兼容性"), copy.text("Compatible", "兼容"), .success),
                    dimension("coordinator", copy.text("Recovery coordinator", "恢复协调器"), copy.text("Ready", "就绪"), .success),
                ],
                actions: [.rollbackCore]
            ),
            component(
                id: .coreCatalog,
                version: copy.text("Recommended 1.19.28", "推荐 1.19.28"),
                summary: copy.text(
                    "The signed Catalog is fresh and its accepted sequence is retained.",
                    "签名目录有效，已接受的序列已保留。"
                ),
                trust: .verified,
                availability: .current,
                dimensions: catalogDimensions(copy),
                actions: [.refreshCoreCatalog]
            ),
        ]
    }

    private static func applicationDimensions(
        _ copy: VisualFixtureLocalizedCopy,
        availability: String
    ) -> [UpdatesCoreRecoveryDimension] {
        [
            dimension("local", copy.text("Local application trust", "本地应用信任"), copy.text("Verified", "已验证"), .success),
            dimension("feed", copy.text("Update feed", "更新源"), copy.text("Signed · Stable", "已签名 · 稳定版"), .success),
            dimension("availability", copy.text("Update availability", "更新可用性"), availability, .success),
            dimension("last-check", copy.text("Last feed check", "上次更新源检查"), copy.text("30 minutes ago", "30 分钟前"), .success),
        ]
    }

    private static func activeCoreDimensions(
        _ copy: VisualFixtureLocalizedCopy,
        runtimeHealthy: Bool
    ) -> [UpdatesCoreRecoveryDimension] {
        [
            dimension("artifact", copy.text("Artifact verification", "文件验证"), copy.text("Signature verified", "签名已验证"), .success),
            dimension("digest", copy.text("Catalog digest", "目录摘要"), "9f3b2c1a…e42d", .success),
            dimension("compatibility", copy.text("Compatibility", "兼容性"), copy.text("Compatible", "兼容"), .success),
            dimension("runtime", copy.text("Runtime health", "运行时健康"), runtimeHealthy ? copy.text("Running · Connected", "运行中 · 已连接") : copy.text("Controller unavailable", "Controller 不可用"), runtimeHealthy ? .success : .error),
        ]
    }

    private static func catalogDimensions(
        _ copy: VisualFixtureLocalizedCopy
    ) -> [UpdatesCoreRecoveryDimension] {
        [
            dimension("signature", copy.text("Signature", "签名"), copy.text("Verified", "已验证"), .success),
            dimension("sequence", copy.text("Accepted sequence", "已接受序列"), "42", .success),
            dimension("freshness", copy.text("Freshness", "有效期"), copy.text("Fresh · 6 days remaining", "有效 · 剩余 6 天"), .success),
            dimension("recommended", copy.text("Recommended Core", "推荐内核"), "1.19.28 · arm64", .success),
        ]
    }

    private static func component(
        id: UpdatesCoreRecoveryComponentID,
        version: String,
        summary: String,
        trust: UpdatesCoreRecoveryTrustState,
        availability: UpdatesCoreRecoveryAvailabilityState,
        dimensions: [UpdatesCoreRecoveryDimension],
        errorCode: String? = nil,
        affected: Bool = false,
        actions: [UpdatesCoreRecoveryAction]
    ) -> UpdatesCoreRecoveryComponentRowModel {
        .init(
            id: id,
            version: version,
            summary: summary,
            trust: trust,
            availability: availability,
            dimensions: dimensions,
            stableErrorCode: errorCode,
            isAffected: affected,
            actions: actions
        )
    }

    private static func dimension(
        _ id: String,
        _ label: String,
        _ value: String,
        _ status: VelaSemanticStatus
    ) -> UpdatesCoreRecoveryDimension {
        .init(id: id, label: label, value: value, detail: nil, status: status)
    }

    private static func replacing(
        _ components: [UpdatesCoreRecoveryComponentRowModel],
        with replacement: UpdatesCoreRecoveryComponentRowModel
    ) -> [UpdatesCoreRecoveryComponentRowModel] {
        components.map { $0.id == replacement.id ? replacement : $0 }
    }

    private static func operationBanner(
        _ operation: UpdatesCoreRecoveryOperation,
        copy: VisualFixtureLocalizedCopy
    ) -> UpdatesCoreRecoveryBanner {
        .init(
            title: operationTitle(operation, copy: copy),
            detail: copy.text(
                "The previously committed working state remains authoritative until verification and commit succeed.",
                "验证和提交成功前，先前已提交的可用状态仍是权威状态。"
            ),
            status: .pending,
            affectedComponentID: operation.componentID,
            stableErrorCode: nil
        )
    }

    private static func pipeline(
        _ operation: UpdatesCoreRecoveryOperation,
        active: Int,
        copy: VisualFixtureLocalizedCopy
    ) -> [UpdatesCoreRecoveryPipelineStep] {
        let titles: [String] = switch operation {
        case .installingAppUpdate:
            [
                copy.text("Capture runtime state", "捕获运行状态"),
                copy.text("Move services to safe stop", "将服务安全停止"),
                copy.text("Authorize installer", "授权安装器"),
                copy.text("Hand off to Sparkle", "移交给 Sparkle"),
            ]
        case .downloadingCore:
            [
                copy.text("Download fixed-role artifacts", "下载固定角色文件"),
                copy.text("Verify digests", "验证摘要"),
                copy.text("Build signed bundle", "构建签名包"),
                copy.text("Commit installation record", "提交安装记录"),
            ]
        case .activatingCore:
            [
                copy.text("Start candidate", "启动候选内核"),
                copy.text("Verify Controller and runtime", "验证 Controller 和运行时"),
                copy.text("Observe probation", "观察试运行"),
                copy.text("Commit known-good state", "提交已知可用状态"),
            ]
        default:
            [
                copy.text("Prepare", "准备"),
                copy.text("Verify", "验证"),
                copy.text("Apply", "应用"),
                copy.text("Commit", "提交"),
            ]
        }
        return titles.enumerated().map { index, title in
            .init(
                id: "\(operation.rawValue)-\(index)",
                title: title,
                detail: nil,
                state: index < active ? .complete : (index == active ? .active : .pending)
            )
        }
    }

    private static func failedRecoveryPipeline(
        _ copy: VisualFixtureLocalizedCopy
    ) -> [UpdatesCoreRecoveryPipelineStep] {
        [
            .init(id: "lock", title: copy.text("Lock automatic changes", "锁定自动更改"), detail: nil, state: .complete),
            .init(id: "restore", title: copy.text("Restore trusted Core", "恢复可信内核"), detail: nil, state: .failed),
            .init(id: "verify", title: copy.text("Verify runtime and ownership", "验证运行时与所有权"), detail: nil, state: .pending),
            .init(id: "commit", title: copy.text("Commit recovered state", "提交恢复状态"), detail: nil, state: .pending),
        ]
    }

    private static func operationTitle(
        _ operation: UpdatesCoreRecoveryOperation,
        copy: VisualFixtureLocalizedCopy
    ) -> String {
        switch operation {
        case .installingAppUpdate: copy.text("Preparing the application update", "正在准备应用更新")
        case .downloadingCore: copy.text("Downloading and verifying a Core", "正在下载并验证内核")
        case .activatingCore: copy.text("Activating and verifying the Core", "正在激活并验证内核")
        case .checkingAppUpdate: copy.text("Checking the application update", "正在检查应用更新")
        case .refreshingCoreCatalog: copy.text("Refreshing the Core Catalog", "正在刷新内核目录")
        case .stagingCore: copy.text("Staging Core activation", "正在暂存内核激活")
        case .verifyingRecoveryPoint: copy.text("Verifying the recovery point", "正在验证恢复点")
        case .restoringRecoveryPoint: copy.text("Restoring the recovery point", "正在恢复恢复点")
        }
    }
}
#endif
