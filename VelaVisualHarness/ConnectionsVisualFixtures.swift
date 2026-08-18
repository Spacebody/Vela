#if DEBUG
import Foundation
import SwiftUI

private enum ConnectionsVisualFixtureFailure: Error {
    case unavailable
}

private struct ConnectionsVisualFixtureAPI: MihomoAPIProviding, Sendable {
    func version() async throws -> MihomoVersion {
        throw ConnectionsVisualFixtureFailure.unavailable
    }

    func configs() async throws -> MihomoConfigs {
        throw ConnectionsVisualFixtureFailure.unavailable
    }

    func patchConfigs(_ patch: MihomoConfigPatch) async throws {
        throw ConnectionsVisualFixtureFailure.unavailable
    }

    func proxies() async throws -> MihomoProxiesResponse {
        throw ConnectionsVisualFixtureFailure.unavailable
    }

    func connections() async throws -> ConnectionsSnapshot {
        try await Task.sleep(for: .milliseconds(1_500))
        throw ConnectionsVisualFixtureFailure.unavailable
    }
}

private struct ConnectionsVisualFixtureStream: MihomoConnectionsStreaming, Sendable {
    func snapshots(
        generation: ConfigurationGeneration
    ) -> AsyncThrowingStream<ConnectionsStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    func stop() async {}
}

@MainActor
private enum ConnectionsVisualFixtureFactory {
    struct Fixture {
        let snapshot: ConnectionsSnapshot?
        let phase: ConnectionsWorkspacePhase
        let selectedConnectionID: String?
        let lastSuccessfulRefreshAt: Date?
        let error: ConnectionsFailure?
        let pendingMutationPhase: ConnectionMutationPhase?
    }

    static func makeModel(
        configuration: VisualUITestConfiguration
    ) -> ConnectionsViewModel {
        ConnectionsViewModel(
            service: ConnectionsService(apiClient: ConnectionsVisualFixtureAPI()),
            stream: ConnectionsVisualFixtureStream(),
            now: { configuration.fixedDate },
            localeIdentifier: { configuration.localeIdentifier.rawValue }
        )
    }

    static func fixture(
        for configuration: VisualUITestConfiguration
    ) -> Fixture {
        let populated = decodedSnapshot()
        let empty = ConnectionsSnapshot(
            downloadTotal: 0,
            uploadTotal: 0,
            connections: [],
            memory: 68_157_440
        )
        let lastSuccessful = configuration.fixedDate.addingTimeInterval(-42)
        let selected = configuration.inspector == .open ? "connection-browser" : nil

        switch configuration.state {
        case .loading:
            return Fixture(
                snapshot: nil,
                phase: .loading,
                selectedConnectionID: nil,
                lastSuccessfulRefreshAt: nil,
                error: nil,
                pendingMutationPhase: nil
            )
        case .loaded:
            return Fixture(
                snapshot: populated,
                phase: .loaded,
                selectedConnectionID: selected,
                lastSuccessfulRefreshAt: lastSuccessful,
                error: nil,
                pendingMutationPhase: nil
            )
        case .empty:
            return Fixture(
                snapshot: empty,
                phase: .empty,
                selectedConnectionID: nil,
                lastSuccessfulRefreshAt: lastSuccessful,
                error: nil,
                pendingMutationPhase: nil
            )
        case .refreshing:
            return Fixture(
                snapshot: populated,
                phase: .refreshing,
                selectedConnectionID: selected,
                lastSuccessfulRefreshAt: lastSuccessful,
                error: nil,
                pendingMutationPhase: nil
            )
        case .pendingMutation:
            return Fixture(
                snapshot: populated,
                phase: .pendingMutation,
                selectedConnectionID: "connection-browser",
                lastSuccessfulRefreshAt: lastSuccessful,
                error: nil,
                pendingMutationPhase: .closing
            )
        case .partialFailure:
            return Fixture(
                snapshot: populated,
                phase: .partialFailure,
                selectedConnectionID: selected,
                lastSuccessfulRefreshAt: lastSuccessful,
                error: .streamUnavailable,
                pendingMutationPhase: nil
            )
        case .failure:
            return Fixture(
                snapshot: nil,
                phase: .failure,
                selectedConnectionID: nil,
                lastSuccessfulRefreshAt: nil,
                error: .snapshotDecodeFailed,
                pendingMutationPhase: nil
            )
        case .offline:
            let preservesSnapshot = configuration.inspector == .open
            return Fixture(
                snapshot: preservesSnapshot ? populated : nil,
                phase: preservesSnapshot ? .offlineWithSnapshot : .offlineWithoutSnapshot,
                selectedConnectionID: preservesSnapshot ? "connection-browser" : nil,
                lastSuccessfulRefreshAt: preservesSnapshot
                    ? configuration.fixedDate.addingTimeInterval(-600)
                    : nil,
                error: nil,
                pendingMutationPhase: nil
            )
        case .stale:
            return Fixture(
                snapshot: populated,
                phase: .stale,
                selectedConnectionID: selected,
                lastSuccessfulRefreshAt: configuration.fixedDate.addingTimeInterval(-540),
                error: nil,
                pendingMutationPhase: nil
            )
        case .permissionRequired, .transitioning, .rollbackFailed:
            preconditionFailure("Unregistered Connections visual state")
        }
    }

