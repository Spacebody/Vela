import Foundation
import Testing
@testable import Vela

@Suite("Proxies Table and Inspector presentation")
struct ProxiesPresentationTests {
    @Test("Route preview requires traffic takeover, not only static node data")
    func routePreviewRequiresTrafficTakeover() {
        #expect(!ProxiesRoutePreviewPolicy.isActive(
            isTrafficConnected: false,
            hasSelectedCandidate: true
        ))
        #expect(!ProxiesRoutePreviewPolicy.isActive(
            isTrafficConnected: true,
            hasSelectedCandidate: false
        ))
        #expect(ProxiesRoutePreviewPolicy.isActive(
            isTrafficConnected: true,
            hasSelectedCandidate: true
        ))
    }

    @Test("Loaded selection and Inspector share one stable group identity")
    func selectionAndInspectorStayAligned() throws {
        let catalog = try fixtureCatalog()
        let requested = ProxiesGroupID(rawValue: "Streaming")
        let snapshot = makeSnapshot(
            catalog: catalog,
            selection: requested
        )

        #expect(snapshot.selectedGroupID == requested)
        #expect(snapshot.rows.first(where: { $0.id == requested }) != nil)
        guard case let .selected(inspector) = snapshot.inspectorState(
            for: snapshot.selectedGroupID
        ) else {
            Issue.record("Loaded selection must produce a selected Inspector.")
            return
        }
        #expect(inspector.id == requested)
        #expect(inspector.name == "Streaming")
        #expect(inspector.currentProxy == "Tokyo")
    }

    @Test("Empty and full failure clear old table and Inspector identity")
    func emptyAndFailureClearSelection() {
        let oldSelection = ProxiesGroupID(rawValue: "Automatic")
        let empty = ProxiesPresentationFactory.make(
            catalog: .empty,
            controllerState: .connected,
            isLoading: false,
            operation: nil,
            delayStates: [:],
            selectedGroupID: oldSelection,
            errorSummary: nil
        )
        let failure = ProxiesPresentationFactory.make(
            catalog: .empty,
            controllerState: .connected,
            isLoading: false,
            operation: nil,
            delayStates: [:],
            selectedGroupID: oldSelection,
            errorSummary: "invalid response"
        )

        #expect(empty.state == .empty)
        #expect(empty.rows.isEmpty)
        #expect(empty.selectedGroupID == nil)
        #expect(empty.inspectorState(for: oldSelection) == .empty)

        #expect(failure.state == .fullFailure)
        #expect(failure.rows.isEmpty)
        #expect(failure.selectedGroupID == nil)
        #expect(failure.inspectorState(for: oldSelection) == .failure("invalid response"))
        #expect(!failure.actions.canTestGroup)
        #expect(failure.actions.showsDiagnostics)
    }

    @Test("Removed selection falls back deterministically to the first group")
    func removedSelectionFallsBack() throws {
        let snapshot = makeSnapshot(
            catalog: try fixtureCatalog(),
            selection: ProxiesGroupID(rawValue: "Removed")
        )

        #expect(snapshot.selectedGroupID == snapshot.rows.first?.id)
        #expect(snapshot.selectedGroupID == ProxiesGroupID(rawValue: "Automatic"))
    }

    @Test("Sorting rows preserves selection by stable group identity")
    func sortedRowsPreserveSelection() throws {
        let requested = ProxiesGroupID(rawValue: "Streaming")
        let snapshot = makeSnapshot(
            catalog: try fixtureCatalog(),
            selection: requested
        )
        let descendingRows = snapshot.rows.sorted { $0.name > $1.name }

        #expect(
            ProxiesSelectionPolicy.resolve(requested, rows: descendingRows)
                == requested
        )
    }

    @Test("Liquid Glass group controls filter attention and sort by name")
    func liquidGlassGroupControlsTransformRows() throws {
        let catalog = try fixtureCatalog()
        let loaded = makeSnapshot(
            catalog: catalog,
            selection: ProxiesGroupID(rawValue: "Automatic")
        )
        let named = ProxyGroupListPresentation.rows(
            from: loaded.rows,
            groups: loaded.groups,
            searchText: "",
            filter: .all,
            sort: .name
        )
        #expect(named.map(\.name) == named.map(\.name).sorted())

        let group = try #require(catalog.group(named: "Automatic"))
        let requested = try #require(group.nodes.first(where: { $0.name == "Tokyo" }))
        let pending = ProxiesPresentationFactory.make(
            catalog: catalog,
            controllerState: .connected,
            isLoading: false,
            operation: .selecting(groupName: group.name, proxyID: requested.id),
            delayStates: [:],
            selectedGroupID: ProxiesGroupID(rawValue: group.name),
            errorSummary: nil
        )
        let attention = ProxyGroupListPresentation.rows(
            from: pending.rows,
            groups: pending.groups,
            searchText: "",
            filter: .needsAttention,
            sort: .configuration
        )
        #expect(attention.map(\.id) == [ProxiesGroupID(rawValue: "Automatic")])
    }

    @Test("Pending mutation keeps committed current separate from requested target")
    func pendingMutationSeparatesCurrentAndRequested() throws {
        let catalog = try fixtureCatalog()
        let group = try #require(catalog.group(named: "Automatic"))
        let requested = try #require(group.nodes.first(where: { $0.name == "Tokyo" }))
        let groupID = ProxiesGroupID(rawValue: group.name)
        let snapshot = ProxiesPresentationFactory.make(
            catalog: catalog,
            controllerState: .connected,
            isLoading: false,
            operation: .selecting(groupName: group.name, proxyID: requested.id),
            delayStates: [:],
            selectedGroupID: groupID,
            errorSummary: nil
        )

        #expect(snapshot.state == .pendingMutation)
        let row = try #require(snapshot.rows.first(where: { $0.id == groupID }))
        #expect(row.currentProxy == "Seattle")
        #expect(row.isPending)
        guard case let .selected(inspector) = snapshot.inspectorState(for: groupID) else {
            Issue.record("Pending group must remain inspectable.")
            return
        }
        #expect(inspector.currentProxy == "Seattle")
        #expect(inspector.requestedProxy == "Tokyo")
        #expect(inspector.mutationPhase == .applying)
        #expect(inspector.candidates.first(where: { $0.name == "Tokyo" })?.isRequested == true)
        #expect(!snapshot.actions.canTestGroup)
        #expect(!snapshot.actions.canMutateSelection)
    }

    @Test("Country node families receive stable display ordinals without changing Controller IDs")
    func countryNodesUsePresentationOnlyOrdinals() throws {
        let response = try JSONDecoder().decode(
            MihomoProxiesResponse.self,
            from: Data(Self.countryFixtureJSON.utf8)
        )
        let catalog = ProxyCatalog(
            runtimeResponse: response,
            providerResponse: .empty,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let groupID = ProxiesGroupID(rawValue: "SSRDOG")
        let snapshot = makeSnapshot(catalog: catalog, selection: groupID)
        let inspector = try #require(snapshot.groups[groupID])

        #expect(inspector.candidates.map(\.name) == [
            "香港高速 | 01",
            "Hong Kong Premium | 02",
            "🇭🇰 Hong Kong | 07",
        ])
        #expect(inspector.candidates.map(\.id.name) == [
            "香港高速",
            "Hong Kong Premium",
            "🇭🇰 Hong Kong | 07",
        ])
    }

    @Test("Refreshing and partial failure retain last-good rows with safe actions")
    func lastGoodStatesRetainRows() throws {
        let catalog = try fixtureCatalog()
        let selection = ProxiesGroupID(rawValue: "Automatic")
        let refreshing = ProxiesPresentationFactory.make(
            catalog: catalog,
            controllerState: .connected,
            isLoading: true,
            operation: .refreshing,
            delayStates: [:],
            selectedGroupID: selection,
            errorSummary: nil
        )
        let partial = ProxiesPresentationFactory.make(
            catalog: catalog,
            controllerState: .connected,
            isLoading: false,
            operation: nil,
            delayStates: [:],
            selectedGroupID: selection,
            errorSummary: "provider timed out"
        )

        #expect(refreshing.state == .refreshing)
        #expect(refreshing.rows.map(\.id) == partial.rows.map(\.id))
        #expect(!refreshing.rows.isEmpty)
        #expect(!refreshing.actions.canRefresh)
        #expect(!refreshing.actions.canTestGroup)
        #expect(partial.state == .partialFailure)
        #expect(!partial.rows.isEmpty)
        #expect(partial.selectedGroupID == selection)
        guard case let .selected(inspector) = partial.inspectorState(for: selection) else {
            Issue.record("Partial failure must retain the selected Inspector.")
            return
        }
        #expect(inspector.failureSummary == "provider timed out")
    }

    @Test("Snapshot generation changes when authoritative catalog generation changes")
    func generationRejectsStaleIdentity() throws {
        let first = try fixtureCatalog(updatedAt: Date(timeIntervalSince1970: 10))
        let second = try fixtureCatalog(updatedAt: Date(timeIntervalSince1970: 20))
        let firstSnapshot = makeSnapshot(catalog: first)
        let secondSnapshot = makeSnapshot(catalog: second)

        #expect(firstSnapshot.generation != secondSnapshot.generation)
    }

    @Test("Fixture clock is carried into Inspector health evidence")
    func referenceClockIsDeterministic() throws {
        let referenceDate = Date(timeIntervalSince1970: 1_700_000_600)
        let groupID = ProxiesGroupID(rawValue: "Automatic")
        let snapshot = ProxiesPresentationFactory.make(
            catalog: try fixtureCatalog(),
            controllerState: .connected,
            isLoading: false,
            operation: nil,
            delayStates: [:],
            selectedGroupID: groupID,
            errorSummary: nil,
            referenceDate: referenceDate
        )

        #expect(snapshot.groups[groupID]?.referenceDate == referenceDate)
    }

    @Test("Automatic groups expose strategy evidence without manual selection")
    func automaticStrategyCapability() throws {
        let snapshot = makeSnapshot(catalog: try fixtureCatalog())
        let automatic = try #require(snapshot.groups[ProxiesGroupID(rawValue: "Automatic")])
        let streaming = try #require(snapshot.groups[ProxiesGroupID(rawValue: "Streaming")])

        #expect(automatic.allowsManualSelection)
        #expect(!streaming.allowsManualSelection)
    }

    @Test("Disconnected Controller keeps configured groups visible but runtime actions disabled")
    func offlineConfiguredCatalog() throws {
        let catalog = try fixtureCatalog()
        let snapshot = ProxiesPresentationFactory.make(
            catalog: catalog,
            controllerState: .disconnected,
            isLoading: false,
            operation: nil,
            delayStates: [:],
            selectedGroupID: nil,
            errorSummary: nil
        )

        #expect(snapshot.state == .offline)
        #expect(snapshot.rows.count == catalog.groups.count)
        #expect(snapshot.selectedGroupID != nil)
        #expect(!snapshot.actions.canRefresh)
        #expect(!snapshot.actions.canTestGroup)
        #expect(!snapshot.actions.canMutateSelection)
    }

    @Test("Layout metrics keep Inspector and compact columns within contract")
    func layoutMetrics() {
        #expect(ProxiesLayoutMetrics.inspectorMinimumWidth == 300)
        #expect(ProxiesLayoutMetrics.inspectorIdealWidth == 340)
        #expect(ProxiesLayoutMetrics.inspectorMaximumWidth == 380)
        #expect(ProxiesLayoutMetrics.tableRowHeight == VelaMetrics.tableRowHeight)
        #expect(ProxiesLayoutMetrics.tableCellContentHeight == 26)
        #expect(!ProxiesLayoutMetrics.resolve(tableWidth: 540).showsStrategyColumn)
        #expect(ProxiesLayoutMetrics.resolve(tableWidth: 760).showsStrategyColumn)
    }

    @Test("Large deterministic catalog remains bounded across refresh and selection churn")
    func largeCatalogResourceFixture() throws {
        let catalog = try largeCatalog(groupCount: 100, candidatesPerGroup: 100)
        let delayStates = Dictionary(uniqueKeysWithValues: catalog.groups.flatMap { group in
            let groupID = ProxiesGroupID(rawValue: group.name)
            return group.nodes.enumerated().map { index, node in
                (
                    ProxiesDelayKey(groupID: groupID, nodeID: node.id),
                    ProxyDelayState.measured(milliseconds: UInt16(20 + index))
                )
            }
        })
        let descriptorCountBefore = openFileDescriptorCount()
        var selection: ProxiesGroupID?
        var lastSnapshot: ProxiesPresentationSnapshot?

        for iteration in 0..<100 {
            let requested = ProxiesGroupID(rawValue: "Group \(iteration % 100)")
            lastSnapshot = ProxiesPresentationFactory.make(
                catalog: catalog,
                controllerState: .connected,
                isLoading: iteration.isMultiple(of: 2),
                operation: iteration.isMultiple(of: 2) ? .refreshing : nil,
                delayStates: delayStates,
                selectedGroupID: requested,
                errorSummary: nil
            )
            selection = lastSnapshot?.selectedGroupID
        }
        for iteration in 0..<500 {
            selection = ProxiesSelectionPolicy.resolve(
                ProxiesGroupID(rawValue: "Group \(iteration % 100)"),
                rows: lastSnapshot?.rows ?? []
            )
        }
        for iteration in 0..<50 {
            let requested = ProxiesGroupID(rawValue: "Group \(iteration % 100)")
            _ = lastSnapshot?.inspectorState(for: requested)
            _ = lastSnapshot?.inspectorState(for: nil)
        }

        #expect(lastSnapshot?.rows.count == 100)
        #expect(lastSnapshot?.groups.values.allSatisfy { $0.candidates.count == 100 } == true)
        #expect(lastSnapshot?.groups.values.allSatisfy {
            $0.candidates.allSatisfy { $0.latency.milliseconds != nil }
        } == true)
        #expect(selection != nil)
        if let descriptorCountBefore, let descriptorCountAfter = openFileDescriptorCount() {
            #expect(descriptorCountAfter <= descriptorCountBefore + 4)
        }
    }

    private func makeSnapshot(
        catalog: ProxyCatalog,
        selection: ProxiesGroupID? = nil
    ) -> ProxiesPresentationSnapshot {
        ProxiesPresentationFactory.make(
            catalog: catalog,
            controllerState: .connected,
            isLoading: false,
            operation: nil,
            delayStates: [:],
            selectedGroupID: selection,
            errorSummary: nil
        )
    }

    private func fixtureCatalog(
        updatedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) throws -> ProxyCatalog {
        let response = try JSONDecoder().decode(
            MihomoProxiesResponse.self,
            from: Data(Self.fixtureJSON.utf8)
        )
        return ProxyCatalog(
            runtimeResponse: response,
            providerResponse: .empty,
            updatedAt: updatedAt
        )
    }

    private func largeCatalog(
        groupCount: Int,
        candidatesPerGroup: Int
    ) throws -> ProxyCatalog {
        var proxies: [String: Any] = [:]
        for candidate in 0..<candidatesPerGroup {
            let name = "Node \(candidate)"
            proxies[name] = [
                "name": name,
                "type": "Shadowsocks",
                "alive": true,
                "history": [],
            ]
        }
        let members = (0..<candidatesPerGroup).map { "Node \($0)" }
        for group in 0..<groupCount {
            let name = "Group \(group)"
            proxies[name] = [
                "name": name,
                "type": "Selector",
                "now": members[group % candidatesPerGroup],
                "all": members,
                "history": [],
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: ["proxies": proxies])
        let response = try JSONDecoder().decode(MihomoProxiesResponse.self, from: data)
        return ProxyCatalog(
            runtimeResponse: response,
            providerResponse: .empty,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func openFileDescriptorCount() -> Int? {
        try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
    }

    private static let fixtureJSON = #"""
    {
      "proxies": {
        "Automatic": {"name":"Automatic","type":"Selector","now":"Seattle","all":["Seattle","Tokyo"],"history":[]},
        "Streaming": {"name":"Streaming","type":"URLTest","now":"Tokyo","all":["Tokyo","Seattle"],"history":[]},
        "Seattle": {"name":"Seattle","type":"Shadowsocks","alive":true,"history":[{"time":"2026-07-14T09:40:30Z","delay":42}]},
        "Tokyo": {"name":"Tokyo","type":"Shadowsocks","alive":true,"history":[{"time":"2026-07-14T09:40:30Z","delay":68}]}
      }
    }
    """#

    private static let countryFixtureJSON = #"""
    {
      "proxies": {
        "SSRDOG": {
          "name":"SSRDOG",
          "type":"Selector",
          "now":"香港高速",
          "all":["香港高速","Hong Kong Premium","🇭🇰 Hong Kong | 07"],
          "history":[]
        },
        "香港高速": {"name":"香港高速","type":"AnyTLS","alive":true,"history":[]},
        "Hong Kong Premium": {"name":"Hong Kong Premium","type":"AnyTLS","alive":true,"history":[]},
        "🇭🇰 Hong Kong | 07": {"name":"🇭🇰 Hong Kong | 07","type":"AnyTLS","alive":true,"history":[]}
      }
    }
    """#
}
