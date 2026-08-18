import Darwin
import Foundation
import Testing
@testable import VelaPrivilegedCore

@Suite("openat-anchored privileged filesystem")
struct POSIXRootFileSystemTests {
    @Test("Writes, fsyncs, replaces, and reads a 0600 file")
    func atomicRoundTrip() throws {
        try withFileSystem { fileSystem, rootURL in
            let directory = try SafeRelativePath("users/501/runtime")
            try fileSystem.createDirectory(directory)
            let file = try directory.appending("journal.json")

            try fileSystem.writeDataAtomically(Data("one".utf8), to: file, replacingExisting: false)
            #expect(try fileSystem.readData(at: file, maximumBytes: 32) == Data("one".utf8))
            #expect(try fileSystem.identity(of: file).permissions == 0o600)

            try fileSystem.writeDataAtomically(Data("two".utf8), to: file, replacingExisting: true)
            #expect(try fileSystem.readData(at: file, maximumBytes: 32) == Data("two".utf8))

            let attributes = try FileManager.default.attributesOfItem(
                atPath: rootURL.appending(path: file.description).path
            )
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        }
    }

    @Test("Does not overwrite a staging destination")
    func exclusiveDestination() throws {
        try withFileSystem { fileSystem, _ in
            let file = try SafeRelativePath("value.bin")
            try fileSystem.writeDataAtomically(Data([1]), to: file, replacingExisting: false)
            #expect(throws: POSIXRootFileSystemError.destinationExists) {
                try fileSystem.writeDataAtomically(Data([2]), to: file, replacingExisting: false)
            }
            #expect(try fileSystem.readData(at: file, maximumBytes: 1) == Data([1]))
        }
    }

    @Test("Rejects a symlink in an intermediate component")
    func intermediateSymlink() throws {
        try withFileSystem { fileSystem, rootURL in
            let outside = rootURL.deletingLastPathComponent().appending(path: UUID().uuidString)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: outside) }
            try FileManager.default.createSymbolicLink(
                at: rootURL.appending(path: "escape"),
                withDestinationURL: outside
            )

            #expect(throws: POSIXRootFileSystemError.symlinkRejected) {
                try fileSystem.createDirectory(try SafeRelativePath("escape/owned"))
            }
            #expect(!FileManager.default.fileExists(atPath: outside.appending(path: "owned").path))
        }
    }

    @Test("Rejects an unsafe existing root rather than chmodding it")
    func unsafeRootPermissions() throws {
        let root = try temporaryDirectory(mode: 0o755)
        defer { try? FileManager.default.removeItem(at: root) }
        let policy = PrivilegedOwnershipPolicy(userID: getuid(), groupID: getgid())

        #expect(throws: POSIXRootFileSystemError.unsafePermissions) {
            _ = try POSIXRootFileSystem.openExisting(at: root, policy: policy)
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: root.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o755)
    }

    @Test("Bootstrap allows a trusted ancestor group different from descendant policy")
    func trustedAncestorMayUseSystemManagedGroup() throws {
        var groups = [gid_t](repeating: 0, count: 64)
        let count = getgroups(Int32(groups.count), &groups)
        guard count > 0,
            let alternateGroup = groups.prefix(Int(count)).first(where: { $0 != getgid() })
        else {
            return
        }

        let ancestor = try temporaryDirectory(mode: 0o700)
        defer { try? FileManager.default.removeItem(at: ancestor) }
        #expect(chown(ancestor.path, uid_t(bitPattern: -1), alternateGroup) == 0)

        let policy = PrivilegedOwnershipPolicy(userID: getuid(), groupID: getgid())
        let fileSystem = try POSIXRootFileSystem.bootstrap(
            trustedAncestorURL: ancestor,
            relativeRoot: try SafeRelativePath("dev.test.Vela/Privileged"),
            policy: policy
        )
        #expect(fileSystem.rootIdentity.groupID == getgid())
        #expect(fileSystem.rootIdentity.permissions == 0o700)
    }

    @Test("Bounded runtime cleanup refuses an entry-count overflow")
    func boundedTreeCleanupEnforcesCount() throws {
        try withFileSystem { fileSystem, _ in
            let runtime = try SafeRelativePath("runtime/generation")
            try fileSystem.createDirectory(runtime)
            try fileSystem.writeDataAtomically(
                Data([1]),
                to: try runtime.appending("cache.db"),
                replacingExisting: false
            )
            try fileSystem.writeDataAtomically(
                Data([2]),
                to: try runtime.appending("cache.db-wal"),
                replacingExisting: false
            )
            let identity = try fileSystem.identity(of: runtime)

            #expect(throws: POSIXRootFileSystemError.treeLimitExceeded) {
                try fileSystem.removeBoundedTreeContents(
                    at: runtime,
                    expectedRootIdentity: identity,
                    limits: POSIXTreeRemovalLimits(
                        maximumDepth: 2,
                        maximumEntries: 1,
                        maximumRegularFileBytes: 1_024
                    )
                )
            }
            #expect(try fileSystem.readData(
                at: try runtime.appending("cache.db"),
                maximumBytes: 1
            ) == Data([1]))
            #expect(try fileSystem.readData(
                at: try runtime.appending("cache.db-wal"),
                maximumBytes: 1
            ) == Data([2]))
        }
    }

    @Test("Bounded cleanup preflights the full tree before unlinking")
    func boundedTreeCleanupPreflightsBeforeMutation() throws {
        try withFileSystem { fileSystem, root in
            let runtime = try SafeRelativePath("runtime/generation")
            try fileSystem.createDirectory(runtime)
            let config = try runtime.appending("config.yaml")
            try fileSystem.writeDataAtomically(
                Data("mode: rule\n".utf8),
                to: config,
                replacingExisting: false
            )
            try FileManager.default.createSymbolicLink(
                at: root.appending(path: runtime.description).appending(path: "escape"),
                withDestinationURL: URL(fileURLWithPath: "/tmp")
            )

            #expect(throws: POSIXRootFileSystemError.symlinkRejected) {
                try fileSystem.removeBoundedTreeContents(
                    at: runtime,
                    expectedRootIdentity: try fileSystem.identity(of: runtime)
                )
            }
            #expect(try fileSystem.readData(at: config, maximumBytes: 64)
                == Data("mode: rule\n".utf8))
        }
    }

    @Test("Directory promotion checks the recorded inode before atomic rename")
    func directoryPromotionChecksIdentity() throws {
        try withFileSystem { fileSystem, root in
            let source = try SafeRelativePath("staging/candidate")
            let other = try SafeRelativePath("staging/other")
            let destination = try SafeRelativePath("runtime/generations/candidate")
            try fileSystem.createDirectory(source)
            try fileSystem.createDirectory(other)
            try fileSystem.createDirectory(try SafeRelativePath("runtime/generations"))
            let sourceIdentity = try fileSystem.verifiedDirectoryIdentity(at: source)

            #expect(throws: POSIXRootFileSystemError.unsafeOwnership) {
                try fileSystem.moveDirectory(
                    source,
                    to: destination,
                    expectedIdentity: try fileSystem.verifiedDirectoryIdentity(at: other)
                )
            }
            #expect(FileManager.default.fileExists(
                atPath: root.appending(path: source.description).path
            ))

            try fileSystem.moveDirectory(
                source,
                to: destination,
                expectedIdentity: sourceIdentity
            )
            let promoted = try fileSystem.verifiedDirectoryIdentity(at: destination)
            #expect(promoted.device == sourceIdentity.device)
            #expect(promoted.inode == sourceIdentity.inode)
            #expect(!FileManager.default.fileExists(
                atPath: root.appending(path: source.description).path
            ))
        }
    }

    private func withFileSystem(
        _ operation: (POSIXRootFileSystem, URL) throws -> Void
    ) throws {
        let root = try temporaryDirectory(mode: 0o700)
        defer { try? FileManager.default.removeItem(at: root) }
        let policy = PrivilegedOwnershipPolicy(userID: getuid(), groupID: getgid())
        let fileSystem = try POSIXRootFileSystem.openExisting(at: root, policy: policy)
        try operation(fileSystem, root)
    }

    private func temporaryDirectory(mode: Int) throws -> URL {
        let url = URL.temporaryDirectory.appending(path: "VelaPrivilegedCore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: mode)],
            ofItemAtPath: url.path
        )
        return url
    }
}
