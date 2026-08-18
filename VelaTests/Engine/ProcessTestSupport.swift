import CryptoKit
import Foundation
@testable import Vela

enum ProcessTestSupport {
    static func makeTemporaryDirectory() throws -> URL {
        let directory = URL.temporaryDirectory
            .appending(path: "Vela-ProcessTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func removeTemporaryDirectory(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }

    static func makeScript(
        in directory: URL,
        name: String = "mihomo-test",
        body: String,
        executable: Bool = true
    ) throws -> URL {
        let url = directory.appending(path: name)
        let source = "#!/bin/sh\n\(body)\n"
        try Data(source.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: executable ? 0o700 : 0o600],
            ofItemAtPath: url.path
        )
        return url
    }

    static func resolvedExecutable(at url: URL) -> ResolvedMihomoExecutable {
        guard let data = try? Data(contentsOf: url),
            let verifiedFile = try? POSIXMihomoCoreFileInspector().inspectExecutable(at: url)
        else {
            return ResolvedMihomoExecutable(
                url: url,
                version: "mihomo test",
                sha256: String(repeating: "a", count: 64)
            )
        }
        let sha256 = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        return ResolvedMihomoExecutable(
            url: url,
            version: "mihomo test",
            sha256: sha256,
            verifiedFile: verifiedFile
        )
    }

    static func validConfigurationResult() -> ConfigurationValidationResult {
        ConfigurationValidationResult(
            status: .valid,
            stdout: "configuration is valid",
            stderr: "",
            issues: [],
            duration: .milliseconds(1)
        )
    }

    static func invalidConfigurationResult(line: Int = 3) -> ConfigurationValidationResult {
        let message = "yaml: line \(line): invalid value"
        return ConfigurationValidationResult(
            status: .invalid(exitCode: 1),
            stdout: "",
            stderr: message,
            issues: [ConfigurationValidationIssue(source: .stderr, message: message, lineNumber: line)],
            duration: .milliseconds(1)
        )
    }
}

actor StubProcessExecutor: ProcessExecuting {
    private let result: Result<ProcessExecutionResult, ProcessExecutionError>
    private var requests: [ProcessExecutionRequest] = []

    init(result: Result<ProcessExecutionResult, ProcessExecutionError>) {
        self.result = result
    }

    func execute(_ request: ProcessExecutionRequest) async throws -> ProcessExecutionResult {
        requests.append(request)
        return try result.get()
    }

    func recordedRequests() -> [ProcessExecutionRequest] {
        requests
    }
}

final class StubMihomoExecutableResolver: MihomoExecutableResolving {
    private let result: Result<ResolvedMihomoExecutable, MihomoExecutableResolverError>
    private let delay: Duration?
    private let invocationCounter = ProcessInvocationCounter()

    init(
        result: Result<ResolvedMihomoExecutable, MihomoExecutableResolverError>,
        delay: Duration? = nil
    ) {
        self.result = result
        self.delay = delay
    }

    func resolve() async throws -> ResolvedMihomoExecutable {
        await invocationCounter.increment()
        if let delay {
            try await Task.sleep(for: delay)
        }
        return try result.get()
    }

    func calls() async -> Int {
        await invocationCounter.value
    }
}

final class StubConfigurationValidator: ConfigurationValidating {
    private let result: ConfigurationValidationResult
    private let delay: Duration?
    private let invocationCounter = ProcessInvocationCounter()

    init(result: ConfigurationValidationResult, delay: Duration? = nil) {
        self.result = result
        self.delay = delay
    }

    func validate(
        configurationURL: URL,
        using executable: ResolvedMihomoExecutable,
        timeout: Duration
    ) async -> ConfigurationValidationResult {
        await invocationCounter.increment()
        if let delay {
            try? await Task.sleep(for: delay)
        }
        return result
    }

    func callCount() async -> Int {
        await invocationCounter.value
    }
}

private actor ProcessInvocationCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}
