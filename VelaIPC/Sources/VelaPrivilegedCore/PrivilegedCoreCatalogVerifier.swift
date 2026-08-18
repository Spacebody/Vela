import CryptoKit
import Foundation
import VelaIPC

public struct VerifiedCoreFile: Equatable, Sendable {
    public let role: CoreFileRole
    public let expectedSize: Int
    public let expectedSHA256: String
}

public enum VerifiedCoreCatalogStatus: String, Codable, Equatable, Sendable {
    case recommended
    case available
    case blocked
    case withdrawn
}

public struct VerifiedCoreCompatibilityConstraints: Codable, Equatable, Sendable {
    public let minimumVelaVersion: String
    public let minimumVelaBuild: UInt64
    public let maximumVelaBuild: UInt64?
    public let minimumMacOS: String
    public let architectures: [String]
    public let helperProtocolMinimum: Int
    public let helperProtocolMaximum: Int
    public let dataSchemaMinimum: Int
    public let dataSchemaMaximum: Int
    public let controllerAPIProfile: String
    public let bundleIdentifier: String
    public let compatibilitySuiteVersion: Int
    public let compatibilityReportSHA256: String

    public init(
        minimumVelaVersion: String,
        minimumVelaBuild: UInt64,
        maximumVelaBuild: UInt64?,
        minimumMacOS: String,
        architectures: [String],
        helperProtocolMinimum: Int,
        helperProtocolMaximum: Int,
        dataSchemaMinimum: Int,
        dataSchemaMaximum: Int,
        controllerAPIProfile: String,
        bundleIdentifier: String,
        compatibilitySuiteVersion: Int,
        compatibilityReportSHA256: String
    ) {
        self.minimumVelaVersion = minimumVelaVersion
        self.minimumVelaBuild = minimumVelaBuild
        self.maximumVelaBuild = maximumVelaBuild
        self.minimumMacOS = minimumMacOS
        self.architectures = architectures
        self.helperProtocolMinimum = helperProtocolMinimum
        self.helperProtocolMaximum = helperProtocolMaximum
        self.dataSchemaMinimum = dataSchemaMinimum
        self.dataSchemaMaximum = dataSchemaMaximum
        self.controllerAPIProfile = controllerAPIProfile
        self.bundleIdentifier = bundleIdentifier
        self.compatibilitySuiteVersion = compatibilitySuiteVersion
        self.compatibilityReportSHA256 = compatibilityReportSHA256
    }

    public static func current(coreVersion _: String) -> Self {
        Self(
            minimumVelaVersion: "0.6.0",
            minimumVelaBuild: 1,
            maximumVelaBuild: nil,
            minimumMacOS: "15.0",
            architectures: ["arm64"],
            helperProtocolMinimum: VelaIPCConstants.protocolMinimum,
            helperProtocolMaximum: VelaIPCConstants.protocolMaximum,
            dataSchemaMinimum: VelaIPCConstants.coreDataSchemaVersion,
            dataSchemaMaximum: VelaIPCConstants.coreDataSchemaVersion,
            controllerAPIProfile: VelaIPCConstants.currentControllerAPIProfile,
            bundleIdentifier: VelaIPCConstants.expectedExternalCoreSigningIdentifier,
            compatibilitySuiteVersion: 1,
            compatibilityReportSHA256: String(repeating: "0", count: 64)
        )
    }
}

public struct VerifiedCoreCatalogSelection: Equatable, Sendable {
    public let coreID: CoreID
    public let upstreamVersion: String
    public let packageRevision: Int
    public let sequence: UInt64
    public let catalogSHA256: String
    public let status: VerifiedCoreCatalogStatus
    public let blockReason: String?
    public let compatibility: VerifiedCoreCompatibilityConstraints
    public let files: [VerifiedCoreFile]

    public init(
        coreID: CoreID,
        upstreamVersion: String,
        packageRevision: Int,
        sequence: UInt64,
        catalogSHA256: String,
        status: VerifiedCoreCatalogStatus = .recommended,
        blockReason: String? = nil,
        compatibility: VerifiedCoreCompatibilityConstraints? = nil,
        files: [VerifiedCoreFile]
    ) {
        self.coreID = coreID
        self.upstreamVersion = upstreamVersion
        self.packageRevision = packageRevision
        self.sequence = sequence
        self.catalogSHA256 = catalogSHA256
        self.status = status
        self.blockReason = blockReason
        self.compatibility = compatibility ?? .current(coreVersion: upstreamVersion)
        self.files = files
    }
}

