import Darwin
import Foundation

nonisolated enum ReliabilityFileKind: Equatable, Sendable {
    case regular
    case directory
    case symbolicLink
    case other
}

nonisolated struct ReliabilityFileMetadata: Equatable, Sendable {
    let kind: ReliabilityFileKind
    let permissions: Int
    let ownerUserID: UInt32
    let size: Int64
    let device: UInt64
    let inode: UInt64
}

nonisolated protocol ReliabilityFileSystemProviding: Sendable {
    func metadata(at url: URL) throws -> ReliabilityFileMetadata?
    func createDirectory(at url: URL) throws
    func contentsOfDirectory(at url: URL) throws -> [URL]
    func readData(at url: URL) throws -> Data
    func writeDataAtomically(_ data: Data, to url: URL) throws
    func moveItem(at source: URL, to destination: URL) throws
    func removeItem(at url: URL) throws
    func setPOSIXPermissions(_ permissions: Int, at url: URL) throws
}

nonisolated struct LiveReliabilityFileSystem: ReliabilityFileSystemProviding, Sendable {
    func metadata(at url: URL) throws -> ReliabilityFileMetadata? {
        var status = stat()
        let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.lstat(path, &status)
        }
        if result != 0 {
            if errno == ENOENT { return nil }
            throw ReliabilityEvidenceStoreError.storageInspectionFailed
        }

        let kind: ReliabilityFileKind = switch status.st_mode & mode_t(S_IFMT) {
        case mode_t(S_IFREG): .regular
        case mode_t(S_IFDIR): .directory
        case mode_t(S_IFLNK): .symbolicLink
        default: .other
        }
        return ReliabilityFileMetadata(
            kind: kind,
            permissions: Int(status.st_mode & 0o7777),
            ownerUserID: status.st_uid,
            size: Int64(status.st_size),
            device: UInt64(status.st_dev),
            inode: UInt64(status.st_ino)
        )
    }

    func createDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
    }

    func contentsOfDirectory(at url: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsSubdirectoryDescendants]
        )
    }

    func readData(at url: URL) throws -> Data {
        try Data(contentsOf: url, options: [.mappedIfSafe])
    }

    func writeDataAtomically(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }

    func moveItem(at source: URL, to destination: URL) throws {
        try FileManager.default.moveItem(at: source, to: destination)
    }

    func removeItem(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    func setPOSIXPermissions(_ permissions: Int, at url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: permissions)],
            ofItemAtPath: url.path
        )
    }
}

nonisolated protocol ReliabilityClockProviding: Sendable {
    func now() -> Date
}

nonisolated struct LiveReliabilityClock: ReliabilityClockProviding, Sendable {
    func now() -> Date { .now }
}

nonisolated protocol ReliabilityIdentifierProviding: Sendable {
    func makeIdentifier() -> UUID
}

nonisolated struct LiveReliabilityIdentifierProvider: ReliabilityIdentifierProviding, Sendable {
    func makeIdentifier() -> UUID { UUID() }
}
