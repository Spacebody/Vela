#if DEBUG
import Foundation
import SwiftUI

private enum RulesVisualFixtureFailure: Error {
    case unavailable
}

private struct RulesVisualFixtureAPI: MihomoAPIProviding, Sendable {
    func version() async throws -> MihomoVersion {
        throw RulesVisualFixtureFailure.unavailable
    }

    func configs() async throws -> MihomoConfigs {
        throw RulesVisualFixtureFailure.unavailable
    }

    func patchConfigs(_ patch: MihomoConfigPatch) async throws {
        throw RulesVisualFixtureFailure.unavailable
    }

    func proxies() async throws -> MihomoProxiesResponse {
        throw RulesVisualFixtureFailure.unavailable
    }

    func rules() async throws -> MihomoRulesResponse {
        try await Task.sleep(for: .seconds(60))
        throw RulesVisualFixtureFailure.unavailable
    }
}

@MainActor
private enum RulesVisualFixtureFactory {
    struct Fixture {
        let rules: [ManagedRule]
        let phase: RulesWorkspacePhase
        let selectedRuleID: RuleID?
        let provenance: [RuleID: RuleProvenanceEvidence]
        let lastSuccessfulRefreshAt: Date?
        let error: RulesFailure?
        let pendingMutation: PendingRuleMutation?
    }

    private static let generation = ConfigurationGeneration(
        id: UUID(uuidString: "9F9E7F2C-E5F2-4B7F-BF09-AC8A8B90A701")!
    )

    static func makeModel(
        configuration: VisualUITestConfiguration
    ) -> RulesViewModel {
        RulesViewModel(
            service: RulesService(
                apiClient: RulesVisualFixtureAPI(),
                generation: generation
            ),
            now: { configuration.fixedDate }
        )
    }

    static func fixture(
        for configuration: VisualUITestConfiguration
    ) -> Fixture {
        let populated = managedRules()
        let provenance = provenance(for: populated)
        let lastSuccessful = configuration.fixedDate.addingTimeInterval(-42)
        let selected = configuration.inspector == .open ? populated.first?.id : nil

        switch configuration.state {
        case .loading:
            return Fixture(
                rules: [],
                phase: .loading,
                selectedRuleID: nil,
                provenance: [:],
                lastSuccessfulRefreshAt: nil,
                error: nil,
                pendingMutation: nil
            )
        case .loaded:
            return Fixture(
                rules: populated,
                phase: .loaded,
                selectedRuleID: selected,
                provenance: provenance,
                lastSuccessfulRefreshAt: lastSuccessful,
                error: nil,
                pendingMutation: nil
            )
        case .empty:
            return Fixture(
                rules: [],
                phase: .emptyConfiguration,
                selectedRuleID: nil,
                provenance: [:],
                lastSuccessfulRefreshAt: lastSuccessful,
                error: nil,
                pendingMutation: nil
            )
        case .refreshing:
            return Fixture(
                rules: populated,
                phase: .refreshing,
                selectedRuleID: selected,
                provenance: provenance,
                lastSuccessfulRefreshAt: lastSuccessful,
                error: nil,
                pendingMutation: nil
            )
        case .pendingMutation:
            let target = populated[1]
            return Fixture(
                rules: populated,
                phase: .temporaryMutation,
                selectedRuleID: target.id,
                provenance: provenance,
                lastSuccessfulRefreshAt: lastSuccessful,
                error: nil,
                pendingMutation: PendingRuleMutation(
                    targetRuleID: target.id,
                    currentDisabled: false,
                    requestedDisabled: true,
                    phase: .applying,
                    startedAt: configuration.fixedDate.addingTimeInterval(-1)
                )
            )
        case .partialFailure:
            return Fixture(
                rules: populated,
                phase: .partialFailure,
                selectedRuleID: selected,
                provenance: provenance,
                lastSuccessfulRefreshAt: lastSuccessful,
                error: .fetchFailed,
                pendingMutation: nil
            )
        case .failure:
            return Fixture(
                rules: [],
                phase: .failure,
                selectedRuleID: nil,
                provenance: [:],
                lastSuccessfulRefreshAt: nil,
                error: .fetchFailed,
                pendingMutation: nil
            )
        case .stale:
            return Fixture(
                rules: populated,
                phase: .stale,
                selectedRuleID: selected,
                provenance: provenance,
                lastSuccessfulRefreshAt: configuration.fixedDate.addingTimeInterval(-540),
                error: nil,
                pendingMutation: nil
            )
        case .transitioning:
            return Fixture(
                rules: populated,
                phase: .configurationApplying,
                selectedRuleID: selected,
                provenance: provenance,
                lastSuccessfulRefreshAt: lastSuccessful,
                error: nil,
                pendingMutation: nil
            )
        case .offline, .permissionRequired, .rollbackFailed:
            preconditionFailure("Unregistered Rules visual state")
        }
    }

