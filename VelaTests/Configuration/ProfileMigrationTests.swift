import Foundation
import Testing
@testable import Vela

@Suite("Profile schema v2 migration")
struct ProfileMigrationTests {
    private let fixtureProfileID = UUID(
        uuidString: "0F6EF4B0-46C1-4CC0-B9C7-1BB752B38A10"
    )!

    @Test("Pack v1 fixture migrates transactionally and remains idempotent")
    func packV1FixtureMigratesAndPreservesBackup() async throws {
        let root = try ConfigurationTestSupport.makeTemporaryDirectory()
        defer { ConfigurationTestSupport.removeTemporaryDirectory(root) }

        let directories = ApplicationDirectories(root: root.appending(path: "store"))
        try directories.prepare()
        let legacyData = try fixtureData(named: "profile-store-v1.json")
        try legacyData.write(to: directories.profilesMetadata, options: .atomic)
        let originalYAML = Data("mixed-port: 7890\nmode: rule\n".utf8)
        let profileURL = directories.profiles.appending(path: "\(fixtureProfileID.uuidString).yaml")
        try originalYAML.write(to: profileURL, options: .atomic)

        let store = ProfileStore(directories: directories)
        let profiles = try await store.profiles()

        let profile = try #require(profiles.first)
        #expect(profiles.count == 1)
        #expect(profile.id == fixtureProfileID)
        #expect(profile.name == "Local Profile")
        #expect(profile.originalFileName == "config.yaml")
        #expect(profile.sourceKind == .localFile)
        #expect(profile.currentRevisionID == nil)
        #expect(profile.previousRevisionIDs.isEmpty)
        #expect(profile.remote == nil)
        #expect(try await store.selectedProfileID() == fixtureProfileID)
        #expect(try Data(contentsOf: profileURL) == originalYAML)
        #expect(try Data(contentsOf: directories.profilesMetadataV1Backup) == legacyData)
        #expect(!FileManager.default.fileExists(
            atPath: directories.profilesMetadataMigrationCandidate.path
        ))

        let migratedObject = try metadataObject(at: directories.profilesMetadata)
        #expect(migratedObject["schemaVersion"] as? Int == 2)
        let migratedProfiles = try #require(migratedObject["profiles"] as? [[String: Any]])
        #expect(migratedProfiles.first?["displayName"] as? String == "Local Profile")
        #expect(migratedProfiles.first?["sourceKind"] as? String == "localFile")

        for file in [
            profileURL,
            directories.profilesMetadata,
            directories.profilesMetadataV1Backup,
        ] {
            try expectPermissions(0o600, at: file)
        }

        // A v2 open must never rewrite the one retained v1 backup.
        let sentinelBackup = Data("retained-first-backup".utf8)
        try sentinelBackup.write(to: directories.profilesMetadataV1Backup, options: .atomic)
        let reopened = ProfileStore(directories: directories)
        #expect(try await reopened.profiles().map(\.id) == [fixtureProfileID])
        #expect(try Data(contentsOf: directories.profilesMetadataV1Backup) == sentinelBackup)
    }

    @Test("Actual V0.1 field names and epoch dates migrate without losing unknown metadata")
    func actualVersionOneShapePreservesUnknownMetadata() async throws {
        let root = try ConfigurationTestSupport.makeTemporaryDirectory()
        defer { ConfigurationTestSupport.removeTemporaryDirectory(root) }

        let directories = ApplicationDirectories(root: root.appending(path: "store"))
        try directories.prepare()
        let legacyData = Data(
            """
            {
              "profiles": [
                {
                  "id": "0F6EF4B0-46C1-4CC0-B9C7-1BB752B38A10",
                  "name": "Current V0.1 Profile",
                  "originalFileName": "current.yaml",
                  "createdAt": 1700000000,
                  "updatedAt": 1700000100.5,
                  "legacyFlag": true,
                  "legacyObject": {"owner": "user", "count": 3}
                }
              ],
              "selectedProfileID": "0F6EF4B0-46C1-4CC0-B9C7-1BB752B38A10",
              "futureEnvelopeMetadata": {"keep": [1, 2, 3]}
            }
            """.utf8
        )
        try legacyData.write(to: directories.profilesMetadata, options: .atomic)

        let store = ProfileStore(directories: directories)
        let profile = try #require(try await store.profiles().first)
        #expect(profile.name == "Current V0.1 Profile")
        #expect(profile.originalFileName == "current.yaml")
        #expect(profile.createdAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(profile.updatedAt == Date(timeIntervalSince1970: 1_700_000_100.5))
        #expect(profile.additionalMetadata["legacyFlag"] == .bool(true))
        #expect(
            profile.additionalMetadata["legacyObject"]
                == .object(["owner": .string("user"), "count": .integer(3)])
        )

        let migrated = try metadataObject(at: directories.profilesMetadata)
        let migratedProfiles = try #require(migrated["profiles"] as? [[String: Any]])
        #expect(migrated["futureEnvelopeMetadata"] != nil)
        #expect(migratedProfiles.first?["legacyFlag"] as? Bool == true)
        #expect(migratedProfiles.first?["legacyObject"] != nil)
        #expect(migratedProfiles.first?["name"] == nil)
        #expect(migratedProfiles.first?["originalFileName"] == nil)
    }

    @Test("Pack v2 fixture opens without migration or backup")
    func packV2FixtureIsIdempotent() async throws {
        let root = try ConfigurationTestSupport.makeTemporaryDirectory()
        defer { ConfigurationTestSupport.removeTemporaryDirectory(root) }

        let directories = ApplicationDirectories(root: root.appending(path: "store"))
        try directories.prepare()
        let versionTwoData = try fixtureData(named: "profile-store-v2.json")
        try versionTwoData.write(to: directories.profilesMetadata, options: .atomic)
        try Data("stale candidate".utf8).write(
            to: directories.profilesMetadataMigrationCandidate,
            options: .atomic
        )

        let store = ProfileStore(directories: directories)
        let profile = try #require(try await store.profiles().first)

        #expect(profile.id == fixtureProfileID)
        #expect(profile.name == "Local Profile")
        #expect(profile.sourceKind == .localFile)
        #expect(try Data(contentsOf: directories.profilesMetadata) == versionTwoData)
        #expect(!FileManager.default.fileExists(atPath: directories.profilesMetadataV1Backup.path))
        #expect(!FileManager.default.fileExists(
            atPath: directories.profilesMetadataMigrationCandidate.path
        ))
    }

    @Test("Invalid v1 never replaces the original database with an empty v2 database")
    func invalidVersionOnePreservesOriginal() async throws {
        let root = try ConfigurationTestSupport.makeTemporaryDirectory()
        defer { ConfigurationTestSupport.removeTemporaryDirectory(root) }

        let directories = ApplicationDirectories(root: root.appending(path: "store"))
        try directories.prepare()
        let invalidData = Data(
            """
            {
              "profiles": [{
                "id": "not-a-uuid",
                "displayName": "Broken",
                "sourceFileName": "broken.yaml",
                "createdAt": "not-a-date",
                "updatedAt": "2026-07-01T00:00:00Z"
              }],
              "selectedProfileID": null
            }
            """.utf8
        )
        try invalidData.write(to: directories.profilesMetadata, options: .atomic)

        let store = ProfileStore(directories: directories)
        do {
            _ = try await store.profiles()
            Issue.record("Expected invalid legacy metadata to fail migration")
        } catch let error as ProfileStoreError {
            guard case .metadataMigrationFailed = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
        }

        #expect(try Data(contentsOf: directories.profilesMetadata) == invalidData)
        #expect(!FileManager.default.fileExists(atPath: directories.profilesMetadataV1Backup.path))
        #expect(!FileManager.default.fileExists(
            atPath: directories.profilesMetadataMigrationCandidate.path
        ))
    }

    @Test("Interrupted final replacement preserves v1 and a later launch recovers idempotently")
    func interruptedMigrationRecoversOnNextLaunch() async throws {
        let root = try ConfigurationTestSupport.makeTemporaryDirectory()
        defer { ConfigurationTestSupport.removeTemporaryDirectory(root) }

        let directories = ApplicationDirectories(root: root.appending(path: "store"))
        try directories.prepare()
        let legacyData = try fixtureData(named: "profile-store-v1.json")
        try legacyData.write(to: directories.profilesMetadata, options: .atomic)

        let failingStore = ProfileStore(
            directories: directories,
            fileSystem: MigrationCommitFailingFileSystem(
                blockedURL: directories.profilesMetadata
            )
        )
        do {
            _ = try await failingStore.profiles()
            Issue.record("Expected the simulated atomic replacement to fail")
        } catch let error as ProfileStoreError {
            guard case .metadataMigrationFailed = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
        }

        #expect(try Data(contentsOf: directories.profilesMetadata) == legacyData)
        #expect(try Data(contentsOf: directories.profilesMetadataV1Backup) == legacyData)
        #expect(FileManager.default.fileExists(
            atPath: directories.profilesMetadataMigrationCandidate.path
        ))

        let recoveredStore = ProfileStore(directories: directories)
        #expect(try await recoveredStore.profiles().map(\.id) == [fixtureProfileID])
        #expect(try metadataObject(at: directories.profilesMetadata)["schemaVersion"] as? Int == 2)
        #expect(!FileManager.default.fileExists(
            atPath: directories.profilesMetadataMigrationCandidate.path
        ))
    }

    @Test("Deleting a profile removes raw, revision, staging, and override artifacts")
    func deletionCleansVersionedArtifacts() async throws {
        let root = try ConfigurationTestSupport.makeTemporaryDirectory()
        defer { ConfigurationTestSupport.removeTemporaryDirectory(root) }

        let source = try ConfigurationTestSupport.write(
            "mixed-port: 7890\nproxies:\n  - name: Delete\n    type: ss\n    server: example.com\n    port: 8388\n    cipher: aes-128-gcm\n    password: secret\n",
            named: "Delete.yaml",
            in: root
        )
        let directories = ApplicationDirectories(root: root.appending(path: "store"))
        let store = ProfileStore(directories: directories)
        let profile = try await store.importProfile(from: source)
        try await store.prepareWorkingDirectories(for: profile.id)

        let revisionID = UUID()
        let revisionURL = await store.revisionURL(for: profile.id, revisionID: revisionID)
        let stagingDirectory = await store.stagingDirectory(for: profile.id)
        let stagedRaw = stagingDirectory.appending(path: "candidate.yaml")
        let overrideURL = await store.overrideURL(for: profile.id)
        try Data("revision".utf8).write(to: revisionURL, options: .atomic)
        try Data("candidate".utf8).write(to: stagedRaw, options: .atomic)
        try Data("{}".utf8).write(to: overrideURL, options: .atomic)

        try await store.deleteProfile(id: profile.id)

        for artifact in [
            await store.configurationURL(for: profile.id),
            await store.historyDirectory(for: profile.id),
            stagingDirectory,
            overrideURL,
        ] {
            #expect(!FileManager.default.fileExists(atPath: artifact.path))
        }
        #expect(try await store.profiles().isEmpty)
    }

    @Test("Remote profile metadata round-trips without requiring a secret payload")
    func remoteMetadataRoundTrips() throws {
        let profile = Profile(
            id: fixtureProfileID,
            name: "Remote",
            originalFileName: "subscription.yaml",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_100),
            sourceKind: .remoteSubscription,
            currentRevisionID: UUID(),
            previousRevisionIDs: [UUID()],
            remote: RemoteProfileMetadata(
                redactedURL: "https://example.com/•••/subscription",
                autoUpdateEnabled: true,
                schedule: .custom(minutes: 30),
                etag: "\"fixture\"",
                lastModified: "Sat, 11 Jul 2026 03:00:00 GMT",
                usage: SubscriptionUsage(
                    upload: 1,
                    download: 2,
                    total: 10,
                    expireUnixSeconds: 1_893_456_000
                ),
                lastFailure: PersistedFailureSummary(
                    kind: "timeout",
                    message: "Request timed out.",
                    occurredAt: Date(timeIntervalSince1970: 1_700_000_200)
                )
            )
        )
        let envelope = ProfileDatabaseEnvelope(profiles: [profile])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(envelope)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        #expect(try decoder.decode(ProfileDatabaseEnvelope.self, from: data) == envelope)
        let encodedText = String(decoding: data, as: UTF8.self)
        #expect(!encodedText.localizedCaseInsensitiveContains("authorization"))
        #expect(!encodedText.localizedCaseInsensitiveContains("password"))
    }

    @Test("ProfileStore creates and updates remote profiles without writing a raw secret URL")
    func profileStoreCreatesAndUpdatesRemoteProfiles() async throws {
        let root = try ConfigurationTestSupport.makeTemporaryDirectory()
        defer { ConfigurationTestSupport.removeTemporaryDirectory(root) }

        let directories = ApplicationDirectories(root: root.appending(path: "store"))
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let profileID = fixtureProfileID
        let store = ProfileStore(
            directories: directories,
            idGenerator: { profileID },
            now: { timestamp }
        )
        let initial = RemoteProfileMetadata(
            redactedURL: "https://example.com/•••/subscription",
            schedule: .everySixHours
        )

        let created = try await store.createRemoteProfile(
            name: " Remote Profile ",
            metadata: initial
        )
        #expect(created.id == profileID)
        #expect(created.name == "Remote Profile")
        #expect(created.sourceKind == .remoteSubscription)
        #expect(created.remote == initial)
        #expect(!FileManager.default.fileExists(
            atPath: (await store.configurationURL(for: profileID)).path
        ))

        var updated = initial
        updated.autoUpdateEnabled = true
        updated.etag = "\"updated\""
        let saved = try await store.updateRemoteMetadata(for: profileID, metadata: updated)
        #expect(saved.remote == updated)
        #expect(try await store.profile(id: profileID)?.remote == updated)

        let metadataText = try String(
            contentsOf: directories.profilesMetadata,
            encoding: .utf8
        )
        #expect(metadataText.contains("https:\\/\\/example.com\\/•••\\/subscription")
            || metadataText.contains("https://example.com/•••/subscription"))
        #expect(!metadataText.contains("?"))
    }

    @Test("Remote metadata rejects user info, query, and fragment components")
    func remoteMetadataMustBeRedacted() async throws {
        let root = try ConfigurationTestSupport.makeTemporaryDirectory()
        defer { ConfigurationTestSupport.removeTemporaryDirectory(root) }
        let store = ProfileStore(
            directories: ApplicationDirectories(root: root.appending(path: "store"))
        )

        do {
            _ = try await store.createRemoteProfile(
                name: "Unsafe",
                metadata: RemoteProfileMetadata(
                    redactedURL: "https://user@example.com/subscription?token=secret#fragment"
                )
            )
            Issue.record("Expected sensitive URL components to be rejected")
        } catch let error as ProfileStoreError {
            #expect(error == .remoteMetadataContainsSensitiveURLComponents)
        }
    }

    @Test("Raw revision commits retain the newest three revisions and prune older files")
    func revisionCommitRetainsNewestThree() async throws {
        let root = try ConfigurationTestSupport.makeTemporaryDirectory()
        defer { ConfigurationTestSupport.removeTemporaryDirectory(root) }

        let source = try ConfigurationTestSupport.write(
            "mixed-port: 7000\nproxies:\n  - name: Revision\n    type: ss\n    server: example.com\n    port: 8388\n    cipher: aes-128-gcm\n    password: secret\n",
            named: "Revision.yaml",
            in: root
        )
        let directories = ApplicationDirectories(root: root.appending(path: "store"))
        let store = ProfileStore(directories: directories)
        let profile = try await store.importProfile(from: source)
        let revisionIDs = [
            UUID(uuidString: "00000000-0000-4000-8000-000000000001")!,
            UUID(uuidString: "00000000-0000-4000-8000-000000000002")!,
            UUID(uuidString: "00000000-0000-4000-8000-000000000003")!,
            UUID(uuidString: "00000000-0000-4000-8000-000000000004")!,
        ]

        for (index, revisionID) in revisionIDs.enumerated() {
            let data = Data("mixed-port: \(7_001 + index)\n".utf8)
            let revision = try await store.commitRawRevision(
                data,
                for: profile.id,
                revisionID: revisionID,
                createdAt: Date(timeIntervalSince1970: TimeInterval(1_700_000_001 + index))
            )
            #expect(revision.id == revisionID)
            #expect(revision.byteCount == data.count)
            #expect(revision.contentSHA256.count == 64)
        }

        let updatedProfile = try #require(try await store.profile(id: profile.id))
        #expect(updatedProfile.currentRevisionID == revisionIDs[3])
        #expect(updatedProfile.previousRevisionIDs == [revisionIDs[2], revisionIDs[1]])
        #expect(try await store.revisions(for: profile.id).map(\.id) == [
            revisionIDs[3],
            revisionIDs[2],
            revisionIDs[1],
        ])
        #expect(try await store.readConfiguration(for: profile.id) == Data("mixed-port: 7004\n".utf8))
        #expect(try await store.readRevision(
            profileID: profile.id,
            revisionID: revisionIDs[1]
        ) == Data("mixed-port: 7002\n".utf8))

        let prunedURL = await store.revisionURL(
            for: profile.id,
            revisionID: revisionIDs[0]
        )
        #expect(!FileManager.default.fileExists(atPath: prunedURL.path))
        for retainedID in revisionIDs[1...] {
            let url = await store.revisionURL(for: profile.id, revisionID: retainedID)
            #expect(FileManager.default.fileExists(atPath: url.path))
            try expectPermissions(0o600, at: url)
        }
    }

    @Test("A metadata failure rolls back raw and history changes from a revision commit")
    func revisionCommitRollsBackOnMetadataFailure() async throws {
        let root = try ConfigurationTestSupport.makeTemporaryDirectory()
        defer { ConfigurationTestSupport.removeTemporaryDirectory(root) }

        let source = try ConfigurationTestSupport.write(
            "mixed-port: 7000\nproxies:\n  - name: Stable\n    type: ss\n    server: example.com\n    port: 8388\n    cipher: aes-128-gcm\n    password: secret\n",
            named: "Stable.yaml",
            in: root
        )
        let directories = ApplicationDirectories(root: root.appending(path: "store"))
        let liveStore = ProfileStore(directories: directories)
        let profile = try await liveStore.importProfile(from: source)
        let originalRaw = try await liveStore.readConfiguration(for: profile.id)
        let revisionID = UUID()
        let revisionURL = await liveStore.revisionURL(
            for: profile.id,
            revisionID: revisionID
        )
        let failingStore = ProfileStore(
            directories: directories,
            fileSystem: MigrationCommitFailingFileSystem(
                blockedURL: directories.profilesMetadata
            )
        )

        do {
            _ = try await failingStore.commitRawRevision(
                Data("mixed-port: 7999\n".utf8),
                for: profile.id,
                revisionID: revisionID
            )
            Issue.record("Expected metadata persistence to fail")
        } catch let error as ProfileStoreError {
            guard case .metadataWriteFailed = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
        }

        #expect(try await liveStore.readConfiguration(for: profile.id) == originalRaw)
        #expect(try await liveStore.revisions(for: profile.id).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: revisionURL.path))
    }

    private func fixtureData(named name: String) throws -> Data {
        // Keep these two tiny pack fixtures in-process. Hosted macOS unit tests
        // may otherwise trigger an interactive Documents-folder TCC prompt when
        // they try to read the repository, which makes unattended CI hang.
        let contents: String = switch name {
        case "profile-store-v1.json":
            """
            {
              "profiles": [
                {
                  "id": "0F6EF4B0-46C1-4CC0-B9C7-1BB752B38A10",
                  "displayName": "Local Profile",
                  "sourceFileName": "config.yaml",
                  "createdAt": "2026-07-01T00:00:00Z",
                  "updatedAt": "2026-07-01T00:00:00Z"
                }
              ],
              "selectedProfileID": "0F6EF4B0-46C1-4CC0-B9C7-1BB752B38A10"
            }
            """
        case "profile-store-v2.json":
            """
            {
              "schemaVersion": 2,
              "profiles": [
                {
                  "id": "0F6EF4B0-46C1-4CC0-B9C7-1BB752B38A10",
                  "displayName": "Local Profile",
                  "sourceKind": "localFile",
                  "sourceFileName": "config.yaml",
                  "createdAt": "2026-07-01T00:00:00Z",
                  "updatedAt": "2026-07-01T00:00:00Z",
                  "currentRevisionID": null,
                  "previousRevisionIDs": [],
                  "remote": null
                }
              ],
              "selectedProfileID": "0F6EF4B0-46C1-4CC0-B9C7-1BB752B38A10"
            }
            """
        default:
            throw FixtureError.unknownFixture(name)
        }
        return Data(contents.utf8)
    }

    private func metadataObject(at url: URL) throws -> [String: Any] {
        try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
    }

    private func expectPermissions(_ expected: Int, at url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
        #expect(permissions.intValue & 0o777 == expected)
    }
}

private struct MigrationCommitFailingFileSystem: FileSystemProviding {
    private let live = LiveFileSystem()
    let blockedURL: URL

    func applicationSupportDirectory() -> URL? {
        live.applicationSupportDirectory()
    }

    func createDirectory(at url: URL) throws {
        try live.createDirectory(at: url)
    }

    func fileExists(at url: URL) -> Bool {
        live.fileExists(at: url)
    }

    func readData(at url: URL) throws -> Data {
        try live.readData(at: url)
    }

    func writeDataAtomically(_ data: Data, to url: URL) throws {
        if url.standardizedFileURL == blockedURL.standardizedFileURL {
            throw MigrationCommitFailure.expected
        }
        try live.writeDataAtomically(data, to: url)
    }

    func moveItem(at source: URL, to destination: URL) throws {
        try live.moveItem(at: source, to: destination)
    }

    func removeItem(at url: URL) throws {
        try live.removeItem(at: url)
    }

    func setPOSIXPermissions(_ permissions: Int, at url: URL) throws {
        try live.setPOSIXPermissions(permissions, at: url)
    }
}

private enum MigrationCommitFailure: Error {
    case expected
}

private enum FixtureError: Error {
    case unknownFixture(String)
}
