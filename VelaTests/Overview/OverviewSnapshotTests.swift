import Foundation
import Testing
import VelaIPC
@testable import Vela

@Suite("Overview design-pack snapshots")
struct OverviewSnapshotTests {
    private let now = Date(timeIntervalSince1970: 1_768_298_460)

    @Test("Active backend remains distinct from the preferred backend")
    func activeAndPreferredBackendRemainDistinct() {
        let stopped = OverviewBackendPresentation(
            activeBackend: nil,
            preferredBackend: .userProcess,
            isTransitioning: false
        )
        let transitioning = OverviewBackendPresentation(
            activeBackend: .userProcess,
            preferredBackend: .privilegedDaemon,
            isTransitioning: true
        )

        #expect(stopped.primaryBackend == nil)
        #expect(stopped.preferredBackend == .userProcess)
        #expect(transitioning.primaryBackend == .userProcess)
        #expect(transitioning.preferredBackend == .privilegedDaemon)
    }

    @Test("No configuration selects recovery instead of a failing start")
    func noConfigurationChoosesConfiguration() {
        let decision = OverviewPrimaryActionDecision.resolve(
            isRunning: false,
            hasConfiguration: false,
            canStart: false,
            isBusy: false,
            busyReason: "busy",
            startUnavailableReason: "unavailable"
        )

        #expect(decision.action == .chooseConfiguration)
        #expect(decision.isEnabled)
        #expect(decision.disabledReason == nil)
    }

    @Test("A configured but unavailable start exposes a reason")
    func configuredUnavailableStartHasReason() {
        let decision = OverviewPrimaryActionDecision.resolve(
            isRunning: false,
            hasConfiguration: true,
            canStart: false,
            isBusy: false,
            busyReason: "busy",
            startUnavailableReason: "Validate first"
        )

        #expect(decision.action == .start)
        #expect(!decision.isEnabled)
        #expect(decision.disabledReason == "Validate first")
    }

    @Test("Enabling TUN without a ready privileged component opens setup")
    func unavailableTunEnableOpensSetup() {
        let decision = OverviewTunActionDecision.resolve(
            requestedEnabled: true,
            privilegedComponentIsReady: false
        )

        #expect(decision == .showSetup)
    }

    @Test("A ready TUN request is applied directly")
    func readyTunRequestIsApplied() {
        let enableDecision = OverviewTunActionDecision.resolve(
            requestedEnabled: true,
            privilegedComponentIsReady: true
        )
        let disableDecision = OverviewTunActionDecision.resolve(
            requestedEnabled: false,
            privilegedComponentIsReady: false
        )

        #expect(enableDecision == .apply(true))
        #expect(disableDecision == .apply(false))
    }

    @Test("Stale traffic generation cannot repopulate a new configuration")
    func staleGenerationIsIgnored() throws {
        var history = OverviewTrafficHistory()
        history.beginGeneration("configuration-a")
        history.record(point(at: now, value: 1), generation: "configuration-a")
        history.beginGeneration("configuration-b")
        history.record(point(at: now.addingTimeInterval(1), value: 2), generation: "configuration-a")

        #expect(history.generation == "configuration-b")
        #expect(history.points.isEmpty)

        history.record(point(at: now.addingTimeInterval(2), value: 3), generation: "configuration-b")
        let latestPoint = try #require(history.points.last)
        #expect(latestPoint.downloadBytesPerSecond == 3)
    }

    @Test("Sixty minutes of one-second traffic samples remains bounded")
    func sixtyMinuteTrafficFixtureIsBounded() throws {
        var history = OverviewTrafficHistory()
        history.beginGeneration("main")

        for second in 0 ..< 3_600 {
            history.record(
                point(at: now.addingTimeInterval(TimeInterval(second)), value: Int64(second)),
                generation: "main"
            )
        }

        let latestPoint = try #require(history.points.last)
        let earliestPoint = try #require(history.points.first)
        #expect(history.points.count <= OverviewTrafficHistory.maximumPointCount)
        #expect(latestPoint.downloadBytesPerSecond == 3_599)
        #expect(earliestPoint.timestamp >= now.addingTimeInterval(3_479))
    }

