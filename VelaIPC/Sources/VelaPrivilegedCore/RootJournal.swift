import Darwin
import Foundation
import VelaIPC

public enum RootDesiredState: String, Codable, Sendable {
    case stopped
    case running
}

public struct RootProcessIdentity: Codable, Equatable, Sendable {
    public let processID: Int32
    public let startTimeSeconds: UInt64
    public let startTimeMicroseconds: UInt64
    public let executableDevice: UInt64
    public let executableInode: UInt64
    public let executableRelativePath: SafeRelativePath
    public let signingIdentifier: String
    public let teamIdentifier: String

    public init(
        processID: Int32,
        startTimeSeconds: UInt64,
        startTimeMicroseconds: UInt64,
        executableDevice: UInt64,
        executableInode: UInt64,
        executableRelativePath: SafeRelativePath,
        signingIdentifier: String,
        teamIdentifier: String
    ) {
        self.processID = processID
        self.startTimeSeconds = startTimeSeconds
        self.startTimeMicroseconds = startTimeMicroseconds
        self.executableDevice = executableDevice
        self.executableInode = executableInode
        self.executableRelativePath = executableRelativePath
        self.signingIdentifier = signingIdentifier
        self.teamIdentifier = teamIdentifier
    }
}

public struct RootRuntimeJournal: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = VelaIPCConstants.rootDataSchemaVersion

    public let schemaVersion: Int
    public var desiredState: RootDesiredState
    public var instanceID: UUID?
    public var processIdentity: RootProcessIdentity?
    public var configurationSHA256: String?
    public var tunInterface: String?
    public var routeProbeAddress: String?
    public var preexistingTunInterfaces: [String]?
    public var ownerUID: UInt32?
    public var activeTransactionID: UUID?
    public var lastCleanShutdown: Bool

    public init(
        schemaVersion: Int = currentSchemaVersion,
        desiredState: RootDesiredState = .stopped,
        instanceID: UUID? = nil,
        processIdentity: RootProcessIdentity? = nil,
        configurationSHA256: String? = nil,
        tunInterface: String? = nil,
        routeProbeAddress: String? = nil,
        preexistingTunInterfaces: [String]? = nil,
        ownerUID: UInt32? = nil,
        activeTransactionID: UUID? = nil,
        lastCleanShutdown: Bool = true
    ) {
        self.schemaVersion = schemaVersion
        self.desiredState = desiredState
        self.instanceID = instanceID
        self.processIdentity = processIdentity
        self.configurationSHA256 = configurationSHA256
        self.tunInterface = tunInterface
        self.routeProbeAddress = routeProbeAddress
        self.preexistingTunInterfaces = preexistingTunInterfaces
        self.ownerUID = ownerUID
        self.activeTransactionID = activeTransactionID
        self.lastCleanShutdown = lastCleanShutdown
    }
}

