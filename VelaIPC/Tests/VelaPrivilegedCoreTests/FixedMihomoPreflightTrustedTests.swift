import Darwin
import Foundation
import Testing
import VelaIPC
@testable import VelaPrivilegedCore

@Suite("Trusted Mihomo preflight target")
struct FixedMihomoPreflightTrustedTests {
    @Test("Preflight validates only the root-owned generation with exact ID, Team and version")
    func validatesTrustedGeneration() async throws {
        try await withExecutable { store, executable, source in
            let inspector = RecordingSigningInspector(
                signature: PrivilegedCodeSignature(
                    signingIdentifier: VelaIPCConstants.expectedMihomoSigningIdentifier,
                    teamIdentifier: "TEAM123456"
                )
            )
            let preflight = FixedMihomoPreflight(
                executableStore: store,
                signingInspector: inspector,
                versionProbe: FixedVersionProbe()
            )
            let result = try await preflight.run(
                executable: executable,
                expectedHelperSignature: PrivilegedCodeSignature(
                    signingIdentifier: VelaIPCConstants.helperIdentifier,
                    teamIdentifier: "TEAM123456"
                ),
                workingDirectoryURL: executable.url.deletingLastPathComponent()
            )

            #expect(result.executable.url.path != source.path)
            #expect(inspector.inspectedPaths() == [executable.url.path, executable.url.path])
            #expect(result.mihomoSignature.signingIdentifier == "mihomo")
        }
    }

    @Test("A same-Team executable with the wrong signing identifier is rejected")
    func rejectsWrongMihomoIdentifier() async throws {
        try await withExecutable { store, executable, _ in
            let preflight = FixedMihomoPreflight(
                executableStore: store,
                signingInspector: RecordingSigningInspector(
                    signature: PrivilegedCodeSignature(
                        signingIdentifier: "not-mihomo",
                        teamIdentifier: "TEAM123456"
                    )
                ),
                versionProbe: FixedVersionProbe()
            )
            await #expect(throws: FixedMihomoPreflightError.signingIdentifierMismatch) {
                _ = try await preflight.run(
                    executable: executable,
                    expectedHelperSignature: PrivilegedCodeSignature(
                        signingIdentifier: VelaIPCConstants.helperIdentifier,
                        teamIdentifier: "TEAM123456"
                    ),
                    workingDirectoryURL: executable.url.deletingLastPathComponent()
                )
            }
        }
    }

    @Test("A catalog Core keeps the one exact stable bundle identifier")
    func acceptsExternalCoreIdentifier() async throws {
        try await withExecutable { store, executable, _ in
            let preflight = FixedMihomoPreflight(
                executableStore: store,
                signingInspector: RecordingSigningInspector(
                    signature: PrivilegedCodeSignature(
                        signingIdentifier: VelaIPCConstants.expectedExternalCoreSigningIdentifier,
                        teamIdentifier: "TEAM123456"
                    )
                ),
                versionProbe: FixedVersionProbe()
            )
            _ = try await preflight.run(
                executable: executable,
                expectedHelperSignature: PrivilegedCodeSignature(
                    signingIdentifier: VelaIPCConstants.helperIdentifier,
                    teamIdentifier: "TEAM123456"
                ),
                workingDirectoryURL: executable.url.deletingLastPathComponent()
            )
        }
    }

    private func withExecutable(
        _ operation: (
            TrustedMihomoExecutableStore,
            TrustedMihomoExecutable,
            URL
        ) async throws -> Void
    ) async throws {
        let root = URL.temporaryDirectory.appending(path: "VelaPreflight-\(UUID().uuidString)")
        let source = URL.temporaryDirectory.appending(path: "VelaMachO-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: root.path
        )
        var magic = UInt32(MH_MAGIC_64).littleEndian
        var cpu = Int32(CPU_TYPE_ARM64).littleEndian
        var data = withUnsafeBytes(of: &magic) { Data($0) }
        data.append(withUnsafeBytes(of: &cpu) { Data($0) })
        try data.write(to: source)
        guard chmod(source.path, 0o500) == 0 else {
            throw POSIXRootFileSystemError.systemCall(operation: "chmod", code: errno)
        }
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: root)
        }
        let fileSystem = try POSIXRootFileSystem.openExisting(
            at: root,
            policy: PrivilegedOwnershipPolicy(userID: getuid(), groupID: getgid())
        )
        let store = TrustedMihomoExecutableStore(fileSystem: fileSystem)
        try await operation(store, store.installBundledExecutable(from: source), source)
    }
}

private final class RecordingSigningInspector: PrivilegedCodeSigningInspecting,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let signature: PrivilegedCodeSignature
    private var paths: [String] = []

    init(signature: PrivilegedCodeSignature) {
        self.signature = signature
    }

    func inspect(
        at url: URL,
        validateNestedCode _: Bool,
        requirement _: PrivilegedCodeSigningRequirement?
    ) throws -> PrivilegedCodeSignature {
        lock.lock()
        paths.append(url.path)
        lock.unlock()
        return signature
    }

    func inspectedPaths() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return paths
    }
}

private struct FixedVersionProbe: FixedMihomoVersionProbing {
    func probe(
        executableURL _: URL,
        workingDirectoryURL _: URL
    ) async throws -> MihomoVersionProbeResult {
        MihomoVersionProbeResult(
            status: 0,
            output: "Mihomo Meta \(VelaIPCConstants.expectedMihomoVersion) darwin arm64\n",
            timedOut: false
        )
    }
}