public struct VerifiedCoreCatalogPolicyUpdate: Equatable, Sendable {
    public let sequence: UInt64
    public let catalogSHA256: String
    public let selections: [VerifiedCoreCatalogSelection]
}

public enum PrivilegedCoreCompatibilityPolicy {
    public static func isSatisfied(
        _ constraints: VerifiedCoreCompatibilityConstraints
    ) -> Bool {
        guard let currentBuild = UInt64(VelaIPCConstants.helperBuild),
            compareNumericVersions(
                VelaIPCConstants.helperSemanticVersion,
                constraints.minimumVelaVersion
            ) != .orderedAscending,
            currentBuild >= constraints.minimumVelaBuild,
            constraints.maximumVelaBuild.map({ currentBuild <= $0 }) ?? true,
            (constraints.helperProtocolMinimum ... constraints.helperProtocolMaximum)
                .contains(VelaIPCConstants.protocolMaximum),
            (constraints.dataSchemaMinimum ... constraints.dataSchemaMaximum)
                .contains(VelaIPCConstants.coreDataSchemaVersion),
            constraints.architectures.contains("arm64"),
            constraints.bundleIdentifier
                == VelaIPCConstants.expectedExternalCoreSigningIdentifier,
            VelaIPCConstants.supportedControllerAPIProfiles.contains(
                constraints.controllerAPIProfile
            ),
            constraints.compatibilitySuiteVersion
                == VelaIPCConstants.coreCompatibilitySuiteVersion,
            isSupportedMinimumMacOS(constraints.minimumMacOS)
        else { return false }
        return true
    }

    static func numericVersion(_ value: String) -> [Int]? {
        let normalized = value.hasPrefix("v") ? String(value.dropFirst()) : value
        let fields = normalized.split(separator: ".", omittingEmptySubsequences: false)
        guard (2 ... 4).contains(fields.count) else { return nil }
        var result: [Int] = []
        for field in fields {
            guard !field.isEmpty,
                field == "0" || field.first != "0",
                field.utf8.allSatisfy({ (48 ... 57).contains($0) }),
                let integer = Int(field)
            else { return nil }
            result.append(integer)
        }
        return result
    }

    private static func compareNumericVersions(
        _ lhs: String,
        _ rhs: String
    ) -> ComparisonResult {
        guard let left = numericVersion(lhs), let right = numericVersion(rhs) else {
            return .orderedAscending
        }
        for index in 0 ..< max(left.count, right.count) {
            let leftValue = index < left.count ? left[index] : 0
            let rightValue = index < right.count ? right[index] : 0
            if leftValue < rightValue { return .orderedAscending }
            if leftValue > rightValue { return .orderedDescending }
        }
        return .orderedSame
    }

    private static func isSupportedMinimumMacOS(_ value: String) -> Bool {
        guard let fields = numericVersion(value), (2 ... 3).contains(fields.count) else {
            return false
        }
        return ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(
                majorVersion: fields[0],
                minorVersion: fields[1],
                patchVersion: fields.count == 3 ? fields[2] : 0
            )
        )
    }
}

public protocol PrivilegedCoreCatalogVerifying: Sendable {
    func verify(
        rawCatalog: Data,
        signatureEnvelope: Data,
        selectedCoreID: CoreID,
        highestAcceptedSequence: UInt64,
        highestAcceptedSHA256: String?
    ) throws -> VerifiedCoreCatalogSelection

    func verifyInstalledEvidence(
        rawCatalog: Data,
        signatureEnvelope: Data,
        selectedCoreID: CoreID,
        expectedSequence: UInt64,
        expectedSHA256: String
    ) throws -> VerifiedCoreCatalogSelection

    func verifyPolicyRefresh(
        rawCatalog: Data,
        signatureEnvelope: Data,
        installedCoreIDs: Set<CoreID>,
        highestAcceptedSequence: UInt64,
        highestAcceptedSHA256: String?
    ) throws -> VerifiedCoreCatalogPolicyUpdate
}

