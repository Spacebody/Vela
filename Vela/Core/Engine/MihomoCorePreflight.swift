import Darwin
import CryptoKit
import Foundation

nonisolated struct MihomoCoreFileSnapshot: Equatable, Sendable {
    let url: URL
    let permissions: UInt32
    let ownerUserID: UInt32
    let ownerGroupID: UInt32
    let deviceID: UInt64
    let inode: UInt64
    let fileSize: Int64
    let modificationTimeSeconds: Int64
    let modificationTimeNanoseconds: Int64
}

nonisolated protocol MihomoCoreFileInspecting: Sendable {
    func inspectExecutable(at url: URL) throws -> MihomoCoreFileSnapshot
}

nonisolated struct POSIXMihomoCoreFileInspector: MihomoCoreFileInspecting, Sendable {
    func inspectExecutable(at url: URL) throws -> MihomoCoreFileSnapshot {
        guard url.isFileURL else {
            throw MihomoCoreFileInspectionError.notAFileURL(url.absoluteString)
        }

        var metadata = stat()
        let status = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.lstat(path, &metadata)
        }
        guard status == 0 else {
            let errorNumber = errno
            if errorNumber == ENOENT {
                throw MihomoCoreFileInspectionError.missing(url)
            }
            throw MihomoCoreFileInspectionError.metadataReadFailed(
                path: url.path,
                errorNumber: errorNumber,
                reason: String(cString: strerror(errorNumber))
            )
        }

        let mode = metadata.st_mode
        let fileType = mode & mode_t(S_IFMT)
        if fileType == mode_t(S_IFLNK) {
            throw MihomoCoreFileInspectionError.symbolicLink(url)
        }
        guard fileType == mode_t(S_IFREG) else {
            throw MihomoCoreFileInspectionError.notRegularFile(url)
        }

        let executableBits = mode_t(S_IXUSR | S_IXGRP | S_IXOTH)
        guard mode & executableBits != 0,
            FileManager.default.isExecutableFile(atPath: url.path)
        else {
            throw MihomoCoreFileInspectionError.notExecutable(url)
        }

        let unsafeWriteBits = mode_t(S_IWGRP | S_IWOTH)
        guard mode & unsafeWriteBits == 0 else {
            throw MihomoCoreFileInspectionError.insecurePermissions(
                path: url.path,
                permissions: UInt32(mode & 0o7777)
            )
        }

        return MihomoCoreFileSnapshot(
            url: url,
            permissions: UInt32(mode & 0o7777),
            ownerUserID: metadata.st_uid,
            ownerGroupID: metadata.st_gid,
            deviceID: UInt64(metadata.st_dev),
            inode: UInt64(metadata.st_ino),
            fileSize: Int64(metadata.st_size),
            modificationTimeSeconds: Int64(metadata.st_mtimespec.tv_sec),
            modificationTimeNanoseconds: Int64(metadata.st_mtimespec.tv_nsec)
        )
    }
}

nonisolated enum MihomoVerifiedExecutableGuardError: Error, Equatable, Sendable {
    case missingVerifiedFile(URL)
    case fileInspection(MihomoCoreFileInspectionError)
    case metadataChanged(URL)
    case readFailed(path: String, reason: String)
    case checksumChanged(path: String, expected: String, actual: String)
}

extension MihomoVerifiedExecutableGuardError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .missingVerifiedFile(url):
            "The Mihomo core at \(url.path) has no verified file identity snapshot."
        case let .fileInspection(error):
            "The bundled Mihomo core changed after preflight: \(error.localizedDescription)"
        case let .metadataChanged(url):
            "The bundled Mihomo core at \(url.path) was replaced or modified after preflight."
        case let .readFailed(path, reason):
            "The bundled Mihomo core at \(path) could not be re-read after preflight: \(reason)"
        case let .checksumChanged(path, expected, actual):
            "The bundled Mihomo core at \(path) changed after preflight (expected SHA-256 \(expected), found \(actual))."
        }
    }
}

