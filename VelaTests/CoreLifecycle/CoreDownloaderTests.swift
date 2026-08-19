import Darwin
import Foundation
import Testing

@testable import Vela

@Suite("Core downloader")
struct CoreDownloaderTests {
    @Test("Download workspaces are private and explicitly removable")
    func downloadWorkspaceLifecycle() async throws {
        let temporaryDirectory = try ConfigurationTestSupport.makeTemporaryDirectory()
        defer {
            ConfigurationTestSupport.removeTemporaryDirectory(temporaryDirectory)
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: temporaryDirectory.path
        )

        let downloader = CoreFileDownloader()
        let workspace = try await downloader.createWorkspace(in: temporaryDirectory)

        var status = stat()
        let result = workspace.directory.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.lstat(path, &status)
        }
        #expect(result == 0)
        #expect(status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR))
        #expect(status.st_mode & 0o077 == 0)

        await downloader.removeWorkspace(workspace)
        #expect(!FileManager.default.fileExists(atPath: workspace.directory.path))
    }

    @Test("Download workspace creation rejects an untrusted staging directory")
    func downloadWorkspaceRejectsUnsafeRoot() async throws {
        let temporaryDirectory = try ConfigurationTestSupport.makeTemporaryDirectory()
        defer {
            ConfigurationTestSupport.removeTemporaryDirectory(temporaryDirectory)
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o777)],
            ofItemAtPath: temporaryDirectory.path
        )

        let downloader = CoreFileDownloader()
        await #expect(throws: CoreDownloadError.unsafeTemporaryDirectory) {
            _ = try await downloader.createWorkspace(in: temporaryDirectory)
        }
        let contents = try FileManager.default.contentsOfDirectory(
            at: temporaryDirectory,
            includingPropertiesForKeys: nil
        )
        #expect(contents.isEmpty)
    }
}
