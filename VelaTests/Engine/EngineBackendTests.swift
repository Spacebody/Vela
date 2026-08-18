import Foundation
import Testing
import VelaIPC
@testable import Vela

@Suite("Engine backend abstraction")
struct EngineBackendTests {
    @Test("User backend preserves the prepared launch and returns a redacted runtime")
    func userBackendStartAndStop() async throws {
        let manager = EngineBackendProcessManagerFake()
        let startedAt = Date(timeIntervalSince1970: 1_725_000_000)
        await manager.setStartedAt(startedAt)
        let backend = UserProcessEngineBackend(
            processManager: manager,
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
        let material = makeUserMaterial(secret: "controller-secret")

        let runtime = try await backend.start(EngineStartRequest(
            backend: .userProcess,
            material: material
        ))

        #expect(runtime.backend == .userProcess)
        #expect(runtime.processID == EngineBackendTestValues.pid)
        #expect(runtime.startedAt == startedAt)
        #expect(runtime.configurationSHA256 == EngineBackendTestValues.configurationSHA)
        #expect(runtime.controller.secret.description == "<redacted>")
        #expect(runtime.controller.secret.debugDescription == "SecretValue(<redacted>)")
        #expect(runtime.controller.secret.withValue { $0 } == "controller-secret")
        #expect(await manager.preparedStartCallCount() == 1)

        let runningStatus = try await backend.status()
        #expect(runningStatus.lifecycle == .running)
        #expect(runningStatus.runtime == runtime)
        #expect(runningStatus.processRunning)

        let report = try await backend.stop(EngineStopRequest(
            instanceID: runtime.instanceID,
            reason: .userRequested
        ))
        #expect(report.backend == .userProcess)
        #expect(report.instanceID == runtime.instanceID)
        #expect(report.processID == EngineBackendTestValues.pid)
        #expect(report.wasRunning)
        #expect(report.stopped)
        #expect(!report.forced)
        #expect(await manager.stopCallCount() == 1)

        let stoppedStatus = try await backend.status()
        #expect(stoppedStatus.lifecycle == .stopped)
        #expect(stoppedStatus.runtime == nil)
        #expect(!stoppedStatus.processRunning)
    }

    @Test("Prepared candidates are single-owner and abortable")
    func preparedCandidateOwnership() async throws {
        let backend = UserProcessEngineBackend(
            processManager: EngineBackendProcessManagerFake()
        )
        let request = EngineStartRequest(
            backend: .userProcess,
            material: makeUserMaterial()
        )
        let first = try await backend.prepareStart(request)

        do {
            _ = try await backend.prepareStart(request)
            Issue.record("Expected a second prepared candidate to be rejected")
        } catch let error as EngineBackendError {
            #expect(error == .preparationInProgress)
        }

        await backend.abortStart(first)
        let replacement = try await backend.prepareStart(request)
        #expect(replacement.id != first.id)
        await backend.abortStart(replacement)

        let status = try await backend.status()
        #expect(status.lifecycle == .stopped)
    }

    @Test("A stop request for another runtime cannot stop the owned process")
    func wrongRuntimeCannotStopProcess() async throws {
        let manager = EngineBackendProcessManagerFake()
        let backend = UserProcessEngineBackend(processManager: manager)
        let runtime = try await backend.start(EngineStartRequest(
            backend: .userProcess,
            material: makeUserMaterial()
        ))
        let wrongID = UUID()

        do {
            _ = try await backend.stop(EngineStopRequest(
                instanceID: wrongID,
                reason: .backendTransition
            ))
            Issue.record("Expected a mismatched runtime stop to be rejected")
        } catch let error as EngineBackendError {
            #expect(error == .runtimeMismatch(
                expected: wrongID,
                actual: runtime.instanceID
            ))
        }

