import Foundation
import Testing
@testable import VelaPrivilegedCore

@Suite("Bounded child process timeouts")
struct BoundedProcessTimeoutTests {
    @Test("Version probe returns promptly when the real child never exits")
    func versionProbeTimeoutIsReal() async throws {
        let probe = FoundationFixedMihomoVersionProbe(timeout: .milliseconds(100))
        let start = ContinuousClock.now
        let result = try await probe.probe(
            executableURL: URL(fileURLWithPath: "/usr/bin/yes"),
            workingDirectoryURL: .temporaryDirectory
        )
        let elapsed = start.duration(to: .now)

        #expect(result.timedOut)
        #expect(elapsed < .seconds(2))
    }

    @Test("Configuration validation returns promptly when the real child never exits")
    func validationTimeoutIsReal() async throws {
        let runner = FoundationFixedMihomoCommandRunner(timeout: .milliseconds(100))
        let config = URL.temporaryDirectory.appending(path: "timeout-\(UUID().uuidString).yaml")
        try Data("mode: rule\n".utf8).write(to: config)
        defer { try? FileManager.default.removeItem(at: config) }
        let start = ContinuousClock.now
        let result = try await runner.validateConfiguration(
            executableURL: URL(fileURLWithPath: "/usr/bin/yes"),
            dataDirectoryURL: .temporaryDirectory,
            configurationURL: config
        )
        let elapsed = start.duration(to: .now)

        #expect(result.timedOut)
        #expect(elapsed < .seconds(2))
    }
}
