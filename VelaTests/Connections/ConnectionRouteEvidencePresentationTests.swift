import Testing
@testable import Vela

@Suite("Connections route evidence presentation")
struct ConnectionRouteEvidencePresentationTests {
    @Test("Only explicit exact confidence uses a success status")
    func onlyExactConfidenceSucceeds() {
        let exact = ConnectionRouteEvidencePresentation(confidence: .exact)
        let nonExact = [
            ConnectionRouteEvidencePresentation(confidence: .ambiguous),
            ConnectionRouteEvidencePresentation(confidence: .unavailable),
            ConnectionRouteEvidencePresentation(confidence: .staleGeneration),
        ]

        #expect(exact.semanticStatus == .success)
        #expect(nonExact.allSatisfy { $0.semanticStatus != .success })
    }

    @Test("Current Mihomo response reports unavailable source confidence")
    func currentResponseDoesNotClaimExactEvidence() {
        let presentation = ConnectionRouteEvidencePresentation.currentMihomoResponse

        #expect(presentation.confidence == .unavailable)
        #expect(presentation.semanticStatus == .neutral)
        #expect(presentation.label == "Confidence Unavailable")
        #expect(presentation.label != "Runtime Evidence")
    }

    @Test("Ambiguous and stale evidence remain visibly distinct")
    func nonExactEvidenceHasSpecificSemantics() {
        let ambiguous = ConnectionRouteEvidencePresentation(confidence: .ambiguous)
        let stale = ConnectionRouteEvidencePresentation(confidence: .staleGeneration)

        #expect(ambiguous.semanticStatus == .warning)
        #expect(ambiguous.label == "Ambiguous Route Evidence")
        #expect(stale.semanticStatus == .stale)
        #expect(stale.label == "Stale Route Evidence")
    }
}