    @Test("Connection preview is derived from the raw runtime snapshot")
    func connectionPreviewUsesRawRuntimeSnapshot() throws {
        let runtimeSnapshot = try makeConnectionsSnapshot()
        let overviewSnapshot = OverviewConnectionSnapshot(snapshot: runtimeSnapshot)

        #expect(overviewSnapshot.activeCount == 6)
        #expect(overviewSnapshot.downloadTotal == 9_000)
        #expect(overviewSnapshot.uploadTotal == 3_000)
        #expect(overviewSnapshot.preview.count == OverviewConnectionSnapshot.maximumPreviewCount)
        #expect(overviewSnapshot.preview.map(\.id) == ["c6", "c5", "c4", "c3", "c2"])
        #expect(overviewSnapshot.preview.first?.destination == "six.example")
        #expect(overviewSnapshot.preview.first?.process == "Safari")
        #expect(overviewSnapshot.preview.first?.proxy == "Tokyo · JP")
    }

    @Test("Connection preview clamps invalid traffic without changing active count")
    func connectionPreviewClampsInvalidTraffic() throws {
        let data = Data(
            """
            {
              "downloadTotal": -1,
              "uploadTotal": -2,
              "connections": [
                {
                  "id": "negative",
                  "metadata": {"destinationIP": "203.0.113.9"},
                  "upload": -4,
                  "download": -8,
                  "chains": []
                }
              ]
            }
            """.utf8
        )
        let runtimeSnapshot = try JSONDecoder().decode(ConnectionsSnapshot.self, from: data)
        let overviewSnapshot = OverviewConnectionSnapshot(snapshot: runtimeSnapshot)

        #expect(overviewSnapshot.activeCount == 1)
        #expect(overviewSnapshot.uploadTotal == 0)
        #expect(overviewSnapshot.downloadTotal == 0)
        #expect(overviewSnapshot.preview.first?.uploadBytes == 0)
        #expect(overviewSnapshot.preview.first?.downloadBytes == 0)
        #expect(overviewSnapshot.preview.first?.destination == "203.0.113.9")
    }

    @Test("Proxy presentation cache rebuilds only when its catalog revision changes")
    @MainActor
    func proxyPresentationCacheUsesCatalogRevision() {
        let cache = OverviewProxySnapshotCache()
        let revision = Date(timeIntervalSince1970: 1_768_298_400)
        let firstCatalog = ProxyCatalog(groups: [], updatedAt: revision)
        let equivalentRevision = ProxyCatalog(groups: [], updatedAt: revision)
        let nextCatalog = ProxyCatalog(
            groups: [],
            updatedAt: revision.addingTimeInterval(1)
        )
        var buildCount = 0

        _ = cache.snapshots(for: firstCatalog) {
            buildCount += 1
            return []
        }
        _ = cache.snapshots(for: equivalentRevision) {
            buildCount += 1
            return []
        }
        _ = cache.snapshots(for: nextCatalog) {
            buildCount += 1
            return []
        }

        #expect(buildCount == 2)
    }

    @Test("Proxy presentation cache tracks offline catalog value changes")
    @MainActor
    func proxyPresentationCacheTracksStaticCatalogs() {
        let cache = OverviewProxySnapshotCache()
        let emptyCatalog = ProxyCatalog(groups: [])
        let changedCatalog = ProxyCatalog(
            groups: [],
            fetchErrors: [
                ProxyCatalogFetchError(
                    source: .proxyProviders,
                    endpoint: "/providers/proxies",
                    message: "offline"
                ),
            ]
        )
        var buildCount = 0

        _ = cache.snapshots(for: emptyCatalog) {
            buildCount += 1
            return []
        }
        _ = cache.snapshots(for: emptyCatalog) {
            buildCount += 1
            return []
        }
        _ = cache.snapshots(for: changedCatalog) {
            buildCount += 1
            return []
        }

        #expect(buildCount == 2)
    }

