import Darwin
import Foundation

public struct LiveProcessSnapshot: Equatable, Sendable {
    public let processID: Int32
    public let effectiveUserID: UInt32
    public let startTimeSeconds: UInt64
    public let startTimeMicroseconds: UInt64
    public let executableURL: URL
    public let executableIdentity: POSIXFileIdentity
    public let codeSignature: PrivilegedCodeSignature
}

public protocol LiveProcessInspecting: Sendable {
    func inspect(processID: Int32, expectedExecutableURL: URL) throws -> LiveProcessSnapshot
}

public struct DarwinLiveProcessInspector: LiveProcessInspecting {
    private let signingInspector: any PrivilegedCodeSigningInspecting

    public init(
        signingInspector: any PrivilegedCodeSigningInspecting =
            SecurityPrivilegedCodeSigningInspector()
    ) {
        self.signingInspector = signingInspector
    }

    public func inspect(
        processID: Int32,
        expectedExecutableURL: URL
    ) throws -> LiveProcessSnapshot {
        guard processID > 1 else { throw ProcessIdentityError.invalidProcessID }

        var processInfo = proc_bsdinfo()
        let infoSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(
            processID,
            PROC_PIDTBSDINFO,
            0,
            &processInfo,
            infoSize
        ) == infoSize else {
            throw ProcessIdentityError.processUnavailable
        }

        var pathBytes = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let pathLength = pathBytes.withUnsafeMutableBytes {
            proc_pidpath(processID, $0.baseAddress, UInt32($0.count))
        }
        guard pathLength > 0 else { throw ProcessIdentityError.processPathUnavailable }
        let path = String(
            decoding: pathBytes.prefix(Int(pathLength)).map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
        let actualURL = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let expectedURL = expectedExecutableURL.resolvingSymlinksInPath()
        guard actualURL.path == expectedURL.path else {
            throw ProcessIdentityError.executablePathMismatch
        }

        var status = stat()
        guard lstat(expectedURL.path, &status) == 0 else {
            throw ProcessIdentityError.processPathUnavailable
        }
        guard status.st_mode & S_IFMT == S_IFREG else {
            throw ProcessIdentityError.executablePathMismatch
        }
        let signature = try signingInspector.inspect(at: expectedURL, validateNestedCode: false)
        return LiveProcessSnapshot(
            processID: processID,
            effectiveUserID: processInfo.pbi_uid,
            startTimeSeconds: processInfo.pbi_start_tvsec,
            startTimeMicroseconds: processInfo.pbi_start_tvusec,
            executableURL: actualURL,
            executableIdentity: POSIXFileIdentity(status),
            codeSignature: signature
        )
    }
}

public struct ProcessIdentityVerifier: Sendable {
    private let inspector: any LiveProcessInspecting

    public init(inspector: any LiveProcessInspecting = DarwinLiveProcessInspector()) {
        self.inspector = inspector
    }

    public func verify(
        journalIdentity: RootProcessIdentity,
        expectedExecutableURL: URL
    ) throws -> LiveProcessSnapshot {
        let live = try inspector.inspect(
            processID: journalIdentity.processID,
            expectedExecutableURL: expectedExecutableURL
        )
        guard live.effectiveUserID == 0 else { throw ProcessIdentityError.userMismatch }
        guard live.startTimeSeconds == journalIdentity.startTimeSeconds,
            live.startTimeMicroseconds == journalIdentity.startTimeMicroseconds
        else {
            throw ProcessIdentityError.startTimeMismatch
        }
        guard live.executableIdentity.device == journalIdentity.executableDevice,
            live.executableIdentity.inode == journalIdentity.executableInode
        else {
            throw ProcessIdentityError.executableIdentityMismatch
        }
        guard live.codeSignature.signingIdentifier == journalIdentity.signingIdentifier,
            live.codeSignature.teamIdentifier == journalIdentity.teamIdentifier
        else {
            throw ProcessIdentityError.codeSignatureMismatch
        }
        return live
    }
}

public enum ProcessIdentityError: Error, Equatable, Sendable {
    case invalidProcessID
    case processUnavailable
    case processPathUnavailable
    case executablePathMismatch
    case userMismatch
    case startTimeMismatch
    case executableIdentityMismatch
    case codeSignatureMismatch
}
