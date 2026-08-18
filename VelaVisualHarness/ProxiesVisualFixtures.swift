#if DEBUG
import Foundation
import SwiftUI

nonisolated enum ProxiesVisualFixtureFactory {
    static func snapshot(
        for configuration: VisualUITestConfiguration,
        selectedGroupID: ProxiesGroupID?
    ) -> ProxiesPresentationSnapshot {
        let state = workspaceState(configuration.state)
        let catalog = catalog(
            hasRows: state.hasRows,
            updatedAt: configuration.fixedDate.addingTimeInterval(
                state == .stale ? -720 : -120
            )
        )
        let operation: ProxyOperationState? = switch state {
        case .refreshing:
            .refreshing
        case .pendingMutation:
            pendingOperation(in: catalog)
        case .loading, .loaded, .stale, .empty, .fullFailure,
             .partialFailure, .offline:
            nil
        }
        let errorSummary: String? = switch state {
        case .fullFailure:
            "Controller returned an invalid proxy catalog."
        case .partialFailure:
            "Provider Airport A timed out; runtime groups remain available."
        case .stale:
            "The last refresh could not be confirmed."
        default:
            nil
        }

        return ProxiesPresentationFactory.make(
            catalog: catalog,
            controllerState: state == .offline ? .disconnected : .connected,
            isLoading: state == .loading || state == .refreshing,
            operation: operation,
            delayStates: delayStates(in: catalog),
            selectedGroupID: selectedGroupID,
            errorSummary: errorSummary,
            referenceDate: configuration.fixedDate,
            stateOverride: state
        )
    }

    private static func workspaceState(
        _ state: VisualUITestConfiguration.State
    ) -> ProxiesWorkspaceState {
        switch state {
        case .loading:
            .loading
        case .loaded:
            .loaded
        case .empty:
            .empty
        case .refreshing:
            .refreshing
        case .pendingMutation, .transitioning:
            .pendingMutation
        case .partialFailure, .rollbackFailed:
            .partialFailure
        case .failure, .permissionRequired:
            .fullFailure
        case .offline:
            .offline
        case .stale:
            .stale
        }
    }

    private static func catalog(
        hasRows: Bool,
        updatedAt: Date
    ) -> ProxyCatalog {
        guard hasRows else {
            return ProxyCatalog(groups: [], updatedAt: updatedAt)
        }
        guard let data = fixtureJSON.data(using: .utf8),
            let response = try? JSONDecoder().decode(
                MihomoProxiesResponse.self,
                from: data
            )
        else {
            preconditionFailure("The deterministic Proxies fixture must decode.")
        }
        return ProxyCatalog(
            runtimeResponse: response,
            providerResponse: .empty,
            updatedAt: updatedAt
        )
    }

    private static func pendingOperation(
        in catalog: ProxyCatalog
    ) -> ProxyOperationState? {
        guard let group = catalog.group(named: "Auto Select"),
            let requested = group.nodes.first(where: { $0.name == "Osaka · JP" })
        else { return nil }
        return .selecting(groupName: group.name, proxyID: requested.id)
    }

    private static func delayStates(
        in catalog: ProxyCatalog
    ) -> [ProxiesDelayKey: ProxyDelayState] {
        var result: [ProxiesDelayKey: ProxyDelayState] = [:]
        for group in catalog.groups {
            let groupID = ProxiesGroupID(rawValue: group.name)
            for node in group.nodes {
                guard let delay = node.delay.milliseconds else { continue }
                result[
                    ProxiesDelayKey(groupID: groupID, nodeID: node.id)
                ] = .measured(milliseconds: delay)
            }
        }
        return result
    }

    private static let fixtureJSON = #"""
    {
      "proxies": {
        "Auto Select": {
          "name": "Auto Select",
          "type": "Selector",
          "now": "Tokyo · JP",
          "all": ["Tokyo · JP", "Osaka · JP", "Singapore · SG", "Hong Kong · HK", "Taipei · TW", "Los Angeles · US", "New York · US", "London · GB", "Frankfurt · DE", "Sydney · AU", "Paris · FR"],
          "history": []
        },
        "Global": {
          "name": "Global",
          "type": "Selector",
          "now": "Tokyo · JP",
          "all": ["Tokyo · JP", "Osaka · JP", "Singapore · SG", "Hong Kong · HK", "Taipei · TW", "Los Angeles · US", "New York · US", "London · GB", "Frankfurt · DE", "Sydney · AU", "Paris · FR", "Direct"],
          "history": []
        },
        "Streaming": {
          "name": "Streaming",
          "type": "URLTest",
          "now": "Osaka · JP",
          "all": ["Tokyo · JP", "Osaka · JP", "Singapore · SG", "Hong Kong · HK", "Los Angeles · US", "London · GB", "Sydney · AU", "Paris · FR"],
          "history": []
        },
        "Domestic": {
          "name": "Domestic",
          "type": "Selector",
          "now": "Direct",
          "all": ["Direct", "Hong Kong · HK", "Taipei · TW", "Singapore · SG", "Tokyo · JP", "Osaka · JP", "Los Angeles · US", "New York · US", "London · GB", "Frankfurt · DE"],
          "history": []
        },
        "Direct": {
          "name": "Direct",
          "type": "Selector",
          "now": "DIRECT",
          "all": ["DIRECT"],
          "history": []
        },
        "Reject": {
          "name": "Reject",
          "type": "Selector",
          "now": "REJECT",
          "all": ["REJECT"],
          "history": []
        },
        "DIRECT": {
          "name": "DIRECT",
          "type": "Direct",
          "alive": true,
          "history": []
        },
        "REJECT": {
          "name": "REJECT",
          "type": "Reject",
          "alive": true,
          "history": []
        },
        "Tokyo · JP": {
          "name": "Tokyo · JP",
          "type": "Shadowsocks",
          "alive": true,
          "history": [{"time": "2026-07-14T09:40:30Z", "delay": 42}]
        },
        "Osaka · JP": {
          "name": "Osaka · JP",
          "type": "Shadowsocks",
          "alive": true,
          "history": [{"time": "2026-07-14T09:40:30Z", "delay": 58}]
        },
        "Singapore · SG": {
          "name": "Singapore · SG",
          "type": "VLESS",
          "alive": true,
          "history": [{"time": "2026-07-14T09:40:30Z", "delay": 63}]
        },
        "Hong Kong · HK": {
          "name": "Hong Kong · HK",
          "type": "VLESS",
          "alive": true,
          "history": [{"time": "2026-07-14T09:40:30Z", "delay": 72}]
        },
        "Taipei · TW": {
          "name": "Taipei · TW",
          "type": "Shadowsocks",
          "alive": true,
          "history": [{"time": "2026-07-14T09:40:30Z", "delay": 83}]
        },
        "Los Angeles · US": {
          "name": "Los Angeles · US",
          "type": "VLESS",
          "alive": true,
          "history": [{"time": "2026-07-14T09:40:30Z", "delay": 145}]
        },
        "New York · US": {
          "name": "New York · US",
          "type": "VLESS",
          "alive": true,
          "history": [{"time": "2026-07-14T09:40:30Z", "delay": 156}]
        },
        "London · GB": {
          "name": "London · GB",
          "type": "Shadowsocks",
          "alive": true,
          "history": [{"time": "2026-07-14T09:40:30Z", "delay": 167}]
        },
        "Frankfurt · DE": {
          "name": "Frankfurt · DE",
          "type": "VLESS",
          "alive": true,
          "history": [{"time": "2026-07-14T09:40:30Z", "delay": 178}]
        },
        "Sydney · AU": {
          "name": "Sydney · AU",
          "type": "Shadowsocks",
          "alive": true,
          "history": [{"time": "2026-07-14T09:40:30Z", "delay": 187}]
        },
        "Paris · FR": {
          "name": "Paris · FR",
          "type": "VLESS",
          "alive": true,
          "history": [{"time": "2026-07-14T09:40:30Z", "delay": 201}]
        }
      }
    }
    """#
}

nonisolated private extension ProxiesWorkspaceState {
    var hasRows: Bool {
        switch self {
        case .loaded, .refreshing, .pendingMutation, .stale, .partialFailure:
            true
        case .loading, .empty, .fullFailure, .offline:
            false
        }
    }
}

struct ProxiesVisualFixtureView: View {
    let configuration: VisualUITestConfiguration

    @State private var selectedGroupID: ProxiesGroupID?
    @State private var showsInspector: Bool

    init(configuration: VisualUITestConfiguration) {
        self.configuration = configuration
        _showsInspector = State(initialValue: configuration.inspector == .open)
    }

    var body: some View {
        ProxiesLiquidGlassDashboardView(
            snapshot: ProxiesVisualFixtureFactory.snapshot(
                for: configuration,
                selectedGroupID: selectedGroupID
            ),
            runtimeMode: .rule,
            isTrafficConnected: configuration.state != .offline,
            selectedGroupID: $selectedGroupID,
            showsInspector: $showsInspector,
            action: { _ in }
        )
        .environment(\.velaAccessibilityOverrides, accessibilityOverrides)
        .overlay(alignment: .topLeading) {
            VisualReadyMarker(fixtureID: configuration.fixtureID)
            if accessibilityOverrides.reduceMotion == true {
                VisualSurfaceMarker(
                    identifier: "proxies.accessibility.reduceMotion",
                    label: "Proxies Reduce Motion"
                )
            }
            if accessibilityOverrides.increasedContrast == true {
                VisualSurfaceMarker(
                    identifier: "proxies.accessibility.increasedContrast",
                    label: "Proxies Increase Contrast"
                )
            }
        }
    }

    private var accessibilityOverrides: VelaAccessibilityOverrides {
        VelaAccessibilityOverrides(
            reduceMotion: launchFlag("-VelaProxiesReduceMotion"),
            increasedContrast: launchFlag("-VelaProxiesIncreaseContrast")
        )
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