public extension PrivilegedCoreCatalogVerifying {
    func verifyInstalledEvidence(
        rawCatalog: Data,
        signatureEnvelope: Data,
        selectedCoreID: CoreID,
        expectedSequence: UInt64,
        expectedSHA256: String
    ) throws -> VerifiedCoreCatalogSelection {
        let selection = try verify(
            rawCatalog: rawCatalog,
            signatureEnvelope: signatureEnvelope,
            selectedCoreID: selectedCoreID,
            highestAcceptedSequence: expectedSequence,
            highestAcceptedSHA256: expectedSHA256
        )
        guard selection.sequence == expectedSequence,
            selection.catalogSHA256 == expectedSHA256
        else { throw PrivilegedCoreCatalogError.evidenceMismatch }
        return selection
    }

    func verifyPolicyRefresh(
        rawCatalog _: Data,
        signatureEnvelope _: Data,
        installedCoreIDs _: Set<CoreID>,
        highestAcceptedSequence _: UInt64,
        highestAcceptedSHA256 _: String?
    ) throws -> VerifiedCoreCatalogPolicyUpdate {
        throw PrivilegedCoreCatalogError.unsupportedVerificationMode
    }
}

public struct PrivilegedCoreCatalogVerifier: PrivilegedCoreCatalogVerifying, Sendable {
    private let trustRoots: [CoreCatalogTrustRoot]
    private let keySetVersion: Int
    private let now: @Sendable () -> Date

    public init(
        trustRoots: [CoreCatalogTrustRoot] = VelaCoreCatalogTrustRoots.all,
        keySetVersion: Int = VelaCoreCatalogTrustRoots.version,
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.trustRoots = trustRoots
        self.keySetVersion = keySetVersion
        self.now = now
    }

    public func verify(
        rawCatalog: Data,
        signatureEnvelope: Data,
        selectedCoreID: CoreID,
        highestAcceptedSequence: UInt64,
        highestAcceptedSHA256: String?
    ) throws -> VerifiedCoreCatalogSelection {
        let verified = try verifyCatalog(
            rawCatalog: rawCatalog,
            signatureEnvelope: signatureEnvelope,
            freshness: .current,
            highestAcceptedSequence: highestAcceptedSequence,
            highestAcceptedSHA256: highestAcceptedSHA256
        )
        guard !selectedCoreID.isFactory,
            let selection = verified.selections.first(where: { $0.coreID == selectedCoreID })
        else { throw PrivilegedCoreCatalogError.coreNotPresent }
        guard selection.status == .recommended || selection.status == .available else {
            throw PrivilegedCoreCatalogError.coreBlocked
        }
        guard PrivilegedCoreCompatibilityPolicy.isSatisfied(selection.compatibility) else {
            throw PrivilegedCoreCatalogError.coreIncompatible
        }
        return selection
    }

    public func verifyInstalledEvidence(
        rawCatalog: Data,
        signatureEnvelope: Data,
        selectedCoreID: CoreID,
        expectedSequence: UInt64,
        expectedSHA256: String
    ) throws -> VerifiedCoreCatalogSelection {
        let verified = try verifyCatalog(
            rawCatalog: rawCatalog,
            signatureEnvelope: signatureEnvelope,
            freshness: .installedEvidence,
            highestAcceptedSequence: nil,
            highestAcceptedSHA256: nil
        )
        guard verified.sequence == expectedSequence,
            verified.catalogSHA256 == expectedSHA256,
            let selection = verified.selections.first(where: { $0.coreID == selectedCoreID })
        else { throw PrivilegedCoreCatalogError.evidenceMismatch }
        return selection
    }

    public func verifyPolicyRefresh(
        rawCatalog: Data,
        signatureEnvelope: Data,
        installedCoreIDs: Set<CoreID>,
        highestAcceptedSequence: UInt64,
        highestAcceptedSHA256: String?
    ) throws -> VerifiedCoreCatalogPolicyUpdate {
        let verified = try verifyCatalog(
            rawCatalog: rawCatalog,
            signatureEnvelope: signatureEnvelope,
            freshness: .current,
            highestAcceptedSequence: highestAcceptedSequence,
            highestAcceptedSHA256: highestAcceptedSHA256
        )
        return VerifiedCoreCatalogPolicyUpdate(
            sequence: verified.sequence,
            catalogSHA256: verified.catalogSHA256,
            selections: verified.selections.filter { installedCoreIDs.contains($0.coreID) }
        )
    }