nonisolated struct MihomoVerifiedExecutableGuard: Sendable {
    static func verifyUnchanged(_ executable: ResolvedMihomoExecutable) throws {
        guard let verifiedFile = executable.verifiedFile else {
            throw MihomoVerifiedExecutableGuardError.missingVerifiedFile(executable.url)
        }

        let currentFile: MihomoCoreFileSnapshot
        do {
            currentFile = try POSIXMihomoCoreFileInspector().inspectExecutable(at: executable.url)
        } catch let error as MihomoCoreFileInspectionError {
            throw MihomoVerifiedExecutableGuardError.fileInspection(error)
        } catch {
            throw MihomoVerifiedExecutableGuardError.readFailed(
                path: executable.url.path,
                reason: error.localizedDescription
            )
        }

        guard currentFile == verifiedFile else {
            throw MihomoVerifiedExecutableGuardError.metadataChanged(executable.url)
        }

        let currentChecksum: String
        do {
            currentChecksum = SHA256.hash(data: try Data(contentsOf: executable.url))
                .map { String(format: "%02x", $0) }
                .joined()
        } catch {
            throw MihomoVerifiedExecutableGuardError.readFailed(
                path: executable.url.path,
                reason: error.localizedDescription
            )
        }
        guard currentChecksum == executable.sha256 else {
            throw MihomoVerifiedExecutableGuardError.checksumChanged(
                path: executable.url.path,
                expected: executable.sha256,
                actual: currentChecksum
            )
        }
    }
}

nonisolated struct MihomoCorePreflightRequest: Equatable, Sendable {
    let applicationBundleURL: URL
    let signatureTeamPolicy: CodeSignatureTeamPolicy
    let versionProbeCurrentDirectoryURL: URL?

    init(
        applicationBundleURL: URL,
        signatureTeamPolicy: CodeSignatureTeamPolicy,
        versionProbeCurrentDirectoryURL: URL? = nil
    ) {
        self.applicationBundleURL = applicationBundleURL
        self.signatureTeamPolicy = signatureTeamPolicy
        self.versionProbeCurrentDirectoryURL = versionProbeCurrentDirectoryURL
    }
}

nonisolated struct MihomoCorePreflightResult: Equatable, Sendable {
    let descriptor: MihomoCoreDescriptor
    let executableURL: URL
    let file: MihomoCoreFileSnapshot
    let machO: MachOInspection
    let signature: CodeSignatureVerification
    let version: MihomoVersionIdentity
}

nonisolated protocol MihomoCorePreflighting: Sendable {
    func run(_ request: MihomoCorePreflightRequest) async throws -> MihomoCorePreflightResult
}

