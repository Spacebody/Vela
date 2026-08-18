import Foundation
import VelaIPC

nonisolated enum UpdatesCoreRecoveryComponentID: String, CaseIterable, Identifiable, Sendable {
    case application
    case activeCore
    case recoveryPoint
    case coreCatalog

    var id: Self { self }
}

nonisolated enum UpdatesCoreRecoveryOverallState: String, Equatable, Sendable {
    case allVerified
    case updateAvailable
    case attentionRequired
    case verificationIncomplete
    case operationInProgress
    case recoveryRequired
    case unavailable

    var semanticStatus: VelaSemanticStatus {
        switch self {
        case .allVerified: .success
        case .updateAvailable: .info
        case .attentionRequired: .warning
        case .verificationIncomplete: .warning
        case .operationInProgress: .pending
        case .recoveryRequired: .error
        case .unavailable: .neutral
        }
    }
}

nonisolated enum UpdatesCoreRecoveryTrustState: String, Equatable, Sendable {
    case verified
    case verificationIncomplete
    case stale
    case failed
    case unavailable

    var semanticStatus: VelaSemanticStatus {
        switch self {
        case .verified: .success
        case .verificationIncomplete: .warning
        case .stale: .stale
        case .failed: .error
        case .unavailable: .neutral
        }
    }
}

nonisolated enum UpdatesCoreRecoveryAvailabilityState: String, Equatable, Sendable {
    case current
    case updateAvailable
    case downloaded
    case ready
    case available
    case checking
    case transitioning
    case unavailable
    case unknown

    var semanticStatus: VelaSemanticStatus {
        switch self {
        case .current, .ready: .success
        case .updateAvailable, .downloaded, .available: .info
        case .checking, .transitioning: .pending
        case .unavailable: .error
        case .unknown: .neutral
        }
    }
}

nonisolated enum UpdatesCoreRecoveryOperation: String, Equatable, Sendable {
    case checkingAppUpdate
    case installingAppUpdate
    case refreshingCoreCatalog
    case downloadingCore
    case stagingCore
    case activatingCore
    case verifyingRecoveryPoint
    case restoringRecoveryPoint

    var componentID: UpdatesCoreRecoveryComponentID {
        switch self {
        case .checkingAppUpdate, .installingAppUpdate:
            .application
        case .refreshingCoreCatalog, .downloadingCore:
            .coreCatalog
        case .stagingCore, .activatingCore:
            .activeCore
        case .verifyingRecoveryPoint, .restoringRecoveryPoint:
            .recoveryPoint
        }
    }
}

nonisolated enum UpdatesCoreRecoveryPermissionKind: String, Equatable, Sendable {
    case installerAuthorization
    case privilegedComponent
    case fileAccess
}

nonisolated enum UpdatesCoreRecoveryAction: String, Equatable, Sendable {
    case checkApplicationUpdate
    case refreshCoreCatalog
    case verifyAll
    case downloadRecommendedCore
    case activateRecommendedCore
    case rollbackCore
    case repairInterruptedActivation
    case openRecovery
}

nonisolated struct UpdatesCoreRecoveryDimension: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    let value: String
    let detail: String?
    let status: VelaSemanticStatus
}

nonisolated struct UpdatesCoreRecoveryPipelineStep: Identifiable, Equatable, Sendable {
    enum State: String, Equatable, Sendable {
        case complete
        case active
        case pending
        case failed
    }

    let id: String
    let title: String
    let detail: String?
    let state: State
}

nonisolated struct UpdatesCoreRecoveryComponentRowModel: Identifiable, Equatable, Sendable {
    let id: UpdatesCoreRecoveryComponentID
    let version: String
    let summary: String
    let trust: UpdatesCoreRecoveryTrustState
    let availability: UpdatesCoreRecoveryAvailabilityState
    let dimensions: [UpdatesCoreRecoveryDimension]
    let stableErrorCode: String?
    let isAffected: Bool
    let actions: [UpdatesCoreRecoveryAction]
}

nonisolated struct UpdatesCoreRecoveryPermission: Equatable, Sendable {
    let kind: UpdatesCoreRecoveryPermissionKind
    let operation: UpdatesCoreRecoveryOperation
    let title: String
    let detail: String
}

nonisolated struct UpdatesCoreRecoveryBanner: Equatable, Sendable {
    let title: String
    let detail: String
    let status: VelaSemanticStatus
    let affectedComponentID: UpdatesCoreRecoveryComponentID?
    let stableErrorCode: String?
}

