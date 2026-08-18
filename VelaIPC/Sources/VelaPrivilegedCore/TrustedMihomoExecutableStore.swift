import CryptoKit
import Darwin
import Foundation
import VelaIPC

public struct TrustedMihomoExecutable: Equatable, Sendable {
    public let relativePath: SafeRelativePath
    public let url: URL
    public let identity: POSIXFileIdentity
    public let contentSHA256: String?

    init(
        relativePath: SafeRelativePath,
        url: URL,
        identity: POSIXFileIdentity,
        contentSHA256: String?
    ) {
        self.relativePath = relativePath
        self.url = url
        self.identity = identity
        self.contentSHA256 = contentSHA256
    }
}

public enum TrustedMihomoExecutableError: Error, Equatable, Sendable {
    case invalidSourceURL
    case sourceMissing
    case sourceIsSymlink
    case sourceNotRegular
    case sourceNotExecutable
    case sourceSizeInvalid
    case sourceChanged
    case invalidGenerationPath
    case invalidGenerationContents
}

/// Imports the untrusted bundle copy through one O_NOFOLLOW descriptor, then
/// exposes only an immutable-by-unprivileged-users root-owned generation.
public struct TrustedMihomoExecutableStore: Sendable {
    private let fileSystem: POSIXRootFileSystem
    private let sourceOpenedHook: (@Sendable () throws -> Void)?

    public init(fileSystem: POSIXRootFileSystem) {
        self.fileSystem = fileSystem
        sourceOpenedHook = nil
    }

    init(
        fileSystem: POSIXRootFileSystem,
        sourceOpenedHook: @escaping @Sendable () throws -> Void
    ) {
        self.fileSystem = fileSystem
        self.sourceOpenedHook = sourceOpenedHook
    }

