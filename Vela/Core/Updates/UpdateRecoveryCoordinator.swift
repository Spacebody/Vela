import Foundation
import OSLog

nonisolated enum UpdateLaunchDisposition: Equatable, Sendable {
    case normal
    case pendingRecovery(UpdateJournalDiagnosticSummary)
    case safeMode(code: String, message: String)

    var allowsAutomaticServices: Bool {
        if case .normal = self { return true }
        return false
    }
}

nonisolated struct UpdateRecoveryProof: Equatable, Sendable {
    let profileRestored: Bool
    let backendRestored: Bool
    let modeRestored: Bool
    let proxySelectionsRestored: Bool
    let systemProxyRestored: Bool
    let healthVerified: Bool
    let warnings: [String]

    var isHealthy: Bool {
        profileRestored
            && backendRestored
            && modeRestored
            && proxySelectionsRestored
            && systemProxyRestored
            && healthVerified
    }
}

@MainActor
final class UpdateRecoveryCoordinator {
    typealias HelperValidator = @MainActor @Sendable (UpdateJournal) async throws -> Void
    typealias CoreRestorer = @MainActor @Sendable (UpdateRuntimeSnapshot) async throws -> Void
    typealias RuntimeRestorer = @MainActor @Sendable (UpdateRuntimeSnapshot) async throws
        -> UpdateRecoveryProof
    typealias LifecycleSink = @MainActor @Sendable (UpdateLifecycleStatus) -> Void

    private let store: UpdateJournalStore
    private let manifestReader: BuildManifestReader
    private let bundle: Bundle
    private let validateHelper: HelperValidator
    private let restoreCore: CoreRestorer
    private let restoreRuntime: RuntimeRestorer
    private let lifecycleSink: LifecycleSink
    private let now: @Sendable () -> Date

    private(set) var disposition: UpdateLaunchDisposition = .normal
    private var pendingJournal: UpdateJournal?

    init(
        store: UpdateJournalStore,
        manifestReader: BuildManifestReader = BuildManifestReader(),
        bundle: Bundle = .main,
        validateHelper: @escaping HelperValidator,
        restoreCore: @escaping CoreRestorer = { _ in },
        restoreRuntime: @escaping RuntimeRestorer,
        lifecycleSink: @escaping LifecycleSink = { _ in },
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.store = store
        self.manifestReader = manifestReader
        self.bundle = bundle
        self.validateHelper = validateHelper
        self.restoreCore = restoreCore
        self.restoreRuntime = restoreRuntime
        self.lifecycleSink = lifecycleSink
        self.now = now
    }

    /// Runs before subscription scheduling, automation, and Sparkle startup.
    /// A journal or manifest uncertainty always resolves to safe mode.
    func preflightLaunch() async -> UpdateLaunchDisposition {
        do {
            let identity = try ReleaseBuildIdentity(bundle: bundle)
            guard var journal = try await store.load() else {
                if try BundledReleaseManifestPolicy.requiresValidation(in: bundle) {
                    try validateBundledRelease(identity: identity)
                }
                disposition = .normal
                return disposition
            }

            if journal.phase == .committed {
                guard identity == journal.target else {
                    return enterSafeMode(
                        code: "committed_build_mismatch",
                        message: "The committed update journal does not match this application build."
                    )
                }
                try validateBundledRelease(identity: identity)
                disposition = .normal
                return disposition
            }

            if identity == journal.source,
                Self.canAbandonBeforeInstaller(journal.phase)
            {
                if try BundledReleaseManifestPolicy.requiresValidation(in: bundle) {
                    try validateBundledRelease(identity: identity)
                }
                try await store.clear(expectedUpdateID: journal.updateID)
                pendingJournal = nil
                disposition = .normal
                lifecycleSink(.idle)
                UpdateLog.recovery.info("Abandoned a pre-installer journal for the unchanged source build")
                return disposition
            }

            guard identity == journal.target else {
                let code = identity == journal.source
                    ? "installer_not_committed"
                    : "unexpected_build_after_update"
                return enterSafeMode(
                    code: code,
                    message: "The active update journal does not match this application build."
                )
            }

            try validateBundledRelease(identity: identity)

            journal.phase = .firstLaunch
            UpdateLog.recovery.info("Post-update recovery preflight accepted the target build")
            journal.lastUpdatedAt = now()
            journal.failure = nil
            try await store.save(journal)
            pendingJournal = journal
            disposition = .pendingRecovery(journal.diagnosticSummary)
            lifecycleSink(.preparing)
            return disposition
        } catch {
            return enterSafeMode(
                code: Self.failureCode(for: error),
                message: DiagnosticTextSanitizer.redact(error.localizedDescription)
            )
        }
    }

    private func validateBundledRelease(
        identity: ReleaseBuildIdentity
    ) throws {
        let manifest = try manifestReader.readBundled(
            from: bundle,
            expectedBuildIdentity: identity
        )
        guard let configuredChannel = bundle.object(
            forInfoDictionaryKey: "VelaReleaseChannel"
        ) as? String,
            ReleaseChannel(rawValue: configuredChannel) == manifest.app.channel
        else {
            throw UpdateRecoveryCoordinatorError.releaseChannelMismatch
        }

        let configuredPrereleaseLabel = Self.normalizedLabel(
            bundle.object(forInfoDictionaryKey: "VelaPrereleaseLabel") as? String
        )
        guard configuredPrereleaseLabel
            == Self.normalizedLabel(manifest.app.prereleaseLabel)
        else {
            throw UpdateRecoveryCoordinatorError.prereleaseLabelMismatch
        }

        let compatibility = manifestReader.compatibilityReport(for: manifest)
        guard compatibility.isCompatible else {
            throw UpdateRecoveryCoordinatorError.releaseIncompatible
        }
    }