    private func verifyCatalog(
        rawCatalog: Data,
        signatureEnvelope: Data,
        freshness: CatalogFreshness,
        highestAcceptedSequence: UInt64?,
        highestAcceptedSHA256: String?
    ) throws -> VerifiedCoreCatalogPolicyUpdate {
        guard rawCatalog.count <= VelaIPCConstants.maximumCoreCatalogBytes,
            signatureEnvelope.count <= VelaIPCConstants.maximumCoreSignatureEnvelopeBytes
        else { throw PrivilegedCoreCatalogError.sizeLimit }

        // Authenticate the exact bytes before decoding any Catalog-controlled
        // JSON. Installed evidence deliberately ignores Catalog/current-key
        // expiry, but it still uses the Helper's current keyring and rejects a
        // root now marked revoked.
        let envelopeObject = try strictJSONObject(signatureEnvelope)
        try validateObjectKeys(
            envelopeObject,
            exactly: ["schemaVersion", "catalogSHA256", "signatures"]
        )
        try validateSignatureObjects(envelopeObject)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope = try decoder.decode(SignatureEnvelope.self, from: signatureEnvelope)
        guard envelope.schemaVersion == 1,
            (1 ... 8).contains(envelope.signatures.count),
            Set(envelope.signatures.map(\.keyID)).count == envelope.signatures.count
        else { throw PrivilegedCoreCatalogError.invalidEnvelope }
        let digest = IntegrityValue.sha256Hex(of: rawCatalog)
        guard try IntegrityValue.normalizedSHA256(envelope.catalogSHA256) == digest else {
            throw PrivilegedCoreCatalogError.catalogHashMismatch
        }
        let verificationInstant = now()
        let acceptedRoots = try verifyAtLeastOneSignature(
            envelope.signatures,
            rawCatalog: rawCatalog,
            currentValidityAt: freshness == .current ? verificationInstant : nil
        )

        let catalogObject = try strictJSONObject(rawCatalog)
        try validateObjectKeys(
            catalogObject,
            exactly: [
                "schemaVersion", "sequence", "generatedAt", "expiresAt",
                "catalogKeySetVersion", "entries",
            ]
        )
        try validateNestedCatalogObjects(catalogObject)
        let catalog = try decoder.decode(Catalog.self, from: rawCatalog)
        guard catalog.schemaVersion == 1,
            catalog.sequence > 0,
            catalog.catalogKeySetVersion > 0,
            catalog.catalogKeySetVersion <= keySetVersion,
            !catalog.entries.isEmpty,
            catalog.entries.count <= 100,
            catalog.expiresAt > catalog.generatedAt,
            catalog.entries.filter({ $0.status == .recommended }).count <= 1
        else { throw PrivilegedCoreCatalogError.invalidCatalog }
        guard acceptedRoots.contains(where: { root in
            catalog.generatedAt >= root.notBefore
                && (root.notAfter.map { catalog.generatedAt <= $0 } ?? true)
        }) else { throw PrivilegedCoreCatalogError.signatureRejected }
        if freshness == .current {
            guard catalog.generatedAt <= verificationInstant.addingTimeInterval(5 * 60),
                catalog.expiresAt > verificationInstant
            else { throw PrivilegedCoreCatalogError.invalidCatalog }
        }
        if let highestAcceptedSequence {
            if catalog.sequence < highestAcceptedSequence {
                throw PrivilegedCoreCatalogError.replayedSequence
            }
            if catalog.sequence == highestAcceptedSequence,
                let highestAcceptedSHA256,
                highestAcceptedSHA256 != digest
            {
                throw PrivilegedCoreCatalogError.equivocatedSequence
            }
        }

        var seen = Set<CoreID>()
        for entry in catalog.entries {
            try validateEntry(entry, generatedAt: catalog.generatedAt)
            guard seen.insert(entry.coreID).inserted else {
                throw PrivilegedCoreCatalogError.invalidCatalog
            }
        }
        return VerifiedCoreCatalogPolicyUpdate(
            sequence: catalog.sequence,
            catalogSHA256: digest,
            selections: catalog.entries.map {
                selection(from: $0, sequence: catalog.sequence, digest: digest)
            }
        )
    }

