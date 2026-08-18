#if DEBUG
import Foundation
import Testing
@testable import Vela

@Suite("Vela visual preview fixtures")
struct VelaPreviewFixtureTests {
    @Test("Preview scenarios cover every required state")
    func scenariosCoverStateMatrix() {
        #expect(Set(VelaPreviewScenario.allCases) == Set([
            .healthy,
            .stopped,
            .degraded,
            .loading,
            .empty,
            .permissionRequired,
            .transitioning,
            .rollbackFailed,
            .largeData,
        ]))

        let fixtures = VelaPreviewScenario.allCases.map {
            VelaPreviewFixtures.fixture(for: $0)
        }
        #expect(fixtures.map(\.scenario) == VelaPreviewScenario.allCases)
        #expect(Set(fixtures.map(\.id)).count == fixtures.count)
        #expect(VelaPreviewFixtures.fixture(for: .largeData).itemCount == 50_000)
        #expect(VelaPreviewFixtures.fixture(for: .transitioning).isBusy)
        #expect(VelaPreviewFixtures.fixture(for: .rollbackFailed).status == .error)
    }

    @Test("Preview inputs are deterministic across machines")
    func environmentIsDeterministic() {
        let environment = VelaPreviewFixtures.environment

        #expect(environment.localeIdentifier == "en_US_POSIX")
        #expect(environment.calendarIdentifier == "gregorian")
        #expect(environment.timeZoneIdentifier == "UTC")
        #expect(environment.referenceDate == Date(timeIntervalSince1970: 1_767_225_600))
        #expect(environment.nodeNames == ["Primary", "Fallback", "Direct"])
        #expect(environment.identifiers.count == Set(environment.identifiers).count)
        #expect(environment.chartSamples.count == 12)
        #expect(!environment.animationsEnabled)
    }

    @Test("Status fixtures exercise every semantic status")
    func statusFixturesCoverSemanticVocabulary() {
        #expect(Set(VelaPreviewFixtures.statusPills.map(\.status)) == Set(VelaSemanticStatus.allCases))
        #expect(hasUniqueIDs(VelaPreviewFixtures.statusPills))
    }

    @Test("Component fixture collections use stable unique identifiers")
    func fixtureIdentifiersAreStableAndUnique() {
        #expect(hasUniqueIDs(VelaPreviewFixtures.metricCards))
        #expect(hasUniqueIDs(VelaPreviewFixtures.stateBanners))
        #expect(hasUniqueIDs(VelaPreviewFixtures.emptyStates))
        #expect(hasUniqueIDs(VelaPreviewFixtures.inspectorValues))

        let identifiers = VelaPreviewFixtures.statusPills.map(\.id)
            + VelaPreviewFixtures.metricCards.map(\.id)
            + VelaPreviewFixtures.stateBanners.map(\.id)
            + VelaPreviewFixtures.emptyStates.map(\.id)
            + VelaPreviewFixtures.inspectorValues.map(\.id)
        #expect(identifiers.allSatisfy { identifier in
            !identifier.isEmpty
                && identifier.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        })
    }

    @Test("Fixtures are sendable pure values without external resource references")
    func fixturesRemainPureValues() {
        requireSendable(VelaPreviewScenario.allCases)
        requireSendable(VelaPreviewFixtures.environment)
        requireSendable(VelaPreviewScenario.allCases.map {
            VelaPreviewFixtures.fixture(for: $0)
        })
        requireSendable(VelaPreviewFixtures.statusPills)
        requireSendable(VelaPreviewFixtures.metricCards)
        requireSendable(VelaPreviewFixtures.stateBanners)
        requireSendable(VelaPreviewFixtures.emptyStates)
        requireSendable(VelaPreviewFixtures.inspectorValues)

        let surfacedText = String(describing: VelaPreviewFixtures.statusPills)
            + String(describing: VelaPreviewFixtures.metricCards)
            + String(describing: VelaPreviewFixtures.stateBanners)
            + String(describing: VelaPreviewFixtures.emptyStates)
            + String(describing: VelaPreviewFixtures.inspectorValues)
        for forbidden in ["http://", "https://", "/Users/", "secret=", "token="] {
            #expect(!surfacedText.localizedCaseInsensitiveContains(forbidden))
        }
    }

    private func hasUniqueIDs<Value: Identifiable>(_ values: [Value]) -> Bool
    where Value.ID: Hashable {
        Set(values.map(\.id)).count == values.count
    }

    private func requireSendable<Value: Sendable>(_: Value) {}
}
#endif
