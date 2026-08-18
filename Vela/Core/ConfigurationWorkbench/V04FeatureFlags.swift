import Foundation

/// Development gates for the staged V0.4 rollout.
///
/// The compiler is enabled because it preserves V0.3 runtime semantics. Layer
/// cutover remains disabled until the Workbench editor and runtime transaction
/// both use `ConfigurationLayerStore`; running migration before that point would
/// create two writable sources of truth.
nonisolated struct V04FeatureFlags: Codable, Equatable, Sendable {
    var deterministicCompilerEnabled: Bool
    var configurationLayerCutoverEnabled: Bool
    var automaticScenesEnabled: Bool
    var appIntentMutationsEnabled: Bool
    var automationSocketEnabled: Bool

    static let sprintOne = V04FeatureFlags(
        deterministicCompilerEnabled: true,
        configurationLayerCutoverEnabled: false,
        automaticScenesEnabled: false,
        appIntentMutationsEnabled: false,
        automationSocketEnabled: false
    )
}
