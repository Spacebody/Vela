import Foundation

nonisolated enum ConfigurationValidationStatus: Equatable, Sendable {
    case valid
    case invalid(exitCode: Int32)
    case timedOut
    case executionFailed(message: String)
    case coreIntegrityFailed(message: String)
}

nonisolated enum ConfigurationValidationOutputSource: String, Equatable, Sendable {
    case stdout
    case stderr
    case execution
}

nonisolated struct ConfigurationValidationIssue: Equatable, Sendable {
    let source: ConfigurationValidationOutputSource
    let message: String
    let lineNumber: Int?
}

nonisolated struct ConfigurationValidationResult: Equatable, Sendable {
    let status: ConfigurationValidationStatus
    let stdout: String
    let stderr: String
    let issues: [ConfigurationValidationIssue]
    let duration: Duration

    init(
        status: ConfigurationValidationStatus,
        stdout: String,
        stderr: String,
        issues: [ConfigurationValidationIssue],
        duration: Duration
    ) {
        let redactor = SensitiveTextRedactor(context: .validation)
        self.status = switch status {
        case .valid:
            .valid
        case let .invalid(exitCode):
            .invalid(exitCode: exitCode)
        case .timedOut:
            .timedOut
        case let .executionFailed(message):
            .executionFailed(message: redactor.redact(message))
        case let .coreIntegrityFailed(message):
            .coreIntegrityFailed(message: redactor.redact(message))
        }
        self.stdout = redactor.redact(stdout)
        self.stderr = redactor.redact(stderr)
        self.issues = issues.map { issue in
            ConfigurationValidationIssue(
                source: issue.source,
                message: redactor.redact(issue.message, lineNumberHint: issue.lineNumber),
                lineNumber: issue.lineNumber
            )
        }
        self.duration = duration
    }

    var isValid: Bool {
        status == .valid
    }

    var copyableError: String {
        if !stderr.isEmpty {
            return stderr
        }
        if !stdout.isEmpty {
            return stdout
        }
        if case let .coreIntegrityFailed(message) = status {
            return message
        }
        if case let .executionFailed(message) = status {
            return message
        }
        return ""
    }
}

nonisolated protocol ConfigurationValidating: Sendable {
    func validate(
        configurationURL: URL,
        using executable: ResolvedMihomoExecutable,
        timeout: Duration
    ) async -> ConfigurationValidationResult

    func validate(
        configurationURL: URL,
        dataDirectoryURL: URL,
        using executable: ResolvedMihomoExecutable,
        timeout: Duration
    ) async -> ConfigurationValidationResult
}

extension ConfigurationValidating {
    func validate(
        configurationURL: URL,
        dataDirectoryURL _: URL,
        using executable: ResolvedMihomoExecutable,
        timeout: Duration
    ) async -> ConfigurationValidationResult {
        await validate(
            configurationURL: configurationURL,
            using: executable,
            timeout: timeout
        )
    }
}

