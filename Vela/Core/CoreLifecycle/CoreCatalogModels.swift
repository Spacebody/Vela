import Foundation
import VelaIPC

nonisolated enum CoreCatalogStatus: String, Codable, CaseIterable, Sendable {
    case recommended
    case available
    case blocked
    case withdrawn
}

nonisolated extension CoreFileRole {
    var requiredRelativePath: String {
        switch self {
        case .infoPlist: "Contents/Info.plist"
        case .executable: "Contents/MacOS/mihomo"
        case .codeResources: "Contents/_CodeSignature/CodeResources"
        case .license: "Contents/Resources/LICENSE"
        case .notice: "Contents/Resources/NOTICE.md"
        case .source: "Contents/Resources/source.json"
        case .compatibility: "Contents/Resources/compatibility.json"
        }
    }

    var requiredMode: String { self == .executable ? "0755" : "0644" }
    var requiredPOSIXMode: Int { self == .executable ? 0o755 : 0o644 }
    var maximumBytes: UInt64 {
        self == .executable ? 64 * 1_024 * 1_024 : 5 * 1_024 * 1_024
    }
}

nonisolated struct CoreFileDescriptor: Codable, Equatable, Sendable {
    let role: CoreFileRole
    let relativePath: String
    let url: URL
    let sha256: String
    let size: UInt64
    let mode: String

    func validate() throws {
        guard relativePath == role.requiredRelativePath else {
            throw CoreCatalogValidationError.invalidPath(role: role, value: relativePath)
        }
        guard mode == role.requiredMode else {
            throw CoreCatalogValidationError.invalidMode(role: role, value: mode)
        }
        guard size > 0, size <= role.maximumBytes else {
            throw CoreCatalogValidationError.invalidSize(role: role, value: size)
        }
        try CoreCatalogURLPolicy.validate(url)
        guard Self.isSHA256(sha256) else {
            throw CoreCatalogValidationError.invalidSHA256(sha256)
        }
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48 ... 57).contains($0) || (97 ... 102).contains($0)
        }
    }
}

nonisolated struct CoreUpstreamMetadata: Codable, Equatable, Sendable {
    let repositoryURL: URL
    let tag: String
    let commit: String
    let assetURL: URL
    let assetName: String
    let archiveSHA256: String
    let archiveSizeBytes: UInt64
    let sourceURL: URL
    let license: String

    func validate() throws {
        try CoreCatalogURLPolicy.validate(repositoryURL)
        try CoreCatalogURLPolicy.validate(assetURL)
        try CoreCatalogURLPolicy.validate(sourceURL)
        for value in [tag, commit, assetName, license] {
            try CoreCatalogStringPolicy.validate(value)
        }
        guard archiveSHA256.utf8.count == 64,
            archiveSHA256.utf8.allSatisfy({
                (48 ... 57).contains($0) || (97 ... 102).contains($0)
            }),
            archiveSizeBytes > 0,
            archiveSizeBytes <= CoreFileRole.executable.maximumBytes
        else {
            throw CoreCatalogValidationError.invalidUpstreamMetadata
        }
    }
}

