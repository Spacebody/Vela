import Foundation
import OSLog

nonisolated enum VelaSignpostCategory: String, CaseIterable, Codable, Sendable {
    case app = "App"
    case engine = "Engine"
    case configuration = "Configuration"
    case transitions = "Transitions"
    case updates = "Updates"
    case data = "Data"
    case support = "Support"
}

/// Stable, bounded interval names. No API accepts a caller-provided signpost name.
nonisolated enum VelaSignpostInterval: String, CaseIterable, Codable, Sendable {
    case appLaunchToFirstMeaningfulRender = "AppLaunchToFirstMeaningfulRender"
    case engineStart = "EngineStart"
    case engineStop = "EngineStop"
    case systemProxyApply = "SystemProxyApply"
    case systemProxyRestore = "SystemProxyRestore"
    case tunTransition = "TUNTransition"
    case helperHandshake = "HelperHandshake"
    case configurationCompile = "ConfigurationCompile"
    case mihomoConfigurationTest = "MihomoConfigurationTest"
    case profileUpdateTransaction = "ProfileUpdateTransaction"
    case sceneActivation = "SceneActivation"
    case workbenchSave = "WorkbenchSave"
    case connectionsDecodeApply = "ConnectionsDecodeApply"
    case rulesDecodeFilter = "RulesDecodeFilter"
    case appUpdatePreparationRecovery = "AppUpdatePreparationRecovery"
    case coreActivation = "CoreActivation"
    case coreProbation = "CoreProbation"
    case coreRollback = "CoreRollback"
    case helpSearch = "HelpSearch"
    case supportBundleRedactionExport = "SupportBundleRedactionExport"

    var category: VelaSignpostCategory {
        switch self {
        case .appLaunchToFirstMeaningfulRender:
            .app
        case .engineStart, .engineStop:
            .engine
        case .configurationCompile, .mihomoConfigurationTest, .workbenchSave:
            .configuration
        case .systemProxyApply, .systemProxyRestore, .tunTransition,
             .helperHandshake, .profileUpdateTransaction, .sceneActivation:
            .transitions
        case .appUpdatePreparationRecovery, .coreActivation, .coreProbation, .coreRollback:
            .updates
        case .connectionsDecodeApply, .rulesDecodeFilter:
            .data
        case .helpSearch, .supportBundleRedactionExport:
            .support
        }
    }
}

nonisolated struct VelaSignpostToken: Hashable, Sendable {
    let id: UUID
    let interval: VelaSignpostInterval

    init(id: UUID = UUID(), interval: VelaSignpostInterval) {
        self.id = id
        self.interval = interval
    }
}

nonisolated enum VelaSignpostOutcome: String, CaseIterable, Codable, Sendable {
    case succeeded
    case failed
    case cancelled
}

nonisolated protocol VelaSignpostRecording: Sendable {
    func begin(_ interval: VelaSignpostInterval) async -> VelaSignpostToken
    func end(_ token: VelaSignpostToken, outcome: VelaSignpostOutcome) async
}

