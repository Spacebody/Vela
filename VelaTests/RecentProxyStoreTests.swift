import Foundation
import Testing
@testable import Vela

@Suite("Recent proxy store")
struct RecentProxyStoreTests {
    @Test("An empty store loads no recent proxies")
    func emptyStoreLoadsNoRecords() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let records = try await fixture.store.load(for: fixture.firstProfileID)

        #expect(records.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.metadataURL.path))
    }

    @Test("Records persist in metadata and reload newest first")
    func recordsPersistAndReloadInReverseChronologicalOrder() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let older = Date(timeIntervalSince1970: 1_700_000_000)
        let newer = older.addingTimeInterval(60)

        try await fixture.store.record(
            profileID: fixture.firstProfileID,
            groupName: "Proxy",
            proxyName: "Hong Kong 01",
            usedAt: older
        )
        try await fixture.store.record(
            profileID: fixture.firstProfileID,
            groupName: "Proxy",
            proxyName: "Japan 02",
            usedAt: newer
        )

        #expect(FileManager.default.fileExists(atPath: fixture.metadataURL.path))
        let reopenedStore = RecentProxyStore(directories: fixture.directories)
        let records = try await reopenedStore.load(for: fixture.firstProfileID)
        #expect(records.map(\.proxyName) == ["Japan 02", "Hong Kong 01"])
        #expect(records.map(\.usedAt) == [newer, older])
    }

    @Test("Histories are isolated by profile")
    func historiesAreIsolatedByProfile() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)

        try await fixture.store.record(
            profileID: fixture.firstProfileID,
            groupName: "Proxy",
            proxyName: "Hong Kong 01",
            usedAt: timestamp
        )
        try await fixture.store.record(
            profileID: fixture.secondProfileID,
            groupName: "Proxy",
            proxyName: "Hong Kong 01",
            usedAt: timestamp.addingTimeInterval(1)
        )

        let firstRecords = try await fixture.store.load(for: fixture.firstProfileID)
        let secondRecords = try await fixture.store.load(for: fixture.secondProfileID)
        #expect(firstRecords.map(\.proxyName) == ["Hong Kong 01"])
        #expect(secondRecords.map(\.proxyName) == ["Hong Kong 01"])
        #expect(firstRecords.first?.usedAt == timestamp)
        #expect(secondRecords.first?.usedAt == timestamp.addingTimeInterval(1))
    }

    @Test("Recording the same group and proxy refreshes one entry")
    func duplicateGroupAndProxyRefreshesExistingEntry() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let older = Date(timeIntervalSince1970: 1_700_000_000)
        let newer = older.addingTimeInterval(120)

        try await fixture.store.record(
            profileID: fixture.firstProfileID,
            groupName: "Primary",
            proxyName: "Hong Kong 01",
            usedAt: older
        )
        try await fixture.store.record(
            profileID: fixture.firstProfileID,
            groupName: "Fallback",
            proxyName: "Hong Kong 01",
            usedAt: older.addingTimeInterval(30)
        )
        try await fixture.store.record(
            profileID: fixture.firstProfileID,
            groupName: "Primary",
            proxyName: "Hong Kong 01",
            usedAt: newer
        )

        let records = try await fixture.store.load(for: fixture.firstProfileID)
        #expect(records.count == 2)
        #expect(records.first?.groupName == "Primary")
        #expect(records.first?.usedAt == newer)
        #expect(records.last?.groupName == "Fallback")
    }

    @Test("The entry limit applies independently to every profile")
    func limitAppliesPerProfile() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        for index in 0..<10 {
            try await fixture.store.record(
                profileID: fixture.firstProfileID,
                groupName: "Proxy",
                proxyName: "Node \(index)",
                usedAt: base.addingTimeInterval(TimeInterval(index))
            )
        }
        for index in 0..<2 {
            try await fixture.store.record(
                profileID: fixture.secondProfileID,
                groupName: "Proxy",
                proxyName: "Other \(index)",
                usedAt: base.addingTimeInterval(TimeInterval(index))
            )
        }

        let firstRecords = try await fixture.store.load(for: fixture.firstProfileID)
        let secondRecords = try await fixture.store.load(for: fixture.secondProfileID)
        #expect(firstRecords.map(\.proxyName) == [
            "Node 9", "Node 8", "Node 7", "Node 6",
            "Node 5", "Node 4", "Node 3", "Node 2"
        ])
        #expect(secondRecords.map(\.proxyName) == ["Other 1", "Other 0"])
    }

    @Test("Malformed metadata returns a structured decoding error")
    func malformedMetadataReturnsStructuredError() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(
            at: fixture.directories.metadata,
            withIntermediateDirectories: true
        )
        try Data("not-json".utf8).write(to: fixture.metadataURL, options: .atomic)

        do {
            _ = try await fixture.store.load(for: fixture.firstProfileID)
            Issue.record("Expected malformed metadata to fail")
        } catch let error as RecentProxyStoreError {
            guard case let .metadataDecodeFailed(path, _) = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            #expect(path == fixture.metadataURL.path)
        }
    }
}

private struct Fixture {
    let root: URL
    let directories: ApplicationDirectories
    let store: RecentProxyStore
    let firstProfileID: UUID
    let secondProfileID: UUID

    var metadataURL: URL {
        directories.metadata.appendingPathComponent(
            "recent-proxies.json",
            isDirectory: false
        )
    }

    init(maximumEntriesPerProfile: Int = 8) throws {
        guard
            let firstProfileID = UUID(uuidString: "11111111-1111-1111-1111-111111111111"),
            let secondProfileID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")
        else {
            throw FixtureError.invalidIdentifier
        }

        self.firstProfileID = firstProfileID
        self.secondProfileID = secondProfileID
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "VelaRecentProxyTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        directories = ApplicationDirectories(
            root: root.appendingPathComponent("Application Support", isDirectory: true)
        )
        store = RecentProxyStore(
            directories: directories,
            maximumEntriesPerProfile: maximumEntriesPerProfile
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private enum FixtureError: Error {
    case invalidIdentifier
}
