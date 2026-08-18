import Foundation

nonisolated enum SupportIssueCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case cannotConnect
    case systemProxy
    case tun
    case privilegedComponent
    case subscription
    case configuration
    case scenes
    case appUpdate
    case coreUpdate
    case cliAndShortcuts
    case performance
    case crash

    var id: Self { self }

    var localizationKey: String {
        "support.category.\(rawValue)"
    }

    var defaultTitle: String {
        switch self {
        case .cannotConnect: "Cannot Connect"
        case .systemProxy: "System Proxy"
        case .tun: "TUN"
        case .privilegedComponent: "Privileged Component"
        case .subscription: "Subscription"
        case .configuration: "Configuration"
        case .scenes: "Scenes"
        case .appUpdate: "App Update"
        case .coreUpdate: "Core Update"
        case .cliAndShortcuts: "CLI and Shortcuts"
        case .performance: "Performance"
        case .crash: "Crash"
        }
    }

    var helpTopicRawValue: String {
        switch self {
        case .systemProxy, .tun, .privilegedComponent:
            "system-proxy-vs-tun"
        case .subscription, .configuration:
            "configurations-and-subscriptions"
        case .scenes:
            "scenes-and-automation"
        case .appUpdate, .coreUpdate:
            "app-and-core-updates"
        case .cliAndShortcuts:
            "cli-and-shortcuts"
        case .cannotConnect, .performance, .crash:
            "troubleshooting-network"
        }
    }
}

nonisolated enum SupportCheckStatus: String, Codable, Sendable {
    case healthy
    case warning
    case failed
    case unavailable
}

nonisolated struct SupportCheckResult: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let detail: String
    let status: SupportCheckStatus
    let stableCode: String?

    init(
        id: String,
        title: String,
        detail: String,
        status: SupportCheckStatus,
        stableCode: String? = nil
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.status = status
        self.stableCode = stableCode
    }
}

nonisolated enum SupportRepairActionID: String, Codable, CaseIterable, Identifiable, Sendable {
    case refreshHealth
    case validateConfiguration
    case reconnectPrivilegedComponent
    case restoreSystemProxy
    case stopVelaNetworkServices
    case refreshSubscriptions
    case checkAppUpdate
    case checkCoreCatalog

    var id: Self { self }

    static func allowed(for category: SupportIssueCategory) -> [Self] {
        switch category {
        case .cannotConnect:
            [.refreshHealth, .validateConfiguration, .restoreSystemProxy]
        case .systemProxy:
            [.refreshHealth, .restoreSystemProxy]
        case .tun:
            [.refreshHealth, .reconnectPrivilegedComponent, .restoreSystemProxy]
        case .privilegedComponent:
            [.reconnectPrivilegedComponent, .refreshHealth]
        case .subscription:
            [.refreshSubscriptions, .validateConfiguration]
        case .configuration:
            [.validateConfiguration, .refreshHealth]
        case .scenes:
            [.refreshHealth]
        case .appUpdate:
            [.checkAppUpdate]
        case .coreUpdate:
            [.checkCoreCatalog, .refreshHealth]
        case .cliAndShortcuts:
            [.refreshHealth]
        case .performance:
            [.refreshHealth]
        case .crash:
            [.refreshHealth, .stopVelaNetworkServices]
        }
    }

    var defaultTitle: String {
        switch self {
        case .refreshHealth: "Refresh Health"
        case .validateConfiguration: "Validate Configuration"
        case .reconnectPrivilegedComponent: "Reconnect Privileged Component"
        case .restoreSystemProxy: "Restore System Proxy Mode"
        case .stopVelaNetworkServices: "Stop Vela Network Services"
        case .refreshSubscriptions: "Refresh Subscriptions"
        case .checkAppUpdate: "Check for App Updates"
        case .checkCoreCatalog: "Check Core Catalog"
        }
    }
}

nonisolated enum GuidedSupportPhase: String, Codable, Sendable {
    case chooseCategory
    case runningDiagnostics
    case results
  case confirmingRepair
    case repairing
    case verifying
  case resolved
  case unresolved
  case permissionBlocked
    case readyToExport
}

nonisolated enum SupportBundlePreparationStage: String, Codable, CaseIterable, Sendable {
  case collecting
  case redacting
  case validating
  case ready
}

nonisolated struct SupportBundleAppIdentity: Codable, Equatable, Sendable {
    let version: String
    let build: Int
    let channel: String
    let architecture: String
}

nonisolated struct SupportBundleSystemSummary: Codable, Equatable, Sendable {
    let macOSVersion: String
    let architecture: String
    let locale: String
}

nonisolated struct SupportBundleSnapshot: Codable, Equatable, Sendable {
    let app: SupportBundleAppIdentity
    let system: SupportBundleSystemSummary
    let issueCategory: SupportIssueCategory
    let diagnostics: [SupportCheckResult]
    let appUpdateSummary: String?
    let coreUpdateSummary: String?
    let stableErrorCodes: [String]
}

nonisolated struct SupportBundleOptions: Equatable, Sendable {
    var includeRecentAppLogs = false
    var includeCrashSummary = false
    var includeReliabilityEvidence = false
    var recentAppLogs: String?
    var crashSummary: String?
    var reliabilityEvidence: String?
}

nonisolated struct SupportBundleManifest: Codable, Equatable, Sendable {
    struct FileEntry: Codable, Equatable, Sendable {
        let path: String
        let size: Int
        let sha256: String
    }

    let schemaVersion: Int
    let createdAt: Date
    let app: SupportBundleAppIdentity
    let redactionVersion: Int
    let files: [FileEntry]
}

nonisolated struct SupportBundlePreview: Identifiable, Equatable, Sendable {
    let id: UUID
    let stagingDirectory: URL
    let archiveURL: URL
    let manifest: SupportBundleManifest
    let archiveByteCount: Int
    let includedOptionalLogs: Bool
    let includedCrashSummary: Bool
    let includedReliabilityEvidence: Bool
}

nonisolated enum SupportBundleError: Error, Equatable, Sendable {
    case invalidRelativePath(String)
    case tooManyFiles(Int)
    case payloadTooLarge(Int)
    case archiveTooLarge(Int)
    case sensitiveDataDetected([SupportSecretKind])
    case invalidUTF8
    case unsafeStagingDirectory
    case archiveUnavailable
    case destinationIsDirectory
    case couldNotCreateBundle(String)
}

extension SupportBundleError: LocalizedError {
    var errorDescription: String? {
        switch self {
    case .invalidRelativePath(let path):
            "The support bundle contains an invalid path: \(path)"
    case .tooManyFiles(let count):
            "The support bundle contains \(count) files; the limit is 100."
    case .payloadTooLarge(let bytes), .archiveTooLarge(let bytes):
            "The support bundle is \(bytes) bytes; the limit is 10 MiB."
        case .sensitiveDataDetected:
            "Sensitive data remained after redaction, so export was blocked."
        case .invalidUTF8:
            "Optional support text is not valid UTF-8."
        case .unsafeStagingDirectory:
            "The support bundle staging directory is unsafe."
        case .archiveUnavailable:
            "The prepared support archive is unavailable."
        case .destinationIsDirectory:
            "The selected support bundle destination is a directory."
    case .couldNotCreateBundle(let reason):
            "The support bundle could not be created: \(reason)"
        }
    }
}
