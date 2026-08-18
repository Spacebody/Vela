import Darwin
import Foundation
import Testing
@testable import Vela

@Suite(.serialized)
struct ProcessExecutorTests {
    @Test
    func capturesStandardOutputStandardErrorAndExitCode() async throws {
        let directory = try ProcessTestSupport.makeTemporaryDirectory()
        defer { ProcessTestSupport.removeTemporaryDirectory(directory) }
        let script = try ProcessTestSupport.makeScript(
            in: directory,
            body: "printf 'hello-out'; printf 'hello-err' >&2; exit 7"
        )

        let result = try await ProcessExecutor().execute(
            ProcessExecutionRequest(executableURL: script)
        )

        #expect(result.terminationStatus == 7)
        #expect(result.terminationReason == .exit)
        #expect(result.stdout == "hello-out")
        #expect(result.stderr == "hello-err")
        #expect(!result.timedOut)
        #expect(!result.succeeded)
    }

    @Test
    func timeoutTerminatesTheOwnedProcess() async throws {
        let directory = try ProcessTestSupport.makeTemporaryDirectory()
        defer { ProcessTestSupport.removeTemporaryDirectory(directory) }
        let script = try ProcessTestSupport.makeScript(
            in: directory,
            body: "echo $$; exec /bin/sleep 5"
        )

        let result = try await ProcessExecutor().execute(
            ProcessExecutionRequest(
                executableURL: script,
                timeout: .seconds(4),
                terminationGracePeriod: .milliseconds(100)
            )
        )

        let pid = try #require(Int32(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(result.timedOut)
        #expect(Darwin.kill(pid, 0) == -1)
    }

    @Test
    func cancellationCleansUpTheChildBeforeReturning() async throws {
        let directory = try ProcessTestSupport.makeTemporaryDirectory()
        defer { ProcessTestSupport.removeTemporaryDirectory(directory) }
        let pidFile = directory.appending(path: "pid")
        let script = try ProcessTestSupport.makeScript(
            in: directory,
            body: "echo $$ > '\(pidFile.path)'; exec /bin/sleep 5"
        )
        let executor = ProcessExecutor()

        let task = Task {
            try await executor.execute(
                ProcessExecutionRequest(
                    executableURL: script,
                    timeout: .seconds(10),
                    terminationGracePeriod: .milliseconds(100)
                )
            )
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while !FileManager.default.fileExists(atPath: pidFile.path), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {
            // Expected after the child has been terminated and reaped.
        }

        let pidText = try String(contentsOf: pidFile, encoding: .utf8)
        let pid = try #require(Int32(pidText.trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(Darwin.kill(pid, 0) == -1)
    }
}
