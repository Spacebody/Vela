import Darwin
import Foundation

public struct FixedMihomoCommandResult: Equatable, Sendable {
    public let status: Int32
    public let output: String
    public let timedOut: Bool
}

public protocol FixedMihomoCommandRunning: Sendable {
    func validateConfiguration(
        executableURL: URL,
        dataDirectoryURL: URL,
        configurationURL: URL
    ) async throws -> FixedMihomoCommandResult
}

public actor FoundationFixedMihomoCommandRunner: FixedMihomoCommandRunning {
    private let timeout: Duration

    public init(timeout: Duration = .seconds(10)) {
        self.timeout = timeout
    }

    public func validateConfiguration(
        executableURL: URL,
        dataDirectoryURL: URL,
        configurationURL: URL
    ) async throws -> FixedMihomoCommandResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = [
            "-t", "-d", dataDirectoryURL.path, "-f", configurationURL.path,
        ]
        process.currentDirectoryURL = dataDirectoryURL
        process.environment = Self.minimumEnvironment(home: dataDirectoryURL)
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let capturedOutput = BoundedCommandOutput(maximumBytes: 64 * 1_024)
        pipe.fileHandleForReading.readabilityHandler = { readable in
            let data = readable.availableData
            if !data.isEmpty { capturedOutput.append(data) }
        }
        do {
            try process.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            pipe.fileHandleForWriting.closeFile()
            try? pipe.fileHandleForReading.close()
            throw FixedMihomoCommandError.launchFailed
        }

        let termination = await BoundedProcessWaiter.wait(
            for: process,
            timeout: timeout
        )
        pipe.fileHandleForReading.readabilityHandler = nil
        pipe.fileHandleForWriting.closeFile()
        if termination.exited {
            capturedOutput.append(pipe.fileHandleForReading.readDataToEndOfFile())
        }
        try? pipe.fileHandleForReading.close()
        return FixedMihomoCommandResult(
            status: termination.exited ? process.terminationStatus : SIGKILL,
            output: String(decoding: capturedOutput.data(), as: UTF8.self),
            timedOut: termination.timedOut
        )
    }

    static func minimumEnvironment(home: URL) -> [String: String] {
        [
            "HOME": home.path,
            "PATH": "/usr/bin:/bin",
            "TMPDIR": URL.temporaryDirectory.path,
        ]
    }
}

final class BoundedCommandOutput: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumBytes: Int
    private var storage = Data()

    init(maximumBytes: Int) {
        self.maximumBytes = maximumBytes
    }

    func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard storage.count < maximumBytes else { return }
        storage.append(data.prefix(maximumBytes - storage.count))
    }

    func data() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

public enum FixedMihomoCommandError: Error, Equatable, Sendable {
    case launchFailed
}