nonisolated struct CoreCompatibilityConstraints: Codable, Equatable, Sendable {
    let minimumVelaVersion: String
    let minimumVelaBuild: UInt64
    let maximumVelaBuild: UInt64?
    let helperProtocolMinimum: UInt64
    let helperProtocolMaximum: UInt64
    let dataSchemaMinimum: UInt64
    let dataSchemaMaximum: UInt64
    let controllerAPIProfile: String
    let minimumMacOS: String
    let architectures: [String]
    let bundleIdentifier: String
    let compatibilitySuiteVersion: UInt64
    let compatibilityReportSHA256: String

    func validate() throws {
        for value in [minimumVelaVersion, controllerAPIProfile, minimumMacOS, bundleIdentifier] {
            try CoreCatalogStringPolicy.validate(value)
        }
        guard minimumVelaBuild > 0,
            maximumVelaBuild.map({ $0 >= minimumVelaBuild }) ?? true,
            helperProtocolMinimum > 0,
            helperProtocolMaximum >= helperProtocolMinimum,
            dataSchemaMinimum > 0,
            dataSchemaMaximum >= dataSchemaMinimum,
            compatibilitySuiteVersion > 0,
            architectures == ["arm64"],
            bundleIdentifier == VelaIPCConstants.expectedExternalCoreSigningIdentifier,
            compatibilityReportSHA256.utf8.count == 64,
            compatibilityReportSHA256.utf8.allSatisfy({
                (48 ... 57).contains($0) || (97 ... 102).contains($0)
            })
        else {
            throw CoreCatalogValidationError.invalidCompatibilityConstraints
        }
    }
}

nonisolated struct CoreCatalogEntry: Codable, Equatable, Sendable, Identifiable {
    var id: CoreID { coreID }

    let coreID: CoreID
    let upstreamVersion: String
    let packageRevision: UInt64
    let status: CoreCatalogStatus
    let publishedAt: Date
    let releaseNotesURL: URL
    let upstream: CoreUpstreamMetadata
    let vela: CoreCompatibilityConstraints
    let files: [CoreFileDescriptor]
    let blockReason: String?

    func validate() throws {
        try CoreCatalogStringPolicy.validate(upstreamVersion)
        guard packageRevision > 0,
            coreID.packageRevision == Int(exactly: packageRevision),
            coreID.upstreamVersion == upstreamVersion
        else {
            throw CoreCatalogValidationError.invalidPackageRevision
        }
        try CoreCatalogURLPolicy.validate(releaseNotesURL)
        try upstream.validate()
        try vela.validate()
        guard files.count <= 16 else {
            throw CoreCatalogValidationError.tooManyFiles(files.count)
        }
        let roles = Set(files.map(\.role))
        guard roles.count == files.count else {
            throw CoreCatalogValidationError.duplicateFileRole
        }
        let paths = Set(files.map(\.relativePath))
        guard paths.count == files.count else {
            throw CoreCatalogValidationError.duplicateFilePath
        }
        guard roles == Set(CoreFileRole.allCases) else {
            throw CoreCatalogValidationError.missingRequiredFileRole
        }
        for file in files { try file.validate() }
        if status == .blocked || status == .withdrawn {
            guard let blockReason, !blockReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CoreCatalogValidationError.terminalEntryMissingReason
            }
            try CoreCatalogStringPolicy.validate(blockReason)
        } else if blockReason != nil {
            throw CoreCatalogValidationError.nonTerminalEntryHasReason
        }
    }

    func file(for role: CoreFileRole) -> CoreFileDescriptor? {
        files.first { $0.role == role }
    }
}

nonisolated struct CoreCatalog: Codable, Equatable, Sendable {
    static let supportedSchemaVersion = 1
    static let maximumEntries = 100

    let schemaVersion: Int
    let sequence: UInt64
    let generatedAt: Date
    let expiresAt: Date
    let catalogKeySetVersion: Int
    let entries: [CoreCatalogEntry]

    func validate() throws {
        guard schemaVersion == Self.supportedSchemaVersion else {
            throw CoreCatalogValidationError.unsupportedSchemaVersion(schemaVersion)
        }
        guard sequence > 0 else { throw CoreCatalogValidationError.invalidSequence }
        guard catalogKeySetVersion > 0 else {
            throw CoreCatalogValidationError.invalidKeySetVersion
        }
        guard expiresAt > generatedAt else {
            throw CoreCatalogValidationError.invalidValidityWindow
        }
        guard entries.count <= Self.maximumEntries else {
            throw CoreCatalogValidationError.tooManyEntries(entries.count)
        }
        guard Set(entries.map(\.coreID)).count == entries.count else {
            throw CoreCatalogValidationError.duplicateCoreID
        }
        guard entries.filter({ $0.status == .recommended }).count <= 1 else {
            throw CoreCatalogValidationError.multipleRecommendedEntries
        }
        for entry in entries { try entry.validate() }
    }

    var recommendedEntry: CoreCatalogEntry? {
        entries.first { $0.status == .recommended }
    }
}

