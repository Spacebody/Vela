import CryptoKit
import Foundation
import Security

nonisolated struct RuntimeValidationCacheHit: Equatable, Sendable {
    let configurationFingerprint: RuntimeConfigurationFingerprint
}

nonisolated protocol RuntimeValidationCaching: Sendable {
    func cachedValidation(
        configurationURL: URL,
        dataDirectoryURL: URL,
        executable: ResolvedMihomoExecutable
    ) async -> RuntimeValidationCacheHit?

    func recordSuccessfulValidation(
        configurationURL: URL,
        dataDirectoryURL: URL,
        executable: ResolvedMihomoExecutable
    ) async
}

nonisolated struct DisabledRuntimeValidationCache: RuntimeValidationCaching {
    func cachedValidation(
        configurationURL _: URL,
        dataDirectoryURL _: URL,
        executable _: ResolvedMihomoExecutable
    ) async -> RuntimeValidationCacheHit? {
        nil
    }

    func recordSuccessfulValidation(
        configurationURL _: URL,
        dataDirectoryURL _: URL,
        executable _: ResolvedMihomoExecutable
    ) async {}
}

nonisolated struct RuntimePrivateFileStoreBackend: SecureStoreBackend {
    private static let maximumValueBytes = 1 * 1_024 * 1_024

    let directoryURL: URL

    init(directoryURL: URL) {
        self.directoryURL = directoryURL.standardizedFileURL
    }

    func data(service: String, account: String) throws -> Data? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directoryURL.path) else { return nil }
        try validateDirectory(fileManager: fileManager)

        let url = storageURL(service: service, account: account)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let expectedByteCount = try validateRegularFile(at: url)
        guard expectedByteCount <= Self.maximumValueBytes else {
            throw RuntimePrivateFileStoreError.valueTooLarge
        }

        let value = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard value.count == expectedByteCount else {
            throw RuntimePrivateFileStoreError.fileChangedDuringRead
        }
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: url.path
        )
        return value
    }

    func setData(_ data: Data, service: String, account: String) throws {
        guard data.count <= Self.maximumValueBytes else {
            throw RuntimePrivateFileStoreError.valueTooLarge
        }

        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        try validateDirectory(fileManager: fileManager)
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: directoryURL.path
        )

        let url = storageURL(service: service, account: account)
        if fileManager.fileExists(atPath: url.path) {
            _ = try validateRegularFile(at: url)
        }
        try data.write(to: url, options: [.atomic])
        _ = try validateRegularFile(at: url)
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: url.path
        )
    }

    func removeData(service: String, account: String) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directoryURL.path) else { return }
        try validateDirectory(fileManager: fileManager)

        let url = storageURL(service: service, account: account)
        guard fileManager.fileExists(atPath: url.path) else { return }
        _ = try validateRegularFile(at: url)
        try fileManager.removeItem(at: url)
    }

    func storageURL(service: String, account: String) -> URL {
        let identity = Data("\(service)\u{0}\(account)".utf8)
        let filename = SHA256.hash(data: identity)
            .map { String(format: "%02x", $0) }
            .joined()
        return directoryURL.appendingPathComponent("\(filename).store", isDirectory: false)
    }

    private func validateDirectory(fileManager: FileManager) throws {
        let values = try directoryURL.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw RuntimePrivateFileStoreError.invalidDirectory
        }
        guard fileManager.fileExists(atPath: directoryURL.path) else {
            throw RuntimePrivateFileStoreError.invalidDirectory
        }
    }

    private func validateRegularFile(at url: URL) throws -> Int {
        let values = try url.resourceValues(forKeys: [
            .fileSizeKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw RuntimePrivateFileStoreError.invalidFile
        }
        return max(0, values.fileSize ?? 0)
    }
}