    private static func managedRules() -> [ManagedRule] {
        guard let data = fixtureJSON.data(using: .utf8),
              let response = try? JSONDecoder().decode(MihomoRulesResponse.self, from: data)
        else {
            preconditionFailure("The deterministic Rules fixture must decode.")
        }
        return response.rules.map { rule in
            ManagedRule(
                id: RuleID(
                    configurationGeneration: generation,
                    originalIndex: rule.index
                ),
                value: rule
            )
        }
    }

    private static func provenance(
        for rules: [ManagedRule]
    ) -> [RuleID: RuleProvenanceEvidence] {
        Dictionary(uniqueKeysWithValues: rules.enumerated().map { offset, rule in
            let evidence: RuleProvenanceEvidence
            switch offset {
            case 0:
                evidence = RuleProvenanceEvidence(
                    sourceLayer: .configuration,
                    sourceDisplayName: "Daily Driver",
                    sourcePointer: "rules[20]",
                    providerDisplayName: nil,
                    providerEntry: nil,
                    providerStatus: nil,
                    confidence: .exact,
                    evidenceGenerationID: generation.id
                )
            case 1:
                evidence = RuleProvenanceEvidence(
                    sourceLayer: .scene,
                    sourceDisplayName: "Work",
                    sourcePointer: "scenes.work.rules[0]",
                    providerDisplayName: nil,
                    providerEntry: nil,
                    providerStatus: nil,
                    confidence: .exact,
                    evidenceGenerationID: generation.id
                )
            case 2:
                evidence = RuleProvenanceEvidence(
                    sourceLayer: .configuration,
                    sourceDisplayName: "Daily Driver",
                    sourcePointer: nil,
                    providerDisplayName: nil,
                    providerEntry: nil,
                    providerStatus: nil,
                    confidence: .ambiguous,
                    evidenceGenerationID: generation.id
                )
            case 3:
                evidence = RuleProvenanceEvidence(
                    sourceLayer: .provider,
                    sourceDisplayName: "Daily Driver",
                    sourcePointer: "rule-providers.work",
                    providerDisplayName: "Work",
                    providerEntry: "work.example.invalid",
                    providerStatus: "Healthy",
                    confidence: .exact,
                    evidenceGenerationID: generation.id
                )
            default:
                evidence = .unavailable(generationID: generation.id)
            }
            return (rule.id, evidence)
        })
    }