/// Production recorder. Interval state never leaves this actor's isolation domain.
actor LiveVelaSignpostRecorder: VelaSignpostRecording {
    static let subsystem = "dev.yilin.Vela"

    private struct ActiveInterval {
        let interval: VelaSignpostInterval
        let state: OSSignpostIntervalState
    }

    private let app = OSSignposter(subsystem: subsystem, category: VelaSignpostCategory.app.rawValue)
    private let engine = OSSignposter(
        subsystem: subsystem,
        category: VelaSignpostCategory.engine.rawValue
    )
    private let configuration = OSSignposter(
        subsystem: subsystem,
        category: VelaSignpostCategory.configuration.rawValue
    )
    private let transitions = OSSignposter(
        subsystem: subsystem,
        category: VelaSignpostCategory.transitions.rawValue
    )
    private let updates = OSSignposter(
        subsystem: subsystem,
        category: VelaSignpostCategory.updates.rawValue
    )
    private let data = OSSignposter(subsystem: subsystem, category: VelaSignpostCategory.data.rawValue)
    private let support = OSSignposter(
        subsystem: subsystem,
        category: VelaSignpostCategory.support.rawValue
    )

    private var active: [UUID: ActiveInterval] = [:]

    func begin(_ interval: VelaSignpostInterval) -> VelaSignpostToken {
        let token = VelaSignpostToken(id: UUID(), interval: interval)
        let state = beginInterval(interval)
        active[token.id] = ActiveInterval(interval: interval, state: state)
        return token
    }

    func end(_ token: VelaSignpostToken, outcome _: VelaSignpostOutcome) {
        guard let interval = active.removeValue(forKey: token.id),
              interval.interval == token.interval
        else { return }
        endInterval(interval.interval, state: interval.state)
    }

    private func signposter(for category: VelaSignpostCategory) -> OSSignposter {
        switch category {
        case .app: app
        case .engine: engine
        case .configuration: configuration
        case .transitions: transitions
        case .updates: updates
        case .data: data
        case .support: support
        }
    }

    private func beginInterval(_ interval: VelaSignpostInterval) -> OSSignpostIntervalState {
        let signposter = signposter(for: interval.category)
        return switch interval {
        case .appLaunchToFirstMeaningfulRender:
            signposter.beginInterval("AppLaunchToFirstMeaningfulRender")
        case .engineStart:
            signposter.beginInterval("EngineStart")
        case .engineStop:
            signposter.beginInterval("EngineStop")
        case .systemProxyApply:
            signposter.beginInterval("SystemProxyApply")
        case .systemProxyRestore:
            signposter.beginInterval("SystemProxyRestore")
        case .tunTransition:
            signposter.beginInterval("TUNTransition")
        case .helperHandshake:
            signposter.beginInterval("HelperHandshake")
        case .configurationCompile:
            signposter.beginInterval("ConfigurationCompile")
        case .mihomoConfigurationTest:
            signposter.beginInterval("MihomoConfigurationTest")
        case .profileUpdateTransaction:
            signposter.beginInterval("ProfileUpdateTransaction")
        case .sceneActivation:
            signposter.beginInterval("SceneActivation")
        case .workbenchSave:
            signposter.beginInterval("WorkbenchSave")
        case .connectionsDecodeApply:
            signposter.beginInterval("ConnectionsDecodeApply")
        case .rulesDecodeFilter:
            signposter.beginInterval("RulesDecodeFilter")
        case .appUpdatePreparationRecovery:
            signposter.beginInterval("AppUpdatePreparationRecovery")
        case .coreActivation:
            signposter.beginInterval("CoreActivation")
        case .coreProbation:
            signposter.beginInterval("CoreProbation")
        case .coreRollback:
            signposter.beginInterval("CoreRollback")
        case .helpSearch:
            signposter.beginInterval("HelpSearch")
        case .supportBundleRedactionExport:
            signposter.beginInterval("SupportBundleRedactionExport")
        }
    }

    private func endInterval(
        _ interval: VelaSignpostInterval,
        state: OSSignpostIntervalState
    ) {
        let signposter = signposter(for: interval.category)
        switch interval {
        case .appLaunchToFirstMeaningfulRender:
            signposter.endInterval("AppLaunchToFirstMeaningfulRender", state)
        case .engineStart:
            signposter.endInterval("EngineStart", state)
        case .engineStop:
            signposter.endInterval("EngineStop", state)
        case .systemProxyApply:
            signposter.endInterval("SystemProxyApply", state)
        case .systemProxyRestore:
            signposter.endInterval("SystemProxyRestore", state)
        case .tunTransition:
            signposter.endInterval("TUNTransition", state)
        case .helperHandshake:
            signposter.endInterval("HelperHandshake", state)
        case .configurationCompile:
            signposter.endInterval("ConfigurationCompile", state)
        case .mihomoConfigurationTest:
            signposter.endInterval("MihomoConfigurationTest", state)
        case .profileUpdateTransaction:
            signposter.endInterval("ProfileUpdateTransaction", state)
        case .sceneActivation:
            signposter.endInterval("SceneActivation", state)
        case .workbenchSave:
            signposter.endInterval("WorkbenchSave", state)
        case .connectionsDecodeApply:
            signposter.endInterval("ConnectionsDecodeApply", state)
        case .rulesDecodeFilter:
            signposter.endInterval("RulesDecodeFilter", state)
        case .appUpdatePreparationRecovery:
            signposter.endInterval("AppUpdatePreparationRecovery", state)
        case .coreActivation:
            signposter.endInterval("CoreActivation", state)
        case .coreProbation:
            signposter.endInterval("CoreProbation", state)
        case .coreRollback:
            signposter.endInterval("CoreRollback", state)
        case .helpSearch:
            signposter.endInterval("HelpSearch", state)
        case .supportBundleRedactionExport:
            signposter.endInterval("SupportBundleRedactionExport", state)
        }
    }
}

nonisolated enum VelaSignpostScope {
    /// Closes every interval exactly once on success, error, or cooperative cancellation.
    static func measure<Value: Sendable>(
        _ interval: VelaSignpostInterval,
        recorder: any VelaSignpostRecording,
        operation: @Sendable () async throws -> Value
    ) async throws -> Value {
        let token = await recorder.begin(interval)
        do {
            try Task.checkCancellation()
            let value = try await operation()
            try Task.checkCancellation()
            await recorder.end(token, outcome: .succeeded)
            return value
        } catch is CancellationError {
            await recorder.end(token, outcome: .cancelled)
            throw CancellationError()
        } catch {
            await recorder.end(token, outcome: .failed)
            throw error
        }
    }
}
