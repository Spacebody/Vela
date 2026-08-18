import Darwin
import Foundation
import Testing
@testable import VelaPrivilegedCore

@Suite("Root runtime journal validation")
struct RootJournalValidationTests {
    @Test("Dirty journal preserves the probe and pre-launch utun baseline")
    func crashRecoveryMetadataRoundTrips() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try await fixture.store.prepare()

        let expected = RootRuntimeJournal(
            desiredState: .running,
            instanceID: UUID(),
            configurationSHA256: String(repeating: "a", count: 64),
            routeProbeAddress: "8.8.8.8",
            preexistingTunInterfaces: ["utun2", "utun7"],
            ownerUID: UInt32(getuid()),
            activeTransactionID: UUID(),
            lastCleanShutdown: false
        )

        try await fixture.store.save(expected)
        #expect(try await fixture.store.load() == expected)
    }

    @Test("Journal save rejects an oversized utun baseline")
    func saveRejectsOversizedBaseline() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try await fixture.store.prepare()
        let invalid = RootRuntimeJournal(
            preexistingTunInterfaces: Array(
                repeating: "utun1",
                count: PrivilegedTunInterfaceValidator.maximumJournalBaselineCount + 1
            )
        )

        await #expect(throws: RootJournalError.invalidPreexistingTunInterfaces) {
            try await fixture.store.save(invalid)
        }
    }

    @Test("Journal load rejects malformed or non-canonical utun names")
    func loadRejectsMalformedBaseline() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try await fixture.store.prepare()
        let invalid = RootRuntimeJournal(
            routeProbeAddress: "1.1.1.1",
            preexistingTunInterfaces: ["utun9", "utun", "utun2"],
            lastCleanShutdown: false
        )
        try fixture.fileSystem.writeDataAtomically(
            try JSONEncoder().encode(invalid),
            to: try SafeRelativePath("state/runtime-journal.json"),
            replacingExisting: false
        )

        await #expect(throws: RootJournalError.invalidPreexistingTunInterfaces) {
            _ = try await fixture.store.load()
        }
    }

    @Test("A clean journal carrying a process identity is rejected")
    func loadRejectsCorruptedCleanJournalWithPID() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try await fixture.store.prepare()
        let invalid = RootRuntimeJournal(
            processIdentity: RootProcessIdentity(
                processID: 123,
                startTimeSeconds: 1,
                startTimeMicroseconds: 2,
                executableDevice: 3,
                executableInode: 4,
                executableRelativePath: try SafeRelativePath(
                    "executables/generations/test/mihomo"
                ),
                signingIdentifier: "dev.yilin.Vela.Mihomo",
                teamIdentifier: "TEAM123456"
            )
        )
        try fixture.fileSystem.writeDataAtomically(
            try JSONEncoder().encode(invalid),
            to: try SafeRelativePath("state/runtime-journal.json"),
            replacingExisting: false
        )

        await #expect(throws: RootJournalError.invalidState) {
            _ = try await fixture.store.load()
        }
    }

    @Test("A dirty journal missing probe or utun baseline is rejected")
    func saveRejectsIncompleteDirtyJournal() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try await fixture.store.prepare()
        let invalid = RootRuntimeJournal(
            desiredState: .running,
            instanceID: UUID(),
            configurationSHA256: String(repeating: "b", count: 64),
            ownerUID: UInt32(getuid()),
            activeTransactionID: UUID(),
            lastCleanShutdown: false
        )

        await #expect(throws: RootJournalError.invalidState) {
            try await fixture.store.save(invalid)
        }
    }

    private func makeFixture() throws -> JournalFixture {
        let root = URL.temporaryDirectory.appending(
            path: "VelaRootJournal-\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: root.path
        )
        let fileSystem = try POSIXRootFileSystem.openExisting(
            at: root,
            policy: PrivilegedOwnershipPolicy(userID: getuid(), groupID: getgid())
        )
        return JournalFixture(
            root: root,
            fileSystem: fileSystem,
            store: RootJournalStore(fileSystem: fileSystem)
        )
    }
}

private struct JournalFixture {
    let root: URL
    let fileSystem: POSIXRootFileSystem
    let store: RootJournalStore
}