public actor RootJournalStore {
    private let fileSystem: POSIXRootFileSystem

    public init(fileSystem: POSIXRootFileSystem) {
        self.fileSystem = fileSystem
    }

    public func prepare() throws {
        let directory = try SafeRelativePath("state")
        try fileSystem.createDirectory(directory)

        let entries = try fileSystem.directoryEntries(at: directory, maximumCount: 8)
        var temporaryFiles: [SafeRelativePath] = []
        for entry in entries {
            if entry.name == "runtime-journal.json" {
                guard entry.isRegularFile else {
                    throw RootJournalError.invalidDirectoryContents
                }
                _ = try fileSystem.verifiedRegularFileIdentity(
                    at: try directory.appending(entry.name),
                    maximumBytes: Int64(VelaIPCConstants.maximumPayloadBytes)
                )
                continue
            }
            guard RootAtomicTemporaryArtifact.isExactName(entry.name) else {
                throw RootJournalError.invalidDirectoryContents
            }
            temporaryFiles.append(try RootAtomicTemporaryArtifact.validate(
                entry,
                in: directory,
                fileSystem: fileSystem,
                maximumBytes: Int64(VelaIPCConstants.maximumPayloadBytes)
            ))
        }

        // Every entry is preflighted before the first unlink. `removeFile`
        // repeats no-follow/type/ownership/mode validation at deletion time.
        for path in temporaryFiles {
            try fileSystem.removeFile(path)
        }
    }

    public func load() throws -> RootRuntimeJournal? {
        let journalPath = try Self.journalPath()
        let data: Data
        do {
            data = try fileSystem.readData(
                at: journalPath,
                maximumBytes: VelaIPCConstants.maximumPayloadBytes
            )
        } catch let error as POSIXRootFileSystemError {
            if case let .systemCall(_, code) = error, code == ENOENT { return nil }
            throw error
        }

        let journal = try JSONDecoder().decode(RootRuntimeJournal.self, from: data)
        try Self.validate(journal)
        return journal
    }

    public func save(_ journal: RootRuntimeJournal) throws {
        try Self.validate(journal)
        let journalPath = try Self.journalPath()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(journal)
        let exists: Bool
        do {
            _ = try fileSystem.identity(of: journalPath)
            exists = true
        } catch let error as POSIXRootFileSystemError {
            if case let .systemCall(_, code) = error, code == ENOENT {
                exists = false
            } else {
                throw error
            }
        }
        try fileSystem.writeDataAtomically(
            data,
            to: journalPath,
            replacingExisting: exists
        )
    }

    private static func validate(_ journal: RootRuntimeJournal) throws {
        guard journal.schemaVersion == RootRuntimeJournal.currentSchemaVersion else {
            throw RootJournalError.unsupportedSchema(journal.schemaVersion)
        }
        if let hash = journal.configurationSHA256 {
            _ = try IntegrityValue.normalizedSHA256(hash)
        }
        if let address = journal.routeProbeAddress,
            !PrivilegedRouteProbeSelector.isAllowedJournalAddress(address)
        {
            throw RootJournalError.invalidRouteProbeAddress
        }
        if let interface = journal.tunInterface,
            !PrivilegedTunInterfaceValidator.isValid(interface)
        {
            throw RootJournalError.invalidTunInterface
        }
        if let interfaces = journal.preexistingTunInterfaces,
            !PrivilegedTunInterfaceValidator.isValidJournalBaseline(interfaces)
        {
            throw RootJournalError.invalidPreexistingTunInterfaces
        }

        if journal.lastCleanShutdown {
            guard journal.desiredState == .stopped,
                journal.instanceID == nil,
                journal.processIdentity == nil,
                journal.configurationSHA256 == nil,
                journal.tunInterface == nil,
                journal.routeProbeAddress == nil,
                journal.preexistingTunInterfaces == nil,
                journal.ownerUID == nil,
                journal.activeTransactionID == nil
            else {
                throw RootJournalError.invalidState
            }
        } else {
            guard journal.desiredState == .running,
                journal.instanceID != nil,
                journal.configurationSHA256 != nil,
                journal.routeProbeAddress != nil,
                journal.preexistingTunInterfaces != nil,
                journal.ownerUID != nil,
                journal.activeTransactionID != nil,
                journal.tunInterface == nil || journal.processIdentity != nil
            else {
                throw RootJournalError.invalidState
            }
        }
    }

    public func clear() throws {
        let path = try Self.journalPath()
        do {
            try fileSystem.removeFile(path)
        } catch let error as POSIXRootFileSystemError {
            if case let .systemCall(_, code) = error, code == ENOENT { return }
            throw error
        }
    }

    private static func journalPath() throws -> SafeRelativePath {
        try SafeRelativePath("state/runtime-journal.json")
    }
}

public enum RootJournalError: Error, Equatable, Sendable {
    case unsupportedSchema(Int)
    case invalidDirectoryContents
    case invalidRouteProbeAddress
    case invalidTunInterface
    case invalidPreexistingTunInterfaces
    case invalidState
}
