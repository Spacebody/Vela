import Foundation
import Testing
@testable import Vela

@Suite("Profile store")
struct ProfileStoreTests {
    @Test("Import uses a UUID filename and persists Codable metadata")
    func importAndReloadMetadata() async throws {
        let temporaryDirectory = try ConfigurationTestSupport.makeTemporaryDirectory()
        defer { ConfigurationTestSupport.removeTemporaryDirectory(temporaryDirectory) }

        let source = try ConfigurationTestSupport.write(
            """
            mixed-port: 7000
            mode: rule
            proxies:
              - name: Test
                type: ss
                server: example.com
                port: 8388
                cipher: aes-128-gcm
                password: secret

            """,
            named: "Home.yaml",
            in: temporaryDirectory
        )
        let originalData = try Data(contentsOf: source)
        let id = UUID(uuidString: "03B3DA3D-1096-4640-B4D6-E733B2101710")
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let expectedID = try #require(id)
        let directories = ApplicationDirectories(
            root: temporaryDirectory.appendingPathComponent("store", isDirectory: true)
        )
        let store = ProfileStore(
            directories: directories,
            idGenerator: { expectedID },
            now: { timestamp }
        )

        let imported = try await store.importProfile(from: source)

        #expect(imported.id == expectedID)
        #expect(imported.name == "Home")
        #expect(imported.originalFileName == "Home.yaml")
        #expect(imported.createdAt == timestamp)
        #expect(imported.configurationFileName == "\(expectedID.uuidString).yaml")
        #expect(try Data(contentsOf: source) == originalData)
        #expect(try await store.readConfiguration(for: expectedID) == originalData)
        #expect(FileManager.default.fileExists(atPath: directories.profilesMetadata.path))

        let metadataObject = try #require(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: directories.profilesMetadata)
            ) as? [String: Any]
        )
        #expect(metadataObject["schemaVersion"] as? Int == 2)
        let encodedProfiles = try #require(metadataObject["profiles"] as? [[String: Any]])
        #expect(encodedProfiles.first?["displayName"] as? String == "Home")
        #expect(encodedProfiles.first?["sourceFileName"] as? String == "Home.yaml")
        #expect(encodedProfiles.first?["sourceKind"] as? String == "localFile")

        for privateFile in [
            directories.profilesMetadata,
            await store.configurationURL(for: expectedID),
        ] {
            let attributes = try FileManager.default.attributesOfItem(atPath: privateFile.path)
            let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
            #expect(permissions.intValue & 0o777 == 0o600)
        }

        let reopenedStore = ProfileStore(directories: directories)
        let reloaded = try await reopenedStore.profiles()
        #expect(reloaded == [imported])
    }

    @Test("Import normalizes a proxy link list while preserving the source file")
    func importNormalizesProxyLinksWithoutMutatingSource() async throws {
        let temporaryDirectory = try ConfigurationTestSupport.makeTemporaryDirectory()
        defer { ConfigurationTestSupport.removeTemporaryDirectory(temporaryDirectory) }

        let credentials = Data("aes-128-gcm:secret".utf8).base64EncodedString()
        let sourceText = "ss://\(credentials)@example.com:8388#Tokyo\n"
        let source = try ConfigurationTestSupport.write(
            sourceText,
            named: "Provider.txt",
            in: temporaryDirectory
        )
        let directories = ApplicationDirectories(
            root: temporaryDirectory.appendingPathComponent("store", isDirectory: true)
        )
        let store = ProfileStore(directories: directories)

        let converted = try await SubscriptionConversionService().convertToMihomoYAML(
            content: sourceText,
            sourceURL: source,
            options: SubscriptionConversionOptions()
        )
        let convertedSource = try ConfigurationTestSupport.write(
            converted.yaml,
            named: "Provider.yaml",
            in: temporaryDirectory
        )

        let profile = try await store.importProfile(from: convertedSource)
        let stored = try await store.readConfiguration(for: profile.id)
        let document = try YAMLDocument(yaml: String(decoding: stored, as: UTF8.self))

        #expect(try String(contentsOf: source, encoding: .utf8) == sourceText)
        guard case let .sequence(proxies)? = document["proxies"] else {
            Issue.record("Expected one normalized proxy")
            return
        }
        #expect(proxies.count == 1)
        #expect(document["mode"] == nil)
        #expect(document["rules"] == nil)
    }

    @Test("Import rejects HTML and unrelated YAML before creating profile artifacts")
    func importRejectsNonMihomoDocuments() async throws {
        let temporaryDirectory = try ConfigurationTestSupport.makeTemporaryDirectory()
        defer { ConfigurationTestSupport.removeTemporaryDirectory(temporaryDirectory) }

        let directories = ApplicationDirectories(
            root: temporaryDirectory.appendingPathComponent("store", isDirectory: true)
        )
        let store = ProfileStore(directories: directories)

        for (name, contents) in [
            ("page.yaml", "<!doctype html><html><body>Sign in</body></html>"),
            ("notes.yaml", "project: Vela\nowner: Jerry\n"),
        ] {
            let source = try ConfigurationTestSupport.write(
                contents,
                named: name,
                in: temporaryDirectory
            )
            do {
                _ = try await store.importProfile(from: source)
                Issue.record("Expected \(name) to be rejected")
            } catch let error as ProfileStoreError {
                guard case .sourceReadFailed = error else {
                    Issue.record("Unexpected error: \(error)")
                    continue
                }
            }
        }

        #expect(try await store.profiles().isEmpty)
    }

    @Test("Same source name creates independent profiles without overwriting")
    func duplicateNamesDoNotOverwrite() async throws {
        let temporaryDirectory = try ConfigurationTestSupport.makeTemporaryDirectory()
        defer { ConfigurationTestSupport.removeTemporaryDirectory(temporaryDirectory) }

        let firstSourceDirectory = temporaryDirectory.appendingPathComponent("first", isDirectory: true)
        let secondSourceDirectory = temporaryDirectory.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: firstSourceDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondSourceDirectory, withIntermediateDirectories: true)
        let firstSource = try ConfigurationTestSupport.write(
            "mixed-port: 7001\nproxies:\n  - name: First\n    type: ss\n    server: first.example.com\n    port: 8388\n    cipher: aes-128-gcm\n    password: secret\n",
            named: "Profile.yaml",
            in: firstSourceDirectory
        )
        let secondSource = try ConfigurationTestSupport.write(
            "mixed-port: 7002\nproxies:\n  - name: Second\n    type: ss\n    server: second.example.com\n    port: 8388\n    cipher: aes-128-gcm\n    password: secret\n",
            named: "Profile.yaml",
            in: secondSourceDirectory
        )
        let directories = ApplicationDirectories(
            root: temporaryDirectory.appendingPathComponent("store", isDirectory: true)
        )
        let store = ProfileStore(directories: directories)

        let first = try await store.importProfile(from: firstSource)
        let second = try await store.importProfile(from: secondSource)
        let firstData = try await store.readConfiguration(for: first.id)
        let secondData = try await store.readConfiguration(for: second.id)
        let profiles = try await store.profiles()

        #expect(first.id != second.id)
        #expect(first.name == second.name)
        #expect(firstData != secondData)
        #expect(profiles.count == 2)
    }

    @Test("Selected profile is validated and persisted")
    func selectedProfilePersists() async throws {
        let temporaryDirectory = try ConfigurationTestSupport.makeTemporaryDirectory()
        defer { ConfigurationTestSupport.removeTemporaryDirectory(temporaryDirectory) }

        let source = try ConfigurationTestSupport.write(
            "mixed-port: 7000\nproxies:\n  - name: Selected\n    type: ss\n    server: example.com\n    port: 8388\n    cipher: aes-128-gcm\n    password: secret\n",
            named: "Selected.yaml",
            in: temporaryDirectory
        )
        let directories = ApplicationDirectories(
            root: temporaryDirectory.appendingPathComponent("store", isDirectory: true)
        )
        let store = ProfileStore(directories: directories)
        let profile = try await store.importProfile(from: source)

        try await store.selectProfile(id: profile.id)
        let selectedID = try await store.selectedProfileID()
        #expect(selectedID == profile.id)

        let reopenedStore = ProfileStore(directories: directories)
        let reopenedSelectedID = try await reopenedStore.selectedProfileID()
        #expect(reopenedSelectedID == profile.id)

        let missingID = UUID()
        do {
            try await reopenedStore.selectProfile(id: missingID)
            Issue.record("Expected selecting an unknown profile to fail")
        } catch let error as ProfileStoreError {
            #expect(error == .profileNotFound(missingID))
        }
    }

    @Test("Deleting the selected profile clears selection")
    func deletingSelectedProfileClearsSelection() async throws {
        let temporaryDirectory = try ConfigurationTestSupport.makeTemporaryDirectory()
        defer { ConfigurationTestSupport.removeTemporaryDirectory(temporaryDirectory) }

        let source = try ConfigurationTestSupport.write(
            "mixed-port: 7000\nproxies:\n  - name: Disposable\n    type: ss\n    server: example.com\n    port: 8388\n    cipher: aes-128-gcm\n    password: secret\n",
            named: "Disposable.yaml",
            in: temporaryDirectory
        )
        let directories = ApplicationDirectories(
            root: temporaryDirectory.appendingPathComponent("store", isDirectory: true)
        )
        let store = ProfileStore(directories: directories)
        let profile = try await store.importProfile(from: source)
        try await store.selectProfile(id: profile.id)

        try await store.deleteProfile(id: profile.id)

        let selectedID = try await store.selectedProfileID()
        let profiles = try await store.profiles()
        #expect(selectedID == nil)
        #expect(profiles.isEmpty)
        let configurationURL = await store.configurationURL(for: profile.id)
        #expect(!FileManager.default.fileExists(atPath: configurationURL.path))
    }

    @Test("Building a runtime configuration writes only active.yaml")
    func buildsRuntimeConfigurationWithoutChangingProfile() async throws {
        let temporaryDirectory = try ConfigurationTestSupport.makeTemporaryDirectory()
        defer { ConfigurationTestSupport.removeTemporaryDirectory(temporaryDirectory) }

        let source = try ConfigurationTestSupport.write(
            "mixed-port: 7000\nmode: rule\nproxies:\n  - name: Runtime\n    type: ss\n    server: example.com\n    port: 8388\n    cipher: aes-128-gcm\n    password: secret\n",
            named: "Runtime.yaml",
            in: temporaryDirectory
        )
        let directories = ApplicationDirectories(
            root: temporaryDirectory.appendingPathComponent("store", isDirectory: true)
        )
        let store = ProfileStore(directories: directories)
        let profile = try await store.importProfile(from: source)
        let profileDataBeforeBuild = try await store.readConfiguration(for: profile.id)

        let runtimeURL = try await store.buildRuntimeConfiguration(
            for: profile.id,
            parameters: RuntimeConfigParameters(
                externalController: "127.0.0.1:19090",
                secret: "test-runtime-secret",
                mixedPort: 17890
            )
        )

        let profileDataAfterBuild = try await store.readConfiguration(for: profile.id)
        #expect(runtimeURL == directories.activeConfiguration)
        #expect(profileDataAfterBuild == profileDataBeforeBuild)
        #expect(FileManager.default.fileExists(atPath: runtimeURL.path))
    }

    @Test("Runtime builds apply the active Scene configuration layer")
    func runtimeBuildAppliesSceneLayer() async throws {
        let temporaryDirectory = try ConfigurationTestSupport.makeTemporaryDirectory()
        defer { ConfigurationTestSupport.removeTemporaryDirectory(temporaryDirectory) }

        let source = try ConfigurationTestSupport.write(
            "mode: rule\nmixed-port: 7000\nproxies:\n  - name: Scene\n    type: ss\n    server: example.com\n    port: 8388\n    cipher: aes-128-gcm\n    password: secret\n",
            named: "Scene.yaml",
            in: temporaryDirectory
        )
        let directories = ApplicationDirectories(
            root: temporaryDirectory.appendingPathComponent("store", isDirectory: true)
        )
        let store = ProfileStore(directories: directories)
        let profile = try await store.importProfile(from: source)
        let sceneID = UUID(uuidString: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE")!
        let layer = ConfigurationLayer(
            name: "Scene mode",
            kind: .scene,
            operations: [
                ConfigurationOperation(
                    order: 10,
                    path: try YAMLPointer("/mode"),
                    kind: .set,
                    value: .string("direct")
                )
            ]
        )

        let runtimeURL = try await store.buildRuntimeConfiguration(
            for: profile.id,
            parameters: RuntimeConfigParameters(
                externalController: "127.0.0.1:19090",
                secret: "scene-runtime-secret",
                mixedPort: 17890
            ),
            using: RuntimeConfigBuilder(),
            context: ConfigurationCompilationContext(
                profileID: profile.id,
                profileRevisionID: profile.currentRevisionID,
                layers: [layer],
                generationID: sceneID
            )
        )

        let yaml = try String(contentsOf: runtimeURL, encoding: .utf8)
        let document = try YAMLDocument(yaml: yaml)
        #expect(try document.value(at: ["mode"]) == .string("direct"))
        #expect(try document.value(at: ["mixed-port"]) == .integer(17_890))
    }

    @Test("A metadata failure during deletion restores the profile file")
    func deletionRollsBackWhenMetadataWriteFails() async throws {
        let temporaryDirectory = try ConfigurationTestSupport.makeTemporaryDirectory()
        defer { ConfigurationTestSupport.removeTemporaryDirectory(temporaryDirectory) }

        let source = try ConfigurationTestSupport.write(
            "mixed-port: 7000\nproxies:\n  - name: Keep\n    type: ss\n    server: example.com\n    port: 8388\n    cipher: aes-128-gcm\n    password: secret\n",
            named: "Keep.yaml",
            in: temporaryDirectory
        )
        let directories = ApplicationDirectories(
            root: temporaryDirectory.appendingPathComponent("store", isDirectory: true)
        )
        let liveStore = ProfileStore(directories: directories)
        let profile = try await liveStore.importProfile(from: source)
        let configurationURL = await liveStore.configurationURL(for: profile.id)
        let failingStore = ProfileStore(
            directories: directories,
            fileSystem: MetadataWriteFailingFileSystem()
        )

        do {
            try await failingStore.deleteProfile(id: profile.id)
            Issue.record("Expected metadata persistence to fail")
        } catch let error as ProfileStoreError {
            guard case .metadataWriteFailed = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
        }

        #expect(FileManager.default.fileExists(atPath: configurationURL.path))
        let reopenedStore = ProfileStore(directories: directories)
        let restoredProfile = try await reopenedStore.profile(id: profile.id)
        #expect(restoredProfile?.id == profile.id)
        #expect(restoredProfile?.name == profile.name)
        #expect(restoredProfile?.originalFileName == profile.originalFileName)
    }
}

private struct MetadataWriteFailingFileSystem: FileSystemProviding {
    private let live = LiveFileSystem()

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
        if url.lastPathComponent == "profiles.json" {
            throw MetadataWriteFailingFileSystemError.expectedFailure
        }
        try live.writeDataAtomically(data, to: url)
    }

    func moveItem(at source: URL, to destination: URL) throws {
        try live.moveItem(at: source, to: destination)
    }

    func removeItem(at url: URL) throws {
        try live.removeItem(at: url)
    }
}

private enum MetadataWriteFailingFileSystemError: Error {
    case expectedFailure
}
