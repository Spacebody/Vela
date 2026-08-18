import Foundation

actor SystemProxyRecoveryStore: SystemProxyRecoveryStoring {
    private let directories: ApplicationDirectories
    private let fileSystem: any FileSystemProviding

    init(
        directories: ApplicationDirectories,
        fileSystem: any FileSystemProviding = LiveFileSystem()
    ) {
        self.directories = directories
        self.fileSystem = fileSystem
    }

    func load() async throws -> SystemProxyRecoveryLease? {
        guard fileSystem.fileExists(at: metadataURL) else {
            return nil
        }

        let data: Data
        do {
            data = try fileSystem.readData(at: metadataURL)
        } catch {
            throw SystemProxyRecoveryStoreError.readFailed(
                path: metadataURL.path,
                reason: String(describing: error)
            )
        }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let lease = try decoder.decode(SystemProxyRecoveryLease.self, from: data)
            guard lease.version == SystemProxyRecoveryLease.currentVersion else {
                throw SystemProxyRecoveryStoreError.unsupportedVersion(lease.version)
            }
            try validateUniqueServiceIDs(in: lease)
            return lease
        } catch let error as SystemProxyRecoveryStoreError {
            throw error
        } catch {
            throw SystemProxyRecoveryStoreError.decodeFailed(
                path: metadataURL.path,
                reason: String(describing: error)
            )
        }
    }

    func save(_ lease: SystemProxyRecoveryLease) async throws {
        do {
            try fileSystem.createDirectory(at: directories.metadata)
        } catch {
            throw SystemProxyRecoveryStoreError.preparationFailed(
                path: directories.metadata.path,
                reason: String(describing: error)
            )
        }

        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            data = try encoder.encode(lease)
        } catch {
            throw SystemProxyRecoveryStoreError.encodeFailed(reason: String(describing: error))
        }

        do {
            try fileSystem.writeDataAtomically(data, to: metadataURL)
        } catch {
            throw SystemProxyRecoveryStoreError.writeFailed(
                path: metadataURL.path,
                reason: String(describing: error)
            )
        }
    }

    func clear() async throws {
        guard fileSystem.fileExists(at: metadataURL) else {
            return
        }
        do {
            try fileSystem.removeItem(at: metadataURL)
        } catch {
            throw SystemProxyRecoveryStoreError.clearFailed(
                path: metadataURL.path,
                reason: String(describing: error)
            )
        }
    }

    private var metadataURL: URL {
        directories.metadata.appendingPathComponent(
            "system-proxy-recovery.json",
            isDirectory: false
        )
    }

    private func validateUniqueServiceIDs(in lease: SystemProxyRecoveryLease) throws {
        var serviceIDs = Set<String>()
        for service in lease.services {
            guard serviceIDs.insert(service.id).inserted else {
                throw SystemProxyRecoveryStoreError.duplicateServiceID(service.id)
            }
        }
    }
}

nonisolated enum SystemProxyRecoveryStoreError: Error, Equatable, Sendable {
    case preparationFailed(path: String, reason: String)
    case readFailed(path: String, reason: String)
    case decodeFailed(path: String, reason: String)
    case unsupportedVersion(Int)
    case duplicateServiceID(String)
    case encodeFailed(reason: String)
    case writeFailed(path: String, reason: String)
    case clearFailed(path: String, reason: String)
}

extension SystemProxyRecoveryStoreError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .preparationFailed(path, reason):
            "Could not prepare system proxy recovery storage at \(path): \(reason)"
        case let .readFailed(path, reason):
            "Could not read system proxy recovery data at \(path): \(reason)"
        case let .decodeFailed(path, reason):
            "Could not decode system proxy recovery data at \(path): \(reason)"
        case let .unsupportedVersion(version):
            "System proxy recovery data version \(version) is unsupported."
        case let .duplicateServiceID(id):
            "System proxy recovery data contains duplicate service ID \(id)."
        case let .encodeFailed(reason):
            "Could not encode system proxy recovery data: \(reason)"
        case let .writeFailed(path, reason):
            "Could not save system proxy recovery data at \(path): \(reason)"
        case let .clearFailed(path, reason):
            "Could not clear system proxy recovery data at \(path): \(reason)"
        }
    }
}
