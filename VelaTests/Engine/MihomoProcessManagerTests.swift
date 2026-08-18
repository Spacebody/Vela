import Darwin
import Dispatch
import Foundation
import Testing
@testable import Vela

@Suite(.serialized)
struct MihomoProcessManagerTests {
    @Test
    func launchUsesManagedArgumentsDirectoryAndSanitizedEnvironment() async throws {
        let directory = try ProcessTestSupport.makeTemporaryDirectory()
        defer { ProcessTestSupport.removeTemporaryDirectory(directory) }
        let home = directory.appending(path: "mihomo", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let executable = try ProcessTestSupport.makeScript(
            in: directory,
            body: """
            printf 'args:%s\\n' "$*"
            printf 'pwd:%s\\n' "$PWD"
            if /usr/bin/env | /usr/bin/grep -q '^CLASH_'; then
              printf 'clash-env-present\\n'
            else
              printf 'clash-env-clean\\n'
            fi
            exec /bin/sleep 30
            """
        )
        let configuration = directory.appending(path: "active.yaml")
        let manager = MihomoProcessManager(
            resolver: StubMihomoExecutableResolver(
                result: .success(ProcessTestSupport.resolvedExecutable(at: executable))
            ),
            validator: StubConfigurationValidator(
                result: ProcessTestSupport.validConfigurationResult()
            ),
            environment: [
                "PATH": "/usr/bin:/bin",
                "CLASH_CONFIG_STRING": "untrusted",
                "CLASH_HOME_DIR": "/tmp/untrusted",
            ]
        )
        let events = await manager.events()
        let outputTask = Task<String, Never> {
            var captured = ""
            for await event in events {
                guard case let .output(output) = event else { continue }
                captured.append(output.text)
                if captured.contains("clash-env-clean") {
                    return captured
                }
            }
            return captured
        }

        _ = try await manager.start(
            configurationURL: configuration,
            dataDirectoryURL: home
        )
        let capturedOutput = await outputTask.value
        _ = try #require(try await manager.stop(timeout: .seconds(1)))

        #expect(capturedOutput.contains(
            "args:-d \(home.path) -f \(configuration.path)"
        ))
        let acceptableWorkingDirectories = [
            home.path,
            home.path.hasPrefix("/var/") ? "/private\(home.path)" : home.path,
        ]
        #expect(acceptableWorkingDirectories.contains { path in
            capturedOutput.contains("pwd:\(path)")
        })
        #expect(capturedOutput.contains("clash-env-clean"))
        #expect(!capturedOutput.contains("clash-env-present"))
    }

    @Test
    func verifiedPreparedLaunchIsNotResolvedOrValidatedTwice() async throws {
        let directory = try ProcessTestSupport.makeTemporaryDirectory()
        defer { ProcessTestSupport.removeTemporaryDirectory(directory) }
        let executable = try ProcessTestSupport.makeScript(
            in: directory,
            body: "exec /bin/sleep 30"
        )
        let resolver = StubMihomoExecutableResolver(
            result: .failure(.resourceMissing(name: "must-not-run"))
        )
        let validator = StubConfigurationValidator(
            result: ProcessTestSupport.invalidConfigurationResult()
        )
        let manager = MihomoProcessManager(resolver: resolver, validator: validator)
        let prepared = MihomoPreparedLaunch(
            executable: ProcessTestSupport.resolvedExecutable(at: executable),
            configurationURL: directory.appending(path: "active.yaml"),
            dataDirectoryURL: directory,
            validationResult: ProcessTestSupport.validConfigurationResult()
        )

        let snapshot = try await manager.start(preparedLaunch: prepared)

        #expect(snapshot.isRunning)
        #expect(await resolver.calls() == 0)
        #expect(await validator.callCount() == 0)
        _ = try await manager.stop(timeout: .seconds(1))
    }

    @Test
    func signedMachOStartAndStopKeepsTheVerifiedVnodeBound() async throws {
        let directory = try ProcessTestSupport.makeTemporaryDirectory()
        defer { ProcessTestSupport.removeTemporaryDirectory(directory) }
        let executable = URL(fileURLWithPath: "/usr/bin/yes")
        let prepared = MihomoPreparedLaunch(
            executable: ProcessTestSupport.resolvedExecutable(at: executable),
            configurationURL: directory.appending(path: "active.yaml"),
            dataDirectoryURL: directory,
            validationResult: ProcessTestSupport.validConfigurationResult()
        )
        let manager = MihomoProcessManager(
            resolver: StubMihomoExecutableResolver(
                result: .success(prepared.executable)
            ),
            validator: StubConfigurationValidator(
                result: ProcessTestSupport.validConfigurationResult()
            )
        )

        let snapshot = try await manager.start(preparedLaunch: prepared)

        #expect(snapshot.isRunning)
        #expect(snapshot.pid != nil)
        #expect(snapshot.executable?.verifiedFile == prepared.executable.verifiedFile)
        let termination = try #require(
            try await manager.stop(timeout: .seconds(1))
        )
        #expect(termination.expected)
        #expect(!(await manager.isRunning()))
    }

    @Test
    func pathnameSwapAfterFinalPreflightCannotBecomeTheRunningImage() async throws {
        let directory = try ProcessTestSupport.makeTemporaryDirectory()
        defer { ProcessTestSupport.removeTemporaryDirectory(directory) }
        let executable = directory.appending(path: "mihomo")
        let replacement = directory.appending(path: "replacement")
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: "/usr/bin/yes"),
            to: executable
        )
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: "/bin/echo"),
            to: replacement
        )

        let resolved = ProcessTestSupport.resolvedExecutable(at: executable)
        let barrier = AtomicProcessRunBarrier()
        let manager = MihomoProcessManager(
            resolver: StubMihomoExecutableResolver(result: .success(resolved)),
            validator: StubConfigurationValidator(
                result: ProcessTestSupport.validConfigurationResult()
            ),
            beforeAtomicProcessRun: { barrier.pause() }
        )
        let prepared = MihomoPreparedLaunch(
            executable: resolved,
            configurationURL: directory.appending(path: "active.yaml"),
            dataDirectoryURL: directory,
            validationResult: ProcessTestSupport.validConfigurationResult()
        )
        // The suite inherits the test target's MainActor isolation. Detach the
        // start so the synchronous semaphore below does not block the task
        // before it reaches the injected launch barrier.
        let startTask = Task.detached(priority: .userInitiated) {
            try await manager.start(preparedLaunch: prepared)
        }

        #expect(await barrier.waitUntilPaused())
        let renameStatus = replacement.withUnsafeFileSystemRepresentation { source in
            executable.withUnsafeFileSystemRepresentation { destination in
                guard let source, let destination else { return -1 }
                return Int(Darwin.rename(source, destination))
            }
        }
        #expect(renameStatus == 0)
        barrier.resume()

        do {
            _ = try await startTask.value
            Issue.record("Expected the post-preflight pathname swap to be rejected")
        } catch let error as MihomoProcessManagerError {
            guard case let .coreIntegrityChanged(path, message) = error else {
                Issue.record("Unexpected process manager error: \(error)")
                return
            }
            #expect(path == executable.path)
            #expect(
                message.contains("vnode")
                    || message.contains("identity")
                    || message.contains("exited")
            )
        }

        #expect(!(await manager.isRunning()))
        #expect(await manager.snapshot() == .stopped)
    }

    @Test
    func sameSignedImageSwapIsKilledAndReapedOnVnodeMismatch() async throws {
        let directory = try ProcessTestSupport.makeTemporaryDirectory()
        defer { ProcessTestSupport.removeTemporaryDirectory(directory) }
        let executable = directory.appending(path: "mihomo")
        let replacement = directory.appending(path: "same-code-replacement")
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: "/usr/bin/yes"),
            to: executable
        )
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: "/usr/bin/yes"),
            to: replacement
        )

        let resolved = ProcessTestSupport.resolvedExecutable(at: executable)
        let originalIdentity = try #require(resolved.verifiedFile)
        let replacementIdentity = try POSIXMihomoCoreFileInspector().inspectExecutable(
            at: replacement
        )
        #expect(originalIdentity.inode != replacementIdentity.inode)

        let barrier = AtomicProcessRunBarrier()
        let manager = MihomoProcessManager(
            resolver: StubMihomoExecutableResolver(result: .success(resolved)),
            validator: StubConfigurationValidator(
                result: ProcessTestSupport.validConfigurationResult()
            ),
            beforeAtomicProcessRun: { barrier.pause() }
        )
        let prepared = MihomoPreparedLaunch(
            executable: resolved,
            configurationURL: directory.appending(path: "active.yaml"),
            dataDirectoryURL: directory,
            validationResult: ProcessTestSupport.validConfigurationResult()
        )
        let startTask = Task.detached(priority: .userInitiated) {
            try await manager.start(preparedLaunch: prepared)
        }

        #expect(await barrier.waitUntilPaused())
        let renameStatus = replacement.withUnsafeFileSystemRepresentation { source in
            executable.withUnsafeFileSystemRepresentation { destination in
                guard let source, let destination else { return -1 }
                return Int(Darwin.rename(source, destination))
            }
        }
        #expect(renameStatus == 0)
        barrier.resume()

        do {
            _ = try await startTask.value
            Issue.record("Expected the different vnode to be rejected")
        } catch let error as MihomoProcessManagerError {
            guard case let .coreIntegrityChanged(path, message) = error else {
                Issue.record("Unexpected process manager error: \(error)")
                return
            }
            #expect(path == executable.path)
            #expect(message.contains("vnode"))
        }

        // launch() publishes managed state only after the post-spawn checks;
        // its rejection path synchronously SIGKILLs and reaps the child.
        #expect(!(await manager.isRunning()))
        #expect(await manager.snapshot() == .stopped)
    }

    @Test
    func concurrentStartSharesPreparationAndCreatesOnlyOneProcess() async throws {
        let directory = try ProcessTestSupport.makeTemporaryDirectory()
        defer { ProcessTestSupport.removeTemporaryDirectory(directory) }
        let executable = try ProcessTestSupport.makeScript(
            in: directory,
            body: "echo started; exec /bin/sleep 30"
        )
        let configuration = try ProcessTestSupport.makeScript(
            in: directory,
            name: "active.yaml",
            body: "# configuration",
            executable: false
        )
        let resolver = StubMihomoExecutableResolver(
            result: .success(ProcessTestSupport.resolvedExecutable(at: executable)),
            delay: .milliseconds(40)
        )
        let validator = StubConfigurationValidator(
            result: ProcessTestSupport.validConfigurationResult(),
            delay: .milliseconds(40)
        )
        let manager = MihomoProcessManager(resolver: resolver, validator: validator)

        async let firstStart = manager.start(configurationURL: configuration)
        async let secondStart = manager.start(configurationURL: configuration)
        let (first, second) = try await (firstStart, secondStart)

        #expect(first.isRunning)
        #expect(first.pid == second.pid)
        #expect(await resolver.calls() == 1)
        #expect(await validator.callCount() == 1)

        let termination = try #require(try await manager.stop(timeout: .seconds(1)))
        #expect(termination.pid == first.pid)
        #expect(termination.expected)
        #expect(!(await manager.isRunning()))
        #expect(try await manager.stop(timeout: .milliseconds(50)) == nil)
    }

    @Test
    func differentConcurrentLaunchRequestsNeverSharePreparation() async throws {
        let directory = try ProcessTestSupport.makeTemporaryDirectory()
        defer { ProcessTestSupport.removeTemporaryDirectory(directory) }
        let executable = try ProcessTestSupport.makeScript(
            in: directory,
            body: "exec /bin/sleep 30"
        )
        let resolver = StubMihomoExecutableResolver(
            result: .success(ProcessTestSupport.resolvedExecutable(at: executable)),
            delay: .milliseconds(100)
        )
        let manager = MihomoProcessManager(
            resolver: resolver,
            validator: StubConfigurationValidator(
                result: ProcessTestSupport.validConfigurationResult()
            )
        )
        let firstConfiguration = directory.appending(path: "first.yaml")
        let secondConfiguration = directory.appending(path: "second.yaml")

        let firstStart = Task {
            try await manager.start(configurationURL: firstConfiguration)
        }
        try await Task.sleep(for: .milliseconds(20))

        do {
            _ = try await manager.start(configurationURL: secondConfiguration)
            Issue.record("Expected a different launch request to be rejected")
        } catch let error as MihomoProcessManagerError {
            #expect(error == .launchPreparationInProgress)
        }

        let first = try await firstStart.value
        #expect(first.configurationURL == firstConfiguration)
        _ = try await manager.stop(timeout: .seconds(1))
    }

    @Test
    func invalidConfigurationPreventsLaunch() async throws {
        let directory = try ProcessTestSupport.makeTemporaryDirectory()
        defer { ProcessTestSupport.removeTemporaryDirectory(directory) }
        let executable = try ProcessTestSupport.makeScript(
            in: directory,
            body: "exec /bin/sleep 30"
        )
        let configuration = directory.appending(path: "invalid.yaml")
        let expectedValidation = ProcessTestSupport.invalidConfigurationResult(line: 11)
        let manager = MihomoProcessManager(
            resolver: StubMihomoExecutableResolver(
                result: .success(ProcessTestSupport.resolvedExecutable(at: executable))
            ),
            validator: StubConfigurationValidator(result: expectedValidation)
        )

        do {
            _ = try await manager.start(configurationURL: configuration)
            Issue.record("Expected configuration validation to prevent launch")
        } catch let error as MihomoProcessManagerError {
            #expect(error == .configurationInvalid(expectedValidation))
        }

        #expect(!(await manager.isRunning()))
        #expect(await manager.snapshot() == .stopped)
    }

    @Test
    func additionalArgumentsCannotOverrideManagedLaunchContract() async {
        let manager = MihomoProcessManager(
            resolver: StubMihomoExecutableResolver(
                result: .failure(.resourceMissing(name: "unused"))
            ),
            validator: StubConfigurationValidator(
                result: ProcessTestSupport.validConfigurationResult()
            )
        )

        do {
            _ = try await manager.start(
                configurationURL: URL(fileURLWithPath: "/tmp/active.yaml"),
                additionalArguments: ["-f", "/tmp/other.yaml"]
            )
            Issue.record("Expected unmanaged arguments to be rejected")
        } catch let error as MihomoProcessManagerError {
            #expect(error == .unsafeAdditionalArguments(["-f", "/tmp/other.yaml"]))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func stopOnlyTerminatesTheProcessOwnedByThatManager() async throws {
        let directory = try ProcessTestSupport.makeTemporaryDirectory()
        defer { ProcessTestSupport.removeTemporaryDirectory(directory) }
        let executable = try ProcessTestSupport.makeScript(
            in: directory,
            body: "exec /bin/sleep 30"
        )
        let configuration = directory.appending(path: "active.yaml")
        let resolved = ProcessTestSupport.resolvedExecutable(at: executable)
        let firstManager = MihomoProcessManager(
            resolver: StubMihomoExecutableResolver(result: .success(resolved)),
            validator: StubConfigurationValidator(result: ProcessTestSupport.validConfigurationResult())
        )
        let secondManager = MihomoProcessManager(
            resolver: StubMihomoExecutableResolver(result: .success(resolved)),
            validator: StubConfigurationValidator(result: ProcessTestSupport.validConfigurationResult())
        )

        let first = try await firstManager.start(configurationURL: configuration)
        let second = try await secondManager.start(configurationURL: configuration)
        #expect(first.pid != second.pid)

        _ = try await firstManager.stop(timeout: .seconds(1))
        #expect(!(await firstManager.isRunning()))
        #expect(await secondManager.isRunning())
        #expect(await secondManager.snapshot().pid == second.pid)

        _ = try await secondManager.stop(timeout: .seconds(1))
        #expect(!(await secondManager.isRunning()))
    }

    @Test
    func unexpectedExitUpdatesStateAndEmitsCapturedTermination() async throws {
        let directory = try ProcessTestSupport.makeTemporaryDirectory()
        defer { ProcessTestSupport.removeTemporaryDirectory(directory) }
        let executable = try ProcessTestSupport.makeScript(
            in: directory,
            body: "echo final-out; echo final-err >&2; exit 9"
        )
        let manager = MihomoProcessManager(
            resolver: StubMihomoExecutableResolver(
                result: .success(ProcessTestSupport.resolvedExecutable(at: executable))
            ),
            validator: StubConfigurationValidator(result: ProcessTestSupport.validConfigurationResult())
        )
        let stream = await manager.events()
        let terminationTask = Task<MihomoProcessTermination?, Never> {
            for await event in stream {
                if case let .terminated(termination) = event {
                    return termination
                }
            }
            return nil
        }

        _ = try await manager.start(configurationURL: directory.appending(path: "active.yaml"))
        let termination = try #require(await terminationTask.value)

        #expect(termination.status == 9)
        #expect(!termination.expected)
        #expect(termination.stdout.contains("final-out"))
        #expect(termination.stderr.contains("final-err"))
        #expect(!(await manager.isRunning()))
        #expect(await manager.snapshot() == .stopped)
    }
}

nonisolated private final class AtomicProcessRunBarrier: @unchecked Sendable {
    private let paused = DispatchSemaphore(value: 0)
    private let resumeSignal = DispatchSemaphore(value: 0)

    func pause() {
        paused.signal()
        resumeSignal.wait()
    }

    func waitUntilPaused() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .default).async { [self] in
                continuation.resume(
                    returning: paused.wait(timeout: .now() + 5) == .success
                )
            }
        }
    }

    func resume() {
        resumeSignal.signal()
    }
}