    private static func decodedSnapshot() -> ConnectionsSnapshot {
        guard let data = fixtureJSON.data(using: .utf8),
              let snapshot = try? JSONDecoder().decode(ConnectionsSnapshot.self, from: data)
        else {
            preconditionFailure("The deterministic Connections fixture must decode.")
        }
        return snapshot
    }

    private static let fixtureJSON = #"""
    {
      "downloadTotal": 97102848,
      "uploadTotal": 12848128,
      "memory": 68157440,
      "connections": [
        {
          "id": "connection-browser",
          "metadata": {
            "network": "tcp",
            "type": "HTTPS",
            "sourceIP": "192.0.2.11",
            "sourcePort": 53124,
            "destinationIP": "198.51.100.20",
            "destinationPort": 443,
            "inboundName": "mixed-in",
            "host": "dashboard.example.invalid",
            "process": "Safari",
            "processPath": "/Applications/Safari.app/Contents/MacOS/Safari",
            "sniffHost": "dashboard.example.invalid"
          },
          "upload": 4833280,
          "download": 52428800,
          "start": "2026-07-14T09:37:10Z",
          "chains": ["Seattle · Edge 01", "Automatic"],
          "providerChains": ["Airport A"],
          "rule": "DomainSuffix",
          "rulePayload": "example.invalid"
        },
        {
          "id": "connection-sync",
          "metadata": {
            "network": "tcp",
            "type": "HTTPS",
            "destinationIP": "203.0.113.12",
            "destinationPort": 443,
            "host": "sync.example.invalid",
            "process": "Vela Sync"
          },
          "upload": 3145728,
          "download": 17825792,
          "start": "2026-07-14T09:38:42Z",
          "chains": ["Singapore · Core", "Work"],
          "providerChains": ["Airport A"],
          "rule": "DomainKeyword",
          "rulePayload": "sync"
        },
        {
          "id": "connection-stream",
          "metadata": {
            "network": "udp",
            "type": "QUIC",
            "destinationIP": "198.51.100.45",
            "destinationPort": 443,
            "host": "media.example.invalid",
            "process": "Music"
          },
          "upload": 2097152,
          "download": 12582912,
          "start": "2026-07-14T09:39:04Z",
          "chains": ["Tokyo · Media", "Streaming"],
          "providerChains": ["Airport B"],
          "rule": "RuleSet",
          "rulePayload": "streaming"
        },
        {
          "id": "connection-mail",
          "metadata": {
            "network": "tcp",
            "type": "TLS",
            "destinationIP": "203.0.113.38",
            "destinationPort": 993,
            "host": "mail.example.invalid",
            "process": "Mail"
          },
          "upload": 1572864,
          "download": 8388608,
          "start": "2026-07-14T09:35:18Z",
          "chains": ["Seattle · Edge 01", "Automatic"],
          "providerChains": ["Airport A"],
          "rule": "DomainSuffix",
          "rulePayload": "mail.example.invalid"
        },
        {
          "id": "connection-update",
          "metadata": {
            "network": "tcp",
            "type": "HTTP",
            "destinationIP": "192.0.2.80",
            "destinationPort": 80,
            "host": "updates.example.invalid",
            "process": "softwareupdated"
          },
          "upload": 786432,
          "download": 3145728,
          "start": "2026-07-14T09:40:01Z",
          "chains": ["Direct"],
          "providerChains": [],
          "rule": "GeoIP",
          "rulePayload": "LAN"
        },
        {
          "id": "connection-dns",
          "metadata": {
            "network": "udp",
            "type": "DNS",
            "destinationIP": "192.0.2.53",
            "destinationPort": 53,
            "host": "resolver.example.invalid",
            "process": "mDNSResponder"
          },
          "upload": 311296,
          "download": 2785280,
          "start": "2026-07-14T09:40:28Z",
          "chains": ["Direct"],
          "providerChains": [],
          "rule": "Match",
          "rulePayload": ""
        },
        {
          "id": "connection-xcode",
          "metadata": {
            "network": "tcp",
            "type": "HTTPS",
            "destinationIP": "198.51.100.72",
            "destinationPort": 443,
            "host": "api.github.example.invalid",
            "process": "Xcode"
          },
          "upload": 458752,
          "download": 1966080,
          "start": "2026-07-14T09:40:36Z",
          "chains": ["Singapore · Core", "Work"],
          "providerChains": ["Airport A"],
          "rule": "DomainSuffix",
          "rulePayload": "github.example.invalid"
        },
        {
          "id": "connection-messages",
          "metadata": {
            "network": "tcp",
            "type": "HTTPS",
            "destinationIP": "203.0.113.91",
            "destinationPort": 443,
            "host": "courier.example.invalid",
            "process": "Messages"
          },
          "upload": 286720,
          "download": 1048576,
          "start": "2026-07-14T09:40:42Z",
          "chains": ["Seattle · Edge 01", "Automatic"],
          "providerChains": ["Airport A"],
          "rule": "DomainKeyword",
          "rulePayload": "courier"
        },
        {
          "id": "connection-notes",
          "metadata": {
            "network": "tcp",
            "type": "HTTPS",
            "destinationIP": "198.51.100.104",
            "destinationPort": 443,
            "host": "notes.example.invalid",
            "process": "Notes"
          },
          "upload": 131072,
          "download": 524288,
          "start": "2026-07-14T09:40:48Z",
          "chains": ["Direct"],
          "providerChains": [],
          "rule": "GeoIP",
          "rulePayload": "LAN"
        },
        {
          "id": "connection-calendar",
          "metadata": {
            "network": "tcp",
            "type": "TLS",
            "destinationIP": "192.0.2.118",
            "destinationPort": 443,
            "host": "calendar.example.invalid",
            "process": "Calendar"
          },
          "upload": 98304,
          "download": 425984,
          "start": "2026-07-14T09:40:52Z",
          "chains": ["Seattle · Edge 01", "Automatic"],
          "providerChains": ["Airport A"],
          "rule": "DomainSuffix",
          "rulePayload": "calendar.example.invalid"
        },
        {
          "id": "connection-terminal",
          "metadata": {
            "network": "tcp",
            "type": "HTTPS",
            "destinationIP": "203.0.113.143",
            "destinationPort": 443,
            "host": "registry.example.invalid",
            "process": "Terminal"
          },
          "upload": 65536,
          "download": 262144,
          "start": "2026-07-14T09:40:56Z",
          "chains": ["Singapore · Core", "Work"],
          "providerChains": ["Airport A"],
          "rule": "DomainKeyword",
          "rulePayload": "registry"
        },
        {
          "id": "connection-curl",
          "metadata": {
            "network": "tcp",
            "type": "HTTP",
            "destinationIP": "192.0.2.161",
            "destinationPort": 80,
            "host": "ifconfig.example.invalid",
            "process": "curl"
          },
          "upload": 16384,
          "download": 32768,
          "start": "2026-07-14T09:40:59Z",
          "chains": ["Direct"],
          "providerChains": [],
          "rule": "Match",
          "rulePayload": ""
        }
      ]
    }
    """#
}

struct ConnectionsVisualFixtureView: View {
    let configuration: VisualUITestConfiguration
    @State private var viewModel: ConnectionsViewModel

    init(configuration: VisualUITestConfiguration) {
        self.configuration = configuration
        _viewModel = State(
            initialValue: ConnectionsVisualFixtureFactory.makeModel(
                configuration: configuration
            )
        )
    }

    var body: some View {
        ConnectionsView(viewModel: viewModel)
            .environment(\.velaAccessibilityOverrides, accessibilityOverrides)
            .task(id: configuration.fixtureID) {
                let fixture = ConnectionsVisualFixtureFactory.fixture(
                    for: configuration
                )
                await viewModel.installVisualFixture(
                    snapshot: fixture.snapshot,
                    phase: fixture.phase,
                    selectedConnectionID: fixture.selectedConnectionID,
                    lastSuccessfulRefreshAt: fixture.lastSuccessfulRefreshAt,
                    error: fixture.error,
                    pendingMutationPhase: fixture.pendingMutationPhase
                )
            }
            .overlay(alignment: .topLeading) {
                if viewModel.isDebugFixtureReady {
                    VisualReadyMarker(fixtureID: configuration.fixtureID)
                }
                if accessibilityOverrides.reduceMotion == true {
                    VisualSurfaceMarker(
                        identifier: "connections.accessibility.reduceMotion",
                        label: "Connections Reduce Motion"
                    )
                }
                if accessibilityOverrides.increasedContrast == true {
                    VisualSurfaceMarker(
                        identifier: "connections.accessibility.increasedContrast",
                        label: "Connections Increase Contrast"
                    )
                }
            }
    }

    private var accessibilityOverrides: VelaAccessibilityOverrides {
        VelaAccessibilityOverrides(
            reduceMotion: launchFlag("-VelaConnectionsReduceMotion"),
            increasedContrast: launchFlag("-VelaConnectionsIncreaseContrast")
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