    private func verifyAtLeastOneSignature(
        _ signatures: [SignatureRecord],
        rawCatalog: Data,
        currentValidityAt instant: Date?
    ) throws -> [CoreCatalogTrustRoot] {
        var acceptedRoots: [CoreCatalogTrustRoot] = []
        for signature in signatures {
            guard signature.algorithm == "ed25519",
                signature.keyID.utf8.count <= 128,
                let bytes = Data(base64Encoded: signature.signature),
                bytes.count == 64,
                let root = trustRoots.first(where: { $0.keyID == signature.keyID }),
                root.status != .revoked,
                instant.map({ $0 >= root.notBefore }) ?? true,
                instant.map({ value in root.notAfter.map({ value <= $0 }) ?? true }) ?? true,
                let key = try? root.publicKey(),
                key.isValidSignature(bytes, for: rawCatalog)
            else { continue }
            acceptedRoots.append(root)
        }
        guard !acceptedRoots.isEmpty else {
            throw PrivilegedCoreCatalogError.signatureRejected
        }
        return acceptedRoots
    }

    private func validateEntry(_ entry: CatalogEntry, generatedAt: Date) throws {
        guard !entry.coreID.isFactory,
            entry.upstreamVersion == entry.coreID.upstreamVersion,
            entry.packageRevision == entry.coreID.packageRevision,
            entry.packageRevision > 0,
            entry.files.count == CoreFileRole.allCases.count,
            entry.vela.bundleIdentifier == VelaIPCConstants.expectedExternalCoreSigningIdentifier,
            entry.vela.architectures == ["arm64"],
            entry.vela.minimumVelaBuild > 0,
            entry.vela.maximumVelaBuild.map({ $0 >= entry.vela.minimumVelaBuild }) ?? true,
            entry.vela.helperProtocolMinimum > 0,
            entry.vela.helperProtocolMaximum >= entry.vela.helperProtocolMinimum,
            entry.vela.dataSchemaMinimum > 0,
            entry.vela.dataSchemaMaximum >= entry.vela.dataSchemaMinimum,
            VelaIPCConstants.supportedControllerAPIProfiles.contains(
                entry.vela.controllerAPIProfile
            ),
            entry.vela.compatibilitySuiteVersion > 0,
            (try? IntegrityValue.normalizedSHA256(
                entry.vela.compatibilityReportSHA256
            )) == entry.vela.compatibilityReportSHA256,
            entry.publishedAt <= generatedAt.addingTimeInterval(5 * 60),
            isValidIncidentReason(entry.blockReason, for: entry.status),
            entry.releaseNotesURL.absoluteString.utf8.count <= 2_048,
            isSafeHTTPS(entry.releaseNotesURL),
            PrivilegedCoreCompatibilityPolicy.numericVersion(
                entry.vela.minimumVelaVersion
            ) != nil,
            PrivilegedCoreCompatibilityPolicy.numericVersion(entry.vela.minimumMacOS) != nil,
            isSafeHTTPS(entry.upstream.repositoryURL),
            isSafeHTTPS(entry.upstream.assetURL),
            isSafeHTTPS(entry.upstream.sourceURL),
            (try? IntegrityValue.normalizedSHA256(entry.upstream.archiveSHA256))
                == entry.upstream.archiveSHA256,
            entry.upstream.archiveSizeBytes > 0,
            entry.upstream.archiveSizeBytes <= VelaIPCConstants.maximumMihomoExecutableBytes
        else { throw PrivilegedCoreCatalogError.invalidEntry }

        var roles = Set<CoreFileRole>()
        var total = 0
        for file in entry.files {
            guard roles.insert(file.role).inserted,
                file.relativePath == file.role.requiredRelativePath,
                file.mode == file.role.requiredPublishedMode,
                file.size > 0,
                file.size <= file.role.maximumBytes,
                (try? IntegrityValue.normalizedSHA256(file.sha256)) == file.sha256,
                file.url.absoluteString.utf8.count <= 2_048,
                isSafeHTTPS(file.url)
            else { throw PrivilegedCoreCatalogError.invalidEntry }
            let sum = total.addingReportingOverflow(file.size)
            guard !sum.overflow, sum.partialValue <= VelaIPCConstants.maximumCoreTotalBytes else {
                throw PrivilegedCoreCatalogError.sizeLimit
            }
            total = sum.partialValue
        }
        guard roles == Set(CoreFileRole.allCases) else {
            throw PrivilegedCoreCatalogError.invalidEntry
        }
    }

