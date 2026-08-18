import CryptoKit
import Foundation
import Testing
@testable import Vela

struct MihomoExecutableResolverTests {
    @Test
    func resolvesVersionAndSHA256() async throws {
        let directory = try ProcessTestSupport.makeTemporaryDirectory()
        defer { ProcessTestSupport.removeTemporaryDirectory(directory) }
        let executable = try ProcessTestSupport.makeScript(
            in: directory,
            body: "echo 'Mihomo Meta v1.19.0'"
        )

        let resolved = try await MihomoExecutableResolver(executableURL: executable).resolve()
        let expectedHash = SHA256.hash(data: try Data(contentsOf: executable))
            .map { String(format: "%02x", $0) }
            .joined()

        #expect(resolved.url == executable)
        #expect(resolved.version == "Mihomo Meta v1.19.0")
        #expect(resolved.sha256 == expectedHash)
        #expect(resolved.sha256.count == 64)
    }

    @Test
    func missingExecutableReturnsStructuredError() async throws {
        let directory = try ProcessTestSupport.makeTemporaryDirectory()
        defer { ProcessTestSupport.removeTemporaryDirectory(directory) }
        let missing = directory.appending(path: "missing-mihomo")
        let resolver = MihomoExecutableResolver(executableURL: missing)

        do {
            _ = try await resolver.resolve()
            Issue.record("Expected a missing executable error")
        } catch let error as MihomoExecutableResolverError {
            #expect(error == .executableMissing(missing))
        }
    }

    @Test
    func nonExecutableFileIsRejectedWithoutChangingPermissions() async throws {
        let directory = try ProcessTestSupport.makeTemporaryDirectory()
        defer { ProcessTestSupport.removeTemporaryDirectory(directory) }
        let executable = try ProcessTestSupport.makeScript(
            in: directory,
            body: "echo version",
            executable: false
        )
        let resolver = MihomoExecutableResolver(executableURL: executable)

        do {
            _ = try await resolver.resolve()
            Issue.record("Expected an executable permission error")
        } catch let error as MihomoExecutableResolverError {
            #expect(error == .executableNotRunnable(executable))
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: executable.path)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber).intValue & 0o777
        #expect(permissions == 0o600)
    }

    @Test
    func versionProbeFailurePreservesBothOutputStreams() async throws {
        let directory = try ProcessTestSupport.makeTemporaryDirectory()
        defer { ProcessTestSupport.removeTemporaryDirectory(directory) }
        let executable = try ProcessTestSupport.makeScript(
            in: directory,
            body: "echo partial-version; echo probe-error >&2; exit 4"
        )
        let resolver = MihomoExecutableResolver(executableURL: executable)

        do {
            _ = try await resolver.resolve()
            Issue.record("Expected a version probe failure")
        } catch let error as MihomoExecutableResolverError {
            guard case let .versionProbeFailed(exitCode, stdout, stderr) = error else {
                Issue.record("Unexpected resolver error: \(error)")
                return
            }
            #expect(exitCode == 4)
            #expect(stdout.contains("partial-version"))
            #expect(stderr.contains("probe-error"))
        }
    }

    @Test
    func bundledCandidateMapsPreflightFailureWithoutTrapping() async {
        let underlying = MihomoCorePreflightError.unexpected(
            stage: .manifest,
            message: "synthetic bundled preflight failure"
        )
        let resolver = MihomoExecutableResolver(
            bundle: .main,
            preflight: FailingResolverPreflight(error: underlying)
        )

        do {
            _ = try await resolver.resolve()
            Issue.record("Expected bundled preflight failure")
        } catch let error as MihomoExecutableResolverError {
            #expect(error == .preflightFailed(underlying))
        } catch {
            Issue.record("Unexpected bundled resolver error: \(error)")
        }
    }
}

private struct FailingResolverPreflight: MihomoCorePreflighting {
    let error: MihomoCorePreflightError

    func run(_ request: MihomoCorePreflightRequest) async throws -> MihomoCorePreflightResult {
        throw error
    }
}
