import Darwin
import Foundation
import Testing
@testable import Vela

struct ConfigurationValidatorTests {
    @Test
    func successfulValidationUsesMihomoTestArguments() async throws {
        let execution = ProcessExecutionResult(
            terminationStatus: 0,
            terminationReason: .exit,
            stdout: "configuration file is valid",
            stderr: "",
            timedOut: false,
            duration: .milliseconds(5)
        )
        let executor = StubProcessExecutor(result: .success(execution))
        let validator = ConfigurationValidator(
            processExecutor: executor,
            environment: [
                "PATH": "/usr/bin",
                "CLASH_CONFIG_STRING": "untrusted",
            ]
        )
        let directory = try ProcessTestSupport.makeTemporaryDirectory()
        defer { ProcessTestSupport.removeTemporaryDirectory(directory) }
        let executableURL = try ProcessTestSupport.makeScript(in: directory, body: "exit 0")
        let configurationURL = URL(fileURLWithPath: "/tmp/active.yaml")

        let result = await validator.validate(
            configurationURL: configurationURL,
            using: ProcessTestSupport.resolvedExecutable(at: executableURL),
            timeout: .seconds(2)
        )

        #expect(result.status == .valid)
        #expect(result.isValid)
        #expect(result.stdout == "configuration file is valid")
        #expect(result.issues.isEmpty)
        let request = try #require(await executor.recordedRequests().first)
        #expect(request.executableURL == executableURL)
        #expect(request.arguments == [
            "-t",
            "-d", configurationURL.deletingLastPathComponent().path,
            "-f", configurationURL.path,
        ])
        #expect(request.currentDirectoryURL == configurationURL.deletingLastPathComponent())
        #expect(request.environment == ["PATH": "/usr/bin"])
        #expect(request.timeout == .seconds(2))
    }

    @Test
    func nonzeroExitPreservesStderrAndParsesLineNumber() async throws {
        let directory = try ProcessTestSupport.makeTemporaryDirectory()
        defer { ProcessTestSupport.removeTemporaryDirectory(directory) }
        let executableURL = try ProcessTestSupport.makeScript(in: directory, body: "exit 0")
        let stderr = "configuration test failed\nyaml: line 27: mapping values are not allowed"
        let execution = ProcessExecutionResult(
            terminationStatus: 2,
            terminationReason: .exit,
            stdout: "raw stdout",
            stderr: stderr,
            timedOut: false,
            duration: .milliseconds(8)
        )
        let validator = ConfigurationValidator(
            processExecutor: StubProcessExecutor(result: .success(execution))
        )

        let result = await validator.validate(
            configurationURL: URL(fileURLWithPath: "/tmp/active.yaml"),
            using: ProcessTestSupport.resolvedExecutable(at: executableURL)
        )

        #expect(result.status == .invalid(exitCode: 2))
        #expect(!result.isValid)
        #expect(result.stderr == stderr)
        #expect(result.copyableError == stderr)
        #expect(result.issues.contains { $0.source == .stderr && $0.lineNumber == 27 })
    }

    @Test
    func validationOutputIsRedactedBeforeItEntersTheResult() async throws {
        let directory = try ProcessTestSupport.makeTemporaryDirectory()
        defer { ProcessTestSupport.removeTemporaryDirectory(directory) }
        let executableURL = try ProcessTestSupport.makeScript(in: directory, body: "exit 0")
        let execution = ProcessExecutionResult(
            terminationStatus: 2,
            terminationReason: .exit,
            stdout: """
            fetching https://subscriber:credential@private.example.com/config.yaml?token=stdout-secret#fragment
              proxies:
                - name: private-node
            """,
            stderr: """
            open /Users/jerry/Library/Application Support/Vela/active.yaml: permission denied
            Authorization: Bearer stderr-secret
            yaml: line 42: password: inline-secret
            """,
            timedOut: false,
            duration: .milliseconds(8)
        )
        let validator = ConfigurationValidator(
            processExecutor: StubProcessExecutor(result: .success(execution))
        )

        let result = await validator.validate(
            configurationURL: URL(fileURLWithPath: "/tmp/active.yaml"),
            using: ProcessTestSupport.resolvedExecutable(at: executableURL)
        )

        let surfacedText = ([result.stdout, result.stderr, result.copyableError]
            + result.issues.map(\.message))
            .joined(separator: "\n")
            .lowercased()
        for forbidden in [
            "stdout-secret",
            "stderr-secret",
            "inline-secret",
            "subscriber",
            "credential",
            "private.example.com",
            "private-node",
            "/users/jerry",
            "authorization:",
            "password:",
        ] {
            #expect(!surfacedText.contains(forbidden))
        }
        #expect(result.stdout.contains("<redacted-url>"))
        #expect(result.issues.contains {
            $0.source == .stderr
                && $0.lineNumber == 42
                && $0.message == "Mihomo validation output at line 42 was redacted."
        })
    }

    @Test
    func timeoutIsStructuredAndPreservesCapturedError() async throws {
        let directory = try ProcessTestSupport.makeTemporaryDirectory()
        defer { ProcessTestSupport.removeTemporaryDirectory(directory) }
        let executableURL = try ProcessTestSupport.makeScript(in: directory, body: "exit 0")
        let execution = ProcessExecutionResult(
            terminationStatus: SIGTERM,
            terminationReason: .uncaughtSignal,
            stdout: "checking",
            stderr: "yaml: line 8: still parsing",
            timedOut: true,
            duration: .milliseconds(50)
        )
        let validator = ConfigurationValidator(
            processExecutor: StubProcessExecutor(result: .success(execution))
        )

        let result = await validator.validate(
            configurationURL: URL(fileURLWithPath: "/tmp/active.yaml"),
            using: ProcessTestSupport.resolvedExecutable(at: executableURL)
        )

        #expect(result.status == .timedOut)
        #expect(result.stdout == "checking")
        #expect(result.stderr == "yaml: line 8: still parsing")
        #expect(result.issues.contains { $0.lineNumber == 8 })
    }

    @Test
    func launchFailureIsReturnedInsteadOfThrown() async throws {
        let directory = try ProcessTestSupport.makeTemporaryDirectory()
        defer { ProcessTestSupport.removeTemporaryDirectory(directory) }
        let executableURL = try ProcessTestSupport.makeScript(in: directory, body: "exit 0")
        let validator = ConfigurationValidator(
            processExecutor: StubProcessExecutor(result: .failure(.executableMissing(executableURL)))
        )

        let result = await validator.validate(
            configurationURL: URL(fileURLWithPath: "/tmp/active.yaml"),
            using: ProcessTestSupport.resolvedExecutable(at: executableURL)
        )

        guard case let .executionFailed(message) = result.status else {
            Issue.record("Expected a structured execution failure")
            return
        }
        #expect(message == "Mihomo validation output was redacted.")
        #expect(!message.contains(executableURL.path))
        #expect(result.stderr == message)
        #expect(result.issues.count == 1)
        #expect(result.issues.first?.source == .execution)
    }
}
