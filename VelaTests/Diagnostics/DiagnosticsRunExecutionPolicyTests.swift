import Foundation
import Testing
@testable import Vela

@Suite("Diagnostics run execution policy", .serialized)
struct DiagnosticsRunExecutionPolicyTests {
    @Test("History contains only checks attempted by the completed step")
    func historyContainsOnlyAttemptedChecks() {
        let rows = [row(id: "core", result: .passed), row(id: "provider", result: .warning)]
        let entries = DiagnosticsRunHistoryPolicy.entries(
            runID: "RUN12345",
            rows: rows,
            attemptedCheckIDs: ["provider"],
            outcome: .completed,
            completedAt: Date(timeIntervalSinceReferenceDate: 42),
            durationSeconds: 0.25
        )

        #expect(entries.map(\.checkID) == ["provider"])
        #expect(entries.first?.result == .warning)
        #expect(entries.first?.durationSeconds == 0.25)
    }

    @Test("A completed step does not fabricate a skipped result")
    func attemptedNotRunCheckBecomesSkipped() {
        let entries = DiagnosticsRunHistoryPolicy.entries(
            runID: "RUN12345",
            rows: [row(id: "provider", result: .notRun)],
            attemptedCheckIDs: ["provider"],
            outcome: .completed,
            completedAt: Date(timeIntervalSinceReferenceDate: 42),
            durationSeconds: 0.1
        )

        #expect(entries.isEmpty)
        #expect(
            DiagnosticsRunHistoryPolicy.resolvedResult(
                current: .notRun,
                latestHistory: entries.first
            ) == .notRun
        )
    }

    @Test("An explicitly skipped step is recorded as skipped")
    func explicitSkipIsRecorded() {
        let entries = DiagnosticsRunHistoryPolicy.entries(
            runID: "RUN12345",
            rows: [row(id: "provider", result: .notRun)],
            attemptedCheckIDs: ["provider"],
            outcome: .skipped(reason: "Controller unavailable"),
            completedAt: Date(timeIntervalSinceReferenceDate: 42),
            durationSeconds: 0.1
        )

        #expect(entries.first?.result == .skipped)
    }

    @Test("Execution failures override an otherwise unresolved check")
    func executionFailureIsRecorded() {
        let entries = DiagnosticsRunHistoryPolicy.entries(
            runID: "RUN12345",
            rows: [row(id: "core", result: .notRun)],
            attemptedCheckIDs: ["core"],
            outcome: .failed(message: "probe failed"),
            completedAt: Date(timeIntervalSinceReferenceDate: 42),
            durationSeconds: 0.1
        )

        #expect(entries.first?.result == .failed)
    }

    @Test("Current evidence remains authoritative once it has a concrete result")
    func currentEvidenceWinsOverHistory() {
        let history = DiagnosticsRunHistoryEntry(
            id: "history",
            checkID: "core",
            runID: "RUN12345",
            result: .failed,
            completedAt: Date(timeIntervalSinceReferenceDate: 42),
            durationSeconds: 0.1
        )

        #expect(
            DiagnosticsRunHistoryPolicy.resolvedResult(
                current: .passed,
                latestHistory: history
            ) == .passed
        )
    }

    @Test("Generation gate rejects stale completion")
    func generationGateRejectsStaleCompletion() {
        var gate = DiagnosticsRunGenerationGate()
        let current = UUID()
        let stale = UUID()

        let beganCurrent = gate.begin(current)
        let beganStale = gate.begin(stale)
        let finishedStale = gate.finish(stale)
        #expect(beganCurrent)
        #expect(!beganStale)
        #expect(!finishedStale)
        #expect(gate.accepts(current))
        let finishedCurrent = gate.finish(current)
        #expect(finishedCurrent)
        #expect(gate.activeRunID == nil)
    }

    @Test("Registry duplicate IDs are deterministic and visible")
    func registryReportsDuplicateIDs() {
        let snapshot = DiagnosticsWorkspaceSnapshot(
            registryRevision: "test",
            groups: [
                DiagnosticsCheckGroupModel(
                    category: .updatesCore,
                    checks: [row(id: "duplicate", result: .passed)]
                ),
                DiagnosticsCheckGroupModel(
                    category: .supportEvidence,
                    checks: [row(id: "duplicate", result: .warning)]
                ),
            ],
            registryError: nil,
            isRegistryLoading: false,
            isStale: false
        )

        #expect(snapshot.duplicateCheckIDs == ["duplicate"])
    }

    @Test("Bounded executor returns the operation result before its deadline")
    @MainActor
    func boundedExecutorCompletes() async {
        let result = await DiagnosticsRunOperationExecutor.execute(timeoutSeconds: 1) {
            .completed
        }

        #expect(result == .completed)
    }

    @Test("Bounded executor times out a cooperative slow operation")
    @MainActor
    func boundedExecutorTimesOut() async {
        let result = await DiagnosticsRunOperationExecutor.execute(timeoutSeconds: 0.01) {
            do {
                try await Task.sleep(for: .seconds(1))
                return .completed
            } catch {
                return .cancelled
            }
        }

        #expect(result == .timedOut(seconds: 0.01))
    }

    @Test("Timeout does not wait for an operation that ignores cooperative cancellation")
    @MainActor
    func boundedExecutorDoesNotWaitForCancellation() async {
        let startedAt = Date.now
        let result = await DiagnosticsRunOperationExecutor.execute(timeoutSeconds: 0.01) {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
                    continuation.resume()
                }
            }
            return .completed
        }

        #expect(result == .timedOut(seconds: 0.01))
        #expect(Date.now.timeIntervalSince(startedAt) < 0.1)
    }

    @Test("Cancelling a bounded operation does not fabricate a failure")
    @MainActor
    func boundedExecutorCancels() async {
        let (started, startedContinuation) = AsyncStream.makeStream(of: Void.self)
        let task = Task { @MainActor in
            await DiagnosticsRunOperationExecutor.execute(timeoutSeconds: 1) {
                startedContinuation.yield()
                do {
                    try await Task.sleep(for: .seconds(1))
                    return .completed
                } catch {
                    return .cancelled
                }
            }
        }
        var iterator = started.makeAsyncIterator()
        _ = await iterator.next()
        task.cancel()

        let result = await task.value
        #expect(result == .cancelled, "Expected cancellation, got \(result)")
    }

    @Test("Fifty checks keep deterministic registry order")
    func fiftyChecksRemainDeterministic() {
        let rows = (0..<50).map { row(id: "check.\($0)", result: .passed) }
        let attempted = rows.map(\.id)
        let entries = DiagnosticsRunHistoryPolicy.entries(
            runID: "RUN12345",
            rows: rows,
            attemptedCheckIDs: attempted,
            outcome: .completed,
            completedAt: Date(timeIntervalSinceReferenceDate: 42),
            durationSeconds: 0.5
        )

        #expect(entries.map(\.checkID) == attempted)
    }

    @Test("Per-check history remains bounded after one hundred runs")
    func recentHistoryIsBounded() {
        let history = (0..<100).map { index in
            DiagnosticsRunHistoryEntry(
                id: "history.\(index)",
                checkID: "core",
                runID: "RUN\(index)",
                result: .passed,
                completedAt: Date(timeIntervalSinceReferenceDate: Double(index)),
                durationSeconds: 0.1
            )
        }
        let boundedRow = DiagnosticsCheckRowModel(
            id: "core",
            category: .updatesCore,
            title: "core",
            result: .passed,
            resultLabel: "passed",
            evidence: DiagnosticsEvidencePresentation(
                state: .sufficient,
                source: "test",
                capturedAt: nil,
                summary: "test",
                confidence: "test"
            ),
            applicability: "test",
            evidenceSchema: "test",
            history: history
        )

        #expect(boundedRow.history.count == 20)
        #expect(boundedRow.history.first?.runID == "RUN0")
    }

    @Test("Repair is offered only when an actionable check needs attention")
    func repairAvailabilityFollowsResult() {
        let makeRow: (DiagnosticsCheckResult, DiagnosticsRepairAction?) -> DiagnosticsCheckRowModel = {
            result, action in
            DiagnosticsCheckRowModel(
                id: "system-proxy",
                category: .networkPrivilege,
                title: "System Proxy",
                result: result,
                resultLabel: result.rawValue,
                evidence: DiagnosticsEvidencePresentation(
                    state: .unavailable,
                    source: "test",
                    capturedAt: nil,
                    summary: "test",
                    confidence: "test"
                ),
                applicability: "test",
                repairAction: action,
                evidenceSchema: "test"
            )
        }

        #expect(makeRow(.warning, .restoreSystemProxy).offersRepair)
        #expect(makeRow(.failed, .restoreSystemProxy).offersRepair)
        #expect(makeRow(.blocked, .reinstallPrivilegedComponent).offersRepair)
        #expect(makeRow(.stale, .restoreSystemProxy).offersRepair)
        #expect(!makeRow(.passed, .restoreSystemProxy).offersRepair)
        #expect(!makeRow(.notRun, .restoreSystemProxy).offersRepair)
        #expect(!makeRow(.warning, nil).offersRepair)
    }

    private func row(
        id: String,
        result: DiagnosticsCheckResult
    ) -> DiagnosticsCheckRowModel {
        DiagnosticsCheckRowModel(
            id: id,
            category: .updatesCore,
            title: id,
            result: result,
            resultLabel: result.rawValue,
            evidence: DiagnosticsEvidencePresentation(
                state: .unavailable,
                source: "test",
                capturedAt: nil,
                summary: "test",
                confidence: "test"
            ),
            applicability: "test",
            evidenceSchema: "test"
        )
    }
}
