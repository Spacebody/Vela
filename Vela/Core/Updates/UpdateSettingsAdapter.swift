import Foundation
import Sparkle

/// A deliberately thin bridge to Sparkle's persisted preferences. Vela does
/// not mirror these values into a second UserDefaults namespace.
@MainActor
final class UpdateSettingsAdapter {
    private let updater: SPUUpdater
    private let state: UpdatePresentationState

    init(updater: SPUUpdater, state: UpdatePresentationState) {
        self.updater = updater
        self.state = state
        synchronize()
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        updater.automaticallyChecksForUpdates = enabled
        synchronize()
    }

    func setAutomaticallyDownloadsUpdates(_ enabled: Bool) {
        guard updater.allowsAutomaticUpdates else { return }
        updater.automaticallyDownloadsUpdates = enabled
        synchronize()
    }

    func synchronize() {
        state.synchronizeSettings(
            canCheckForUpdates: updater.canCheckForUpdates,
            automaticallyChecksForUpdates: updater.automaticallyChecksForUpdates,
            automaticallyDownloadsUpdates: updater.automaticallyDownloadsUpdates,
            allowsAutomaticUpdates: updater.allowsAutomaticUpdates,
            updateCheckInterval: updater.updateCheckInterval,
            lastCheckAt: updater.lastUpdateCheckDate
        )
    }
}
