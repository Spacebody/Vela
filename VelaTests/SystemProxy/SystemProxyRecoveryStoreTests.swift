import Foundation
import Testing
@testable import Vela

@Suite("System proxy recovery store")
struct SystemProxyRecoveryStoreTests {
    @Test("Recovery lease persists atomically and can be cleared")
    func leaseRoundTripsAndClears() async throws {
        let fixture = try RecoveryStoreFixture()
        defer { fixture.remove() }
        let original = try SystemProxyPropertyList.emptyConfiguration()
        let managed = try SystemProxyPropertyList.applying(
            target: fixture.target,
            to: original
        )
        let lease = SystemProxyRecoveryLease(
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            target: fixture.target,
            services: [
                SystemProxyRecoveryService(
                    id: "wifi",
                    name: "Wi-Fi",
                    originalConfiguration: original,
                    managedConfiguration: managed
                )
            ]
        )

        try await fixture.store.save(lease)
        let loaded = try await fixture.store.load()

        #expect(loaded == lease)
        #expect(FileManager.default.fileExists(atPath: fixture.metadataURL.path))

        try await fixture.store.clear()
        #expect(try await fixture.store.load() == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.metadataURL.path))
    }

    @Test("Malformed recovery metadata returns a structured decoding error")
    func malformedMetadataFailsWithoutMutation() async throws {
        let fixture = try RecoveryStoreFixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(
            at: fixture.directories.metadata,
            withIntermediateDirectories: true
        )
        try Data("not-json".utf8).write(to: fixture.metadataURL, options: .atomic)

        do {
            _ = try await fixture.store.load()
            Issue.record("Expected malformed metadata to fail")
        } catch let error as SystemProxyRecoveryStoreError {
            guard case let .decodeFailed(path, _) = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            #expect(path == fixture.metadataURL.path)
        }

        #expect(try Data(contentsOf: fixture.metadataURL) == Data("not-json".utf8))
    }

    @Test("Duplicate service IDs return a structured recovery error")
    func duplicateServiceIDsAreRejected() async throws {
        let fixture = try RecoveryStoreFixture()
        defer { fixture.remove() }
        let configuration = try SystemProxyPropertyList.emptyConfiguration()
        let lease = SystemProxyRecoveryLease(
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            target: fixture.target,
            services: [
                SystemProxyRecoveryService(
                    id: "wifi",
                    name: "Wi-Fi",
                    originalConfiguration: configuration,
                    managedConfiguration: configuration
                ),
                SystemProxyRecoveryService(
                    id: "wifi",
                    name: "Wi-Fi (duplicate)",
                    originalConfiguration: configuration,
                    managedConfiguration: configuration
                )
            ]
        )
        try fixture.writeMetadata(for: lease)

        do {
            _ = try await fixture.store.load()
            Issue.record("Expected duplicate service IDs to fail")
        } catch let error as SystemProxyRecoveryStoreError {
            #expect(error == .duplicateServiceID("wifi"))
        }
    }

    @Test("Unique service IDs load successfully")
    func uniqueServiceIDsAreAccepted() async throws {
        let fixture = try RecoveryStoreFixture()
        defer { fixture.remove() }
        let configuration = try SystemProxyPropertyList.emptyConfiguration()
        let lease = SystemProxyRecoveryLease(
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            target: fixture.target,
            services: [
                SystemProxyRecoveryService(
                    id: "ethernet",
                    name: "Ethernet",
                    originalConfiguration: configuration,
                    managedConfiguration: configuration
                ),
                SystemProxyRecoveryService(
                    id: "wifi",
                    name: "Wi-Fi",
                    originalConfiguration: configuration,
                    managedConfiguration: configuration
                )
            ]
        )
        try fixture.writeMetadata(for: lease)

        #expect(try await fixture.store.load() == lease)
    }
}

private struct RecoveryStoreFixture {
    let root: URL
    let directories: ApplicationDirectories
    let store: SystemProxyRecoveryStore
    let target = SystemProxyTarget(host: "127.0.0.1", port: Int(7890))

    var metadataURL: URL {
        directories.metadata.appendingPathComponent(
            "system-proxy-recovery.json",
            isDirectory: false
        )
    }

    init() throws {
        root = URL.temporaryDirectory.appendingPathComponent(
            "Vela-SystemProxyStoreTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        directories = ApplicationDirectories(root: root.appendingPathComponent("Application Support"))
        store = SystemProxyRecoveryStore(directories: directories)
    }

    func writeMetadata(for lease: SystemProxyRecoveryLease) throws {
        try FileManager.default.createDirectory(
            at: directories.metadata,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(lease).write(to: metadataURL, options: .atomic)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
