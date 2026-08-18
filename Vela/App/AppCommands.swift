import SwiftUI

struct AppCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    let engineStore: EngineStore
    let dailyDriver: DailyDriverFeatureHub
    let updateController: UpdateController
    let onboardingCoordinator: OnboardingCoordinator
    let helpNavigationCoordinator: HelpNavigationCoordinator

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button(VelaL10n.string("legacy.settings", defaultValue: "Settings…")) {
                SettingsMainNavigationRequest.open(.settings)
            }
            .keyboardShortcut(",", modifiers: .command)
        }

        CommandGroup(after: .appInfo) {
            Button(VelaL10n.string("legacy.openVela", defaultValue: "Open Vela")) {
                NotificationCenter.default.post(name: .velaOpenMainWindow, object: nil)
            }
            .keyboardShortcut("o", modifiers: .command)

            Divider()

            Button(VelaL10n.string("legacy.checkForUpdatesDialog", defaultValue: "Check for Updates…")) {
                updateController.checkForUpdates()
            }
            .disabled(!updateController.state.canCheckForUpdates)

            Button(
                VelaL10n.string(
                    "onboarding.tour.open",
                    defaultValue: "Take the Vela Tour"
                )
            ) {
                Task { @MainActor in
                    try? await onboardingCoordinator.startTour()
                    openWindow(id: "main")
                    NotificationCenter.default.post(
                        name: .velaOpenOnboarding,
                        object: nil
                    )
                }
            }
        }

        CommandGroup(replacing: .help) {
            Button(
                VelaL10n.string("app.help.open", defaultValue: "Vela Help")
            ) {
                helpNavigationCoordinator.request(topic: nil)
                openWindow(id: "help")
            }
            .keyboardShortcut("?", modifiers: .command)
        }

        CommandGroup(after: .sidebar) {
            Button(VelaL10n.string("legacy.refresh", defaultValue: "Refresh")) {
                NotificationCenter.default.post(name: .velaRefreshCurrentSection, object: nil)
            }
            .keyboardShortcut("r", modifiers: .command)

            Button(VelaL10n.string("legacy.focusSearch", defaultValue: "Focus Search")) {
                NotificationCenter.default.post(name: .velaFocusSearch, object: nil)
            }
            .keyboardShortcut("k", modifiers: .command)
        }

        CommandMenu(VelaL10n.string("legacy.profiles", defaultValue: "Profiles")) {
            Button(VelaL10n.string("legacy.updateSelectedRemoteProfile", defaultValue: "Update Selected Remote Profile")) {
                guard let id = engineStore.selectedProfileID else { return }
                Task { await dailyDriver.profiles.update(id) }
            }
            .keyboardShortcut("u", modifiers: .command)
            .disabled(engineStore.selectedProfile?.sourceKind != .remoteSubscription)

            Button(VelaL10n.string("legacy.updateAllRemoteProfiles", defaultValue: "Update All Remote Profiles")) {
                Task { await dailyDriver.profiles.updateAll() }
            }
            .keyboardShortcut("u", modifiers: [.command, .shift])
            .disabled(!engineStore.profiles.contains { $0.sourceKind == .remoteSubscription })
        }

    }
}

extension Notification.Name {
    static let velaRefreshCurrentSection = Notification.Name(
        "dev.yilin.Vela.refreshCurrentSection"
    )
    static let velaFocusSearch = Notification.Name(
        "dev.yilin.Vela.focusSearch"
    )
    static let velaOpenDiagnostics = Notification.Name(
        "dev.yilin.Vela.openDiagnostics"
    )
    static let velaOpenHelpTopic = Notification.Name(
        "dev.yilin.Vela.openHelpTopic"
    )
    static let velaOpenOnboarding = Notification.Name(
        "dev.yilin.Vela.openOnboarding"
    )
}
