import Foundation
import Testing
@testable import Vela

@MainActor
@Suite("Daily driver bootstrap recovery gate")
struct DailyDriverBootstrapGateTests {
    @Test("Successful recovery starts scheduling with current network state")
    func successfulRecoveryStartsScheduling() async {
        let recorder = RecoveryGateRecorder()
        let gate = makeGate(recorder: recorder)

        let error = await gate.bootstrap(networkAvailable: false)

        #expect(error == nil)
        #expect(recorder.recoveryAttempts == 1)
        #expect(recorder.schedulingStarts == [false])
        #expect(recorder.presentedErrors.isEmpty)
    }

    @Test("Failed recovery is visible and keeps subscription scheduling paused")
    func failedRecoveryPausesScheduling() async {
        let recorder = RecoveryGateRecorder(
            recoveryError: RuntimeConfigTransactionError.rollbackFailed
        )
        let gate = makeGate(recorder: recorder)

        let error = await gate.bootstrap(networkAvailable: true)

        #expect(recorder.recoveryAttempts == 1)
        #expect(recorder.schedulingStarts.isEmpty)
        #expect(recorder.presentedErrors == [error].compactMap { $0 })
        #expect(error?.category == .startup)
        #expect(error?.technicalDetails == "Recovery code: runtime-transaction-recovery-rollback-failed")
        #expect(error?.recoveryActions == [.openDiagnostics, .copyRedactedDetails])
        #expect(error?.message.contains("paused") == false)
        #expect(
            error?.suggestedAction == VelaL10n.string(
                "error.configurationRecovery.action",
                defaultValue:
                    "Open Diagnostics and copy the redacted recovery code. Scheduled remote profile updates remain paused until recovery succeeds on a later launch."
            )
        )
    }

    @Test("Unexpected recovery details never cross the user-facing boundary")
    func unexpectedErrorIsRedacted() async {
        let sensitivePath = "/Users/alice/Library/Application Support/Vela/transaction-secret.json"
        let sensitiveYAML = "proxies: [password: swordfish]"
        let recorder = RecoveryGateRecorder(
            recoveryError: SensitiveRecoveryError(
                description: "\(sensitivePath) \(sensitiveYAML)"
            )
        )
        let gate = makeGate(recorder: recorder)

        let error = await gate.bootstrap(networkAvailable: true)
        let visibleText = [
            error?.title,
            error?.message,
            error?.technicalDetails,
            error?.suggestedAction,
        ]
        .compactMap { $0 }
        .joined(separator: " ")

        #expect(recorder.schedulingStarts.isEmpty)
        #expect(error?.technicalDetails == "Recovery code: runtime-transaction-recovery-unexpected")
        #expect(!visibleText.contains(sensitivePath))
        #expect(!visibleText.contains("swordfish"))
        #expect(!visibleText.contains("proxies:"))
    }

    @Test("Cancellation neither schedules work nor presents a recovery failure")
    func cancellationStopsBootstrapQuietly() async {
        let recorder = RecoveryGateRecorder(recoveryError: CancellationError())
        let gate = makeGate(recorder: recorder)

        let error = await gate.bootstrap(networkAvailable: true)

        #expect(error == nil)
        #expect(recorder.schedulingStarts.isEmpty)
        #expect(recorder.presentedErrors.isEmpty)
    }

    private func makeGate(
        recorder: RecoveryGateRecorder
    ) -> DailyDriverBootstrapGate {
        DailyDriverBootstrapGate(
            recover: {
                try await recorder.recover()
            },
            startScheduling: { networkAvailable in
                recorder.startScheduling(networkAvailable: networkAvailable)
            },
            presentFailure: { error in
                recorder.present(error)
            }
        )
    }
}

@MainActor
private final class RecoveryGateRecorder {
    let recoveryError: (any Error)?
    private(set) var recoveryAttempts = 0
    private(set) var schedulingStarts: [Bool] = []
    private(set) var presentedErrors: [UserFacingError] = []

    init(recoveryError: (any Error)? = nil) {
        self.recoveryError = recoveryError
    }

    func recover() async throws {
        recoveryAttempts += 1
        if let recoveryError {
            throw recoveryError
        }
    }

    func startScheduling(networkAvailable: Bool) {
        schedulingStarts.append(networkAvailable)
    }

    func present(_ error: UserFacingError) {
        presentedErrors.append(error)
    }
}

private struct SensitiveRecoveryError: LocalizedError {
    let description: String

    var errorDescription: String? { description }
}
