import Foundation
import Testing
@testable import Vela

@Suite("Visual fixture determinism")
struct VisualFixtureDeterminismTests {
    @Test("The same seed produces the same stable UUID sequence")
    func seededUUIDSequenceIsStable() {
        var left = SeededVisualUUIDGenerator(seed: 20_260_714)
        var right = SeededVisualUUIDGenerator(seed: 20_260_714)

        let leftValues = (0 ..< 8).map { _ in left.next() }
        let rightValues = (0 ..< 8).map { _ in right.next() }

        #expect(leftValues == rightValues)
        #expect(Set(leftValues).count == leftValues.count)
    }

    @Test("Visual fixtures deny every live external service")
    func environmentIsIsolated() throws {
        let configuration = try #require(
            try VisualUITestConfiguration.resolve(arguments: [
                "Vela",
                VisualUITestConfiguration.modeKey, "YES",
                VisualUITestConfiguration.fixtureKey, "overview.loadedHealthy",
                VisualUITestConfiguration.pageKey, "overview",
                VisualUITestConfiguration.stateKey, "loaded",
                VisualUITestConfiguration.appearanceKey, "light",
                VisualUITestConfiguration.localeKey, "en",
                VisualUITestConfiguration.windowKey, "1040x680",
                VisualUITestConfiguration.inspectorKey, "na",
                VisualUITestConfiguration.fixedDateKey, "2026-07-14T09:41:00Z",
                VisualUITestConfiguration.uuidSeedKey, "20260714",
            ])
        )
        let environment = VisualFixtureEnvironment(configuration: configuration)

