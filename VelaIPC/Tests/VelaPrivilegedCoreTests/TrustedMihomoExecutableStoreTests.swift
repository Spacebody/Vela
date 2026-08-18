import Darwin
import Foundation
import Testing
@testable import VelaPrivilegedCore

@Suite("Root-owned Mihomo executable generations")
struct TrustedMihomoExecutableStoreTests {
    @Test("Bundle path replacement after O_NOFOLLOW open is rejected and never installed")
    func sourcePathSwapIsRejected() throws {
        try withRoot { fileSystem, root in
            let source = root.deletingLastPathComponent()
                .appending(path: "mihomo-source-\(UUID().uuidString)")
            let replacement = root.deletingLastPathComponent()
                .appending(path: "mihomo-replacement-\(UUID().uuidString)")
            let originalData = Data(repeating: 0x41, count: 256 * 1_024)
            let replacementData = Data(repeating: 0x42, count: originalData.count)
            try originalData.write(to: source)
            try replacementData.write(to: replacement)
            guard chmod(source.path, 0o500) == 0, chmod(replacement.path, 0o500) == 0 else {
                throw POSIXRootFileSystemError.systemCall(operation: "chmod", code: errno)
            }
            defer {
                try? FileManager.default.removeItem(at: source)
                try? FileManager.default.removeItem(at: replacement)
            }

            let store = TrustedMihomoExecutableStore(
                fileSystem: fileSystem,
                sourceOpenedHook: {
                    guard Darwin.rename(replacement.path, source.path) == 0 else {
                        throw POSIXRootFileSystemError.systemCall(
                            operation: "rename",
                            code: errno
                        )
                    }
                }
            )
            #expect(throws: TrustedMihomoExecutableError.sourceChanged) {
                try store.installBundledExecutable(from: source)
            }
            #expect(try Data(contentsOf: source) == replacementData)
            try store.removeAllGenerations()
        }
    }

    @Test("A symlink bundle source is rejected")
    func rejectsSymlinkSource() throws {
        try withRoot { fileSystem, root in
            let target = root.deletingLastPathComponent()
                .appending(path: "mihomo-target-\(UUID().uuidString)")
            let link = root.deletingLastPathComponent()
                .appending(path: "mihomo-link-\(UUID().uuidString)")
            try Data("executable".utf8).write(to: target)
            guard chmod(target.path, 0o500) == 0 else {
                throw POSIXRootFileSystemError.systemCall(operation: "chmod", code: errno)
            }
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            defer {
                try? FileManager.default.removeItem(at: link)
                try? FileManager.default.removeItem(at: target)
            }
            let store = TrustedMihomoExecutableStore(fileSystem: fileSystem)
            #expect(throws: TrustedMihomoExecutableError.sourceIsSymlink) {
                try store.installBundledExecutable(from: link)
            }
        }
    }

    @Test("Trusted target ownership and exact non-writable executable mode are revalidated")
    func targetIdentityIsRevalidated() throws {
        try withRoot { fileSystem, root in
            let source = root.deletingLastPathComponent()
                .appending(path: "mihomo-mode-\(UUID().uuidString)")
            try Data("signed-placeholder".utf8).write(to: source)
            guard chmod(source.path, 0o500) == 0 else {
                throw POSIXRootFileSystemError.systemCall(operation: "chmod", code: errno)
            }
            defer { try? FileManager.default.removeItem(at: source) }
            let store = TrustedMihomoExecutableStore(fileSystem: fileSystem)
            let installed = try store.installBundledExecutable(from: source)
            _ = try store.revalidate(installed)

            guard chmod(installed.url.path, 0o700) == 0 else {
                throw POSIXRootFileSystemError.systemCall(operation: "chmod", code: errno)
            }
            #expect(throws: POSIXRootFileSystemError.unsafePermissions) {
                try store.revalidate(installed)
            }
        }
    }

    @Test("Startup removes exact 0600 and legacy 0500 executable temps")
    func removesRecoverableExecutableTemps() throws {
        try withRoot { fileSystem, root in
            let generations = try SafeRelativePath("executables/generations")
            try fileSystem.createDirectory(generations)

            for mode: mode_t in [0o600, POSIXRootFileSystem.trustedExecutableMode] {
                let generationID = UUID().uuidString.lowercased()
                let generation = try generations.appending(generationID)
                try fileSystem.createDirectoryExclusively(generation)
                let tempName = ".vela-\(UUID().uuidString.lowercased()).tmp"
                let temp = root.appending(
                    path: "executables/generations/\(generationID)/\(tempName)"
                )
                try Data(repeating: 0x41, count: 4_096).write(to: temp)
                guard chmod(temp.path, mode) == 0 else {
                    throw POSIXRootFileSystemError.systemCall(operation: "chmod", code: errno)
                }
            }

            let store = TrustedMihomoExecutableStore(fileSystem: fileSystem)
            try store.removeAllGenerations()
            #expect(try FileManager.default.contentsOfDirectory(
                atPath: root.appending(path: "executables/generations").path
            ).isEmpty)
        }
    }

    private func withRoot(
        _ operation: (POSIXRootFileSystem, URL) throws -> Void
    ) throws {
        let root = URL.temporaryDirectory.appending(path: "VelaExecutable-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: root.path
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let fileSystem = try POSIXRootFileSystem.openExisting(
            at: root,
            policy: PrivilegedOwnershipPolicy(userID: getuid(), groupID: getgid())
        )
        try operation(fileSystem, root)
    }
}
