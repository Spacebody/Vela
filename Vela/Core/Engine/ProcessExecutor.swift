import Darwin
import Foundation

nonisolated struct ProcessExecutionRequest: Equatable, Sendable {
    let executableURL: URL
    let arguments: [String]
    let environment: [String: String]?
    let currentDirectoryURL: URL?
    let timeout: Duration
    let terminationGracePeriod: Duration

    init(
        executableURL: URL,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        currentDirectoryURL: URL? = nil,
        timeout: Duration = .seconds(10),
        terminationGracePeriod: Duration = .seconds(1)
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.currentDirectoryURL = currentDirectoryURL
        self.timeout = timeout
        self.terminationGracePeriod = terminationGracePeriod
    }
}

nonisolated enum ProcessTerminationReason: String, Equatable, Sendable {
    case exit
    case uncaughtSignal
}

nonisolated struct ProcessExecutionResult: Equatable, Sendable {
    let terminationStatus: Int32
    let terminationReason: ProcessTerminationReason
    let stdout: String
    let stderr: String
    let timedOut: Bool
    let duration: Duration

    var succeeded: Bool {
        !timedOut && terminationReason == .exit && terminationStatus == 0
    }
}

nonisolated enum ProcessExecutionError: Error, Equatable, Sendable {
    case executableMissing(URL)
    case executableNotRunnable(URL)
    case outputCaptureSetupFailed(String)
    case launchFailed(executableURL: URL, message: String)
}

extension ProcessExecutionError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .executableMissing(url):
            "Executable does not exist at \(url.path)."
        case let .executableNotRunnable(url):
            "File is not executable at \(url.path)."
        case let .outputCaptureSetupFailed(message):
            "Could not prepare process output capture: \(message)"
        case let .launchFailed(executableURL, message):
            "Could not launch \(executableURL.path): \(message)"
        }
    }
}

protocol ProcessExecuting: Actor {
    func execute(_ request: ProcessExecutionRequest) async throws -> ProcessExecutionResult
}

actor ProcessExecutor: ProcessExecuting {
    init() {}

    func execute(_ request: ProcessExecutionRequest) async throws -> ProcessExecutionResult {
        try validateExecutable(at: request.executableURL)

        let capture: ProcessOutputCapture
        do {
            capture = try ProcessOutputCapture()
        } catch {
            throw ProcessExecutionError.outputCaptureSetupFailed(error.localizedDescription)
        }
        defer { capture.cleanUp() }

        let process = Process()
        process.executableURL = request.executableURL
        process.arguments = request.arguments
        process.environment = request.environment
        process.currentDirectoryURL = request.currentDirectoryURL
        process.standardOutput = capture.stdoutHandle
        process.standardError = capture.stderrHandle

        let terminationEvents = processTerminationEvents(for: process)
        let clock = ContinuousClock()
        let startedAt = clock.now

        do {
            try process.run()
        } catch {
            throw ProcessExecutionError.launchFailed(
                executableURL: request.executableURL,
                message: error.localizedDescription
            )
        }

        let waitResult = await waitForProcessTermination(
            process,
            events: terminationEvents,
            timeout: request.timeout,
            terminationGracePeriod: request.terminationGracePeriod
        )

        capture.closeWritingHandles()

        let result = ProcessExecutionResult(
            terminationStatus: waitResult.snapshot.status,
            terminationReason: waitResult.snapshot.reason,
            stdout: capture.readStdout(),
            stderr: capture.readStderr(),
            timedOut: waitResult.timedOut,
            duration: startedAt.duration(to: clock.now)
        )
        try Task.checkCancellation()
        return result
    }

    private func validateExecutable(at url: URL) throws {
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw ProcessExecutionError.executableMissing(url)
        }
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw ProcessExecutionError.executableNotRunnable(url)
        }
    }
}

nonisolated struct ObservedProcessTermination: Equatable, Sendable {
    let status: Int32
    let reason: ProcessTerminationReason
}

nonisolated struct ProcessWaitResult: Equatable, Sendable {
    let snapshot: ObservedProcessTermination
    let timedOut: Bool
}