        #expect(environment.clock.now == configuration.fixedDate)
        #expect(environment.route.fixtureID == configuration.fixtureID)
        #expect(environment.route.captureBoundary == .mainWindow)
        #expect(!environment.allowsNetwork)
        #expect(!environment.allowsKeychain)
        #expect(!environment.allowsPrivilegedHelper)
        #expect(!environment.allowsSystemProxy)
        #expect(!environment.allowsTUN)
    }

    @Test("Every registered page-state fixture resolves through the strict launch contract")
    func registeredFixturesResolve() throws {
        let registryURL = Self.repositoryRoot
            .appending(path: "VisualRecovery/Fixtures/fixture-registry.json")
        let registry = try JSONDecoder().decode(
            RegisteredVisualFixtureRegistry.self,
            from: Data(contentsOf: registryURL)
        )
        let contractURLs = try FileManager.default.contentsOfDirectory(
            at: Self.repositoryRoot.appending(path: "VisualRecovery/Contracts"),
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }
        let contracts = try contractURLs.map {
            try JSONDecoder().decode(
                RegisteredVisualPageContract.self,
                from: Data(contentsOf: $0)
            )
        }

        #expect(registry.schemaVersion == 1)
        #expect(contracts.count == VisualUITestConfiguration.Page.allCases.count)
        #expect(registry.fixtures.count == 103)
        #expect(VisualFixtureRouteCatalog.all.count == 103)
        let registeredIDs = Set(registry.fixtures.map(\.id))
        let contractedIDs = Set(contracts.flatMap(\.fixtures))
        let typedRouteIDs = Set(VisualFixtureRouteCatalog.all.map(\.fixtureID))
        #expect(registeredIDs.count == registry.fixtures.count)
        #expect(contractedIDs.count == 103)
        #expect(registeredIDs.subtracting(contractedIDs).isEmpty)
        #expect(contractedIDs.subtracting(registeredIDs).isEmpty)
        #expect(registeredIDs.subtracting(typedRouteIDs).isEmpty)
        #expect(typedRouteIDs.subtracting(registeredIDs).isEmpty)
        #expect(
            VisualFixturePresentationCatalog.coveredFixtureIDs
                .subtracting(typedRouteIDs).isEmpty
        )
        let registeredOrder = registry.fixtures.map(\.id)
        let typedOrder = VisualFixtureRouteCatalog.all.map(\.fixtureID)
        #expect(registeredOrder.count == typedOrder.count)
        for (registered, typed) in zip(registeredOrder, typedOrder) {
            #expect(registered == typed, "Fixture route order mismatch: \(registered) != \(typed)")
        }

        for page in VisualUITestConfiguration.Page.allCases {
            let registeredStates = Set(
                registry.fixtures
                    .filter { $0.page == page.rawValue }
                    .compactMap { VisualUITestConfiguration.State(rawValue: $0.state) }
            )
            #expect(registeredStates == page.registeredStates)
        }

        for fixture in registry.fixtures {
            #expect(!fixture.liveServicesAllowed, "Live services enabled for \(fixture.id)")
            #expect(!fixture.sensitiveData, "Sensitive data registered for \(fixture.id)")
            #expect(fixture.dataSource == "deterministicInMemory")

            let page = try #require(VisualUITestConfiguration.Page(rawValue: fixture.page))
            let state = try #require(VisualUITestConfiguration.State(rawValue: fixture.state))
            let route = try #require(
                VisualFixtureRouteCatalog.route(page: page, state: state)
            )
            let inspector = try #require(route.captureInspectors.first)
            let configuration = try #require(
                try VisualUITestConfiguration.resolve(arguments: [
                    "Vela",
                    VisualUITestConfiguration.modeKey, "YES",
                    VisualUITestConfiguration.fixtureKey, fixture.id,
                    VisualUITestConfiguration.pageKey, fixture.page,
                    VisualUITestConfiguration.stateKey, fixture.state,
                    VisualUITestConfiguration.appearanceKey, "light",
                    VisualUITestConfiguration.localeKey, "en",
                    VisualUITestConfiguration.windowKey, "1280x820",
                    VisualUITestConfiguration.inspectorKey, inspector.rawValue,
                    VisualUITestConfiguration.fixedDateKey, registry.fixedDate,
                    VisualUITestConfiguration.uuidSeedKey, String(registry.fixedUUIDSeed),
                ])
            )

            #expect(configuration.fixtureID == fixture.id)
            #expect(configuration.page.rawValue == fixture.page)
            #expect(configuration.state.rawValue == fixture.state)
            #expect(VisualFixturePresentationCatalog.supports(configuration))
        }

        let inspectorRoutes = VisualFixtureRouteCatalog.all.filter {
            $0.inspectorPolicy == .toggleable
        }
        #expect(!inspectorRoutes.isEmpty)
        #expect(inspectorRoutes.allSatisfy { $0.captureInspectors == [.closed, .open] })
        #expect(
            VisualFixtureRouteCatalog.all.contains {
                $0.fixtureID == "helpSupport.loaded"
                    && $0.captureBoundary == .mainWindow
            }
        )
        #expect(
            VisualFixtureRouteCatalog.all.contains {
                $0.fixtureID == "updateCoreRecovery.rollbackFailed"
                    && $0.captureBoundary == .mainWindow
            }
        )
    }

    @Test("The typed route catalog expands to the exhaustive capture matrix")
    func captureMatrixIsExhaustive() {
        let scenarioCount = VisualFixtureRouteCatalog.all.reduce(into: 0) {
            count, route in
            let windowCount = route.captureWindowSizes.count
            count += route.captureInspectors.count
                * VisualUITestConfiguration.Appearance.allCases.count
                * VisualUITestConfiguration.LocaleIdentifier.allCases.count
                * windowCount
        }

        #expect(scenarioCount == 1_960)
        #expect(
            VisualFixtureRouteCatalog.all.filter { $0.isMainWindow }.count == 92
        )
        #expect(
            VisualFixtureRouteCatalog.all.filter { !$0.isMainWindow }.count == 11
        )
    }

    private static var repositoryRoot: URL {
        if let staged = ProcessInfo.processInfo.environment["VELA_TEST_REPOSITORY_ROOT"],
           !staged.isEmpty {
            return URL(fileURLWithPath: staged, isDirectory: true)
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

private struct RegisteredVisualFixtureRegistry: Decodable {
    let schemaVersion: Int
    let fixedDate: String
    let fixedUUIDSeed: UInt64
    let fixtures: [RegisteredVisualFixture]
}

private struct RegisteredVisualPageContract: Decodable {
    let page: String
    let fixtures: [String]
}

private struct RegisteredVisualFixture: Decodable {
    let id: String
    let page: String
    let state: String
    let sensitiveData: Bool
    let dataSource: String
    let liveServicesAllowed: Bool
}