nonisolated struct CoreCatalogSignature: Codable, Equatable, Sendable {
    let keyID: String
    let algorithm: String
    let signature: String

    func validate() throws {
        try CoreCatalogStringPolicy.validate(keyID, maximumBytes: 128)
        guard algorithm == "ed25519" else {
            throw CoreCatalogValidationError.unsupportedSignatureAlgorithm(algorithm)
        }
        guard let bytes = Data(base64Encoded: signature), bytes.count == 64 else {
            throw CoreCatalogValidationError.invalidSignatureEncoding
        }
    }
}

nonisolated struct CoreCatalogSignatureEnvelope: Codable, Equatable, Sendable {
    static let supportedSchemaVersion = 1

    let schemaVersion: Int
    let catalogSHA256: String
    let signatures: [CoreCatalogSignature]

    func validate() throws {
        guard schemaVersion == Self.supportedSchemaVersion else {
            throw CoreCatalogValidationError.unsupportedSignatureSchemaVersion(schemaVersion)
        }
        guard catalogSHA256.utf8.count == 64,
            catalogSHA256.utf8.allSatisfy({
                (48 ... 57).contains($0) || (97 ... 102).contains($0)
            })
        else {
            throw CoreCatalogValidationError.invalidSHA256(catalogSHA256)
        }
        guard (1 ... 8).contains(signatures.count) else {
            throw CoreCatalogValidationError.invalidSignatureCount(signatures.count)
        }
        guard Set(signatures.map(\.keyID)).count == signatures.count else {
            throw CoreCatalogValidationError.duplicateSignatureKey
        }
        for signature in signatures { try signature.validate() }
    }
}

nonisolated enum CoreCatalogURLPolicy {
    static let maximumBytes = 2_048

    static func validate(_ url: URL) throws {
        let value = url.absoluteString
        guard value.utf8.count <= maximumBytes,
            url.scheme?.lowercased() == "https",
            let host = url.host, !host.isEmpty,
            url.user == nil,
            url.password == nil,
            url.query == nil,
            url.fragment == nil
        else {
            throw CoreCatalogValidationError.invalidHTTPSURL(value)
        }
    }
}

nonisolated enum CoreCatalogStringPolicy {
    static func validate(_ value: String, maximumBytes: Int = 2_048) throws {
        guard !value.isEmpty,
            value.utf8.count <= maximumBytes,
            !value.unicodeScalars.contains(where: { $0.value < 0x20 && $0 != "\t" })
        else {
            throw CoreCatalogValidationError.invalidString
        }
    }
}

nonisolated enum CoreCatalogValidationError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
    case unsupportedSignatureSchemaVersion(Int)
    case invalidSequence
    case invalidKeySetVersion
    case invalidValidityWindow
    case tooManyEntries(Int)
    case duplicateCoreID
    case multipleRecommendedEntries
    case invalidPackageRevision
    case tooManyFiles(Int)
    case duplicateFileRole
    case duplicateFilePath
    case missingRequiredFileRole
    case invalidPath(role: CoreFileRole, value: String)
    case invalidMode(role: CoreFileRole, value: String)
    case invalidSize(role: CoreFileRole, value: UInt64)
    case invalidSHA256(String)
    case invalidHTTPSURL(String)
    case invalidUpstreamMetadata
    case invalidCompatibilityConstraints
    case terminalEntryMissingReason
    case nonTerminalEntryHasReason
    case invalidString
    case unsupportedSignatureAlgorithm(String)
    case invalidSignatureEncoding
    case invalidSignatureCount(Int)
    case duplicateSignatureKey
}