nonisolated func processTerminationEvents(for process: Process) -> AsyncStream<ObservedProcessTermination> {
    AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
        process.terminationHandler = { terminatedProcess in
            let snapshot = ObservedProcessTermination(
                status: terminatedProcess.terminationStatus,
                reason: terminatedProcess.terminationReason == .exit ? .exit : .uncaughtSignal
            )
            continuation.yield(snapshot)
            continuation.finish()
        }
    }
}

nonisolated func waitForProcessTermination(
    _ process: Process,
    events: AsyncStream<ObservedProcessTermination>,
    timeout: Duration,
    terminationGracePeriod: Duration
) async -> ProcessWaitResult {
    enum RaceResult: Sendable {
        case terminated(ObservedProcessTermination)
        case timeout
        case cancelled
    }

    return await withTaskGroup(of: RaceResult.self) { group in
        group.addTask {
            for await event in events {
                return .terminated(event)
            }
            return .cancelled
        }
        group.addTask {
            do {
                try await Task.sleep(for: timeout)
                return .timeout
            } catch {
                return .cancelled
            }
        }

        guard let firstResult = await group.next() else {
            let snapshot = await terminateOwnedProcessAndWait(
                process,
                terminationGracePeriod: terminationGracePeriod
            )
            return ProcessWaitResult(snapshot: snapshot, timedOut: false)
        }

        switch firstResult {
        case let .terminated(snapshot):
            group.cancelAll()
            return ProcessWaitResult(snapshot: snapshot, timedOut: false)

        case .timeout:
            group.cancelAll()
            let snapshot = await terminateOwnedProcessAndWait(
                process,
                terminationGracePeriod: terminationGracePeriod
            )
            return ProcessWaitResult(snapshot: snapshot, timedOut: true)

        case .cancelled:
            group.cancelAll()
            let snapshot = await terminateOwnedProcessAndWait(
                process,
                terminationGracePeriod: terminationGracePeriod
            )
            return ProcessWaitResult(snapshot: snapshot, timedOut: false)
        }
    }
}

nonisolated private func terminateOwnedProcessAndWait(
    _ process: Process,
    terminationGracePeriod: Duration
) async -> ObservedProcessTermination {
    let ownedPID = process.processIdentifier
    if process.isRunning {
        process.terminate()
    }

    await sleepIgnoringCancellation(for: terminationGracePeriod)

    if process.isRunning, process.processIdentifier == ownedPID {
        _ = Darwin.kill(ownedPID, SIGKILL)
    }

    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(1))
    while process.isRunning, clock.now < deadline {
        await sleepIgnoringCancellation(for: .milliseconds(10))
    }

    guard !process.isRunning else {
        return ObservedProcessTermination(status: SIGKILL, reason: .uncaughtSignal)
    }
    return ObservedProcessTermination(
        status: process.terminationStatus,
        reason: process.terminationReason == .exit ? .exit : .uncaughtSignal
    )
}

nonisolated private func sleepIgnoringCancellation(for duration: Duration) async {
    await Task.detached {
        try? await Task.sleep(for: duration)
    }.value
}

nonisolated private final class ProcessOutputCapture {
    let stdoutHandle: FileHandle
    let stderrHandle: FileHandle

    private let directoryURL: URL
    private let stdoutURL: URL
    private let stderrURL: URL
    private var handlesClosed = false

    init() throws {
        let fileManager = FileManager.default
        directoryURL = URL.temporaryDirectory.appending(path: "Vela-Process-\(UUID().uuidString)")
        stdoutURL = directoryURL.appending(path: "stdout.log")
        stderrURL = directoryURL.appending(path: "stderr.log")

        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        guard fileManager.createFile(atPath: stdoutURL.path, contents: nil),
              fileManager.createFile(atPath: stderrURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }

        stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
        stderrHandle = try FileHandle(forWritingTo: stderrURL)
    }

    func closeWritingHandles() {
        guard !handlesClosed else { return }
        handlesClosed = true
        try? stdoutHandle.synchronize()
        try? stderrHandle.synchronize()
        try? stdoutHandle.close()
        try? stderrHandle.close()
    }

    func readStdout() -> String {
        readString(at: stdoutURL)
    }

    func readStderr() -> String {
        readString(at: stderrURL)
    }

    func cleanUp() {
        closeWritingHandles()
        try? FileManager.default.removeItem(at: directoryURL)
    }

    private func readString(at url: URL) -> String {
        guard let data = try? Data(contentsOf: url) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}
