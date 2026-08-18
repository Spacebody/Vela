import Foundation
import Testing
@testable import Vela

@Suite("Unlock probe response evaluation")
struct UnlockProbeEvaluatorTests {
    @Test("A custom unlock probe survives persistence")
    func customProbePersistenceRoundTrip() throws {
        let definition = StoredUnlockProbeDefinition(
            name: "Example",
            category: "Custom",
            url: URL(string: "https://example.com/status")!
        )

        let data = try JSONEncoder().encode([definition])
        let restored = try JSONDecoder().decode(
            [StoredUnlockProbeDefinition].self,
            from: data
        )

        #expect(restored == [definition])
        #expect(restored.first?.probeDefinition?.url.scheme == "https")
    }

    @Test("Custom services replace only the custom catalog")
    @MainActor
    func replacingCustomServicesKeepsBuiltIns() {
        let model = UnlockTestsViewModel()
        let builtInCount = model.services.count
        let custom = UnlockProbeDefinition(
            id: "custom.example",
            name: "Example",
            category: "Custom",
            systemImage: "network",
            url: URL(string: "https://example.com")!
        )

        model.replaceCustomServices(with: [custom])
        #expect(model.services.count == builtInCount + 1)
        #expect(model.services.last?.id == custom.id)

        model.replaceCustomServices(with: [])
        #expect(model.services.count == builtInCount)
    }

    @Test("A successful public endpoint is available")
    func successfulEndpointIsAvailable() {
        let result = UnlockProbeEvaluator.evaluate(
            statusCode: 204,
            body: Data(),
            latencyMilliseconds: 42,
            region: "JP"
        )

        #expect(result.status == .available)
        #expect(result.latencyMilliseconds == 42)
        #expect(result.region == "JP")
    }

    @Test("Regional markers and HTTP 451 are limited")
    func regionalRestrictionIsLimited() {
        for (statusCode, body) in [
            (200, Data("This service is not available in your region".utf8)),
            (451, Data()),
        ] {
            let result = UnlockProbeEvaluator.evaluate(
                statusCode: statusCode,
                body: body,
                latencyMilliseconds: 10,
                region: nil
            )

            #expect(result.status == .limited)
        }
    }

    @Test("A server failure is unavailable")
    func serverFailureIsUnavailable() {
        let result = UnlockProbeEvaluator.evaluate(
            statusCode: 503,
            body: Data(),
            latencyMilliseconds: 18,
            region: nil
        )

        #expect(result.status == .failed)
    }
}