    private static let fixtureJSON = #"""
    {
      "rules": [
        {
          "index": 20,
          "type": "DOMAIN-SUFFIX",
          "payload": "dashboard.example.invalid",
          "proxy": "Automatic",
          "size": 1,
          "extra": {
            "disabled": false,
            "hitCount": 248,
            "hitAt": "2026-07-14T09:41:18Z",
            "missCount": 18,
            "missAt": "2026-07-14T09:39:00Z"
          }
        },
        {
          "index": 21,
          "type": "PROCESS-NAME",
          "payload": "Mail",
          "proxy": "Work",
          "size": 1,
          "extra": {
            "disabled": false,
            "hitCount": 72,
            "hitAt": "2026-07-14T09:40:42Z",
            "missCount": 4,
            "missAt": "2026-07-14T09:38:00Z"
          }
        },
        {
          "index": 24,
          "type": "IP-CIDR",
          "payload": "192.0.2.0/24",
          "proxy": "DIRECT",
          "size": 1,
          "extra": {
            "disabled": false,
            "hitCount": 31,
            "hitAt": "2026-07-14T09:36:10Z",
            "missCount": 2,
            "missAt": "2026-07-14T09:35:00Z"
          }
        },
        {
          "index": 35,
          "type": "RULE-SET",
          "payload": "Work",
          "proxy": "Work",
          "size": 120,
          "extra": {
            "disabled": false,
            "hitCount": 19,
            "hitAt": "2026-07-14T09:31:08Z",
            "missCount": 11,
            "missAt": "2026-07-14T09:28:00Z"
          }
        },
        {
          "index": 88,
          "type": "GEOIP",
          "payload": "CN",
          "proxy": "DIRECT",
          "size": 1
        },
        {
          "index": 120,
          "type": "MATCH",
          "payload": "",
          "proxy": "Fallback",
          "size": 1,
          "extra": {
            "disabled": false,
            "hitCount": 8,
            "hitAt": "2026-07-14T09:30:00Z",
            "missCount": 0
          }
        }
      ]
    }
    """#
}

struct RulesVisualFixtureView: View {
    let configuration: VisualUITestConfiguration
    @State private var viewModel: RulesViewModel

    init(configuration: VisualUITestConfiguration) {
        self.configuration = configuration
        _viewModel = State(
            initialValue: RulesVisualFixtureFactory.makeModel(
                configuration: configuration
            )
        )
    }

    var body: some View {
        RulesView(
            viewModel: viewModel,
            runtimeAvailability: runtimeAvailability
        )
            .environment(\.velaAccessibilityOverrides, accessibilityOverrides)
            .task(id: configuration.fixtureID) {
                let fixture = RulesVisualFixtureFactory.fixture(for: configuration)
                await viewModel.installVisualFixture(
                    rules: fixture.rules,
                    phase: fixture.phase,
                    selectedRuleID: fixture.selectedRuleID,
                    provenance: fixture.provenance,
                    lastSuccessfulRefreshAt: fixture.lastSuccessfulRefreshAt,
                    error: fixture.error,
                    pendingMutation: fixture.pendingMutation
                )
            }
            .overlay(alignment: .topLeading) {
                if viewModel.isDebugFixtureReady {
                    VisualReadyMarker(fixtureID: configuration.fixtureID)
                }
                if accessibilityOverrides.reduceMotion == true {
                    VisualSurfaceMarker(
                        identifier: "rules.accessibility.reduceMotion",
                        label: "Rules Reduce Motion"
                    )
                }
                if accessibilityOverrides.increasedContrast == true {
                    VisualSurfaceMarker(
                        identifier: "rules.accessibility.increasedContrast",
                        label: "Rules Increase Contrast"
                    )
                }
            }
    }

    private var accessibilityOverrides: VelaAccessibilityOverrides {
        VelaAccessibilityOverrides(
            reduceMotion: launchFlag("-VelaRulesReduceMotion"),
            increasedContrast: launchFlag("-VelaRulesIncreaseContrast")
        )
    }

    private var runtimeAvailability: RulesRuntimeAvailability {
        switch launchValue("-VelaRulesRecoveryReason") {
        case RulesRecoveryReason.mihomoStopped.rawValue:
            RulesRuntimeAvailability(
                isMihomoRunning: false,
                isControllerConnected: false,
                hasConfiguration: true
            )
        case RulesRecoveryReason.controllerDisconnected.rawValue:
            RulesRuntimeAvailability(
                isMihomoRunning: true,
                isControllerConnected: false,
                hasConfiguration: true
            )
        case RulesRecoveryReason.emptyConfiguration.rawValue:
            RulesRuntimeAvailability(
                isMihomoRunning: false,
                isControllerConnected: false,
                hasConfiguration: false
            )
        default:
            .available
        }
    }

    private func launchValue(_ key: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.lastIndex(of: key) else { return nil }
        let valueIndex = arguments.index(after: index)
        guard valueIndex < arguments.endIndex else { return nil }
        return arguments[valueIndex]
    }

    private func launchFlag(_ key: String) -> Bool? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.lastIndex(of: key) else { return nil }
        let valueIndex = arguments.index(after: index)
        guard valueIndex < arguments.endIndex else { return nil }
        return switch arguments[valueIndex].lowercased() {
        case "yes", "true", "1": true
        case "no", "false", "0": false
        default: nil
        }
    }
}
#endif