    private func selection(
        from entry: CatalogEntry,
        sequence: UInt64,
        digest: String
    ) -> VerifiedCoreCatalogSelection {
        let verifiedStatus: VerifiedCoreCatalogStatus = switch entry.status {
        case .recommended: .recommended
        case .available: .available
        case .blocked: .blocked
        case .withdrawn: .withdrawn
        }
        return VerifiedCoreCatalogSelection(
            coreID: entry.coreID,
            upstreamVersion: entry.upstreamVersion,
            packageRevision: entry.packageRevision,
            sequence: sequence,
            catalogSHA256: digest,
            status: verifiedStatus,
            blockReason: entry.blockReason,
            compatibility: VerifiedCoreCompatibilityConstraints(
                minimumVelaVersion: entry.vela.minimumVelaVersion,
                minimumVelaBuild: entry.vela.minimumVelaBuild,
                maximumVelaBuild: entry.vela.maximumVelaBuild,
                minimumMacOS: entry.vela.minimumMacOS,
                architectures: entry.vela.architectures,
                helperProtocolMinimum: entry.vela.helperProtocolMinimum,
                helperProtocolMaximum: entry.vela.helperProtocolMaximum,
                dataSchemaMinimum: entry.vela.dataSchemaMinimum,
                dataSchemaMaximum: entry.vela.dataSchemaMaximum,
                controllerAPIProfile: entry.vela.controllerAPIProfile,
                bundleIdentifier: entry.vela.bundleIdentifier,
                compatibilitySuiteVersion: entry.vela.compatibilitySuiteVersion,
                compatibilityReportSHA256: entry.vela.compatibilityReportSHA256
            ),
            files: entry.files.map {
                VerifiedCoreFile(
                    role: $0.role,
                    expectedSize: $0.size,
                    expectedSHA256: $0.sha256
                )
            }
        )
    }

    private func strictJSONObject(_ data: Data) throws -> [String: Any] {
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw PrivilegedCoreCatalogError.invalidJSON
        }
        guard let object = value as? [String: Any] else {
            throw PrivilegedCoreCatalogError.invalidJSON
        }
        return object
    }

    private func validateObjectKeys(_ object: [String: Any], exactly: Set<String>) throws {
        guard Set(object.keys) == exactly else { throw PrivilegedCoreCatalogError.invalidJSON }
    }

    private func validateSignatureObjects(_ envelope: [String: Any]) throws {
        guard let signatures = envelope["signatures"] as? [[String: Any]],
            !signatures.isEmpty,
            signatures.count <= 8
        else { throw PrivilegedCoreCatalogError.invalidJSON }
        for signature in signatures {
            try validateObjectKeys(
                signature,
                exactly: ["keyID", "algorithm", "signature"]
            )
        }
    }

    private func validateNestedCatalogObjects(_ catalog: [String: Any]) throws {
        guard let entries = catalog["entries"] as? [[String: Any]],
            entries.count <= 100
        else { throw PrivilegedCoreCatalogError.invalidJSON }
        for entry in entries {
            let requiredEntryKeys: Set<String> = [
                    "coreID", "upstreamVersion", "packageRevision", "status",
                    "publishedAt", "releaseNotesURL", "upstream", "vela", "files",
                ]
            let entryKeys = Set(entry.keys)
            guard requiredEntryKeys.isSubset(of: entryKeys),
                entryKeys.isSubset(of: requiredEntryKeys.union(["blockReason"]))
            else { throw PrivilegedCoreCatalogError.invalidJSON }
            guard let upstream = entry["upstream"] as? [String: Any],
                let vela = entry["vela"] as? [String: Any],
                let files = entry["files"] as? [[String: Any]],
                files.count <= 16
            else { throw PrivilegedCoreCatalogError.invalidJSON }
            try validateObjectKeys(
                upstream,
                exactly: [
                    "repositoryURL", "tag", "commit", "assetName", "assetURL",
                    "archiveSHA256", "archiveSizeBytes", "sourceURL", "license",
                ]
            )
            try validateObjectKeys(
                vela,
                exactly: [
                    "minimumVelaVersion", "minimumVelaBuild", "maximumVelaBuild",
                    "minimumMacOS", "architectures", "helperProtocolMinimum",
                    "helperProtocolMaximum", "dataSchemaMinimum", "dataSchemaMaximum",
                    "controllerAPIProfile", "bundleIdentifier",
                    "compatibilitySuiteVersion", "compatibilityReportSHA256",
                ]
            )
            for file in files {
                try validateObjectKeys(
                    file,
                    exactly: ["role", "relativePath", "mode", "size", "sha256", "url"]
                )
            }
        }
    }

    private func isSafeHTTPS(_ url: URL) -> Bool {
        url.absoluteString.utf8.count <= 2_048
            && url.scheme?.lowercased() == "https"
            && url.host?.isEmpty == false
            && url.user == nil
            && url.password == nil
            && url.query == nil
            && url.fragment == nil
    }

    private func isValidIncidentReason(
        _ reason: String?,
        for status: CatalogEntry.Status
    ) -> Bool {
        switch status {
        case .blocked, .withdrawn:
            guard let reason else { return false }
            let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmed.isEmpty
                && reason.utf8.count <= 2_048
                && !reason.unicodeScalars.contains(where: {
                    $0.value < 0x20 && $0 != "\t"
                })
        case .recommended, .available:
            return reason == nil
        }
    }

}

