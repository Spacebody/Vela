import Foundation

nonisolated struct MihomoVersionIdentity: Equatable, Sendable {
    let version: String
    let platform: String
    let architecture: String
    let rawOutput: String
}

nonisolated struct MihomoVersionExpectation: Equatable, Sendable {
    let version: String
    let platform: String
    let architecture: String

    static let required = MihomoVersionExpectation(
        version: MihomoCoreDescriptor.requiredVersion,
        platform: MihomoCoreDescriptor.requiredPlatform,
        architecture: MihomoCoreDescriptor.requiredArchitecture
    )

    init(version: String, platform: String, architecture: String) {
        self.version = version
        self.platform = platform
        self.architecture = architecture
    }

    init(descriptor: MihomoCoreDescriptor) {
        self.init(
            version: descriptor.version,
            platform: descriptor.platform,
            architecture: descriptor.architecture
        )
    }
}

nonisolated protocol MihomoVersionOutputParsing: Sendable {
    func parse(_ rawOutput: String) throws -> MihomoVersionIdentity
}

nonisolated struct StrictMihomoVersionOutputParser: MihomoVersionOutputParsing, Sendable {
    private static let linePattern =
        #"^Mihomo Meta (v[0-9]+\.[0-9]+\.[0-9]+) ([A-Za-z0-9_-]+) ([A-Za-z0-9_]+)(?:\s+.*)?$"#

    func parse(_ rawOutput: String) throws -> MihomoVersionIdentity {
        let expression: NSRegularExpression
        do {
            expression = try NSRegularExpression(pattern: Self.linePattern)
        } catch {
            throw MihomoVersionOutputParserError.parserUnavailable(error.localizedDescription)
        }

        var matches: [MihomoVersionIdentity] = []
        for rawLine in rawOutput.split(whereSeparator: \Character.isNewline) {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let match = expression.firstMatch(in: line, range: range),
                match.range == range,
                let version = Self.capture(1, from: match, in: line),
                let platform = Self.capture(2, from: match, in: line),
                let architecture = Self.capture(3, from: match, in: line)
            else {
                continue
            }
            matches.append(
                MihomoVersionIdentity(
                    version: version,
                    platform: platform,
                    architecture: architecture,
                    rawOutput: rawOutput
                )
            )
        }

        guard matches.count == 1, let identity = matches.first else {
            throw MihomoVersionOutputParserError.malformedOutput(rawOutput)
        }
        return identity
    }

    private static func capture(
        _ index: Int,
        from match: NSTextCheckingResult,
        in value: String
    ) -> String? {
        guard let range = Range(match.range(at: index), in: value) else { return nil }
        return String(value[range])
    }
}

nonisolated protocol MihomoVersionProbing: Sendable {
    func probe(
        executableAt url: URL,
        expected: MihomoVersionExpectation,
        currentDirectoryURL: URL?
    ) async throws -> MihomoVersionIdentity
}

nonisolated struct MihomoVersionProbe: MihomoVersionProbing, Sendable {
    private let processExecutor: any ProcessExecuting
    private let parser: any MihomoVersionOutputParsing
    private let timeout: Duration
    private let environment: [String: String]

    init(
        processExecutor: any ProcessExecuting = ProcessExecutor(),
        parser: any MihomoVersionOutputParsing = StrictMihomoVersionOutputParser(),
        timeout: Duration = .seconds(3),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.processExecutor = processExecutor
        self.parser = parser
        self.timeout = timeout
        self.environment = environment
    }

    func probe(
        executableAt url: URL,
        expected: MihomoVersionExpectation = .required,
        currentDirectoryURL: URL? = nil
    ) async throws -> MihomoVersionIdentity {
        let result: ProcessExecutionResult
        do {
            result = try await processExecutor.execute(
                ProcessExecutionRequest(
                    executableURL: url,
                    arguments: ["-v"],
                    environment: MihomoChildEnvironment.sanitized(environment),
                    currentDirectoryURL: currentDirectoryURL,
                    timeout: timeout
                )
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw MihomoVersionProbeError.executionFailed(
                path: url.path,
                reason: error.localizedDescription
            )
        }

        if result.timedOut {
            throw MihomoVersionProbeError.timedOut(
                timeout: timeout,
                stdout: result.stdout,
                stderr: result.stderr
            )
        }
        guard result.terminationReason == .exit, result.terminationStatus == 0 else {
            throw MihomoVersionProbeError.nonzeroExit(
                status: result.terminationStatus,
                reason: result.terminationReason,
                stdout: result.stdout,
                stderr: result.stderr
            )
        }

        let rawOutput = [result.stdout, result.stderr]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        let identity: MihomoVersionIdentity
        do {
            identity = try parser.parse(rawOutput)
        } catch let error as MihomoVersionOutputParserError {
            throw MihomoVersionProbeError.invalidOutput(error)
        } catch {
            throw MihomoVersionProbeError.invalidOutput(
                .parserUnavailable(error.localizedDescription)
            )
        }

        guard identity.version == expected.version,
            identity.platform == expected.platform,
            identity.architecture == expected.architecture
        else {
            throw MihomoVersionProbeError.identityMismatch(
                expected: expected,
                actual: identity
            )
        }
        return identity
    }
}

nonisolated enum MihomoVersionOutputParserError: Error, Equatable, Sendable {
    case parserUnavailable(String)
    case malformedOutput(String)
}

extension MihomoVersionOutputParserError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .parserUnavailable(reason):
            "Mihomo version output parser is unavailable: \(reason)"
        case let .malformedOutput(output):
            "Mihomo version output does not match the required structured format: \(output)"
        }
    }
}

nonisolated enum MihomoVersionProbeError: Error, Equatable, Sendable {
    case executionFailed(path: String, reason: String)
    case timedOut(timeout: Duration, stdout: String, stderr: String)
    case nonzeroExit(
        status: Int32,
        reason: ProcessTerminationReason,
        stdout: String,
        stderr: String
    )
    case invalidOutput(MihomoVersionOutputParserError)
    case identityMismatch(expected: MihomoVersionExpectation, actual: MihomoVersionIdentity)
}

extension MihomoVersionProbeError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .executionFailed(path, reason):
            "Could not run the Mihomo version probe at \(path): \(reason)"
        case let .timedOut(timeout, stdout, stderr):
            "Mihomo version probe exceeded \(timeout). stdout: \(stdout) stderr: \(stderr)"
        case let .nonzeroExit(status, reason, stdout, stderr):
            "Mihomo version probe exited with \(reason.rawValue) status \(status). stdout: \(stdout) stderr: \(stderr)"
        case let .invalidOutput(error):
            error.localizedDescription
        case let .identityMismatch(expected, actual):
            "Mihomo identity mismatch. Expected \(expected.version) \(expected.platform) \(expected.architecture); found \(actual.version) \(actual.platform) \(actual.architecture)."
        }
    }
}
