import Darwin
import Foundation
import VelaIPC

public struct PrivilegedOwnershipPolicy: Equatable, Sendable {
    public let userID: uid_t
    public let groupID: gid_t
    public let directoryMode: mode_t
    public let fileMode: mode_t

    public init(
        userID: uid_t,
        groupID: gid_t,
        directoryMode: mode_t = 0o700,
        fileMode: mode_t = 0o600
    ) {
        self.userID = userID
        self.groupID = groupID
        self.directoryMode = directoryMode
        self.fileMode = fileMode
    }

    public static let rootWheel = PrivilegedOwnershipPolicy(userID: 0, groupID: 0)
}

public struct POSIXFileIdentity: Codable, Equatable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public let userID: UInt32
    public let groupID: UInt32
    public let permissions: UInt16
    public let size: Int64

    init(_ status: stat) {
        device = UInt64(status.st_dev)
        inode = UInt64(status.st_ino)
        userID = status.st_uid
        groupID = status.st_gid
        permissions = UInt16(status.st_mode & 0o7777)
        size = status.st_size
    }
}

public struct POSIXDirectoryEntry: Equatable, Sendable {
    public let name: String
    public let isDirectory: Bool
    public let isRegularFile: Bool
}

public struct POSIXTreeRemovalLimits: Equatable, Sendable {
    public let maximumDepth: Int
    public let maximumEntries: Int
    public let maximumRegularFileBytes: Int64

    public init(
        maximumDepth: Int = 8,
        maximumEntries: Int = 4_096,
        maximumRegularFileBytes: Int64 = 512 * 1_024 * 1_024
    ) {
        self.maximumDepth = maximumDepth
        self.maximumEntries = maximumEntries
        self.maximumRegularFileBytes = maximumRegularFileBytes
    }
}

public enum POSIXRootFileSystemError: Error, Equatable, Sendable {
    case invalidBaseURL
    case systemCall(operation: String, code: Int32)
    case symlinkRejected
    case notDirectory
    case notRegularFile
    case unsafeOwnership
    case unsafePermissions
    case fileTooLarge
    case treeLimitExceeded
    case crossDeviceEntry
    case unsupportedFileType
    case shortRead
    case destinationExists
}

extension POSIXRootFileSystemError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            "The privileged data directory is invalid."
        case .systemCall:
            "A privileged filesystem operation failed."
        case .symlinkRejected:
            "A symbolic link was rejected in the privileged data directory."
        case .notDirectory:
            "A privileged data directory has an invalid file type."
        case .notRegularFile:
            "A privileged data file has an invalid file type."
        case .unsafeOwnership:
            "The privileged data ownership is unsafe."
        case .unsafePermissions:
            "The privileged data permissions are unsafe."
        case .fileTooLarge:
            "The privileged data file exceeds its size limit."
        case .treeLimitExceeded:
            "The privileged runtime tree exceeds its cleanup limit."
        case .crossDeviceEntry:
            "The privileged runtime tree crosses a filesystem boundary."
        case .unsupportedFileType:
            "The privileged runtime tree contains an unsupported file type."
        case .shortRead:
            "The privileged data file changed while it was being read."
        case .destinationExists:
            "The privileged staging destination already exists."
        }
    }
}

/// An `openat`-anchored filesystem rooted at a verified directory descriptor.
///
/// No operation resolves an attacker-controlled absolute path after initialization.
/// Every traversed directory is opened with `O_NOFOLLOW`, and every existing entry
/// is checked with `fstatat(..., AT_SYMLINK_NOFOLLOW)` before use.
public final class POSIXRootFileSystem: @unchecked Sendable {
    public static let trustedExecutableMode: mode_t = 0o500

    public let policy: PrivilegedOwnershipPolicy
    public let rootIdentity: POSIXFileIdentity
    public let rootURL: URL

    private let rootDescriptor: Int32

    private init(
        rootDescriptor: Int32,
        rootURL: URL,
        policy: PrivilegedOwnershipPolicy,
        rootStatus: stat
    ) {
        self.rootDescriptor = rootDescriptor
        self.rootURL = rootURL
        self.policy = policy
        rootIdentity = POSIXFileIdentity(rootStatus)
    }

    deinit {
        Darwin.close(rootDescriptor)
    }

