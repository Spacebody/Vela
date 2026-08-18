import Darwin
import Foundation
import Testing
@testable import VelaPrivilegedCore

@Suite("Journal target process identity")
struct ProcessIdentityVerifierTests {
    @Test("A process running from a different executable inode is never accepted")
    func rejectsTargetInodeMismatch() throws {
        let expectedURL = URL.temporaryDirectory.appending(path: "identity-a-\(UUID().uuidString)")
        let otherURL = URL.temporaryDirectory.appending(path: "identity-b-\(UUID().uuidString)")
        try Data("a".utf8).write(to: expectedURL)
        try Data("b".utf8).write(to: otherURL)
        defer {
            try? FileManager.default.removeItem(at: expectedURL)
            try? FileManager.default.removeItem(at: otherURL)
        }
        var expectedStatus = stat()
        var otherStatus = stat()
        #expect(lstat(expectedURL.path, &expectedStatus) == 0)
        #expect(lstat(otherURL.path, &otherStatus) == 0)
        let signature = PrivilegedCodeSignature(signingIdentifier: "mihomo", teamIdentifier: "TEAM123456")
        let journal = RootProcessIdentity(
            processID: 123,
            startTimeSeconds: 10,
            startTimeMicroseconds: 20,
            executableDevice: UInt64(expectedStatus.st_dev),
            executableInode: UInt64(expectedStatus.st_ino),
            executableRelativePath: try SafeRelativePath(
                "executables/generations/00000000-0000-0000-0000-000000000001/mihomo"
            ),
            signingIdentifier: signature.signingIdentifier,
            teamIdentifier: signature.teamIdentifier
        )
        let inspector = FixedLiveProcessInspector(
            snapshot: LiveProcessSnapshot(
                processID: 123,
                effectiveUserID: 0,
                startTimeSeconds: 10,
                startTimeMicroseconds: 20,
                executableURL: expectedURL,
                executableIdentity: POSIXFileIdentity(otherStatus),
                codeSignature: signature
            )
        )

        #expect(throws: ProcessIdentityError.executableIdentityMismatch) {
            _ = try ProcessIdentityVerifier(inspector: inspector).verify(
                journalIdentity: journal,
                expectedExecutableURL: expectedURL
            )
        }
    }
}

private struct FixedLiveProcessInspector: LiveProcessInspecting {
    let snapshot: LiveProcessSnapshot

    func inspect(
        processID _: Int32,
        expectedExecutableURL _: URL
    ) throws -> LiveProcessSnapshot {
        snapshot
    }
}
