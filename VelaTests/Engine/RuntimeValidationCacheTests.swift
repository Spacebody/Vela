import Foundation
import Testing
@testable import Vela

struct RuntimeValidationCacheTests {
    @Test
    func exactValidatedInputsProduceCacheHit() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let cache = RuntimeValidationCache(
            backend: fixture.backend,
            service: fixture.service
        )

        await cache.recordSuccessfulValidation(
            configurationURL: fixture.configurationURL,
            dataDirectoryURL: fixture.dataDirectoryURL,
            executable: fixture.executable
        )
        let hit = await cache.cachedValidation(
            configurationURL: fixture.configurationURL,
            dataDirectoryURL: fixture.dataDirectoryURL,
            executable: fixture.executable
        )

        let unwrapped = try #require(hit)
        #expect(unwrapped.configurationFingerprint.url == fixture.configurationURL)
        #expect(unwrapped.configurationFingerprint.byteCount == fixture.configurationData.count)
    }

    @Test
    func configurationChangeInvalidatesCache() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let cache = RuntimeValidationCache(backend: fixture.backend, service: fixture.service)
        await fixture.record(in: cache)

        try Data("mode: direct\n".utf8).write(to: fixture.configurationURL)

        let hit = await fixture.hit(in: cache)
        #expect(hit == nil)
    }

    @Test
    func validationDataChangeInvalidatesCache() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let cache = RuntimeValidationCache(backend: fixture.backend, service: fixture.service)
        await fixture.record(in: cache)

        try Data("changed rules".utf8).write(to: fixture.ruleURL)

        let hit = await fixture.hit(in: cache)
        #expect(hit == nil)
    }

    @Test
    func mutableMihomoCacheDatabaseDoesNotInvalidateValidation() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let cache = RuntimeValidationCache(backend: fixture.backend, service: fixture.service)
        await fixture.record(in: cache)

        try Data("runtime cache changed".utf8).write(
            to: fixture.dataDirectoryURL.appendingPathComponent("cache.db")
        )

        let hit = await fixture.hit(in: cache)
        #expect(hit != nil)
    }

    @Test
    func executableMutationInvalidatesCache() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let cache = RuntimeValidationCache(backend: fixture.backend, service: fixture.service)
        await fixture.record(in: cache)

        try Data("#!/bin/sh\nexit 1\n".utf8).write(to: fixture.executable.url)

        let hit = await fixture.hit(in: cache)
        #expect(hit == nil)
    }

    @Test
    func controllerSecretIsStableAndStoredAsRandomHex() throws {
        let rootURL = try ProcessTestSupport.makeTemporaryDirectory()
        defer { ProcessTestSupport.removeTemporaryDirectory(rootURL) }
        let backend = RuntimePrivateFileStoreBackend(
            directoryURL: rootURL.appendingPathComponent("runtime-state", isDirectory: true)
        )
        let service = "test.runtime-controller.\(UUID().uuidString)"
        let provider = RuntimeControllerSecretProvider(
            backend: backend,
            service: service
        )

        let first = provider.loadOrCreate()
        let second = provider.loadOrCreate()
        let isHex = first.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0)
        }

        #expect(first == second)
        #expect(first.count == 64)
        #expect(isHex)

        let fileURL = backend.storageURL(service: service, account: "controller-secret")
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
        #expect(permissions == 0o600)
    }
}

private struct Fixture {
    let rootURL: URL
    let configurationURL: URL
    let dataDirectoryURL: URL
    let ruleURL: URL
    let configurationData: Data
    let executable: ResolvedMihomoExecutable
    let backend = InMemoryRuntimeSecureStoreBackend()
    let service = "test.runtime-validation.\(UUID().uuidString)"

    init() throws {
        rootURL = try ProcessTestSupport.makeTemporaryDirectory()
        configurationURL = rootURL.appendingPathComponent("active.yaml")
        dataDirectoryURL = rootURL.appendingPathComponent("mihomo", isDirectory: true)
        ruleURL = dataDirectoryURL.appendingPathComponent("ruleset/example.yaml")
        configurationData = Data("mode: rule\n".utf8)
        try FileManager.default.createDirectory(
            at: ruleURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try configurationData.write(to: configurationURL)
        try Data("payload: []\n".utf8).write(to: ruleURL)
        try Data("runtime cache".utf8).write(
            to: dataDirectoryURL.appendingPathComponent("cache.db")
        )
        let executableURL = try ProcessTestSupport.makeScript(in: rootURL, body: "exit 0")
        executable = ProcessTestSupport.resolvedExecutable(at: executableURL)
    }

    func record(in cache: RuntimeValidationCache) async {
        await cache.recordSuccessfulValidation(
            configurationURL: configurationURL,
            dataDirectoryURL: dataDirectoryURL,
            executable: executable
        )
    }

    func hit(in cache: RuntimeValidationCache) async -> RuntimeValidationCacheHit? {
        await cache.cachedValidation(
            configurationURL: configurationURL,
            dataDirectoryURL: dataDirectoryURL,
            executable: executable
        )
    }

    func cleanup() {
        ProcessTestSupport.removeTemporaryDirectory(rootURL)
    }
}

private final class InMemoryRuntimeSecureStoreBackend: SecureStoreBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    func data(service: String, account: String) throws -> Data? {
        lock.withLock { values[key(service: service, account: account)] }
    }

    func setData(_ data: Data, service: String, account: String) throws {
        lock.withLock { values[key(service: service, account: account)] = data }
    }

    func removeData(service: String, account: String) throws {
        lock.withLock { _ = values.removeValue(forKey: key(service: service, account: account)) }
    }

    private func key(service: String, account: String) -> String {
        "\(service)\u{0}\(account)"
    }
}