nonisolated struct UpdatesCoreRecoverySnapshot: Equatable, Sendable {
    let overallState: UpdatesCoreRecoveryOverallState
    let lastVerifiedAt: Date?
    let components: [UpdatesCoreRecoveryComponentRowModel]
    let operation: UpdatesCoreRecoveryOperation?
    let pipeline: [UpdatesCoreRecoveryPipelineStep]
    let permission: UpdatesCoreRecoveryPermission?
    let banner: UpdatesCoreRecoveryBanner?
    let runtimeSummary: String?
    let canVerifyAll: Bool
    let verifyAllUnavailableReason: String?

    func component(_ id: UpdatesCoreRecoveryComponentID) -> UpdatesCoreRecoveryComponentRowModel? {
        components.first { $0.id == id }
    }
}

nonisolated struct UpdatesCoreRecoveryLiveInput: Equatable, Sendable {
    let appVersion: String
    let appBuild: String
    let appChannel: ReleaseChannel
    let appLifecycle: UpdateLifecycleStatus
    let appCanCheck: Bool
    let appLastCheckAt: Date?
    let appLastResultCode: String?
    let appLocalSignatureVerified: Bool?

    let activeCoreID: String
    let activeCoreVersion: String
    let activeCoreSource: CoreDescriptorSource
    let activeCoreStatus: InstalledCoreStatus?
    let activeCoreDigest: String?
    let activeCoreIntegrityVerified: Bool
    let runtimeRunning: Bool
    let controllerConnected: Bool

    let recoveryCoreID: String?
    let recoveryCoreVersion: String?
    let recoveryCoreStatus: InstalledCoreStatus?
    let recoveryRootStoreReady: Bool?
    let canRollback: Bool

    let catalogState: CoreCatalogClientState
    let catalogSequence: UInt64?
    let catalogExpiresAt: Date?
    let catalogEntryCount: Int
    let recommendedCoreVersion: String?
    let recommendedCoreInstalled: Bool
    let recommendedCoreIsActive: Bool
    let recommendedCoreCompatible: Bool

    let activationState: CoreActivationState
    let isDownloading: Bool
    let manualRepairRequired: Bool
    let updateRecoveryPending: Bool
    let productionFeedEnabled: Bool
    let lastCoreError: String?

    init(
        appVersion: String = "0.9.0",
        appBuild: String = "1090",
        appChannel: ReleaseChannel = .stable,
        appLifecycle: UpdateLifecycleStatus = .idle,
        appCanCheck: Bool = true,
        appLastCheckAt: Date? = nil,
        appLastResultCode: String? = nil,
        appLocalSignatureVerified: Bool? = nil,
        activeCoreID: String = "factory:1.19.29",
        activeCoreVersion: String = "1.19.29",
        activeCoreSource: CoreDescriptorSource = .factory,
        activeCoreStatus: InstalledCoreStatus? = nil,
        activeCoreDigest: String? = nil,
        activeCoreIntegrityVerified: Bool = true,
        runtimeRunning: Bool = true,
        controllerConnected: Bool = true,
        recoveryCoreID: String? = "mihomo:1.19.27:1",
        recoveryCoreVersion: String? = "1.19.27",
        recoveryCoreStatus: InstalledCoreStatus? = .knownGood,
        recoveryRootStoreReady: Bool? = true,
        canRollback: Bool = true,
        catalogState: CoreCatalogClientState = .verified(
            sequence: 42,
            expiresAt: .distantFuture,
            keyIDs: ["release"]
        ),
        catalogSequence: UInt64? = 42,
        catalogExpiresAt: Date? = .distantFuture,
        catalogEntryCount: Int = 1,
        recommendedCoreVersion: String? = "1.19.29",
        recommendedCoreInstalled: Bool = true,
        recommendedCoreIsActive: Bool = true,
        recommendedCoreCompatible: Bool = true,
        activationState: CoreActivationState = .idle,
        isDownloading: Bool = false,
        manualRepairRequired: Bool = false,
        updateRecoveryPending: Bool = false,
        productionFeedEnabled: Bool = true,
        lastCoreError: String? = nil
    ) {
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.appChannel = appChannel
        self.appLifecycle = appLifecycle
        self.appCanCheck = appCanCheck
        self.appLastCheckAt = appLastCheckAt
        self.appLastResultCode = appLastResultCode
        self.appLocalSignatureVerified = appLocalSignatureVerified
        self.activeCoreID = activeCoreID
        self.activeCoreVersion = activeCoreVersion
        self.activeCoreSource = activeCoreSource
        self.activeCoreStatus = activeCoreStatus
        self.activeCoreDigest = activeCoreDigest
        self.activeCoreIntegrityVerified = activeCoreIntegrityVerified
        self.runtimeRunning = runtimeRunning
        self.controllerConnected = controllerConnected
        self.recoveryCoreID = recoveryCoreID
        self.recoveryCoreVersion = recoveryCoreVersion
        self.recoveryCoreStatus = recoveryCoreStatus
        self.recoveryRootStoreReady = recoveryRootStoreReady
        self.canRollback = canRollback
        self.catalogState = catalogState
        self.catalogSequence = catalogSequence
        self.catalogExpiresAt = catalogExpiresAt
        self.catalogEntryCount = catalogEntryCount
        self.recommendedCoreVersion = recommendedCoreVersion
        self.recommendedCoreInstalled = recommendedCoreInstalled
        self.recommendedCoreIsActive = recommendedCoreIsActive
        self.recommendedCoreCompatible = recommendedCoreCompatible
        self.activationState = activationState
        self.isDownloading = isDownloading
        self.manualRepairRequired = manualRepairRequired
        self.updateRecoveryPending = updateRecoveryPending
        self.productionFeedEnabled = productionFeedEnabled
        self.lastCoreError = lastCoreError
    }

    @MainActor
    init(
        updateController: UpdateController,
        coreLifecycle: CoreLifecycleController,
        engineStore: EngineStore
    ) {
        let active = coreLifecycle.activeDescriptor
        let previous = coreLifecycle.snapshot?.previousKnownGoodDescriptor
        let recommended = coreLifecycle.recommendedEntry
        let previousRecord = previous.flatMap { descriptor in
            coreLifecycle.installedRecords.first { $0.coreID == descriptor.coreID }
        }

        appVersion = updateController.state.currentVersion
        appBuild = updateController.state.currentBuild
        appChannel = updateController.state.channel
        appLifecycle = updateController.state.lifecycle
        appCanCheck = updateController.state.canCheckForUpdates
        appLastCheckAt = updateController.state.lastCheckAt
        appLastResultCode = updateController.state.lastResult?.code
        // The existing updater exposes feed/key readiness, not a live local
        // application signature verdict. Keep this explicitly unknown.
        appLocalSignatureVerified = nil

        activeCoreID = active.coreID.rawValue
        activeCoreVersion = active.upstreamVersion
        activeCoreSource = active.source
        activeCoreStatus = coreLifecycle.activeRecord?.status
        activeCoreDigest = coreLifecycle.activeRecord?.catalogSHA256
        activeCoreIntegrityVerified = engineStore.coreLifecycleIntegrityVerified
        runtimeRunning = engineStore.isRunning
        controllerConnected = engineStore.controllerState == .connected

        recoveryCoreID = previous?.coreID.rawValue
        recoveryCoreVersion = previous?.upstreamVersion
        recoveryCoreStatus = previousRecord?.status
        recoveryRootStoreReady = previous.flatMap {
            coreLifecycle.rootStoreContains($0.coreID)
        }
        canRollback = coreLifecycle.canRollback

        catalogState = coreLifecycle.catalogState
        catalogSequence = coreLifecycle.catalogSnapshot?.catalog.sequence
        catalogExpiresAt = coreLifecycle.catalogSnapshot?.catalog.expiresAt
        catalogEntryCount = coreLifecycle.catalogSnapshot?.catalog.entries.count ?? 0
        recommendedCoreVersion = recommended?.upstreamVersion
        recommendedCoreInstalled = recommended.map { entry in
            coreLifecycle.installedRecords.contains { $0.coreID == entry.coreID }
        } ?? false
        recommendedCoreIsActive = recommended?.coreID == coreLifecycle.activeCoreID
        recommendedCoreCompatible = coreLifecycle.isRecommendedCompatible

        activationState = coreLifecycle.activationState
        isDownloading = coreLifecycle.isDownloading
        manualRepairRequired = coreLifecycle.manualRepairRequired
        updateRecoveryPending = coreLifecycle.updateRecoveryPending
        productionFeedEnabled = coreLifecycle.productionFeedEnabled
        lastCoreError = coreLifecycle.lastError
    }
}