nonisolated struct ConfigurationValidator: ConfigurationValidating, Sendable {
    private let processExecutor: any ProcessExecuting
    private let environment: [String: String]

    init(
        processExecutor: any ProcessExecuting = ProcessExecutor(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.processExecutor = processExecutor
        self.environment = environment
    }

    func validate(
        configurationURL: URL,
        using executable: ResolvedMihomoExecutable,
        timeout: Duration = .seconds(10)
    ) async -> ConfigurationValidationResult {
        await validate(
            configurationURL: configurationURL,
            dataDirectoryURL: configurationURL.deletingLastPathComponent(),
            using: executable,
            timeout: timeout
        )
    }

    func validate(
        configurationURL: URL,
        dataDirectoryURL: URL,
        using executable: ResolvedMihomoExecutable,
        timeout: Duration = .seconds(10)
    ) async -> ConfigurationValidationResult {
        do {
            try MihomoVerifiedExecutableGuard.verifyUnchanged(executable)
        } catch {
            let message = error.localizedDescription
            return ConfigurationValidationResult(
                status: .coreIntegrityFailed(message: message),
                stdout: "",
                stderr: "",
                issues: [
                    ConfigurationValidationIssue(
                        source: .execution,
                        message: message,
                        lineNumber: nil
                    )
                ],
                duration: .zero
            )
        }

        do {
            let executionResult = try await processExecutor.execute(
                ProcessExecutionRequest(
                    executableURL: executable.url,
                    arguments: [
                        "-t",
                        "-d", dataDirectoryURL.path,
                        "-f", configurationURL.path,
                    ],
                    environment: MihomoChildEnvironment.sanitized(environment),
                    currentDirectoryURL: dataDirectoryURL,
                    timeout: timeout
                )
            )

            if executionResult.timedOut {
                let parsedIssues = issues(
                    stdout: executionResult.stdout,
                    stderr: executionResult.stderr
                )
                return ConfigurationValidationResult(
                    status: .timedOut,
                    stdout: executionResult.stdout,
                    stderr: executionResult.stderr,
                    issues: parsedIssues.isEmpty
                        ? [ConfigurationValidationIssue(
                            source: .execution,
                            message: "Mihomo configuration validation timed out.",
                            lineNumber: nil
                        )]
                        : parsedIssues,
                    duration: executionResult.duration
                )
            }

            guard executionResult.succeeded else {
                let parsedIssues = issues(
                    stdout: executionResult.stdout,
                    stderr: executionResult.stderr
                )
                return ConfigurationValidationResult(
                    status: .invalid(exitCode: executionResult.terminationStatus),
                    stdout: executionResult.stdout,
                    stderr: executionResult.stderr,
                    issues: parsedIssues.isEmpty
                        ? [ConfigurationValidationIssue(
                            source: .execution,
                            message: "Mihomo rejected the configuration with exit code \(executionResult.terminationStatus).",
                            lineNumber: nil
                        )]
                        : parsedIssues,
                    duration: executionResult.duration
                )
            }

            return ConfigurationValidationResult(
                status: .valid,
                stdout: executionResult.stdout,
                stderr: executionResult.stderr,
                issues: [],
                duration: executionResult.duration
            )
        } catch {
            let message = error.localizedDescription
            return ConfigurationValidationResult(
                status: .executionFailed(message: message),
                stdout: "",
                stderr: message,
                issues: [ConfigurationValidationIssue(
                    source: .execution,
                    message: message,
                    lineNumber: nil
                )],
                duration: .zero
            )
        }
    }

    private func issues(stdout: String, stderr: String) -> [ConfigurationValidationIssue] {
        issues(in: stderr, source: .stderr) + issues(in: stdout, source: .stdout)
    }

    private func issues(
        in output: String,
        source: ConfigurationValidationOutputSource
    ) -> [ConfigurationValidationIssue] {
        output
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .map { line in
                ConfigurationValidationIssue(
                    source: source,
                    message: line,
                    lineNumber: lineNumber(in: line)
                )
            }
    }

    private func lineNumber(in message: String) -> Int? {
        let lowercased = message.lowercased()
        var searchRange = lowercased.startIndex..<lowercased.endIndex

        while let marker = lowercased.range(of: "line", range: searchRange) {
            let prefixIsBoundary = marker.lowerBound == lowercased.startIndex
                || !lowercased[lowercased.index(before: marker.lowerBound)].isLetter
            let suffixStartsAtBoundary = marker.upperBound == lowercased.endIndex
                || !lowercased[marker.upperBound].isLetter

            if prefixIsBoundary, suffixStartsAtBoundary {
                let suffix = lowercased[marker.upperBound...]
                let numberStart = suffix.drop {
                    $0.isWhitespace || $0 == ":" || $0 == "#"
                }
                let digits = numberStart.prefix(while: \.isNumber)
                if let line = Int(digits), line > 0 {
                    return line
                }
            }

            searchRange = marker.upperBound..<lowercased.endIndex
        }

        return nil
    }
}
