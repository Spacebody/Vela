import Foundation
import OSLog
import Sparkle

nonisolated struct UpdateInstallTarget: Equatable, Sendable {
    let version: String
    let build: String
}

@MainActor
protocol UpdateInstallationCoordinating: AnyObject {
    func prepareForInstallation(
        target: UpdateInstallTarget,
        installHandler: @escaping @MainActor () -> Void
    )
}

@MainActor
final class UpdateController: NSObject, SPUUpdaterDelegate {
    static let channelPreferenceKey = "VelaUpdateChannel"
    static let stagingLaunchArgument = "--vela-enable-staging-updates"

    let state: UpdatePresentationState
    private(set) lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: self,
        userDriverDelegate: nil
    )
    private(set) lazy var settings = UpdateSettingsAdapter(
        updater: updaterController.updater,
        state: state
    )

    private weak var installationCoordinator: (any UpdateInstallationCoordinating)?
    private let defaults: UserDefaults
    private let applicationBundle: Bundle
    private var hasStarted = false

    init(
        bundle: Bundle = .main,
        defaults: UserDefaults = .standard,
        installationCoordinator: (any UpdateInstallationCoordinating)? = nil
    ) {
        applicationBundle = bundle
        self.defaults = defaults
        self.installationCoordinator = installationCoordinator

        let version = bundle.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "Unknown"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? "Unknown"
        let configuredChannel = bundle.object(
            forInfoDictionaryKey: "VelaReleaseChannel"
        ) as? String
        let persistedChannel = defaults.string(forKey: Self.channelPreferenceKey)
        let channel = ReleaseChannel(rawValue: persistedChannel ?? configuredChannel ?? "stable")
            ?? .stable
        state = UpdatePresentationState(
            currentVersion: version,
            currentBuild: build,
            channel: channel
        )

        super.init()

        // Preserve eager Sparkle setup while avoiding partially initialized IUOs.
        _ = settings
        applyConfigurationAvailability()
    }

    func attachInstallationCoordinator(
        _ coordinator: any UpdateInstallationCoordinating
    ) {
        guard installationCoordinator == nil else {
            UpdateLog.updates.error(
                "Ignored a duplicate update installation coordinator attachment"
            )
            return
        }
        installationCoordinator = coordinator
    }

    func startIfEligible(recoveryAllowsUpdates: Bool) {
        guard !hasStarted, recoveryAllowsUpdates else { return }
        guard configurationIssue() == nil else {
            applyConfigurationAvailability()
            return
        }
        updaterController.startUpdater()
        hasStarted = true
        state.setLifecycle(.idle)
        settings.synchronize()
    }

    func checkForUpdates() {
        guard hasStarted, updaterController.updater.canCheckForUpdates else { return }
        UpdateLog.updates.info("User initiated update check; channel=\(self.state.channel.rawValue, privacy: .public)")
        state.setLifecycle(.checking)
        updaterController.checkForUpdates(nil)
        settings.synchronize()
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        settings.setAutomaticallyChecksForUpdates(enabled)
    }

    func setAutomaticallyDownloadsUpdates(_ enabled: Bool) {
        settings.setAutomaticallyDownloadsUpdates(enabled)
    }

    func setChannel(_ channel: ReleaseChannel) {
        guard channel != state.channel else { return }
        defaults.set(channel.rawValue, forKey: Self.channelPreferenceKey)
        UpdateLog.updates.info("Update channel changed to \(channel.rawValue, privacy: .public)")
        state.setChannel(channel)
        updaterController.updater.resetUpdateCycleAfterShortDelay()
        state.recordResult(
            UpdateCheckSummary(
                code: "channel_changed",
                message: channel == .beta
                    ? "Beta updates are enabled. Stable updates remain eligible."
                    : "Stable updates are enabled. Vela will not automatically downgrade this build."
            )
        )
        settings.synchronize()
    }

    func markRecoveryRequired(phase: String, reason: String) {
        state.setLifecycle(
            .recoveryRequired(
                phase: DiagnosticTextSanitizer.redact(phase),
                reason: DiagnosticTextSanitizer.redact(reason)
            )
        )
        settings.synchronize()
    }

    func redactedDiagnosticsData() throws -> Data {
        var payload: [String: Any] = [
            "schemaVersion": 1,
            "version": state.currentVersion,
            "build": state.currentBuild,
            "channel": state.channel.rawValue,
            "sparkle": state.sparkleVersion,
            "status": state.lifecycle.title,
            "automaticChecks": state.automaticallyChecksForUpdates,
            "automaticDownloads": state.automaticallyDownloadsUpdates,
        ]
        if let lastCheckAt = state.lastCheckAt {
            payload["lastCheckAt"] = ISO8601DateFormatter().string(from: lastCheckAt)
        }
        if let lastResult = state.lastResult {
            payload["lastResult"] = [
                "code": lastResult.code,
                "message": lastResult.message,
                "occurredAt": ISO8601DateFormatter().string(from: lastResult.occurredAt),
            ]
        }
        return try JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
    }

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        UpdateChannelPolicy.allowedChannels(for: state.channel)
    }

    func updater(
        _ updater: SPUUpdater,
        mayPerform updateCheck: SPUUpdateCheck
    ) throws {
        switch state.lifecycle {
        case .preparing, .readyForInstaller, .recoveryRequired:
            throw NSError(
                domain: "dev.yilin.Vela.Updates",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Vela cannot check for another update while update preparation or recovery is active."
                ]
            )
        case .unavailable, .idle, .checking, .updateAvailable, .downloaded, .failed:
            break
        }
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        state.setLifecycle(
            .updateAvailable(
                version: item.displayVersionString,
                build: item.versionString
            )
        )
        state.setReleaseNotesURL(item.releaseNotesURL)
        state.recordResult(
            UpdateCheckSummary(
                code: "update_available",
                message: "A signed update is available."
            )
        )
        settings.synchronize()
    }

    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        state.setLifecycle(
            .downloaded(
                version: item.displayVersionString,
                build: item.versionString
            )
        )
        state.recordResult(
            UpdateCheckSummary(code: "downloaded", message: "The update was downloaded.")
        )
        settings.synchronize()
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        state.setLifecycle(.preparing)
    }

    func updater(
        _ updater: SPUUpdater,
        shouldPostponeRelaunchForUpdate item: SUAppcastItem,
        untilInvokingBlock installHandler: @escaping () -> Void
    ) -> Bool {
        beginSafePreparation(item: item, installHandler: installHandler)
        return true
    }

    func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        beginSafePreparation(item: item, installHandler: immediateInstallHandler)
        return true
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        record(error: error, code: "sparkle_aborted")
    }

    func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: (any Error)?
    ) {
        if let error {
            record(error: error, code: "update_cycle_failed")
        } else if case .checking = state.lifecycle {
            state.setLifecycle(.idle)
            state.recordResult(
                UpdateCheckSummary(code: "up_to_date", message: "No newer update was selected.")
            )
        }
        settings.synchronize()
    }

    private func beginSafePreparation(
        item: SUAppcastItem,
        installHandler: @escaping () -> Void
    ) {
        state.setLifecycle(.preparing)
        guard let installationCoordinator else {
            state.setLifecycle(
                .failed(
                    code: "coordinator_unavailable",
                    message: "The safe installation coordinator is unavailable."
                )
            )
            return
        }

        installationCoordinator.prepareForInstallation(
            target: UpdateInstallTarget(
                version: item.displayVersionString,
                build: item.versionString
            ),
            installHandler: { @MainActor [weak self] in
                self?.state.setLifecycle(.readyForInstaller)
                installHandler()
            }
        )
    }

    private func record(error: any Error, code: String) {
        UpdateLog.sparkleBridge.error("Update cycle failed; code=\(code, privacy: .public)")
        let message = DiagnosticTextSanitizer.redact(error.localizedDescription)
        state.setLifecycle(.failed(code: code, message: message))
        state.recordResult(UpdateCheckSummary(code: code, message: message))
        settings.synchronize()
    }

    private func applyConfigurationAvailability() {
        if let issue = configurationIssue() {
            state.setLifecycle(.unavailable(reason: issue))
            state.synchronizeSettings(
                canCheckForUpdates: false,
                automaticallyChecksForUpdates: false,
                automaticallyDownloadsUpdates: false,
                allowsAutomaticUpdates: false,
                updateCheckInterval: 0,
                lastCheckAt: nil
            )
        }
    }

    private func configurationIssue() -> String? {
        guard let feedString = applicationBundle.object(
            forInfoDictionaryKey: "SUFeedURL"
        ) as? String,
            let feedURL = URL(string: feedString),
            feedURL.scheme?.lowercased() == "https",
            feedURL.host?.isEmpty == false,
            feedURL.user == nil,
            feedURL.password == nil,
            feedURL.query == nil,
            feedURL.fragment == nil
        else {
            return "A fixed HTTPS update feed without credentials, fragments, or tracking parameters is required."
        }

        let stagingOverride = ProcessInfo.processInfo.arguments.contains(
            Self.stagingLaunchArgument
        )
        if feedURL.host?.hasSuffix(".invalid") == true, !stagingOverride {
            return "A release update feed and public key have not been configured."
        }

        guard let publicKey = applicationBundle.object(
            forInfoDictionaryKey: "SUPublicEDKey"
        ) as? String,
            let decoded = Data(base64Encoded: publicKey),
            decoded.count == 32
        else {
            return "The Sparkle Ed25519 public key is missing or invalid."
        }

        return nil
    }
}