nonisolated enum UpdatesCoreRecoveryPresentation {
    static func snapshot(
        input: UpdatesCoreRecoveryLiveInput,
        now: Date = .now
    ) -> UpdatesCoreRecoverySnapshot {
        let operation = currentOperation(input)
        let application = applicationComponent(input)
        let activeCore = activeCoreComponent(input)
        let recovery = recoveryComponent(input)
        let catalog = catalogComponent(input, now: now)
        let components = [application, activeCore, recovery, catalog]
        let banner = banner(input: input, components: components, operation: operation)
        let overall = overallState(
            input: input,
            components: components,
            operation: operation
        )
        let canVerifyAll = operation == nil
            && !input.manualRepairRequired
            && !input.updateRecoveryPending
            && input.appCanCheck
            && input.productionFeedEnabled

        return UpdatesCoreRecoverySnapshot(
            overallState: overall,
            lastVerifiedAt: [input.appLastCheckAt, input.catalogExpiresAt].compactMap { $0 }.min(),
            components: components,
            operation: operation,
            pipeline: pipeline(for: operation, input: input),
            permission: nil,
            banner: banner,
            runtimeSummary: runtimeSummary(input),
            canVerifyAll: canVerifyAll,
            verifyAllUnavailableReason: canVerifyAll ? nil : verifyAllUnavailableReason(input, operation: operation)
        )
    }

    private static func applicationComponent(
        _ input: UpdatesCoreRecoveryLiveInput
    ) -> UpdatesCoreRecoveryComponentRowModel {
        let localTrust: UpdatesCoreRecoveryTrustState = switch input.appLocalSignatureVerified {
        case true: .verified
        case false: .failed
        case nil: .verificationIncomplete
        }
        let feedStatus: VelaSemanticStatus = input.appCanCheck ? .success : .warning
        let availability: UpdatesCoreRecoveryAvailabilityState
        let summary: String
        let errorCode: String?
        switch input.appLifecycle {
        case .idle:
            if input.appLastResultCode == "up_to_date" {
                availability = .current
                summary = "Update feed checked; local signature verification is not exposed."
            } else {
                availability = .unknown
                summary = "Installed version is known; update availability has not been confirmed."
            }
            errorCode = nil
        case .checking:
            availability = .checking
            summary = "Checking the configured signed update feed."
            errorCode = nil
        case .updateAvailable:
            availability = .updateAvailable
            summary = "A signed application update is available."
            errorCode = nil
        case .downloaded:
            availability = .downloaded
            summary = "The signed update is downloaded and awaiting installation."
            errorCode = nil
        case .preparing, .readyForInstaller:
            availability = .transitioning
            summary = "The existing safe installation coordinator owns this operation."
            errorCode = nil
        case .recoveryRequired:
            availability = .unavailable
            summary = "Application update recovery is required before another update."
            errorCode = "APP_UPDATE_RECOVERY_REQUIRED"
        case let .failed(code, _):
            availability = .unavailable
            summary = "The last application update operation failed."
            errorCode = stableCode(code, fallback: "APP_UPDATE_FAILED")
        case .unavailable:
            availability = .unavailable
            summary = "The application update service is not available in this build."
            errorCode = "APP_UPDATE_UNAVAILABLE"
        }

        return UpdatesCoreRecoveryComponentRowModel(
            id: .application,
            version: "\(input.appVersion) (\(input.appBuild))",
            summary: summary,
            trust: localTrust,
            availability: availability,
            dimensions: [
                .init(
                    id: "local-signature",
                    label: "Local application trust",
                    value: trustValue(localTrust),
                    detail: localTrust == .verificationIncomplete
                        ? "No live local-signature verdict is exposed by the current update service."
                        : nil,
                    status: localTrust.semanticStatus
                ),
                .init(
                    id: "update-feed",
                    label: "Update feed",
                    value: input.appCanCheck ? "Configured" : "Unavailable",
                    detail: "Channel: \(input.appChannel.rawValue)",
                    status: feedStatus
                ),
                .init(
                    id: "availability",
                    label: "Update availability",
                    value: availabilityValue(availability),
                    detail: input.appLastCheckAt.map { "Last checked \($0.formatted(date: .abbreviated, time: .shortened))" },
                    status: availability.semanticStatus
                ),
            ],
            stableErrorCode: errorCode,
            isAffected: errorCode != nil,
            actions: input.appCanCheck ? [.checkApplicationUpdate] : []
        )
    }

    private static func activeCoreComponent(
        _ input: UpdatesCoreRecoveryLiveInput
    ) -> UpdatesCoreRecoveryComponentRowModel {
        let operation = currentOperation(input)
        let trust: UpdatesCoreRecoveryTrustState
        if input.activeCoreStatus == .blocked || input.activeCoreStatus == .quarantined {
            trust = .failed
        } else if input.activeCoreIntegrityVerified {
            trust = .verified
        } else {
            trust = .verificationIncomplete
        }
        let availability: UpdatesCoreRecoveryAvailabilityState = operation?.componentID == .activeCore
            ? .transitioning
            : .current
        let runtimeStatus: VelaSemanticStatus = if !input.runtimeRunning {
            .neutral
        } else if input.controllerConnected {
            .success
        } else {
            .error
        }
        let affected = trust == .failed
            || (input.runtimeRunning && !input.controllerConnected)
            || input.manualRepairRequired
        let errorCode = affected
            ? (input.manualRepairRequired ? "CORE_ROLLBACK_REPAIR_REQUIRED" : "ACTIVE_CORE_UNHEALTHY")
            : nil

        return UpdatesCoreRecoveryComponentRowModel(
            id: .activeCore,
            version: "Mihomo \(input.activeCoreVersion)",
            summary: affected
                ? "The active Core needs recovery or verification."
                : "Trust, compatibility, activation, and runtime are reported independently.",
            trust: trust,
            availability: availability,
            dimensions: [
                .init(
                    id: "artifact",
                    label: "Artifact verification",
                    value: trustValue(trust),
                    detail: input.activeCoreSource == .factory ? "Bundled Factory Core" : "Installed User Core",
                    status: trust.semanticStatus
                ),
                .init(
                    id: "digest",
                    label: "Catalog digest",
                    value: input.activeCoreDigest.map(shortDigest) ?? "Not exposed",
                    detail: nil,
                    status: input.activeCoreDigest == nil ? .neutral : .success
                ),
                .init(
                    id: "compatibility",
                    label: "Compatibility",
                    value: compatibilityValue(input.activeCoreStatus),
                    detail: "Core ID \(input.activeCoreID)",
                    status: compatibilityStatus(input.activeCoreStatus)
                ),
                .init(
                    id: "runtime",
                    label: "Runtime health",
                    value: runtimeValue(input),
                    detail: input.runtimeRunning ? "Controller health is evaluated separately." : "A stopped runtime does not invalidate artifact trust.",
                    status: runtimeStatus
                ),
            ],
            stableErrorCode: errorCode,
            isAffected: affected,
            actions: activeCoreActions(input)
        )
    }

    private static func recoveryComponent(
        _ input: UpdatesCoreRecoveryLiveInput
    ) -> UpdatesCoreRecoveryComponentRowModel {
        guard let recoveryVersion = input.recoveryCoreVersion else {
            return UpdatesCoreRecoveryComponentRowModel(
                id: .recoveryPoint,
                version: "None",
                summary: "No previous known-good Core is retained.",
                trust: .unavailable,
                availability: .unavailable,
                dimensions: [
                    .init(id: "artifact", label: "Recovery artifact", value: "Unavailable", detail: nil, status: .neutral),
                    .init(id: "metadata", label: "Recovery metadata", value: "Unavailable", detail: nil, status: .neutral),
                    .init(id: "coordinator", label: "Recovery coordinator", value: input.canRollback ? "Available" : "Not applicable", detail: nil, status: input.canRollback ? .success : .neutral),
                ],
                stableErrorCode: nil,
                isAffected: false,
                actions: input.manualRepairRequired ? [.openRecovery] : []
            )
        }

        let trusted = input.recoveryCoreStatus == .knownGood
            || input.recoveryCoreID?.hasPrefix("factory:") == true
        let storeReady = input.recoveryRootStoreReady != false
        // Store metadata proves a retained known-good selection, but the
        // current services do not expose an on-demand readable-artifact and
        // compatibility verdict. Do not call it fully ready.
        let trust: UpdatesCoreRecoveryTrustState = trusted ? .verificationIncomplete : .failed
        let availability: UpdatesCoreRecoveryAvailabilityState = input.canRollback && storeReady
            ? .available
            : .unknown
        let affected = input.manualRepairRequired || !storeReady || !trusted

        return UpdatesCoreRecoveryComponentRowModel(
            id: .recoveryPoint,
            version: "Mihomo \(recoveryVersion)",
            summary: input.manualRepairRequired
                ? "The retained rollback could not be verified; manual recovery is required."
                : "Retained metadata exists; live artifact readability and compatibility still require verification.",
            trust: trust,
            availability: availability,
            dimensions: [
                .init(
                    id: "artifact",
                    label: "Artifact readability",
                    value: "Verification required",
                    detail: "Retention alone is not treated as recovery readiness.",
                    status: .warning
                ),
                .init(
                    id: "trust",
                    label: "Last known trust",
                    value: trusted ? "Known good metadata" : "Not verified",
                    detail: input.recoveryCoreID,
                    status: trusted ? .success : .error
                ),
                .init(
                    id: "privileged-store",
                    label: "Required store",
                    value: storeValue(input.recoveryRootStoreReady),
                    detail: nil,
                    status: storeStatus(input.recoveryRootStoreReady)
                ),
                .init(
                    id: "coordinator",
                    label: "Recovery coordinator",
                    value: input.canRollback ? "Available" : "Locked",
                    detail: input.manualRepairRequired ? "Use the retained interrupted-activation repair." : nil,
                    status: input.canRollback ? .success : (input.manualRepairRequired ? .error : .neutral)
                ),
            ],
            stableErrorCode: affected ? "RECOVERY_POINT_VERIFICATION_REQUIRED" : nil,
            isAffected: affected,
            actions: recoveryActions(input)
        )
    }

    private static func catalogComponent(
        _ input: UpdatesCoreRecoveryLiveInput,
        now: Date
    ) -> UpdatesCoreRecoveryComponentRowModel {
        let trust: UpdatesCoreRecoveryTrustState
        let availability: UpdatesCoreRecoveryAvailabilityState
        let summary: String
        let errorCode: String?
        switch input.catalogState {
        case .verified:
            trust = input.catalogExpiresAt.map { $0 > now } == true ? .verified : .stale
            availability = .current
            summary = "Signature, sequence, digest, and freshness are tracked separately."
            errorCode = trust == .stale ? "CORE_CATALOG_STALE" : nil
        case .checking:
            trust = input.catalogSequence == nil ? .verificationIncomplete : .verified
            availability = .checking
            summary = "Refreshing through the existing signed Catalog service."
            errorCode = nil
        case .stale, .staleUncached:
            trust = .stale
            availability = .unavailable
            summary = "The trusted Catalog checkpoint is stale; new downloads remain blocked."
            errorCode = "CORE_CATALOG_STALE"
        case .clockSkew:
            trust = .failed
            availability = .unavailable
            summary = "Catalog time validation failed. Check this Mac's clock."
            errorCode = "CORE_CATALOG_CLOCK_SKEW"
        case .failed:
            trust = input.catalogSequence == nil ? .failed : .stale
            availability = .unavailable
            summary = input.catalogSequence == nil
                ? "No trusted Catalog snapshot is available."
                : "The last trusted Catalog remains visible after refresh failure."
            errorCode = "CORE_CATALOG_REFRESH_FAILED"
        case .unconfigured:
            trust = .unavailable
            availability = .unavailable
            summary = "The production signed Core Catalog is not configured."
            errorCode = "CORE_CATALOG_UNAVAILABLE"
        case .idle:
            trust = input.catalogSequence == nil ? .verificationIncomplete : .verified
            availability = input.catalogSequence == nil ? .unknown : .current
            summary = input.catalogSequence == nil
                ? "Catalog verification has not completed."
                : "The last trusted Catalog checkpoint is retained."
            errorCode = nil
        }

        let sequence = input.catalogSequence.map(String.init) ?? "—"
        return UpdatesCoreRecoveryComponentRowModel(
            id: .coreCatalog,
            version: input.recommendedCoreVersion.map { "Recommended \($0)" } ?? "No recommendation",
            summary: summary,
            trust: trust,
            availability: availability,
            dimensions: [
                .init(id: "signature", label: "Signature", value: trustValue(trust), detail: nil, status: trust.semanticStatus),
                .init(id: "sequence", label: "Accepted sequence", value: sequence, detail: "\(input.catalogEntryCount) entries", status: input.catalogSequence == nil ? .neutral : .success),
                .init(id: "freshness", label: "Freshness", value: freshnessValue(input.catalogExpiresAt, now: now), detail: input.catalogExpiresAt.map { "Expires \($0.formatted(date: .abbreviated, time: .shortened))" }, status: freshnessStatus(input.catalogExpiresAt, now: now)),
                .init(id: "recommended", label: "Recommended Core", value: input.recommendedCoreVersion ?? "Unavailable", detail: input.recommendedCoreVersion == nil ? nil : (input.recommendedCoreCompatible ? "Compatible" : "Incompatible"), status: input.recommendedCoreVersion == nil ? .neutral : (input.recommendedCoreCompatible ? .success : .error)),
            ],
            stableErrorCode: errorCode,
            isAffected: errorCode != nil,
            actions: catalogActions(input)
        )
    }

    private static func currentOperation(
        _ input: UpdatesCoreRecoveryLiveInput
    ) -> UpdatesCoreRecoveryOperation? {
        switch input.appLifecycle {
        case .checking: return .checkingAppUpdate
        case .preparing, .readyForInstaller: return .installingAppUpdate
        case .idle, .updateAvailable, .downloaded, .recoveryRequired, .failed, .unavailable:
            break
        }
        if input.updateRecoveryPending { return .restoringRecoveryPoint }
        if input.isDownloading { return .downloadingCore }
        switch input.catalogState {
        case .checking: return .refreshingCoreCatalog
        case .unconfigured, .idle, .verified, .stale, .staleUncached, .clockSkew, .failed:
            break
        }
        return switch input.activationState {
        case .validatingCandidate, .snapshotting: .stagingCore
        case .stoppingCurrent, .startingCandidate, .verifyingCandidate, .probation, .committing:
            .activatingCore
        case .rollingBack: .restoringRecoveryPoint
        case .idle, .failed: nil
        }
    }

    private static func overallState(
        input: UpdatesCoreRecoveryLiveInput,
        components: [UpdatesCoreRecoveryComponentRowModel],
        operation: UpdatesCoreRecoveryOperation?
    ) -> UpdatesCoreRecoveryOverallState {
        if input.manualRepairRequired { return .recoveryRequired }
        if operation != nil { return .operationInProgress }
        if case .recoveryRequired = input.appLifecycle { return .recoveryRequired }
        if components.contains(where: { $0.trust == .failed || $0.stableErrorCode != nil }) {
            return .attentionRequired
        }
        if case .updateAvailable = input.appLifecycle { return .updateAvailable }
        if case .downloaded = input.appLifecycle { return .updateAvailable }
        if components.allSatisfy({ $0.trust == .verified }) { return .allVerified }
        if !input.appCanCheck && !input.productionFeedEnabled { return .unavailable }
        return .verificationIncomplete
    }

    private static func banner(
        input: UpdatesCoreRecoveryLiveInput,
        components: [UpdatesCoreRecoveryComponentRowModel],
        operation: UpdatesCoreRecoveryOperation?
    ) -> UpdatesCoreRecoveryBanner? {
        if input.manualRepairRequired {
            return .init(
                title: "Core recovery is required",
                detail: "Automatic Core changes are paused. Open Recovery to inspect the retained artifact, runtime state, trust evidence, and ownership before repairing the interrupted activation.",
                status: .error,
                affectedComponentID: .recoveryPoint,
                stableErrorCode: "CORE_ROLLBACK_REPAIR_REQUIRED"
            )
        }
        if let operation {
            return .init(
                title: operationTitle(operation),
                detail: "The previously committed working state remains authoritative until verification and commit succeed.",
                status: .pending,
                affectedComponentID: operation.componentID,
                stableErrorCode: nil
            )
        }
        if let affected = components.first(where: { $0.isAffected }) {
            return .init(
                title: "\(componentTitle(affected.id)) needs attention",
                detail: affected.summary,
                status: affected.trust == .failed ? .error : .warning,
                affectedComponentID: affected.id,
                stableErrorCode: affected.stableErrorCode
            )
        }
        return nil
    }

    private static func pipeline(
        for operation: UpdatesCoreRecoveryOperation?,
        input: UpdatesCoreRecoveryLiveInput
    ) -> [UpdatesCoreRecoveryPipelineStep] {
        guard let operation else { return [] }
        let titles: [String]
        let activeIndex: Int
        switch operation {
        case .checkingAppUpdate:
            titles = ["Validate feed configuration", "Fetch signed appcast", "Verify release", "Publish availability"]
            activeIndex = 1
        case .installingAppUpdate:
            titles = ["Capture runtime state", "Move services to safe stop", "Authorize installer", "Hand off to Sparkle"]
            activeIndex = input.appLifecycle == .readyForInstaller ? 3 : 1
        case .refreshingCoreCatalog:
            titles = ["Download Catalog and envelope", "Verify signatures", "Check sequence and freshness", "Retain trusted checkpoint"]
            activeIndex = 1
        case .downloadingCore:
            titles = ["Download fixed-role artifacts", "Verify digests", "Build signed bundle", "Commit installation record"]
            activeIndex = 0
        case .stagingCore:
            titles = ["Validate candidate", "Capture working state", "Stage activation journal", "Prepare runtime switch"]
            activeIndex = input.activationState == .snapshotting ? 1 : 0
        case .activatingCore:
            titles = ["Start candidate", "Verify Controller and runtime", "Observe probation", "Commit known-good state"]
            activeIndex = activationPipelineIndex(input.activationState)
        case .verifyingRecoveryPoint:
            titles = ["Read retained artifact", "Verify trust and digest", "Check compatibility", "Confirm coordinator readiness"]
            activeIndex = 0
        case .restoringRecoveryPoint:
            titles = ["Lock automatic changes", "Restore trusted Core", "Verify runtime and ownership", "Commit recovered state"]
            activeIndex = input.activationState == .rollingBack ? 1 : 2
        }
        return titles.enumerated().map { index, title in
            .init(
                id: "\(operation.rawValue)-\(index)",
                title: title,
                detail: nil,
                state: index < activeIndex ? .complete : (index == activeIndex ? .active : .pending)
            )
        }
    }

    private static func activationPipelineIndex(_ state: CoreActivationState) -> Int {
        switch state {
        case .stoppingCurrent, .startingCandidate: 0
        case .verifyingCandidate: 1
        case .probation: 2
        case .committing: 3
        default: 0
        }
    }

    private static func activeCoreActions(
        _ input: UpdatesCoreRecoveryLiveInput
    ) -> [UpdatesCoreRecoveryAction] {
        if input.manualRepairRequired { return [.openRecovery] }
        var actions: [UpdatesCoreRecoveryAction] = []
        if input.recommendedCoreInstalled && !input.recommendedCoreIsActive
            && input.recommendedCoreCompatible
        {
            actions.append(.activateRecommendedCore)
        }
        if input.canRollback { actions.append(.rollbackCore) }
        return actions
    }

    private static func recoveryActions(
        _ input: UpdatesCoreRecoveryLiveInput
    ) -> [UpdatesCoreRecoveryAction] {
        // Manual repair must enter the single Recovery route first so the
        // existing coordinator can run its preflight before exposing a retry.
        if input.manualRepairRequired { return [.openRecovery] }
        return input.canRollback ? [.rollbackCore] : []
    }

    private static func catalogActions(
        _ input: UpdatesCoreRecoveryLiveInput
    ) -> [UpdatesCoreRecoveryAction] {
        var actions: [UpdatesCoreRecoveryAction] = []
        if input.productionFeedEnabled { actions.append(.refreshCoreCatalog) }
        if input.recommendedCoreVersion != nil && input.recommendedCoreCompatible
            && !input.recommendedCoreInstalled
        {
            actions.append(.downloadRecommendedCore)
        }
        return actions
    }

    private static func verifyAllUnavailableReason(
        _ input: UpdatesCoreRecoveryLiveInput,
        operation: UpdatesCoreRecoveryOperation?
    ) -> String {
        if operation != nil { return "Wait for the current operation to finish." }
        if input.manualRepairRequired { return "Complete Core recovery before running all checks." }
        if input.updateRecoveryPending { return "Application update recovery owns the runtime barrier." }
        if !input.appCanCheck && !input.productionFeedEnabled {
            return "Application and Core update services are unavailable in this build."
        }
        if !input.appCanCheck { return "Application update checking is unavailable." }
        return "The production Core Catalog is unavailable."
    }

    private static func runtimeSummary(_ input: UpdatesCoreRecoveryLiveInput) -> String {
        if !input.runtimeRunning { return "Mihomo is stopped. No runtime health is claimed." }
        return input.controllerConnected
            ? "Mihomo is running and the Controller is connected."
            : "Mihomo is running, but the Controller is not connected."
    }

    private static func stableCode(_ value: String, fallback: String) -> String {
        let normalized = value.uppercased().map { character in
            character.isLetter || character.isNumber ? character : "_"
        }
        let result = String(normalized).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return result.isEmpty ? fallback : String(result.prefix(64))
    }

    private static func shortDigest(_ value: String) -> String {
        guard value.count > 12 else { return value }
        return "\(value.prefix(8))…\(value.suffix(4))"
    }

    private static func trustValue(_ state: UpdatesCoreRecoveryTrustState) -> String {
        switch state {
        case .verified: "Verified"
        case .verificationIncomplete: "Verification incomplete"
        case .stale: "Stale"
        case .failed: "Failed"
        case .unavailable: "Unavailable"
        }
    }

    private static func availabilityValue(_ state: UpdatesCoreRecoveryAvailabilityState) -> String {
        switch state {
        case .current: "Current"
        case .updateAvailable: "Update available"
        case .downloaded: "Downloaded"
        case .ready: "Ready"
        case .available: "Available"
        case .checking: "Checking"
        case .transitioning: "Transitioning"
        case .unavailable: "Unavailable"
        case .unknown: "Not checked"
        }
    }

    private static func compatibilityValue(_ status: InstalledCoreStatus?) -> String {
        switch status {
        case .blocked: "Blocked"
        case .quarantined: "Quarantined"
        case .ready, .knownGood, .withdrawn: "Accepted"
        case nil: "Factory compatibility"
        }
    }

    private static func compatibilityStatus(_ status: InstalledCoreStatus?) -> VelaSemanticStatus {
        switch status {
        case .blocked, .quarantined: .error
        case .withdrawn: .warning
        case .ready, .knownGood, nil: .success
        }
    }

    private static func runtimeValue(_ input: UpdatesCoreRecoveryLiveInput) -> String {
        if !input.runtimeRunning { return "Stopped"
        }
        return input.controllerConnected ? "Running · Connected" : "Running · Controller offline"
    }

    private static func storeValue(_ value: Bool?) -> String {
        switch value {
        case true: "Available"
        case false: "Missing"
        case nil: "Not checked"
        }
    }

    private static func storeStatus(_ value: Bool?) -> VelaSemanticStatus {
        switch value {
        case true: .success
        case false: .error
        case nil: .neutral
        }
    }

    private static func freshnessValue(_ date: Date?, now: Date) -> String {
        guard let date else { return "Not checked" }
        return date > now ? "Fresh" : "Expired"
    }

    private static func freshnessStatus(_ date: Date?, now: Date) -> VelaSemanticStatus {
        guard let date else { return .neutral }
        return date > now ? .success : .stale
    }

    private static func componentTitle(_ id: UpdatesCoreRecoveryComponentID) -> String {
        switch id {
        case .application: "Application"
        case .activeCore: "Active Core"
        case .recoveryPoint: "Recovery Point"
        case .coreCatalog: "Core Catalog"
        }
    }

    private static func operationTitle(_ operation: UpdatesCoreRecoveryOperation) -> String {
        switch operation {
        case .checkingAppUpdate: "Checking for an application update"
        case .installingAppUpdate: "Preparing the application update"
        case .refreshingCoreCatalog: "Refreshing the signed Core Catalog"
        case .downloadingCore: "Downloading and verifying a Core"
        case .stagingCore: "Staging a Core activation"
        case .activatingCore: "Activating and verifying the Core"
        case .verifyingRecoveryPoint: "Verifying the recovery point"
        case .restoringRecoveryPoint: "Restoring the recovery point"
        }
    }
}