nonisolated struct MihomoCorePreflight: MihomoCorePreflighting, Sendable {
    private let descriptorLoader: any MihomoCoreDescriptorLoading
    private let fileInspector: any MihomoCoreFileInspecting
    private let architectureInspector: any MachOArchitectureInspecting
    private let signatureVerifier: any CodeSignatureVerifying
    private let versionProbe: any MihomoVersionProbing

    init(
        descriptorLoader: any MihomoCoreDescriptorLoading = JSONMihomoCoreDescriptorLoader(),
        fileInspector: any MihomoCoreFileInspecting = POSIXMihomoCoreFileInspector(),
        architectureInspector: any MachOArchitectureInspecting = MachOArchitectureInspector(),
        signatureVerifier: any CodeSignatureVerifying = CodeSignatureVerifier(),
        versionProbe: any MihomoVersionProbing = MihomoVersionProbe()
    ) {
        self.descriptorLoader = descriptorLoader
        self.fileInspector = fileInspector
        self.architectureInspector = architectureInspector
        self.signatureVerifier = signatureVerifier
        self.versionProbe = versionProbe
    }

    func run(_ request: MihomoCorePreflightRequest) async throws -> MihomoCorePreflightResult {
        let bundleURL = request.applicationBundleURL.standardizedFileURL
        let manifestURL = bundleURL
            .appending(path: MihomoCoreDescriptor.requiredMetadataBundleRelativePath)
            .appending(path: "manifest.json")

        let descriptor: MihomoCoreDescriptor
        do {
            descriptor = try descriptorLoader.load(from: manifestURL)
        } catch let error as MihomoCoreManifestError {
            throw MihomoCorePreflightError.manifest(error)
        } catch {
            throw MihomoCorePreflightError.unexpected(
                stage: .manifest,
                message: error.localizedDescription
            )
        }

        let executableURL = try Self.safeExecutableURL(
            in: bundleURL,
            relativePath: descriptor.bundleRelativePath
        )

        let file: MihomoCoreFileSnapshot
        do {
            file = try fileInspector.inspectExecutable(at: executableURL)
        } catch let error as MihomoCoreFileInspectionError {
            throw MihomoCorePreflightError.file(error)
        } catch {
            throw MihomoCorePreflightError.unexpected(
                stage: .file,
                message: error.localizedDescription
            )
        }

        try Self.verifyResolvedContainment(
            executableURL: executableURL,
            applicationBundleURL: bundleURL
        )

        let machO: MachOInspection
        do {
            machO = try architectureInspector.inspect(executableAt: executableURL)
        } catch let error as MachOArchitectureInspectionError {
            throw MihomoCorePreflightError.architecture(error)
        } catch {
            throw MihomoCorePreflightError.unexpected(
                stage: .architecture,
                message: error.localizedDescription
            )
        }

        let signature: CodeSignatureVerification
        do {
            signature = try signatureVerifier.verify(
                applicationAt: bundleURL,
                helperAt: executableURL,
                teamPolicy: request.signatureTeamPolicy
            )
        } catch let error as CodeSignatureVerificationError {
            throw MihomoCorePreflightError.signature(error)
        } catch {
            throw MihomoCorePreflightError.unexpected(
                stage: .signature,
                message: error.localizedDescription
            )
        }

        let version: MihomoVersionIdentity
        do {
            version = try await versionProbe.probe(
                executableAt: executableURL,
                expected: MihomoVersionExpectation(descriptor: descriptor),
                currentDirectoryURL: request.versionProbeCurrentDirectoryURL
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as MihomoVersionProbeError {
            throw MihomoCorePreflightError.version(error)
        } catch {
            throw MihomoCorePreflightError.unexpected(
                stage: .version,
                message: error.localizedDescription
            )
        }

        // The version probe executes the helper, so close the inspection-to-use
        // window by verifying both file identity and signatures again afterward.
        let finalFile: MihomoCoreFileSnapshot
        do {
            finalFile = try fileInspector.inspectExecutable(at: executableURL)
        } catch let error as MihomoCoreFileInspectionError {
            throw MihomoCorePreflightError.file(error)
        } catch {
            throw MihomoCorePreflightError.unexpected(
                stage: .file,
                message: error.localizedDescription
            )
        }
        guard finalFile == file else {
            throw MihomoCorePreflightError.unexpected(
                stage: .file,
                message: "Mihomo was replaced or modified while preflight was running."
            )
        }

        let finalSignature: CodeSignatureVerification
        do {
            finalSignature = try signatureVerifier.verify(
                applicationAt: bundleURL,
                helperAt: executableURL,
                teamPolicy: request.signatureTeamPolicy
            )
        } catch let error as CodeSignatureVerificationError {
            throw MihomoCorePreflightError.signature(error)
        } catch {
            throw MihomoCorePreflightError.unexpected(
                stage: .signature,
                message: error.localizedDescription
            )
        }
        guard finalSignature == signature else {
            throw MihomoCorePreflightError.unexpected(
                stage: .signature,
                message: "Mihomo signing information changed while preflight was running."
            )
        }

        return MihomoCorePreflightResult(
            descriptor: descriptor,
            executableURL: executableURL,
            file: finalFile,
            machO: machO,
            signature: finalSignature,
            version: version
        )
    }

    static func safeExecutableURL(in applicationBundleURL: URL, relativePath: String) throws -> URL {
        let root = applicationBundleURL.standardizedFileURL
        let candidate = root.appending(path: relativePath).standardizedFileURL
        guard isDescendant(candidate, of: root) else {
            throw MihomoCorePreflightError.pathEscapesBundle(
                bundlePath: root.path,
                executablePath: candidate.path
            )
        }
        return candidate
    }

    private static func verifyResolvedContainment(
        executableURL: URL,
        applicationBundleURL: URL
    ) throws {
        let resolvedRoot = applicationBundleURL.resolvingSymlinksInPath().standardizedFileURL
        let resolvedExecutable = executableURL.resolvingSymlinksInPath().standardizedFileURL
        guard isDescendant(resolvedExecutable, of: resolvedRoot) else {
            throw MihomoCorePreflightError.pathEscapesBundle(
                bundlePath: resolvedRoot.path,
                executablePath: resolvedExecutable.path
            )
        }
    }

    private static func isDescendant(_ candidate: URL, of root: URL) -> Bool {
        let rootComponents = root.pathComponents
        let candidateComponents = candidate.pathComponents
        guard candidateComponents.count > rootComponents.count else { return false }
        return Array(candidateComponents.prefix(rootComponents.count)) == rootComponents
    }
}

nonisolated enum MihomoCorePreflightStage: String, Equatable, Sendable {
    case manifest
    case file
    case architecture
    case signature
    case version
}

nonisolated enum MihomoCoreFileInspectionError: Error, Equatable, Sendable {
    case notAFileURL(String)
    case missing(URL)
    case metadataReadFailed(path: String, errorNumber: Int32, reason: String)
    case symbolicLink(URL)
    case notRegularFile(URL)
    case notExecutable(URL)
    case insecurePermissions(path: String, permissions: UInt32)
}

extension MihomoCoreFileInspectionError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .notAFileURL(value):
            "Mihomo executable URL is not a file URL: \(value)"
        case let .missing(url):
            "Mihomo executable is missing at \(url.path)."
        case let .metadataReadFailed(path, errorNumber, reason):
            "Could not inspect Mihomo at \(path): \(reason) (errno \(errorNumber))."
        case let .symbolicLink(url):
            "Mihomo executable must not be a symbolic link: \(url.path)"
        case let .notRegularFile(url):
            "Mihomo executable is not a regular file: \(url.path)"
        case let .notExecutable(url):
            "Mihomo executable does not have usable execute permission: \(url.path)"
        case let .insecurePermissions(path, permissions):
            "Mihomo executable at \(path) is group- or world-writable (mode \(String(format: "%04o", permissions)))."
        }
    }
}

nonisolated enum MihomoCorePreflightError: Error, Equatable, Sendable {
    case manifest(MihomoCoreManifestError)
    case pathEscapesBundle(bundlePath: String, executablePath: String)
    case file(MihomoCoreFileInspectionError)
    case architecture(MachOArchitectureInspectionError)
    case signature(CodeSignatureVerificationError)
    case version(MihomoVersionProbeError)
    case unexpected(stage: MihomoCorePreflightStage, message: String)
}

extension MihomoCorePreflightError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .manifest(error):
            error.localizedDescription
        case let .pathEscapesBundle(bundlePath, executablePath):
            "Mihomo executable escaped its app bundle. Bundle: \(bundlePath), executable: \(executablePath)."
        case let .file(error):
            error.localizedDescription
        case let .architecture(error):
            error.localizedDescription
        case let .signature(error):
            error.localizedDescription
        case let .version(error):
            error.localizedDescription
        case let .unexpected(stage, message):
            "Unexpected Mihomo preflight failure during \(stage.rawValue): \(message)"
        }
    }
}
