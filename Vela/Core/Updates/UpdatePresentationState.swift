import Foundation
import Observation

nonisolated enum UpdateLifecycleStatus: Equatable, Sendable {
    case unavailable(reason: String)
    case idle
    case checking
    case updateAvailable(version: String, build: String)
    case downloaded(version: String, build: String)
    case preparing
    case readyForInstaller
    case recoveryRequired(phase: String, reason: String)
    case failed(code: String, message: String)

    var title: String {
        switch self {
        case .unavailable: "Configuration Required"
        case .idle: "Ready"
        case .checking: "Checking"
        case .updateAvailable: "Update Available"
        case .downloaded: "Downloaded"
        case .preparing: "Preparing to Update"
        case .readyForInstaller: "Ready to Install"
        case .recoveryRequired: "Recovery Required"
        case .failed: "Update Failed"
        }
    }

    var detail: String? {
        switch self {
        case let .unavailable(reason): reason
        case .idle: nil
        case .checking: "Vela is securely checking the signed update feed."
        case let .updateAvailable(version, build): "Version \(version) (\(build))"
        case let .downloaded(version, build): "Version \(version) (\(build)) is ready."
        case .preparing: "Network services are moving to a verified safe stop."
        case .readyForInstaller: "The update installer may continue."
        case let .recoveryRequired(phase, reason): "\(phase): \(reason)"
        case let .failed(code, message): "\(code): \(message)"
        }
    }
}

nonisolated struct UpdateCheckSummary: Equatable, Sendable {
    let occurredAt: Date
    let code: String
    let message: String

    init(occurredAt: Date = .now, code: String, message: String) {
        self.occurredAt = occurredAt
        self.code = code
        self.message = DiagnosticTextSanitizer.redact(message)
    }
}

@MainActor
@Observable
final class UpdatePresentationState {
    let currentVersion: String
    let currentBuild: String
    let sparkleVersion = "2.9.4"

    private(set) var channel: ReleaseChannel
    private(set) var lifecycle: UpdateLifecycleStatus
    private(set) var canCheckForUpdates = false
    private(set) var automaticallyChecksForUpdates = false
    private(set) var automaticallyDownloadsUpdates = false
    private(set) var allowsAutomaticUpdates = false
    private(set) var updateCheckInterval: TimeInterval = 0
    private(set) var lastCheckAt: Date?
    private(set) var lastResult: UpdateCheckSummary?
    private(set) var releaseNotesURL: URL?

    init(
        currentVersion: String,
        currentBuild: String,
        channel: ReleaseChannel,
        lifecycle: UpdateLifecycleStatus = .idle
    ) {
        self.currentVersion = currentVersion
        self.currentBuild = currentBuild
        self.channel = channel
        self.lifecycle = lifecycle
    }

    func setChannel(_ channel: ReleaseChannel) {
        self.channel = channel
    }

    func setLifecycle(_ lifecycle: UpdateLifecycleStatus) {
        self.lifecycle = lifecycle
    }

    func synchronizeSettings(
        canCheckForUpdates: Bool,
        automaticallyChecksForUpdates: Bool,
        automaticallyDownloadsUpdates: Bool,
        allowsAutomaticUpdates: Bool,
        updateCheckInterval: TimeInterval,
        lastCheckAt: Date?
    ) {
        self.canCheckForUpdates = canCheckForUpdates
        self.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        self.automaticallyDownloadsUpdates = automaticallyDownloadsUpdates
        self.allowsAutomaticUpdates = allowsAutomaticUpdates
        self.updateCheckInterval = updateCheckInterval
        self.lastCheckAt = lastCheckAt
    }

    func recordResult(_ summary: UpdateCheckSummary) {
        lastResult = summary
    }

    func setReleaseNotesURL(_ url: URL?) {
        guard url?.scheme?.lowercased() == "https" || url == nil else { return }
        releaseNotesURL = url
    }
}