private enum CatalogFreshness: Equatable {
    case current
    case installedEvidence
}

extension CoreFileRole {
    public var requiredRelativePath: String {
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

    public var requiredPublishedMode: String { self == .executable ? "0755" : "0644" }

    public var maximumBytes: Int {
        switch self {
        case .executable: VelaIPCConstants.maximumMihomoExecutableBytes
        case .license: 2 * 1_024 * 1_024
        case .notice, .source, .compatibility: 4 * 1_024 * 1_024
        case .infoPlist, .codeResources: 8 * 1_024 * 1_024
        }
    }
}

private struct SignatureEnvelope: Decodable {
    let schemaVersion: Int
    let catalogSHA256: String
    let signatures: [SignatureRecord]
}

private struct SignatureRecord: Decodable {
    let keyID: String
    let algorithm: String
    let signature: String
}

private struct Catalog: Decodable {
    let schemaVersion: Int
    let sequence: UInt64
    let generatedAt: Date
    let expiresAt: Date
    let catalogKeySetVersion: Int
    let entries: [CatalogEntry]
}

private struct CatalogEntry: Decodable {
    enum Status: String, Decodable { case recommended, available, blocked, withdrawn }
    let coreID: CoreID
    let upstreamVersion: String
    let packageRevision: Int
    let status: Status
    let publishedAt: Date
    let releaseNotesURL: URL
    let upstream: CatalogUpstream
    let vela: CatalogCompatibility
    let files: [CatalogFile]
    let blockReason: String?
}

private struct CatalogFile: Decodable {
    let role: CoreFileRole
    let relativePath: String
    let mode: String
    let size: Int
    let sha256: String
    let url: URL
}

private struct CatalogCompatibility: Decodable {
    let minimumVelaVersion: String
    let minimumVelaBuild: UInt64
    let maximumVelaBuild: UInt64?
    let minimumMacOS: String
    let architectures: [String]
    let helperProtocolMinimum: Int
    let helperProtocolMaximum: Int
    let dataSchemaMinimum: Int
    let dataSchemaMaximum: Int
    let controllerAPIProfile: String
    let bundleIdentifier: String
    let compatibilitySuiteVersion: Int
    let compatibilityReportSHA256: String
}

private struct CatalogUpstream: Decodable {
    let repositoryURL: URL
    let tag: String
    let commit: String
    let assetName: String
    let assetURL: URL
    let archiveSHA256: String
    let archiveSizeBytes: Int
    let sourceURL: URL
    let license: String
}

public enum PrivilegedCoreCatalogError: Error, Equatable, Sendable {
    case sizeLimit
    case invalidJSON
    case invalidEnvelope
    case catalogHashMismatch
    case signatureRejected
    case invalidCatalog
    case replayedSequence
    case equivocatedSequence
    case invalidEntry
    case coreNotPresent
    case coreBlocked
    case coreIncompatible
    case evidenceMismatch
    case unsupportedVerificationMode
}
