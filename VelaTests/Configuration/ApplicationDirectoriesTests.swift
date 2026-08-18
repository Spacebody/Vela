import Foundation
import Testing
@testable import Vela

@Suite("Application directories")
struct ApplicationDirectoriesTests {
    @Test("Preparing directories is idempotent")
    func prepareIsIdempotent() throws {
        let temporaryDirectory = try ConfigurationTestSupport.makeTemporaryDirectory()
        defer { ConfigurationTestSupport.removeTemporaryDirectory(temporaryDirectory) }

        let directories = ApplicationDirectories(
            root: temporaryDirectory.appendingPathComponent("Application Support", isDirectory: true)
        )

        try directories.prepare()
        try directories.prepare()

        for directory in [
            directories.root,
            directories.profiles,
            directories.profileHistory,
            directories.profileStaging,
            directories.runtime,
            directories.runtimeCandidates,
            directories.overrides,
            directories.configuration,
            directories.scenes,
            directories.configurationMigrationBackups,
            directories.legacyOverrideMigrationBackups,
            directories.logs,
            directories.metadata,
            directories.mihomo,
        ] {
            var isDirectory = ObjCBool(false)
            let exists = FileManager.default.fileExists(
                atPath: directory.path,
                isDirectory: &isDirectory
            )
            #expect(exists)
            #expect(isDirectory.boolValue)
            let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
            let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
            #expect(permissions.intValue & 0o777 == 0o700)
        }
    }

    @Test("V0.2 profile, revision, override, candidate, and journal paths are deterministic")
    func versionTwoPathsAreDeterministic() throws {
        let profileID = try #require(
            UUID(uuidString: "0F6EF4B0-46C1-4CC0-B9C7-1BB752B38A10")
        )
        let revisionID = try #require(
            UUID(uuidString: "A9BE4D8F-04D2-46B7-B80F-F0E352147EA8")
        )
        let transactionID = try #require(
            UUID(uuidString: "2888DAFD-69B5-4DF7-BF2E-5506C8D9E5A1")
        )
        let root = URL(fileURLWithPath: "/tmp/Vela-ApplicationDirectories", isDirectory: true)
        let directories = ApplicationDirectories(root: root)

        #expect(
            directories.profileHistoryDirectory(for: profileID).path
                == root.appending(path: "profiles/history/\(profileID.uuidString)").path
        )
        #expect(
            directories.profileStagingDirectory(for: profileID).path
                == root.appending(path: "profiles/staging/\(profileID.uuidString)").path
        )
        #expect(
            directories.profileRevisionURL(profileID: profileID, revisionID: revisionID).path
                == root.appending(
                    path: "profiles/history/\(profileID.uuidString)/\(revisionID.uuidString).yaml"
                ).path
        )
        #expect(
            directories.overrideURL(for: profileID).path
                == root.appending(path: "overrides/\(profileID.uuidString).json").path
        )
        #expect(
            directories.profileStagingURL(transactionID: transactionID).path
                == root.appending(
                    path: "profiles/staging/\(transactionID.uuidString).yaml"
                ).path
        )
        #expect(
            directories.runtimeCandidateURL(transactionID: transactionID).path
                == root.appending(path: "runtime/candidates/\(transactionID.uuidString).yaml").path
        )
        #expect(directories.previousConfiguration.path == root.appending(path: "runtime/previous.yaml").path)
        #expect(
            directories.runtimeTransactionJournal.path
                == root.appending(path: "runtime/transaction.json").path
        )
        #expect(
            directories.profilesMetadataV1Backup.path
                == root.appending(path: "metadata/profiles.json.v1.backup").path
        )
        #expect(
            directories.configurationLayers.path
                == root.appending(path: "configuration/layers.json").path
        )
        #expect(
            directories.scenesDocument.path
                == root.appending(path: "scenes/scenes.json").path
        )
        #expect(
            directories.configurationLayerCandidateURL(operationID: transactionID).path
                == root.appending(
                    path: "configuration/.layers.\(transactionID.uuidString).candidate.json"
                ).path
        )
        #expect(
            directories.legacyOverrideMigrationBackupURL(for: profileID).path
                == root.appending(
                    path: "configuration/migration-backups/v02-overrides/\(profileID.uuidString).json"
                ).path
        )
    }

    @Test("Directory failures are structured")
    func directoryFailureIsStructured() throws {
        let temporaryDirectory = try ConfigurationTestSupport.makeTemporaryDirectory()
        defer { ConfigurationTestSupport.removeTemporaryDirectory(temporaryDirectory) }

        let root = temporaryDirectory.appendingPathComponent("not-a-directory", isDirectory: false)
        try Data("occupied".utf8).write(to: root, options: .atomic)
        let directories = ApplicationDirectories(root: root)

        do {
            try directories.prepare()
            Issue.record("Expected directory preparation to fail")
        } catch let error as ApplicationDirectoriesError {
            guard case let .couldNotCreateDirectory(path, reason) = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            #expect(path == root.path)
            #expect(!reason.isEmpty)
        }
    }
}