        #expect(await manager.stopCallCount() == 0)
        #expect((try await backend.status()).processRunning)
        _ = try await backend.stop(EngineStopRequest(
            instanceID: runtime.instanceID,
            reason: .userRequested
        ))
    }

    @Test("Unexpected process termination is tagged with the active runtime identity")
    func unexpectedTerminationCarriesRuntimeIdentity() async throws {
        let manager = EngineBackendProcessManagerFake()
        let backend = UserProcessEngineBackend(processManager: manager)
        let events = await backend.events()
        let terminationTask = Task<EngineBackendTermination?, Never> {
            for await event in events {
                if case let .terminated(termination) = event,
                    !termination.expected
                {
                    return termination
                }
            }
            return nil
        }

        let runtime = try await backend.start(EngineStartRequest(
            backend: .userProcess,
            material: makeUserMaterial()
        ))
        await manager.emitUnexpectedTermination(status: 9)
        let termination = try #require(await terminationTask.value)

        #expect(termination.instanceID == runtime.instanceID)
        #expect(termination.backend == .userProcess)
        #expect(termination.processID == EngineBackendTestValues.pid)
        #expect(termination.exitCode == 9)
        #expect(!termination.expected)

        let status = try await backend.status()
        #expect(status.lifecycle == .failed)
        #expect(status.runtime == nil)
        #expect(!status.processRunning)
    }

    private func makeUserMaterial(
        secret: String = "test-secret"
    ) -> UserProcessEngineStartMaterial {
        let controllerEndpoint = URL(
            string: "http://127.0.0.1:19090"
        ) ?? URL(fileURLWithPath: "/invalid-controller-endpoint")
        let executable = ResolvedMihomoExecutable(
            url: URL(fileURLWithPath: "/tmp/VelaBackendTests/mihomo"),
            version: "v1.19.28",
            sha256: String(repeating: "a", count: 64)
        )
        return UserProcessEngineStartMaterial(
            preparedLaunch: MihomoPreparedLaunch(
                executable: executable,
                configurationURL: URL(fileURLWithPath: "/tmp/VelaBackendTests/active.yaml"),
                dataDirectoryURL: URL(fileURLWithPath: "/tmp/VelaBackendTests"),
                validationResult: EngineBackendTestValues.validValidation
            ),
            controller: EngineControllerAccess(
                endpoint: controllerEndpoint,
                secret: SecretValue(secret)
            ),
            configurationSHA256: EngineBackendTestValues.configurationSHA
        )
    }
}

nonisolated private enum EngineBackendTestValues {
    static let pid: Int32 = 42_424
    static let configurationSHA = String(repeating: "b", count: 64)
    static let validValidation = ConfigurationValidationResult(
        status: .valid,
        stdout: "configuration is valid",
        stderr: "",
        issues: [],
        duration: .milliseconds(1)
    )
}

private actor EngineBackendProcessManagerFake: MihomoProcessManaging {
    private var running = false
    private var preparedStartCalls = 0
    private var stopCalls = 0
    private var startedAt = Date(timeIntervalSince1970: 1_700_000_000)
    private var currentLaunch: MihomoPreparedLaunch?
    private var continuations: [
        UUID: AsyncStream<MihomoProcessEvent>.Continuation
    ] = [:]

    func setStartedAt(_ date: Date) {
        startedAt = date
    }

    func start(
        configurationURL: URL,
        dataDirectoryURL: URL?,
        additionalArguments: [String],
        validationTimeout: Duration
    ) async throws -> MihomoProcessSnapshot {
        guard let currentLaunch else {
            throw EngineBackendError.invalidPreparedCandidate
        }
        return try await start(preparedLaunch: currentLaunch)
    }

    func start(preparedLaunch: MihomoPreparedLaunch) async throws -> MihomoProcessSnapshot {
        preparedStartCalls += 1
        currentLaunch = preparedLaunch
        running = true
        let snapshot = makeSnapshot()
        emit(.started(snapshot))
        return snapshot
    }

    func stop(timeout: Duration) async throws -> MihomoProcessTermination? {
        stopCalls += 1
        guard running else { return nil }
        running = false
        let termination = MihomoProcessTermination(
            pid: EngineBackendTestValues.pid,
            status: 0,
            reason: .exit,
            expected: true,
            forced: false,
            stdout: "",
            stderr: "",
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(1)
        )
        emit(.terminated(termination))
        return termination
    }

    func restart(
        configurationURL: URL,
        dataDirectoryURL: URL?,
        additionalArguments: [String],
        validationTimeout: Duration,
        stopTimeout: Duration
    ) async throws -> MihomoProcessSnapshot {
        _ = try await stop(timeout: stopTimeout)
        return try await start(
            configurationURL: configurationURL,
            dataDirectoryURL: dataDirectoryURL,
            additionalArguments: additionalArguments,
            validationTimeout: validationTimeout
        )
    }

    func isRunning() async -> Bool {
        running
    }

    func snapshot() async -> MihomoProcessSnapshot {
        running ? makeSnapshot() : .stopped
    }

    func events() async -> AsyncStream<MihomoProcessEvent> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(64)) { continuation in
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    func emitUnexpectedTermination(status: Int32) {
        guard running else { return }
        running = false
        emit(.terminated(MihomoProcessTermination(
            pid: EngineBackendTestValues.pid,
            status: status,
            reason: .exit,
            expected: false,
            forced: false,
            stdout: "",
            stderr: "",
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(1)
        )))
    }

    func preparedStartCallCount() -> Int {
        preparedStartCalls
    }

    func stopCallCount() -> Int {
        stopCalls
    }

    private func makeSnapshot() -> MihomoProcessSnapshot {
        MihomoProcessSnapshot(
            pid: EngineBackendTestValues.pid,
            isRunning: running,
            executable: currentLaunch?.executable,
            configurationURL: currentLaunch?.configurationURL,
            startedAt: startedAt
        )
    }

    private func emit(_ event: MihomoProcessEvent) {
        for continuation in continuations.values {
            continuation.yield(event)
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }
}