    /// Opens an existing root. This is useful after bootstrap and for isolated tests.
    public static func openExisting(
        at rootURL: URL,
        policy: PrivilegedOwnershipPolicy
    ) throws -> POSIXRootFileSystem {
        guard rootURL.isFileURL, rootURL.path.hasPrefix("/") else {
            throw POSIXRootFileSystemError.invalidBaseURL
        }

        var pathStatus = stat()
        guard lstat(rootURL.path, &pathStatus) == 0 else {
            throw systemCall("lstat")
        }
        try validateDirectory(pathStatus, policy: policy, exactPermissions: true)

        let descriptor = Darwin.open(
            rootURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else { throw systemCall("open") }

        do {
            var openedStatus = stat()
            guard fstat(descriptor, &openedStatus) == 0 else {
                throw systemCall("fstat")
            }
            try validateDirectory(openedStatus, policy: policy, exactPermissions: true)
            guard pathStatus.st_dev == openedStatus.st_dev,
                pathStatus.st_ino == openedStatus.st_ino
            else {
                throw POSIXRootFileSystemError.symlinkRejected
            }
            return POSIXRootFileSystem(
                rootDescriptor: descriptor,
                rootURL: rootURL.standardizedFileURL,
                policy: policy,
                rootStatus: openedStatus
            )
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    /// Securely creates/opens a root beneath a pre-existing trusted ancestor.
    /// The ancestor may be 0755 and may use a system-managed group such as
    /// `admin` (gid 80), but must be owned by the expected uid and must not be
    /// group/other writable. Newly created descendants use the exact policy.
    public static func bootstrap(
        trustedAncestorURL: URL,
        relativeRoot: SafeRelativePath,
        policy: PrivilegedOwnershipPolicy
    ) throws -> POSIXRootFileSystem {
        guard trustedAncestorURL.isFileURL, trustedAncestorURL.path.hasPrefix("/") else {
            throw POSIXRootFileSystemError.invalidBaseURL
        }

        var ancestorPathStatus = stat()
        guard lstat(trustedAncestorURL.path, &ancestorPathStatus) == 0 else {
            throw systemCall("lstat")
        }
        try validateTrustedAncestor(ancestorPathStatus, policy: policy)

        var current = Darwin.open(
            trustedAncestorURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard current >= 0 else { throw systemCall("open") }

        do {
            var openedAncestor = stat()
            guard fstat(current, &openedAncestor) == 0 else {
                throw systemCall("fstat")
            }
            try validateTrustedAncestor(openedAncestor, policy: policy)
            guard ancestorPathStatus.st_dev == openedAncestor.st_dev,
                ancestorPathStatus.st_ino == openedAncestor.st_ino
            else {
                throw POSIXRootFileSystemError.symlinkRejected
            }

            for component in relativeRoot.components {
                try ensureDirectory(component, beneath: current, policy: policy)
                let next = try openDirectory(component, beneath: current, policy: policy)
                Darwin.close(current)
                current = next
            }

            var rootStatus = stat()
            guard fstat(current, &rootStatus) == 0 else {
                throw systemCall("fstat")
            }
            try validateDirectory(rootStatus, policy: policy, exactPermissions: true)
            return POSIXRootFileSystem(
                rootDescriptor: current,
                rootURL: relativeRoot.components.reduce(trustedAncestorURL.standardizedFileURL) {
                    $0.appending(path: $1, directoryHint: .isDirectory)
                },
                policy: policy,
                rootStatus: rootStatus
            )
        } catch {
            Darwin.close(current)
            throw error
        }
    }

    public func createDirectory(_ path: SafeRelativePath) throws {
        var current = try duplicatedRootDescriptor()
        defer { Darwin.close(current) }

        for component in path.components {
            try Self.ensureDirectory(component, beneath: current, policy: policy)
            let next = try Self.openDirectory(component, beneath: current, policy: policy)
            Darwin.close(current)
            current = next
        }
    }

    /// Creates only the final component and refuses an existing generation.
    /// This prevents a UUID collision from reusing or cleaning another trusted
    /// executable generation.
    public func createDirectoryExclusively(_ path: SafeRelativePath) throws {
        let parent = try openParent(of: path)
        defer { Darwin.close(parent) }
        let creation = path.lastComponent.withCString {
            mkdirat(parent, $0, policy.directoryMode)
        }
        guard creation == 0 else {
            if errno == EEXIST { throw POSIXRootFileSystemError.destinationExists }
            throw Self.systemCall("mkdirat")
        }

        var shouldRemove = true
        defer {
            if shouldRemove {
                path.lastComponent.withCString { _ = unlinkat(parent, $0, AT_REMOVEDIR) }
            }
        }
        let descriptor = path.lastComponent.withCString {
            openat(parent, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw Self.systemCall("openat") }
        defer { Darwin.close(descriptor) }
        guard fchown(descriptor, policy.userID, policy.groupID) == 0 else {
            throw Self.systemCall("fchown")
        }
        guard fchmod(descriptor, policy.directoryMode) == 0 else {
            throw Self.systemCall("fchmod")
        }
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { throw Self.systemCall("fstat") }
        try Self.validateDirectory(status, policy: policy, exactPermissions: true)
        guard fsync(parent) == 0 else { throw Self.systemCall("fsync") }
        shouldRemove = false
    }

    /// Atomically moves one verified directory inside the anchored root.
    /// Both parent chains are opened with `O_NOFOLLOW`; the destination must
    /// not already exist, so rotation code cannot overwrite an unknown tree.
    public func moveDirectory(
        _ source: SafeRelativePath,
        to destination: SafeRelativePath,
        expectedIdentity: POSIXFileIdentity
    ) throws {
        guard source != destination,
            !destination.components.starts(with: source.components),
            !source.components.starts(with: destination.components)
        else {
            throw POSIXRootFileSystemError.invalidBaseURL
        }

        let sourceParent = try openParent(of: source)
        defer { Darwin.close(sourceParent) }
        let destinationParent = try openParent(of: destination)
        defer { Darwin.close(destinationParent) }

        var sourceStatus = stat()
        let sourceResult = source.lastComponent.withCString {
            fstatat(sourceParent, $0, &sourceStatus, AT_SYMLINK_NOFOLLOW)
        }
        guard sourceResult == 0 else { throw Self.systemCall("fstatat") }
        try Self.validateDirectory(sourceStatus, policy: policy, exactPermissions: true)
        let sourceIdentity = POSIXFileIdentity(sourceStatus)
        guard sourceIdentity.device == expectedIdentity.device,
            sourceIdentity.inode == expectedIdentity.inode,
            sourceIdentity.userID == expectedIdentity.userID,
            sourceIdentity.groupID == expectedIdentity.groupID,
            sourceIdentity.permissions == expectedIdentity.permissions
        else {
            throw POSIXRootFileSystemError.unsafeOwnership
        }

        var destinationStatus = stat()
        let destinationResult = destination.lastComponent.withCString {
            fstatat(destinationParent, $0, &destinationStatus, AT_SYMLINK_NOFOLLOW)
        }
        if destinationResult == 0 {
            guard !Self.isSymbolicLink(destinationStatus) else {
                throw POSIXRootFileSystemError.symlinkRejected
            }
            throw POSIXRootFileSystemError.destinationExists
        }
        guard errno == ENOENT else { throw Self.systemCall("fstatat") }

        let renameResult = source.lastComponent.withCString { sourceName in
            destination.lastComponent.withCString { destinationName in
                renameatx_np(
                    sourceParent,
                    sourceName,
                    destinationParent,
                    destinationName,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard renameResult == 0 else {
            if errno == EEXIST { throw POSIXRootFileSystemError.destinationExists }
            throw Self.systemCall("renameatx_np")
        }
        guard fsync(sourceParent) == 0 else { throw Self.systemCall("fsync") }
        if sourceParent != destinationParent {
            guard fsync(destinationParent) == 0 else { throw Self.systemCall("fsync") }
        }

        var promotedStatus = stat()
        let promotedResult = destination.lastComponent.withCString {
            fstatat(destinationParent, $0, &promotedStatus, AT_SYMLINK_NOFOLLOW)
        }
        guard promotedResult == 0 else { throw Self.systemCall("fstatat") }
        try Self.validateDirectory(promotedStatus, policy: policy, exactPermissions: true)
        let promotedIdentity = POSIXFileIdentity(promotedStatus)
        guard promotedIdentity.device == expectedIdentity.device,
            promotedIdentity.inode == expectedIdentity.inode,
            promotedIdentity.userID == expectedIdentity.userID,
            promotedIdentity.groupID == expectedIdentity.groupID,
            promotedIdentity.permissions == expectedIdentity.permissions
        else {
            throw POSIXRootFileSystemError.unsafeOwnership
        }
    }

    /// Opens the complete path as a directory and returns the identity of the
    /// final descriptor. This is stronger than a leaf `fstatat`: every ancestor
    /// and the leaf are checked with the root ownership policy and `O_NOFOLLOW`.
    public func verifiedDirectoryIdentity(
        at path: SafeRelativePath
    ) throws -> POSIXFileIdentity {
        var descriptor = try duplicatedRootDescriptor()
        defer { Darwin.close(descriptor) }
        for component in path.components {
            let next = try Self.openDirectory(component, beneath: descriptor, policy: policy)
            Darwin.close(descriptor)
            descriptor = next
        }
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { throw Self.systemCall("fstat") }
        try Self.validateDirectory(status, policy: policy, exactPermissions: true)
        return POSIXFileIdentity(status)
    }

    public func identity(of path: SafeRelativePath) throws -> POSIXFileIdentity {
        let parent = try openParent(of: path)
        defer { Darwin.close(parent) }

        var status = stat()
        let result = path.lastComponent.withCString {
            fstatat(parent, $0, &status, AT_SYMLINK_NOFOLLOW)
        }
        guard result == 0 else { throw Self.systemCall("fstatat") }
        guard !Self.isSymbolicLink(status) else {
            throw POSIXRootFileSystemError.symlinkRejected
        }
        return POSIXFileIdentity(status)
    }

    /// Resolves a Helper-managed executable through the verified root
    /// descriptor. Every ancestor is root-policy owned and non-writable, the
    /// leaf cannot be a symlink, and the executable itself must be exactly
    /// owner-readable/executable (0500).
    public func trustedExecutableIdentity(
        at path: SafeRelativePath
    ) throws -> POSIXFileIdentity {
        let parent = try openParent(of: path)
        defer { Darwin.close(parent) }

        var before = stat()
        let statResult = path.lastComponent.withCString {
            fstatat(parent, $0, &before, AT_SYMLINK_NOFOLLOW)
        }
        guard statResult == 0 else { throw Self.systemCall("fstatat") }
        try Self.validateTrustedExecutable(before, policy: policy)

        let descriptor = path.lastComponent.withCString {
            openat(parent, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw Self.systemCall("openat") }
        defer { Darwin.close(descriptor) }

        var after = stat()
        guard fstat(descriptor, &after) == 0 else { throw Self.systemCall("fstat") }
        try Self.validateTrustedExecutable(after, policy: policy)
        guard before.st_dev == after.st_dev, before.st_ino == after.st_ino else {
            throw POSIXRootFileSystemError.symlinkRejected
        }
        return POSIXFileIdentity(after)
    }

    public func directoryEntries(
        at path: SafeRelativePath,
        maximumCount: Int
    ) throws -> [POSIXDirectoryEntry] {
        var descriptor = try duplicatedRootDescriptor()
        do {
            for component in path.components {
                let next = try Self.openDirectory(component, beneath: descriptor, policy: policy)
                Darwin.close(descriptor)
                descriptor = next
            }
        } catch {
            Darwin.close(descriptor)
            throw error
        }

        let enumerationDescriptor = fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
        Darwin.close(descriptor)
        guard enumerationDescriptor >= 0 else { throw Self.systemCall("fcntl") }
        guard let directory = fdopendir(enumerationDescriptor) else {
            Darwin.close(enumerationDescriptor)
            throw Self.systemCall("fdopendir")
        }
        defer { closedir(directory) }

        var entries: [POSIXDirectoryEntry] = []
        while let raw = readdir(directory) {
            let name: String = withUnsafePointer(to: &raw.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            if name == "." || name == ".." { continue }
            guard entries.count < maximumCount else {
                throw POSIXRootFileSystemError.fileTooLarge
            }
            var status = stat()
            let result = name.withCString {
                fstatat(dirfd(directory), $0, &status, AT_SYMLINK_NOFOLLOW)
            }
            guard result == 0 else { throw Self.systemCall("fstatat") }
            guard !Self.isSymbolicLink(status) else {
                throw POSIXRootFileSystemError.symlinkRejected
            }
            entries.append(
                POSIXDirectoryEntry(
                    name: name,
                    isDirectory: Self.isDirectory(status),
                    isRegularFile: Self.isRegularFile(status)
                )
            )
        }
        return entries.sorted { $0.name < $1.name }
    }

    public func readData(
        at path: SafeRelativePath,
        maximumBytes: Int
    ) throws -> Data {
        let descriptor = try openRegularFile(at: path, flags: O_RDONLY)
        defer { Darwin.close(descriptor) }

        var before = stat()
        guard fstat(descriptor, &before) == 0 else { throw Self.systemCall("fstat") }
        try Self.validateRegularFile(before, policy: policy)
        guard before.st_size >= 0, before.st_size <= Int64(maximumBytes) else {
            throw POSIXRootFileSystemError.fileTooLarge
        }

        var data = Data()
        data.reserveCapacity(Int(before.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw Self.systemCall("read")
            }
            guard data.count + count <= maximumBytes else {
                throw POSIXRootFileSystemError.fileTooLarge
            }
            data.append(buffer, count: count)
        }

        var after = stat()
        guard fstat(descriptor, &after) == 0 else { throw Self.systemCall("fstat") }
        guard before.st_dev == after.st_dev,
            before.st_ino == after.st_ino,
            before.st_size == after.st_size,
            Int64(data.count) == after.st_size
        else {
            throw POSIXRootFileSystemError.shortRead
        }
        return data
    }

    /// Reads an exact 0500 root-owned executable through the anchored
    /// descriptor. Resource reads intentionally continue to require 0600.
    public func readTrustedExecutableData(
        at path: SafeRelativePath,
        maximumBytes: Int
    ) throws -> Data {
        let parent = try openParent(of: path)
        defer { Darwin.close(parent) }
        var before = stat()
        let statResult = path.lastComponent.withCString {
            fstatat(parent, $0, &before, AT_SYMLINK_NOFOLLOW)
        }
        guard statResult == 0 else { throw Self.systemCall("fstatat") }
        try Self.validateTrustedExecutable(before, policy: policy)
        guard before.st_size >= 0, before.st_size <= Int64(maximumBytes) else {
            throw POSIXRootFileSystemError.fileTooLarge
        }
        let descriptor = path.lastComponent.withCString {
            openat(parent, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw Self.systemCall("openat") }
        defer { Darwin.close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0 else { throw Self.systemCall("fstat") }
        try Self.validateTrustedExecutable(opened, policy: policy)
        guard before.st_dev == opened.st_dev, before.st_ino == opened.st_ino else {
            throw POSIXRootFileSystemError.symlinkRejected
        }
        var data = Data()
        data.reserveCapacity(Int(opened.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw Self.systemCall("read")
            }
            guard data.count + count <= maximumBytes else {
                throw POSIXRootFileSystemError.fileTooLarge
            }
            data.append(buffer, count: count)
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0,
            opened.st_dev == after.st_dev,
            opened.st_ino == after.st_ino,
            opened.st_size == after.st_size,
            Int64(data.count) == after.st_size
        else { throw POSIXRootFileSystemError.shortRead }
        return data
    }

    /// Opens a regular file through the anchored root and verifies its exact
    /// ownership, permissions, and bounded size without reading its contents.
    /// Startup recovery uses this before deleting a narrowly-recognized atomic
    /// temporary file, then `removeFile` repeats the type/ownership checks at
    /// deletion time.
    public func verifiedRegularFileIdentity(
        at path: SafeRelativePath,
        maximumBytes: Int64
    ) throws -> POSIXFileIdentity {
        guard maximumBytes >= 0 else { throw POSIXRootFileSystemError.fileTooLarge }
        let descriptor = try openRegularFile(at: path, flags: O_RDONLY)
        defer { Darwin.close(descriptor) }

        var status = stat()
        guard fstat(descriptor, &status) == 0 else { throw Self.systemCall("fstat") }
        try Self.validateRegularFile(status, policy: policy)
        guard status.st_size >= 0, status.st_size <= maximumBytes else {
            throw POSIXRootFileSystemError.fileTooLarge
        }
        return POSIXFileIdentity(status)
    }

    public func writeDataAtomically(
        _ data: Data,
        to path: SafeRelativePath,
        replacingExisting: Bool
    ) throws {
        try withAtomicOutput(to: path, replacingExisting: replacingExisting) { descriptor in
            try data.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else { return }
                var written = 0
                while written < rawBuffer.count {
                    let count = Darwin.write(
                        descriptor,
                        baseAddress.advanced(by: written),
                        rawBuffer.count - written
                    )
                    if count < 0 {
                        if errno == EINTR { continue }
                        throw Self.systemCall("write")
                    }
                    written += count
                }
            }
        }
    }

    /// Supplies a newly-created 0600 temporary file in the destination directory.
    /// The closure must write all content. On success the file and directory are
    /// fsynced before an atomic rename; on failure the temporary file is unlinked.
    public func withAtomicOutput<Result>(
        to path: SafeRelativePath,
        replacingExisting: Bool,
        _ body: (Int32) throws -> Result
    ) throws -> Result {
        try withAtomicOutput(
            to: path,
            replacingExisting: replacingExisting,
            destinationMode: policy.fileMode,
            body
        )
    }

    /// Creates an executable as a non-writable root-policy owned 0500 file.
    /// Bytes and ownership are durable while the temp remains 0600; after the
    /// exclusive rename, the still-open inode is changed to 0500 and fsynced.
    /// This leaves every possible crash artifact in one recognized safe mode.
    public func withAtomicTrustedExecutableOutput<Result>(
        to path: SafeRelativePath,
        _ body: (Int32) throws -> Result
    ) throws -> Result {
        try withAtomicOutput(
            to: path,
            replacingExisting: false,
            destinationMode: Self.trustedExecutableMode,
            body
        )
    }

    private func withAtomicOutput<Result>(
        to path: SafeRelativePath,
        replacingExisting: Bool,
        destinationMode: mode_t,
        _ body: (Int32) throws -> Result
    ) throws -> Result {
        let parent = try openParent(of: path)
        defer { Darwin.close(parent) }

        if replacingExisting {
            try validateReplaceableDestination(path.lastComponent, parent: parent)
        }

        let temporaryName = ".vela-\(UUID().uuidString.lowercased()).tmp"
        let temporaryDescriptor = temporaryName.withCString {
            openat(
                parent,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                policy.fileMode
            )
        }
        guard temporaryDescriptor >= 0 else { throw Self.systemCall("openat") }

        var shouldUnlinkTemporary = true
        defer {
            Darwin.close(temporaryDescriptor)
            if shouldUnlinkTemporary {
                temporaryName.withCString { _ = unlinkat(parent, $0, 0) }
            }
        }

        let result = try body(temporaryDescriptor)
        guard fchown(temporaryDescriptor, policy.userID, policy.groupID) == 0 else {
            throw Self.systemCall("fchown")
        }
        // Keep every pre-rename temp in the one recoverable 0600 form. A trusted
        // executable becomes 0500 only after its filename is atomically visible;
        // startup can therefore recognize either a 0600 temp or a 0600 final
        // executable left by a crash during that final mode transition.
        guard fchmod(temporaryDescriptor, policy.fileMode) == 0 else {
            throw Self.systemCall("fchmod")
        }
        guard fsync(temporaryDescriptor) == 0 else { throw Self.systemCall("fsync") }

        let renameResult: Int32 = temporaryName.withCString { temporary in
            path.lastComponent.withCString { destination in
                if replacingExisting {
                    return renameat(parent, temporary, parent, destination)
                }
                return renameatx_np(
                    parent,
                    temporary,
                    parent,
                    destination,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard renameResult == 0 else {
            if !replacingExisting, errno == EEXIST {
                throw POSIXRootFileSystemError.destinationExists
            }
            throw Self.systemCall("renameat")
        }
        shouldUnlinkTemporary = false
        guard fsync(parent) == 0 else { throw Self.systemCall("fsync") }
        if destinationMode != policy.fileMode {
            guard fchmod(temporaryDescriptor, destinationMode) == 0 else {
                throw Self.systemCall("fchmod")
            }
            guard fsync(temporaryDescriptor) == 0 else { throw Self.systemCall("fsync") }
            guard fsync(parent) == 0 else { throw Self.systemCall("fsync") }
        }
        return result
    }

    public func removeFile(_ path: SafeRelativePath) throws {
        let parent = try openParent(of: path)
        defer { Darwin.close(parent) }
        var status = stat()
        let statResult = path.lastComponent.withCString {
            fstatat(parent, $0, &status, AT_SYMLINK_NOFOLLOW)
        }
        guard statResult == 0 else { throw Self.systemCall("fstatat") }
        guard !Self.isSymbolicLink(status) else {
            throw POSIXRootFileSystemError.symlinkRejected
        }
        try Self.validateRegularFile(status, policy: policy)
        let result = path.lastComponent.withCString { unlinkat(parent, $0, 0) }
        guard result == 0 else { throw Self.systemCall("unlinkat") }
        guard fsync(parent) == 0 else { throw Self.systemCall("fsync") }
    }

    public func removeTrustedExecutable(_ path: SafeRelativePath) throws {
        let parent = try openParent(of: path)
        defer { Darwin.close(parent) }
        var status = stat()
        let statResult = path.lastComponent.withCString {
            fstatat(parent, $0, &status, AT_SYMLINK_NOFOLLOW)
        }
        guard statResult == 0 else { throw Self.systemCall("fstatat") }
        try Self.validateTrustedExecutable(status, policy: policy)
        let result = path.lastComponent.withCString { unlinkat(parent, $0, 0) }
        guard result == 0 else { throw Self.systemCall("unlinkat") }
        guard fsync(parent) == 0 else { throw Self.systemCall("fsync") }
    }

    public func removeEmptyDirectory(_ path: SafeRelativePath) throws {
        let parent = try openParent(of: path)
        defer { Darwin.close(parent) }
        var status = stat()
        let statResult = path.lastComponent.withCString {
            fstatat(parent, $0, &status, AT_SYMLINK_NOFOLLOW)
        }
        guard statResult == 0 else { throw Self.systemCall("fstatat") }
        try Self.validateDirectory(status, policy: policy, exactPermissions: true)
        let result = path.lastComponent.withCString { unlinkat(parent, $0, AT_REMOVEDIR) }
        guard result == 0 else { throw Self.systemCall("unlinkat") }
        guard fsync(parent) == 0 else { throw Self.systemCall("fsync") }
    }

    /// Removes only regular files and directories from a stopped runtime tree.
    /// It never follows links, never crosses devices, and enforces strict
    /// depth/count/byte budgets before an attacker-controlled tree can consume
    /// unbounded privileged work.
    public func removeBoundedTreeContents(
        at path: SafeRelativePath,
        expectedRootIdentity: POSIXFileIdentity,
        limits: POSIXTreeRemovalLimits = POSIXTreeRemovalLimits()
    ) throws {
        var descriptor = try duplicatedRootDescriptor()
        do {
            for component in path.components {
                let next = try Self.openDirectory(
                    component,
                    beneath: descriptor,
                    policy: policy
                )
                Darwin.close(descriptor)
                descriptor = next
            }
        } catch {
            Darwin.close(descriptor)
            throw error
        }
        defer { Darwin.close(descriptor) }

        var rootStatus = stat()
        guard fstat(descriptor, &rootStatus) == 0 else { throw Self.systemCall("fstat") }
        let actualRoot = POSIXFileIdentity(rootStatus)
        guard actualRoot.device == expectedRootIdentity.device,
            actualRoot.inode == expectedRootIdentity.inode,
            actualRoot.userID == expectedRootIdentity.userID,
            actualRoot.groupID == expectedRootIdentity.groupID,
            actualRoot.permissions == expectedRootIdentity.permissions
        else {
            throw POSIXRootFileSystemError.unsafeOwnership
        }

        // Validate the complete tree before the first unlink. This makes a
        // predictable policy failure (symlink, ownership, type, or budget)
        // non-mutating. The deletion pass repeats every check so a root-level
        // race between the two passes still fails closed. A power loss during
        // deletion remains retryable from the journal and directory identity.
        var validationBudget = TreeRemovalBudget()
        try validateChildren(
            of: descriptor,
            rootDevice: UInt64(rootStatus.st_dev),
            depth: 0,
            limits: limits,
            budget: &validationBudget
        )
        var budget = TreeRemovalBudget()
        try removeChildren(
            of: descriptor,
            rootDevice: UInt64(rootStatus.st_dev),
            depth: 0,
            limits: limits,
            budget: &budget
        )
        guard fsync(descriptor) == 0 else { throw Self.systemCall("fsync") }
    }

    /// Performs the complete no-follow ownership/type/budget pass used by
    /// `removeBoundedTreeContents` without unlinking anything. Callers that
    /// discover several startup artifacts can preflight every tree before the
    /// first mutation; the actual removal repeats this validation to close the
    /// race between planning and deletion.
    public func validateBoundedTreeContents(
        at path: SafeRelativePath,
        expectedRootIdentity: POSIXFileIdentity,
        limits: POSIXTreeRemovalLimits = POSIXTreeRemovalLimits()
    ) throws {
        var descriptor = try duplicatedRootDescriptor()
        do {
            for component in path.components {
                let next = try Self.openDirectory(
                    component,
                    beneath: descriptor,
                    policy: policy
                )
                Darwin.close(descriptor)
                descriptor = next
            }
        } catch {
            Darwin.close(descriptor)
            throw error
        }
        defer { Darwin.close(descriptor) }

        var rootStatus = stat()
        guard fstat(descriptor, &rootStatus) == 0 else { throw Self.systemCall("fstat") }
        let actualRoot = POSIXFileIdentity(rootStatus)
        guard actualRoot.device == expectedRootIdentity.device,
            actualRoot.inode == expectedRootIdentity.inode,
            actualRoot.userID == expectedRootIdentity.userID,
            actualRoot.groupID == expectedRootIdentity.groupID,
            actualRoot.permissions == expectedRootIdentity.permissions
        else {
            throw POSIXRootFileSystemError.unsafeOwnership
        }

        var budget = TreeRemovalBudget()
        try validateChildren(
            of: descriptor,
            rootDevice: UInt64(rootStatus.st_dev),
            depth: 0,
            limits: limits,
            budget: &budget
        )
    }

    private func openRegularFile(at path: SafeRelativePath, flags: Int32) throws -> Int32 {
        let parent = try openParent(of: path)
        defer { Darwin.close(parent) }

        var status = stat()
        let statResult = path.lastComponent.withCString {
            fstatat(parent, $0, &status, AT_SYMLINK_NOFOLLOW)
        }
        guard statResult == 0 else { throw Self.systemCall("fstatat") }
        try Self.validateRegularFile(status, policy: policy)

        let descriptor = path.lastComponent.withCString {
            openat(parent, $0, flags | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw Self.systemCall("openat") }
        do {
            var opened = stat()
            guard fstat(descriptor, &opened) == 0 else { throw Self.systemCall("fstat") }
            try Self.validateRegularFile(opened, policy: policy)
            guard status.st_dev == opened.st_dev, status.st_ino == opened.st_ino else {
                throw POSIXRootFileSystemError.symlinkRejected
            }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private struct TreeRemovalBudget {
        var entries = 0
        var regularFileBytes: Int64 = 0
    }

    private func validateChildren(
        of directoryDescriptor: Int32,
        rootDevice: UInt64,
        depth: Int,
        limits: POSIXTreeRemovalLimits,
        budget: inout TreeRemovalBudget
    ) throws {
        let enumerationDescriptor = openat(
            directoryDescriptor,
            ".",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard enumerationDescriptor >= 0 else { throw Self.systemCall("openat") }
        guard let directory = fdopendir(enumerationDescriptor) else {
            Darwin.close(enumerationDescriptor)
            throw Self.systemCall("fdopendir")
        }
        defer { closedir(directory) }

        while let raw = readdir(directory) {
            let name: String? = withUnsafePointer(to: &raw.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(validatingCString: $0)
                }
            }
            guard let name else { throw POSIXRootFileSystemError.unsupportedFileType }
            if name == "." || name == ".." { continue }
            budget.entries += 1
            guard budget.entries <= limits.maximumEntries else {
                throw POSIXRootFileSystemError.treeLimitExceeded
            }

            var before = stat()
            let statResult = name.withCString {
                fstatat(dirfd(directory), $0, &before, AT_SYMLINK_NOFOLLOW)
            }
            guard statResult == 0 else { throw Self.systemCall("fstatat") }
            guard !Self.isSymbolicLink(before) else {
                throw POSIXRootFileSystemError.symlinkRejected
            }
            guard UInt64(before.st_dev) == rootDevice else {
                throw POSIXRootFileSystemError.crossDeviceEntry
            }
            guard before.st_uid == policy.userID, before.st_gid == policy.groupID else {
                throw POSIXRootFileSystemError.unsafeOwnership
            }
            guard before.st_mode & 0o022 == 0 else {
                throw POSIXRootFileSystemError.unsafePermissions
            }

            if Self.isRegularFile(before) {
                guard before.st_size >= 0 else {
                    throw POSIXRootFileSystemError.unsupportedFileType
                }
                let total = budget.regularFileBytes.addingReportingOverflow(before.st_size)
                guard !total.overflow,
                    total.partialValue <= limits.maximumRegularFileBytes
                else {
                    throw POSIXRootFileSystemError.treeLimitExceeded
                }
                budget.regularFileBytes = total.partialValue
            } else if Self.isDirectory(before) {
                guard depth < limits.maximumDepth else {
                    throw POSIXRootFileSystemError.treeLimitExceeded
                }
                let child = name.withCString {
                    openat(
                        dirfd(directory),
                        $0,
                        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                    )
                }
                guard child >= 0 else { throw Self.systemCall("openat") }
                do {
                    var after = stat()
                    guard fstat(child, &after) == 0 else { throw Self.systemCall("fstat") }
                    guard before.st_dev == after.st_dev,
                        before.st_ino == after.st_ino,
                        after.st_uid == policy.userID,
                        after.st_gid == policy.groupID,
                        after.st_mode & 0o022 == 0
                    else {
                        throw POSIXRootFileSystemError.unsafeOwnership
                    }
                    try validateChildren(
                        of: child,
                        rootDevice: rootDevice,
                        depth: depth + 1,
                        limits: limits,
                        budget: &budget
                    )
                    Darwin.close(child)
                } catch {
                    Darwin.close(child)
                    throw error
                }
            } else {
                throw POSIXRootFileSystemError.unsupportedFileType
            }
        }
    }

    private func removeChildren(
        of directoryDescriptor: Int32,
        rootDevice: UInt64,
        depth: Int,
        limits: POSIXTreeRemovalLimits,
        budget: inout TreeRemovalBudget
    ) throws {
        let enumerationDescriptor = openat(
            directoryDescriptor,
            ".",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard enumerationDescriptor >= 0 else { throw Self.systemCall("openat") }
        guard let directory = fdopendir(enumerationDescriptor) else {
            Darwin.close(enumerationDescriptor)
            throw Self.systemCall("fdopendir")
        }
        defer { closedir(directory) }

        while let raw = readdir(directory) {
            let name: String? = withUnsafePointer(to: &raw.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(validatingCString: $0)
                }
            }
            guard let name else { throw POSIXRootFileSystemError.unsupportedFileType }
            if name == "." || name == ".." { continue }
            budget.entries += 1
            guard budget.entries <= limits.maximumEntries else {
                throw POSIXRootFileSystemError.treeLimitExceeded
            }

            var before = stat()
            let statResult = name.withCString {
                fstatat(dirfd(directory), $0, &before, AT_SYMLINK_NOFOLLOW)
            }
            guard statResult == 0 else { throw Self.systemCall("fstatat") }
            guard !Self.isSymbolicLink(before) else {
                throw POSIXRootFileSystemError.symlinkRejected
            }
            guard UInt64(before.st_dev) == rootDevice else {
                throw POSIXRootFileSystemError.crossDeviceEntry
            }
            guard before.st_uid == policy.userID, before.st_gid == policy.groupID else {
                throw POSIXRootFileSystemError.unsafeOwnership
            }
            guard before.st_mode & 0o022 == 0 else {
                throw POSIXRootFileSystemError.unsafePermissions
            }

            if Self.isRegularFile(before) {
                guard before.st_size >= 0 else {
                    throw POSIXRootFileSystemError.unsupportedFileType
                }
                let total = budget.regularFileBytes.addingReportingOverflow(before.st_size)
                guard !total.overflow,
                    total.partialValue <= limits.maximumRegularFileBytes
                else {
                    throw POSIXRootFileSystemError.treeLimitExceeded
                }
                budget.regularFileBytes = total.partialValue
                let result = name.withCString { unlinkat(dirfd(directory), $0, 0) }
                guard result == 0 else { throw Self.systemCall("unlinkat") }
            } else if Self.isDirectory(before) {
                guard depth < limits.maximumDepth else {
                    throw POSIXRootFileSystemError.treeLimitExceeded
                }
                let child = name.withCString {
                    openat(
                        dirfd(directory),
                        $0,
                        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                    )
                }
                guard child >= 0 else { throw Self.systemCall("openat") }
                do {
                    var after = stat()
                    guard fstat(child, &after) == 0 else { throw Self.systemCall("fstat") }
                    guard before.st_dev == after.st_dev,
                        before.st_ino == after.st_ino,
                        after.st_uid == policy.userID,
                        after.st_gid == policy.groupID,
                        after.st_mode & 0o022 == 0
                    else {
                        throw POSIXRootFileSystemError.unsafeOwnership
                    }
                    try removeChildren(
                        of: child,
                        rootDevice: rootDevice,
                        depth: depth + 1,
                        limits: limits,
                        budget: &budget
                    )
                    guard fsync(child) == 0 else { throw Self.systemCall("fsync") }
                    Darwin.close(child)
                } catch {
                    Darwin.close(child)
                    throw error
                }
                let result = name.withCString {
                    unlinkat(dirfd(directory), $0, AT_REMOVEDIR)
                }
                guard result == 0 else { throw Self.systemCall("unlinkat") }
            } else {
                throw POSIXRootFileSystemError.unsupportedFileType
            }
        }
        guard fsync(dirfd(directory)) == 0 else { throw Self.systemCall("fsync") }
    }

    private func openParent(of path: SafeRelativePath) throws -> Int32 {
        var current = try duplicatedRootDescriptor()
        do {
            for component in path.components.dropLast() {
                let next = try Self.openDirectory(component, beneath: current, policy: policy)
                Darwin.close(current)
                current = next
            }
            return current
        } catch {
            Darwin.close(current)
            throw error
        }
    }

    private func duplicatedRootDescriptor() throws -> Int32 {
        let descriptor = fcntl(rootDescriptor, F_DUPFD_CLOEXEC, 0)
        guard descriptor >= 0 else { throw Self.systemCall("fcntl") }
        return descriptor
    }

    private func validateReplaceableDestination(_ name: String, parent: Int32) throws {
        var status = stat()
        let result = name.withCString { fstatat(parent, $0, &status, AT_SYMLINK_NOFOLLOW) }
        if result != 0 {
            guard errno == ENOENT else { throw Self.systemCall("fstatat") }
            return
        }
        try Self.validateRegularFile(status, policy: policy)
    }

    private static func ensureDirectory(
        _ component: String,
        beneath parent: Int32,
        policy: PrivilegedOwnershipPolicy
    ) throws {
        var status = stat()
        let existing = component.withCString {
            fstatat(parent, $0, &status, AT_SYMLINK_NOFOLLOW)
        }
        if existing == 0 {
            try validateDirectory(status, policy: policy, exactPermissions: true)
            return
        }
        guard errno == ENOENT else { throw systemCall("fstatat") }

        let creation = component.withCString { mkdirat(parent, $0, policy.directoryMode) }
        guard creation == 0 else {
            if errno == EEXIST {
                let retry = component.withCString {
                    fstatat(parent, $0, &status, AT_SYMLINK_NOFOLLOW)
                }
                guard retry == 0 else { throw systemCall("fstatat") }
                try validateDirectory(status, policy: policy, exactPermissions: true)
                return
            }
            throw systemCall("mkdirat")
        }

        let descriptor = component.withCString {
            openat(parent, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw systemCall("openat") }
        defer { Darwin.close(descriptor) }
        var createdStatus = stat()
        guard fstat(descriptor, &createdStatus) == 0 else { throw systemCall("fstat") }
        guard !isSymbolicLink(createdStatus), isDirectory(createdStatus) else {
            throw POSIXRootFileSystemError.symlinkRejected
        }
        guard fchmod(descriptor, policy.directoryMode) == 0 else {
            throw systemCall("fchmod")
        }
        guard fchown(descriptor, policy.userID, policy.groupID) == 0 else {
            throw systemCall("fchown")
        }
        var finalStatus = stat()
        guard fstat(descriptor, &finalStatus) == 0 else { throw systemCall("fstat") }
        try validateDirectory(finalStatus, policy: policy, exactPermissions: true)
        guard fsync(parent) == 0 else { throw systemCall("fsync") }
    }

    private static func openDirectory(
        _ component: String,
        beneath parent: Int32,
        policy: PrivilegedOwnershipPolicy
    ) throws -> Int32 {
        var before = stat()
        let statResult = component.withCString {
            fstatat(parent, $0, &before, AT_SYMLINK_NOFOLLOW)
        }
        guard statResult == 0 else { throw systemCall("fstatat") }
        try validateDirectory(before, policy: policy, exactPermissions: true)

        let descriptor = component.withCString {
            openat(parent, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw systemCall("openat") }
        do {
            var after = stat()
            guard fstat(descriptor, &after) == 0 else { throw systemCall("fstat") }
            try validateDirectory(after, policy: policy, exactPermissions: true)
            guard before.st_dev == after.st_dev, before.st_ino == after.st_ino else {
                throw POSIXRootFileSystemError.symlinkRejected
            }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private static func validateTrustedAncestor(
        _ status: stat,
        policy: PrivilegedOwnershipPolicy
    ) throws {
        guard !isSymbolicLink(status) else {
            throw POSIXRootFileSystemError.symlinkRejected
        }
        guard isDirectory(status) else { throw POSIXRootFileSystemError.notDirectory }
        // `/Library/Application Support` is root:admin on current macOS.
        // Its system-managed group is not inherited as Vela's data policy.
        guard status.st_uid == policy.userID else {
            throw POSIXRootFileSystemError.unsafeOwnership
        }
        guard status.st_mode & 0o022 == 0 else {
            throw POSIXRootFileSystemError.unsafePermissions
        }
    }

    private static func validateDirectory(
        _ status: stat,
        policy: PrivilegedOwnershipPolicy,
        exactPermissions: Bool
    ) throws {
        guard !isSymbolicLink(status) else {
            throw POSIXRootFileSystemError.symlinkRejected
        }
        guard isDirectory(status) else { throw POSIXRootFileSystemError.notDirectory }
        guard status.st_uid == policy.userID, status.st_gid == policy.groupID else {
            throw POSIXRootFileSystemError.unsafeOwnership
        }
        let permissions = status.st_mode & 0o7777
        if exactPermissions {
            guard permissions == policy.directoryMode else {
                throw POSIXRootFileSystemError.unsafePermissions
            }
        } else if permissions & 0o077 != 0 {
            throw POSIXRootFileSystemError.unsafePermissions
        }
    }

    private static func validateRegularFile(
        _ status: stat,
        policy: PrivilegedOwnershipPolicy
    ) throws {
        guard !isSymbolicLink(status) else {
            throw POSIXRootFileSystemError.symlinkRejected
        }
        guard isRegularFile(status) else {
            throw POSIXRootFileSystemError.notRegularFile
        }
        guard status.st_uid == policy.userID, status.st_gid == policy.groupID else {
            throw POSIXRootFileSystemError.unsafeOwnership
        }
        guard status.st_mode & 0o7777 == policy.fileMode else {
            throw POSIXRootFileSystemError.unsafePermissions
        }
    }

    private static func validateTrustedExecutable(
        _ status: stat,
        policy: PrivilegedOwnershipPolicy
    ) throws {
        guard !isSymbolicLink(status) else {
            throw POSIXRootFileSystemError.symlinkRejected
        }
        guard isRegularFile(status) else {
            throw POSIXRootFileSystemError.notRegularFile
        }
        guard status.st_uid == policy.userID, status.st_gid == policy.groupID else {
            throw POSIXRootFileSystemError.unsafeOwnership
        }
        guard status.st_mode & 0o7777 == trustedExecutableMode else {
            throw POSIXRootFileSystemError.unsafePermissions
        }
    }

    private static func isDirectory(_ status: stat) -> Bool {
        status.st_mode & S_IFMT == S_IFDIR
    }

    private static func isRegularFile(_ status: stat) -> Bool {
        status.st_mode & S_IFMT == S_IFREG
    }

    private static func isSymbolicLink(_ status: stat) -> Bool {
        status.st_mode & S_IFMT == S_IFLNK
    }

    private static func systemCall(_ operation: String) -> POSIXRootFileSystemError {
        .systemCall(operation: operation, code: errno)
    }
}