actor RuntimeValidationCache: RuntimeValidationCaching {
    static let defaultService = "dev.yilin.Vela.runtime-validation"

    private static let account = "last-successful-launch"
    private static let schemaVersion = 1
    private static let maximumDataFiles = 2_048
    private static let maximumDataBytes: UInt64 = 512 * 1_024 * 1_024
    private static let ignoredDataFiles: Set<String> = [
        ".DS_Store",
        "cache.db",
        "cache.db-shm",
        "cache.db-wal",
    ]

    private let backend: any SecureStoreBackend
    private let service: String

    init(
        backend: any SecureStoreBackend,
        service: String = defaultService
    ) {
        self.backend = backend
        self.service = service
    }

    func cachedValidation(
        configurationURL: URL,
        dataDirectoryURL: URL,
        executable: ResolvedMihomoExecutable
    ) async -> RuntimeValidationCacheHit? {
        guard (try? MihomoVerifiedExecutableGuard.verifyUnchanged(executable)) != nil,
            let data = try? backend.data(service: service, account: Self.account),
            let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
            envelope.schemaVersion == Self.schemaVersion,
            let identity = try? await Self.identity(
                configurationURL: configurationURL,
                dataDirectoryURL: dataDirectoryURL,
                executable: executable
            ),
            envelope.identity == identity
        else {
            return nil
        }

        return RuntimeValidationCacheHit(
            configurationFingerprint: RuntimeConfigurationFingerprint(
                url: configurationURL,
                sha256: identity.configurationSHA256,
                byteCount: identity.configurationByteCount
            )
        )
    }

    func recordSuccessfulValidation(
        configurationURL: URL,
        dataDirectoryURL: URL,
        executable: ResolvedMihomoExecutable
    ) async {
        guard (try? MihomoVerifiedExecutableGuard.verifyUnchanged(executable)) != nil,
            let identity = try? await Self.identity(
                configurationURL: configurationURL,
                dataDirectoryURL: dataDirectoryURL,
                executable: executable
            )
        else {
            return
        }

        let envelope = Envelope(
            schemaVersion: Self.schemaVersion,
            identity: identity
        )
        guard let data = try? JSONEncoder.sorted.encode(envelope) else { return }
        try? backend.setData(data, service: service, account: Self.account)
    }

    private nonisolated static func identity(
        configurationURL: URL,
        dataDirectoryURL: URL,
        executable: ResolvedMihomoExecutable
    ) async throws -> Identity {
        try await Task.detached(priority: .userInitiated) {
            let configurationData = try Data(contentsOf: configurationURL)
            let configurationSHA256 = Self.sha256(configurationData)
            let dataDirectory = try Self.dataDirectoryDigest(at: dataDirectoryURL)
            return Identity(
                configurationSHA256: configurationSHA256,
                configurationByteCount: configurationData.count,
                executablePath: executable.url.standardizedFileURL.path,
                executableVersion: executable.version,
                executableSHA256: executable.sha256,
                dataDirectorySHA256: dataDirectory.sha256,
                dataDirectoryFileCount: dataDirectory.fileCount,
                dataDirectoryByteCount: dataDirectory.byteCount
            )
        }.value
    }

    private nonisolated static func dataDirectoryDigest(at rootURL: URL) throws -> DirectoryDigest {
        let root = rootURL.standardizedFileURL
        let keys: Set<URLResourceKey> = [
            .fileSizeKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ]
        var enumerationError: (any Error)?
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsPackageDescendants],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw RuntimeValidationCacheError.dataDirectoryUnavailable(root.path)
        }

        var files: [(relativePath: String, url: URL, byteCount: UInt64)] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: keys)
            if values.isSymbolicLink == true {
                throw RuntimeValidationCacheError.symbolicLink(url.path)
            }
            guard values.isRegularFile == true else { continue }
            let relativePath = String(url.standardizedFileURL.path.dropFirst(root.path.count + 1))
            guard !ignoredDataFiles.contains(relativePath) else { continue }
            guard !ignoredDataFiles.contains(url.lastPathComponent) else { continue }
            guard files.count < maximumDataFiles else {
                throw RuntimeValidationCacheError.dataDirectoryTooLarge
            }
            let byteCount = UInt64(max(0, values.fileSize ?? 0))
            files.append((relativePath, url, byteCount))
        }
        if let enumerationError { throw enumerationError }

        files.sort { $0.relativePath < $1.relativePath }
        var totalBytes: UInt64 = 0
        var hasher = SHA256()
        for file in files {
            totalBytes = try totalBytes.addingWithoutOverflow(file.byteCount)
            guard totalBytes <= maximumDataBytes else {
                throw RuntimeValidationCacheError.dataDirectoryTooLarge
            }
            let data = try Data(contentsOf: file.url, options: [.mappedIfSafe])
            guard data.count == Int(file.byteCount) else {
                throw RuntimeValidationCacheError.fileChangedDuringRead(file.url.path)
            }
            Self.update(&hasher, with: file.relativePath)
            Self.update(&hasher, with: file.byteCount)
            hasher.update(data: data)
        }

        return DirectoryDigest(
            sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined(),
            fileCount: files.count,
            byteCount: totalBytes
        )
    }

    private nonisolated static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func update(_ hasher: inout SHA256, with value: String) {
        let data = Data(value.utf8)
        update(&hasher, with: UInt64(data.count))
        hasher.update(data: data)
    }

    private nonisolated static func update(_ hasher: inout SHA256, with value: UInt64) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { hasher.update(bufferPointer: $0) }
    }

    private struct Envelope: Codable {
        let schemaVersion: Int
        let identity: Identity
    }

    private struct Identity: Codable, Equatable {
        let configurationSHA256: String
        let configurationByteCount: Int
        let executablePath: String
        let executableVersion: String
        let executableSHA256: String
        let dataDirectorySHA256: String
        let dataDirectoryFileCount: Int
        let dataDirectoryByteCount: UInt64
    }

    private struct DirectoryDigest {
        let sha256: String
        let fileCount: Int
        let byteCount: UInt64
    }
}

nonisolated struct RuntimeControllerSecretProvider: Sendable {
    static let defaultService = "dev.yilin.Vela.runtime-controller"

    private static let account = "controller-secret"
    private let backend: any SecureStoreBackend
    private let service: String

    init(
        backend: any SecureStoreBackend,
        service: String = defaultService
    ) {
        self.backend = backend
        self.service = service
    }

    func loadOrCreate() -> String {
        if let data = try? backend.data(service: service, account: Self.account),
            let value = String(data: data, encoding: .utf8),
            Self.isValid(value)
        {
            return value
        }

        let value = Self.makeSecret()
        try? backend.setData(Data(value.utf8), service: service, account: Self.account)
        return value
    }

    private static func isValid(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy(\.isHexDigit)
    }

    private static func makeSecret() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess {
            return bytes.map { String(format: "%02x", $0) }.joined()
        }
        return (UUID().uuidString + UUID().uuidString)
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
    }
}

nonisolated private extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

nonisolated private extension UInt64 {
    func addingWithoutOverflow(_ value: UInt64) throws -> UInt64 {
        let (result, overflow) = addingReportingOverflow(value)
        guard !overflow else { throw RuntimeValidationCacheError.dataDirectoryTooLarge }
        return result
    }
}

nonisolated private enum RuntimeValidationCacheError: Error {
    case dataDirectoryUnavailable(String)
    case dataDirectoryTooLarge
    case symbolicLink(String)
    case fileChangedDuringRead(String)
}

nonisolated private enum RuntimePrivateFileStoreError: Error {
    case invalidDirectory
    case invalidFile
    case valueTooLarge
    case fileChangedDuringRead
}
