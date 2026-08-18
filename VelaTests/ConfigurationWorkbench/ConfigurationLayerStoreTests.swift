import Foundation
import Testing
@testable import Vela

@Suite("Configuration layer store")
struct ConfigurationLayerStoreTests {
    @Test("Committed layers load in precedence order and drafts never leak")
    func committedLayersAreOrdered() async throws {
        let root = try ConfigurationTestSupport.makeTemporaryDirectory()
        defer { ConfigurationTestSupport.removeTemporaryDirectory(root) }
        let directories = ApplicationDirectories(root: root)
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let store = ConfigurationLayerStore(
            directories: directories,
            now: { timestamp }
        )
        let profileID = UUID(uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA")!
        let sceneID = UUID(uuidString: "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB")!

        let global = try await store.save(
            layer(
                id: "30000000-0000-4000-8000-000000000000",
                kind: .global,
                name: "Global"
            )
        )
        let profile = try await store.save(
            layer(
                id: "20000000-0000-4000-8000-000000000000",
                kind: .profile,
                name: "Profile"
            ),
            ownerID: profileID
        )
        let scene = try await store.save(
            layer(
                id: "10000000-0000-4000-8000-000000000000",
                kind: .scene,
                name: "Scene"
            ),
            ownerID: sceneID
        )
        _ = try await store.save(
            layer(
                id: "40000000-0000-4000-8000-000000000000",
                kind: .profile,
                name: "Other Profile",
                enabled: false
            ),
            ownerID: UUID()
        )

        let selected = try await store.layers(profileID: profileID, sceneID: sceneID)
        #expect(selected.map(\.id) == [global.id, profile.id, scene.id])
        #expect(selected.map(\.kind) == [.global, .profile, .scene])
        #expect(selected.map(\.enabled) == [true, true, true])
    }

    @Test("Saving a committed layer increments revision and preserves identity")
    func saveIncrementsRevision() async throws {
        let root = try ConfigurationTestSupport.makeTemporaryDirectory()
        defer { ConfigurationTestSupport.removeTemporaryDirectory(root) }
        let dates = LockedDates([
            Date(timeIntervalSince1970: 100),
            Date(timeIntervalSince1970: 200),
        ])
        let store = ConfigurationLayerStore(
            directories: ApplicationDirectories(root: root),
            now: { dates.next() }
        )
        let id = UUID(uuidString: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE")!
        let createdAt = Date(timeIntervalSince1970: 50)
        let initial = ConfigurationLayer(
            id: id,
            name: "Global",
            kind: .global,
            createdAt: createdAt,
            updatedAt: createdAt
        )

        let first = try await store.save(initial)
        var draft = first
        draft.name = "Global updated"
        let second = try await store.save(draft)

        #expect(first.revision == 1)
        #expect(second.revision == 2)
        #expect(second.id == first.id)
        #expect(second.createdAt == createdAt)
        #expect(second.updatedAt == Date(timeIntervalSince1970: 200))
        #expect(try await store.layer(kind: .global)?.name == "Global updated")
    }

    @Test("Pack layer fixture without timestamps or optional policies decodes")
    func packFixtureCompatibility() throws {
        let fixture = Data(
            """
            {
              "schemaVersion": 1,
              "id": "30C6858D-FAD7-46EC-A1DC-CF708689C426",
              "revision": 1,
              "name": "Profile overrides",
              "kind": "profile",
              "enabled": true,
              "operations": [
                {
                  "id": "7A17437C-47D6-4644-AB52-B4015B4D9748",
                  "enabled": true,
                  "order": 10,
                  "kind": "set",
                  "path": "/sniffer/enable",
                  "value": true
                }
              ]
            }
            """.utf8
        )

        let layer = try JSONDecoder().decode(ConfigurationLayer.self, from: fixture)
        #expect(layer.createdAt == .distantPast)
        #expect(layer.updatedAt == .distantPast)
        #expect(layer.operations.first?.duplicatePolicy == .replace)
        #expect(layer.operations.first?.insertionPosition == .end)
        #expect(layer.operations.first?.value == .bool(true))
    }

    @Test("A failed final replacement leaves the previous store intact")
    func failedCommitDoesNotOverwrite() async throws {
        let root = try ConfigurationTestSupport.makeTemporaryDirectory()
        defer { ConfigurationTestSupport.removeTemporaryDirectory(root) }
        let directories = ApplicationDirectories(root: root)
        let initialStore = ConfigurationLayerStore(directories: directories)
        let initial = try await initialStore.save(
            layer(
                id: "AAAAAAAA-0000-4000-8000-000000000000",
                kind: .global,
                name: "Initial"
            )
        )
        let originalData = try Data(contentsOf: directories.configurationLayers)

        let failingStore = ConfigurationLayerStore(
            directories: directories,
            fileSystem: LayerCommitFailingFileSystem(
                blockedURL: directories.configurationLayers
            )
        )
        var draft = initial
        draft.name = "Must not commit"
        do {
            _ = try await failingStore.save(draft)
            Issue.record("Expected the final layers.json replacement to fail")
        } catch {
            #expect(error is ConfigurationLayerStoreError)
        }

        #expect(try Data(contentsOf: directories.configurationLayers) == originalData)
        let reopened = ConfigurationLayerStore(directories: directories)
        #expect(try await reopened.layer(kind: .global)?.name == "Initial")
    }

    @Test("Protected and conflicting operations never enter committed storage")
    func invalidLayersAreRejected() async throws {
        let root = try ConfigurationTestSupport.makeTemporaryDirectory()
        defer { ConfigurationTestSupport.removeTemporaryDirectory(root) }
        let store = ConfigurationLayerStore(
            directories: ApplicationDirectories(root: root)
        )
        let protected = ConfigurationLayer(
            id: UUID(uuidString: "AAAAAAAA-0000-4000-8000-000000000001")!,
            name: "Protected",
            kind: .global,
            operations: [ConfigurationOperation(
                id: UUID(uuidString: "BBBBBBBB-0000-4000-8000-000000000001")!,
                order: 1,
                path: try YAMLPointer("/secret"),
                kind: .set,
                value: .string("must-not-persist")
            )]
        )
        await #expect(throws: ConfigurationLayerStoreError.self) {
            try await store.save(protected)
        }

        let conflict = ConfigurationLayer(
            id: UUID(uuidString: "AAAAAAAA-0000-4000-8000-000000000002")!,
            name: "Conflict",
            kind: .global,
            operations: [
                ConfigurationOperation(
                    id: UUID(uuidString: "BBBBBBBB-0000-4000-8000-000000000002")!,
                    order: 1,
                    path: try YAMLPointer("/mode"),
                    kind: .set,
                    value: .string("rule")
                ),
                ConfigurationOperation(
                    id: UUID(uuidString: "BBBBBBBB-0000-4000-8000-000000000003")!,
                    order: 2,
                    path: try YAMLPointer("/mode"),
                    kind: .set,
                    value: .string("direct")
                ),
            ]
        )
        await #expect(throws: ConfigurationLayerStoreError.self) {
            try await store.save(conflict)
        }
        #expect(try await store.snapshot().layers.isEmpty)
    }

    private func layer(
        id: String,
        kind: ConfigurationLayerKind,
        name: String,
        enabled: Bool = true
    ) -> ConfigurationLayer {
        ConfigurationLayer(
            id: UUID(uuidString: id)!,
            name: name,
            kind: kind,
            enabled: enabled,
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 10)
        )
    }
}

private nonisolated final class LockedDates: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Date]

    init(_ values: [Date]) {
        self.values = values
    }

    func next() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return values.isEmpty ? .distantPast : values.removeFirst()
    }
}

private struct LayerCommitFailingFileSystem: FileSystemProviding {
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

    func contentsOfDirectory(at url: URL) throws -> [URL] {
        try live.contentsOfDirectory(at: url)
    }

    func isRegularFile(at url: URL) -> Bool {
        live.isRegularFile(at: url)
    }

    func readData(at url: URL) throws -> Data {
        try live.readData(at: url)
    }

    func writeDataAtomically(_ data: Data, to url: URL) throws {
        if url.standardizedFileURL == blockedURL.standardizedFileURL {
            throw LayerCommitFailure.expected
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

private enum LayerCommitFailure: Error {
    case expected
}