    @Test("Connected Tokyo fixture contains the complete control surface")
    func connectedTokyoFixtureIsComplete() throws {
        let snapshot = OverviewVisualFixtureFactory.connectedTokyo(
            strings: OverviewStrings(locale: Locale(identifier: "en")),
            now: now
        )
        let node = try #require(snapshot.node)

        #expect(snapshot.state == .connected)
        #expect(snapshot.configurationName == "Main")
        #expect(snapshot.core.primaryAction.action == .pause)
        #expect(snapshot.route.mode == .rule)
        #expect(snapshot.route.isAvailable)
        #expect(node.name == "Tokyo · JP")
        #expect(snapshot.proxyGroups.map(\.groupName) == ["Auto Select", "Manual"])
        #expect(snapshot.route.sourceDetail == "192.168.1.42")
        #expect(snapshot.route.destinationDetail == "Active")
        #expect(snapshot.metrics.activeConnections == "38")
        #expect(snapshot.metrics.runtime == "01:24:38")
        #expect(node.candidates.count == 5)
        #expect(snapshot.metrics.trafficPoints.count == 60)
        #expect(snapshot.recovery == nil)
    }

    @Test("No-configuration fixture contains no fabricated runtime data")
    func noConfigurationFixtureIsSafe() throws {
        let snapshot = OverviewVisualFixtureFactory.noConfiguration(
            strings: OverviewStrings(locale: Locale(identifier: "en")),
            now: now
        )
        let recovery = try #require(snapshot.recovery)

        #expect(snapshot.state == .noConfiguration)
        #expect(snapshot.configurationName == nil)
        #expect(snapshot.node == nil)
        #expect(snapshot.proxyGroups.isEmpty)
        #expect(snapshot.core.primaryAction.action == .chooseConfiguration)
        #expect(!snapshot.route.isAvailable)
        #expect(snapshot.route.mode == nil)
        #expect(snapshot.metrics.trafficPoints.isEmpty)
        #expect(recovery.action == .chooseConfiguration)
        #expect(recovery.isEnabled)
    }

    @Test("Required visual fixtures cover every design state")
    func stateFixturesAreDistinct() {
        let strings = OverviewStrings(locale: Locale(identifier: "en"))
        let states = [
            OverviewVisualFixtureFactory.connectedTokyo(strings: strings, now: now).state,
            OverviewVisualFixtureFactory.connecting(strings: strings, now: now).state,
            OverviewVisualFixtureFactory.disconnected(strings: strings, now: now).state,
            OverviewVisualFixtureFactory.noConfiguration(strings: strings, now: now).state,
            OverviewVisualFixtureFactory.error(strings: strings, now: now).state,
        ]

        #expect(states == [.connected, .connecting, .disconnected, .noConfiguration, .error])
    }

    @Test("Stress fixtures preserve real geometry inputs")
    func stressFixturesCoverLongNamesAndHighTraffic() throws {
        let strings = OverviewStrings(locale: Locale(identifier: "zh-Hans"))
        let longName = OverviewVisualFixtureFactory.longNodeName(strings: strings, now: now)
        let highTraffic = OverviewVisualFixtureFactory.highTraffic(strings: strings, now: now)
        let node = try #require(longName.node)

        #expect(node.name.count > 24)
        #expect(highTraffic.metrics.download == "986.4 MB/s")
        #expect(highTraffic.metrics.activeConnections == "999")
        #expect(highTraffic.metrics.trafficPoints.count == 60)
    }

    private func point(at date: Date, value: Int64) -> OverviewTrafficPoint {
        OverviewTrafficPoint(
            timestamp: date,
            downloadBytesPerSecond: value,
            uploadBytesPerSecond: value,
            totalDownloadBytes: value,
            totalUploadBytes: value
        )
    }

    private func makeConnectionsSnapshot() throws -> ConnectionsSnapshot {
        let connections = (1 ... 6).map { index in
            """
            {
              "id": "c\(index)",
              "metadata": {
                "host": "\(index == 6 ? "six.example" : "host-\(index).example")",
                "process": "\(index == 6 ? "Safari" : "Vela Test")"
              },
              "upload": \(index * 100),
              "download": \(index * 1_000),
              "chains": ["\(index == 6 ? "Tokyo · JP" : "Auto Select")"]
            }
            """
        }
        let data = Data(
            """
            {
              "downloadTotal": 9000,
              "uploadTotal": 3000,
              "connections": [\(connections.joined(separator: ","))]
            }
            """.utf8
        )
        return try JSONDecoder().decode(ConnectionsSnapshot.self, from: data)
    }
}
