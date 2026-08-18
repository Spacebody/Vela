import Foundation
import VelaIPC

/// Recognizes only the private filename emitted by
/// `POSIXRootFileSystem.withAtomicOutput`. Higher-level recovery code still
/// decides which anchored directories may contain one and which other entries
/// are valid there.
enum RootAtomicTemporaryArtifact {
    static func isExactName(_ name: String) -> Bool {
        let prefix = ".vela-"
        let suffix = ".tmp"
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return false }
        let start = name.index(name.startIndex, offsetBy: prefix.count)
        let end = name.index(name.endIndex, offsetBy: -suffix.count)
        let rawUUID = String(name[start..<end])
        guard let uuid = UUID(uuidString: rawUUID) else { return false }
        return rawUUID == uuid.uuidString.lowercased()
    }

    static func validate(
        _ entry: POSIXDirectoryEntry,
        in directory: SafeRelativePath,
        fileSystem: POSIXRootFileSystem,
        maximumBytes: Int64
    ) throws -> SafeRelativePath {
        guard isExactName(entry.name), entry.isRegularFile else {
            throw POSIXRootFileSystemError.unsupportedFileType
        }
        let path = try directory.appending(entry.name)
        _ = try fileSystem.verifiedRegularFileIdentity(
            at: path,
            maximumBytes: maximumBytes
        )
        return path
    }
}