    private static func normalizedLabel(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private static func canAbandonBeforeInstaller(
        _ phase: UpdateJournalPhase
    ) -> Bool {
        switch phase {
        case .preparing, .quiescing, .readyForInstaller, .failed:
            true
        case .installerStarted, .firstLaunch, .migrating, .verifying,
            .restoring, .committed, .recoveryRequired:
            false
        }
    }

    /// Runs after EngineStore and interrupted configuration transactions have
    /// bootstrapped, but before schedulers, automation listeners, or Sparkle.
    func recoverAfterBootstrap() async -> Bool {
        guard var journal = pendingJournal else {
            return disposition.allowsAutomaticServices
        }
        guard journal.recoveryAttempts < UpdateJournal.maximumRecoveryAttempts else {
            await enterRecoveryRequired(
                &journal,
                code: "recovery_attempt_limit",
                message: "Automatic update recovery has already been attempted."
            )
            return false
        }

        journal.recoveryAttempts += 1
        journal.phase = .migrating
        journal.lastUpdatedAt = now()

        do {
            try await store.save(journal)
            try await validateHelper(journal)
            try await restoreCore(journal.snapshot)

            journal.phase = .restoring
            journal.lastUpdatedAt = now()
            try await store.save(journal)

            let proof = try await restoreRuntime(journal.snapshot)
            guard proof.isHealthy else {
                throw UpdateRecoveryCoordinatorError.healthVerificationFailed
            }

            journal.phase = .verifying
            journal.lastUpdatedAt = now()
            try await store.save(journal)

            journal.phase = .committed
            journal.lastUpdatedAt = now()
            journal.failure = nil
            try await store.save(journal)
            pendingJournal = nil
            disposition = .normal
            lifecycleSink(.idle)
            UpdateLog.recovery.info("Post-update recovery committed successfully")
            return true
        } catch {
            await enterRecoveryRequired(
                &journal,
                code: Self.failureCode(for: error),
                message: DiagnosticTextSanitizer.redact(error.localizedDescription)
            )
            return false
        }
    }

    private func enterSafeMode(
        code: String,
        message: String
    ) -> UpdateLaunchDisposition {
        let safeMessage = DiagnosticTextSanitizer.redact(message)
        UpdateLog.recovery.error("Update launch entered safe mode; code=\(code, privacy: .public)")
        pendingJournal = nil
        disposition = .safeMode(code: code, message: safeMessage)
        lifecycleSink(.recoveryRequired(phase: "preflight", reason: safeMessage))
        return disposition
    }

    private func enterRecoveryRequired(
        _ journal: inout UpdateJournal,
        code: String,
        message: String
    ) async {
        journal.phase = .recoveryRequired
        journal.lastUpdatedAt = now()
        journal.failure = UpdateFailureSummary(
            code: code,
            phase: .recoveryRequired,
            summary: message
        )
        pendingJournal = journal
        try? await store.save(journal)
        let safeMessage = DiagnosticTextSanitizer.redact(message)
        disposition = .safeMode(code: code, message: safeMessage)
        lifecycleSink(.recoveryRequired(phase: "recovery", reason: safeMessage))
    }

    private static func failureCode(for error: any Error) -> String {
        if let error = error as? UpdateRecoveryCoordinatorError {
            return error.rawValue
        }
        if error is RuntimeMutationGateError {
            return "mutation_gate_failed"
        }
        if error is BuildManifestReaderError
            || error is BundledReleaseManifestPolicyError
        {
            return "release_manifest_invalid"
        }
        if error is UpdateJournalStoreError {
            return "update_journal_invalid"
        }
        return "update_recovery_failed"
    }
}

nonisolated enum UpdateRecoveryCoordinatorError: String, Error, Equatable, Sendable {
    case helperUnavailable = "helper_unavailable"
    case helperIncompatible = "helper_incompatible"
    case profileUnavailable = "profile_unavailable"
    case revisionMismatch = "profile_revision_mismatch"
    case healthVerificationFailed = "health_verification_failed"
    case releaseChannelMismatch = "release_channel_mismatch"
    case prereleaseLabelMismatch = "prerelease_label_mismatch"
    case releaseIncompatible = "release_incompatible"
}

extension UpdateRecoveryCoordinatorError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .helperUnavailable:
            "The privileged component is unavailable for update recovery."
        case .helperIncompatible:
            "The installed privileged component is not compatible with this App."
        case .profileUnavailable:
            "The saved update profile is no longer available."
        case .revisionMismatch:
            "The saved profile revision no longer matches the update snapshot."
        case .healthVerificationFailed:
            "Vela could not prove that the restored runtime is healthy."
        case .releaseChannelMismatch:
            "The bundled release manifest does not match this App's update channel."
        case .prereleaseLabelMismatch:
            "The bundled release manifest does not match this App's prerelease label."
        case .releaseIncompatible:
            "This build is not compatible with Vela's installed components or data."
        }
    }
}
