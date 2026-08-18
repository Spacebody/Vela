import Darwin
import Foundation
import Testing
@testable import VelaPrivilegedCore

@Suite("Root journal startup artifacts")
struct RootJournalRecoveryTests {
    @Test("Prepare removes only an exact bounded 0600 atomic temp")
    func removesExactAtomicTemp() async throws {
        try await withRoot { fileSystem, root in
            let state = try SafeRelativePath("state")
            try fileSystem.createDirectory(state)
            let name = ".vela-\(UUID().uuidString.lowercased()).tmp"
            let temp = root.appending(path: "state/\(name)")
            try Data("partial-state".utf8).write(to: temp)
            guard chmod(temp.path, 0o600) == 0 else {
                throw POSIXRootFileSystemError.systemCall(operation: "chmod", code: errno)
            }

            let journal = RootJournalStore(fileSystem: fileSystem)
            try await journal.prepare()
            #expect(!FileManager.default.fileExists(atPath: temp.path))
        }
    }

    @Test("Prepare rejects a near-match state temp without deleting it")
    func rejectsNearMatch() async throws {
        try await withRoot { fileSystem, root in
            let state = try SafeRelativePath("state")
            try fileSystem.createDirectory(state)
            let temp = root.appending(path: "state/.vela-not-a-uuid.tmp")
            try Data("unknown".utf8).write(to: temp)
            guard chmod(temp.path, 0o600) == 0 else {
                throw POSIXRootFileSystemError.systemCall(operation: "chmod", code: errno)
            }

            let journal = RootJournalStore(fileSystem: fileSystem)
            await #expect(throws: RootJournalError.invalidDirectoryContents) {
                try await journal.prepare()
            }
            #expect(FileManager.default.fileExists(atPath: temp.path))
        }
    }

    private func withRoot(
        _ operation: (POSIXRootFileSystem, URL) async throws -> Void
    ) async throws {
        let root = URL.temporaryDirectory.appending(path: "VelaJournal-\(UUID().uuidString)")
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
        try await operation(fileSystem, root)
    }
}
