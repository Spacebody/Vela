import Testing
@testable import Vela

@Suite("Localized runtime status presentation")
struct VelaRuntimeStatusPresentationTests {
    @Test("Engine failures do not expose raw associated details in primary UI copy")
    func engineFailureRedactsAssociatedDetail() {
        let text = VelaRuntimeStatusPresentation.engineFailureSummary(
            .configurationInvalid("sensitive runtime detail")
        )

        #expect(!text.contains("sensitive runtime detail"))
    }

    @Test("Privileged component UI detail does not expose raw failure messages")
    func helperDetailRedactsRawFailures() {
        let damaged = VelaRuntimeStatusPresentation.helperDetail(
            .damaged("sensitive damaged detail")
        )
        let failed = VelaRuntimeStatusPresentation.helperDetail(
            .failed(
                UserFacingError(
                    title: "Technical",
                    message: "sensitive helper detail",
                    isRetryable: false
                )
            )
        )

        #expect(damaged?.contains("sensitive damaged detail") == false)
        #expect(failed?.contains("sensitive helper detail") == false)
    }

    @Test("Update failure detail keeps the stable code but not the raw message")
    func updateFailureUsesStableCode() {
        let text = VelaRuntimeStatusPresentation.updateLifecycleDetail(
            .failed(code: "update_failed", message: "sensitive update detail")
        )

        #expect(text?.contains("update_failed") == true)
        #expect(text?.contains("sensitive update detail") == false)
    }

    @Test("Health presentation is derived from component, not raw prose")
    func healthIssueUsesComponentSemantics() {
        let issue = EngineHealthIssue(
            component: .controller,
            severity: .error,
            summary: "sensitive health summary",
            suggestedAction: "sensitive health action"
        )

        let title = VelaRuntimeStatusPresentation.healthIssueTitle(issue)
        let action = VelaRuntimeStatusPresentation.healthIssueAction(issue)

        #expect(!title.contains("sensitive health summary"))
        #expect(!action.contains("sensitive health action"))
    }
}