    public func installBundledExecutable(
        from sourceURL: URL
    ) throws -> TrustedMihomoExecutable {
        guard sourceURL.isFileURL, sourceURL.path.hasPrefix("/") else {
            throw TrustedMihomoExecutableError.invalidSourceURL
        }

        let sourceDescriptor = sourceURL.path.withCString {
            Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard sourceDescriptor >= 0 else {
            if errno == ELOOP { throw TrustedMihomoExecutableError.sourceIsSymlink }
            if errno == ENOENT { throw TrustedMihomoExecutableError.sourceMissing }
            throw POSIXRootFileSystemError.systemCall(operation: "open", code: errno)
        }
        defer { Darwin.close(sourceDescriptor) }

        var before = stat()
        guard fstat(sourceDescriptor, &before) == 0 else {
            throw POSIXRootFileSystemError.systemCall(operation: "fstat", code: errno)
        }
        try validateSource(before)
        try sourceOpenedHook?()

        let generations = try SafeRelativePath("executables/generations")
        try fileSystem.createDirectory(try SafeRelativePath("executables"))
        try fileSystem.createDirectory(generations)
        let generationID = UUID().uuidString.lowercased()
        let generationRoot = try generations.appending(generationID)
        try fileSystem.createDirectoryExclusively(generationRoot)
        let destination = try generationRoot.appending("mihomo")

        do {
            var hasher = SHA256()
            try fileSystem.withAtomicTrustedExecutableOutput(to: destination) { output in
                var offset: Int64 = 0
                var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
                while offset < before.st_size {
                    let requested = min(buffer.count, Int(before.st_size - offset))
                    let count = pread(sourceDescriptor, &buffer, requested, off_t(offset))
                    if count < 0 {
                        if errno == EINTR { continue }
                        throw POSIXRootFileSystemError.systemCall(
                            operation: "pread",
                            code: errno
                        )
                    }
                    guard count > 0 else {
                        throw TrustedMihomoExecutableError.sourceChanged
                    }
                    try buffer.withUnsafeBytes { bytes in
                        guard let base = bytes.baseAddress else { return }
                        var written = 0
                        while written < count {
                            let result = Darwin.write(
                                output,
                                base.advanced(by: written),
                                count - written
                            )
                            if result < 0 {
                                if errno == EINTR { continue }
                                throw POSIXRootFileSystemError.systemCall(
                                    operation: "write",
                                    code: errno
                                )
                            }
                            written += result
                        }
                    }
                    hasher.update(data: Data(buffer[0 ..< count]))
                    offset += Int64(count)
                }

                var extra: UInt8 = 0
                var extraCount: Int
                repeat {
                    extraCount = pread(sourceDescriptor, &extra, 1, off_t(offset))
                } while extraCount < 0 && errno == EINTR
                guard extraCount == 0 else {
                    throw TrustedMihomoExecutableError.sourceChanged
                }

                var after = stat()
                guard fstat(sourceDescriptor, &after) == 0 else {
                    throw POSIXRootFileSystemError.systemCall(
                        operation: "fstat",
                        code: errno
                    )
                }
                guard sourceWasStable(before: before, after: after) else {
                    throw TrustedMihomoExecutableError.sourceChanged
                }
            }

            let identity = try fileSystem.trustedExecutableIdentity(at: destination)
            guard identity.size == before.st_size else {
                throw TrustedMihomoExecutableError.sourceChanged
            }
            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            return TrustedMihomoExecutable(
                relativePath: destination,
                url: url(for: destination),
                identity: identity,
                contentSHA256: digest
            )
        } catch {
            try? fileSystem.removeTrustedExecutable(destination)
            try? fileSystem.removeFile(destination)
            try? fileSystem.removeEmptyDirectory(generationRoot)
            throw error
        }
    }

    public func resolve(
        relativePath: SafeRelativePath
    ) throws -> TrustedMihomoExecutable {
        try validateGenerationPath(relativePath)
        return TrustedMihomoExecutable(
            relativePath: relativePath,
            url: url(for: relativePath),
            identity: try fileSystem.trustedExecutableIdentity(at: relativePath),
            contentSHA256: nil
        )
    }

    public func revalidate(
        _ executable: TrustedMihomoExecutable
    ) throws -> TrustedMihomoExecutable {
        let resolved = try resolve(relativePath: executable.relativePath)
        guard resolved.url.standardizedFileURL.path == executable.url.standardizedFileURL.path
        else {
            throw TrustedMihomoExecutableError.invalidGenerationPath
        }
        return TrustedMihomoExecutable(
            relativePath: resolved.relativePath,
            url: resolved.url,
            identity: resolved.identity,
            contentSHA256: executable.contentSHA256
        )
    }

    public func removeGeneration(containing relativePath: SafeRelativePath) throws {
        try validateGenerationPath(relativePath)
        let generationRoot = try SafeRelativePath(
            components: Array(relativePath.components.dropLast())
        )
        try fileSystem.removeTrustedExecutable(relativePath)
        try fileSystem.removeEmptyDirectory(generationRoot)
    }

    /// Called only after journal recovery proves that no old managed process is
    /// still using a generation.
    public func removeAllGenerations() throws {
        let generations = try SafeRelativePath("executables/generations")
        let entries: [POSIXDirectoryEntry]
        do {
            entries = try fileSystem.directoryEntries(at: generations, maximumCount: 64)
        } catch let error as POSIXRootFileSystemError {
            if case let .systemCall(_, code) = error, code == ENOENT { return }
            throw error
        }
        var completeExecutables: [SafeRelativePath] = []
        var recoverableRegularFiles: [SafeRelativePath] = []
        var recoverableTrustedFiles: [SafeRelativePath] = []
        var incompleteGenerationRoots: [SafeRelativePath] = []

        // Preflight every generation and every recoverable file before the
        // first unlink. Unknown names, links, modes, or contents remain a
        // fail-closed bootstrap error.
        for entry in entries {
            guard entry.isDirectory,
                let generationID = UUID(uuidString: entry.name),
                entry.name == generationID.uuidString.lowercased()
            else {
                throw TrustedMihomoExecutableError.invalidGenerationContents
            }
            let generationRoot = try generations.appending(entry.name)
            let contents = try fileSystem.directoryEntries(
                at: generationRoot,
                maximumCount: 4
            )
            var executable: SafeRelativePath?
            var isIncomplete = contents.isEmpty
            for content in contents {
                if content.name == "mihomo", content.isRegularFile, executable == nil {
                    let path = try generationRoot.appending("mihomo")
                    do {
                        _ = try resolve(relativePath: path)
                        executable = path
                    } catch POSIXRootFileSystemError.unsafePermissions {
                        // A crash after rename and before the final 0500 chmod
                        // leaves the exact root-owned 0600 destination.
                        _ = try fileSystem.verifiedRegularFileIdentity(
                            at: path,
                            maximumBytes: Int64(VelaIPCConstants.maximumMihomoExecutableBytes)
                        )
                        recoverableRegularFiles.append(path)
                        isIncomplete = true
                    }
                    continue
                }
                guard RootAtomicTemporaryArtifact.isExactName(content.name) else {
                    throw TrustedMihomoExecutableError.invalidGenerationContents
                }
                let temporaryPath = try generationRoot.appending(content.name)
                do {
                    recoverableRegularFiles.append(try RootAtomicTemporaryArtifact.validate(
                        content,
                        in: generationRoot,
                        fileSystem: fileSystem,
                        maximumBytes: Int64(VelaIPCConstants.maximumMihomoExecutableBytes)
                    ))
                } catch POSIXRootFileSystemError.unsafePermissions {
                    // Older builds changed the temp to 0500 before rename. It
                    // remains a recoverable artifact only in this executable
                    // generation directory and only with exact trusted mode.
                    let identity = try fileSystem.trustedExecutableIdentity(at: temporaryPath)
                    guard identity.size >= 0,
                        identity.size <= Int64(VelaIPCConstants.maximumMihomoExecutableBytes)
                    else {
                        throw POSIXRootFileSystemError.fileTooLarge
                    }
                    recoverableTrustedFiles.append(temporaryPath)
                }
                isIncomplete = true
            }
            if let executable {
                guard !isIncomplete || contents.contains(where: { $0.name == "mihomo" }) else {
                    throw TrustedMihomoExecutableError.invalidGenerationContents
                }
                completeExecutables.append(executable)
            } else {
                incompleteGenerationRoots.append(generationRoot)
            }
        }

        for path in recoverableRegularFiles {
            try fileSystem.removeFile(path)
        }
        for path in recoverableTrustedFiles {
            try fileSystem.removeTrustedExecutable(path)
        }
        for executable in completeExecutables {
            try removeGeneration(containing: executable)
        }
        for generationRoot in incompleteGenerationRoots {
            try fileSystem.removeEmptyDirectory(generationRoot)
        }
    }

    public func removeContainerDirectoriesIfEmpty() throws {
        try fileSystem.removeEmptyDirectory(try SafeRelativePath("executables/generations"))
        try fileSystem.removeEmptyDirectory(try SafeRelativePath("executables"))
    }

    private func validateSource(_ status: stat) throws {
        guard status.st_mode & S_IFMT == S_IFREG else {
            throw TrustedMihomoExecutableError.sourceNotRegular
        }
        guard status.st_mode & 0o111 != 0 else {
            throw TrustedMihomoExecutableError.sourceNotExecutable
        }
        guard status.st_size > 0,
            status.st_size <= Int64(VelaIPCConstants.maximumMihomoExecutableBytes)
        else {
            throw TrustedMihomoExecutableError.sourceSizeInvalid
        }
    }

    private func sourceWasStable(before: stat, after: stat) -> Bool {
        before.st_dev == after.st_dev
            && before.st_ino == after.st_ino
            && before.st_size == after.st_size
            && before.st_mode == after.st_mode
            && before.st_uid == after.st_uid
            && before.st_gid == after.st_gid
            && before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec
            && before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec
            && before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec
            && before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
    }

    private func validateGenerationPath(_ path: SafeRelativePath) throws {
        guard path.components.count == 4,
            path.components[0] == "executables",
            path.components[1] == "generations",
            UUID(uuidString: path.components[2]) != nil,
            path.components[3] == "mihomo"
        else {
            throw TrustedMihomoExecutableError.invalidGenerationPath
        }
    }

    private func url(for path: SafeRelativePath) -> URL {
        path.components.reduce(fileSystem.rootURL) { partial, component in
            partial.appending(path: component)
        }
    }
}
