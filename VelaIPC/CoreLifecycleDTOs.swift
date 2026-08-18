import Foundation

/// The only core identifier accepted across the App/Helper trust boundary.
///
/// Factory identifiers are `factory:v<major>.<minor>.<patch>`. Catalog-backed
/// identifiers are `v<major>.<minor>.<patch>-r<positive revision>`. Keeping the
/// grammar here prevents an identifier from becoming a path component or an
/// open-ended executable selector inside the root Helper.
public struct CoreID: RawRepresentable, Codable, Hashable, Sendable,
    CustomStringConvertible
{
    public let rawValue: String
    public let upstreamVersion: String
    public let packageRevision: Int?

    public var isFactory: Bool { packageRevision == nil }
    public var description: String { rawValue }
    public static let factoryV11928 = CoreID(trustedFactoryVersion: "v1.19.28")

    private init(trustedFactoryVersion: String) {
        rawValue = "factory:\(trustedFactoryVersion)"
        upstreamVersion = trustedFactoryVersion
        packageRevision = nil
    }

    public init?(rawValue: String) {
        if rawValue.hasPrefix("factory:") {
            let version = String(rawValue.dropFirst("factory:".count))
            guard Self.isCanonicalVersion(version) else { return nil }
            self.rawValue = rawValue
            upstreamVersion = version
            packageRevision = nil
            return
        }

        guard let marker = rawValue.range(of: "-r", options: .backwards),
            marker.lowerBound > rawValue.startIndex,
            marker.upperBound < rawValue.endIndex
        else { return nil }
        let version = String(rawValue[..<marker.lowerBound])
        let revisionText = String(rawValue[marker.upperBound...])
        guard Self.isCanonicalVersion(version),
            !revisionText.hasPrefix("0"),
            revisionText.utf8.allSatisfy({ (48...57).contains($0) }),
            let revision = Int(revisionText),
            revision > 0
        else { return nil }
        self.rawValue = rawValue
        upstreamVersion = version
        packageRevision = revision
    }

    public static func factory(version: String) throws -> CoreID {
        guard let value = CoreID(rawValue: "factory:\(version)") else {
            throw CoreIDError.invalid
        }
        return value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let value = CoreID(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "The core identifier is not canonical."
            )
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    private static func isCanonicalVersion(_ value: String) -> Bool {
        guard value.first == "v" else { return false }
        let components = value.dropFirst().split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3 else { return false }
        return components.allSatisfy { component in
            !component.isEmpty
                && (component == "0" || component.first != "0")
                && component.utf8.allSatisfy { (48...57).contains($0) }
                && Int(component) != nil
        }
    }
}

public enum CoreIDError: Error, Equatable, Sendable { case invalid }

/// The seven and only seven files accepted by the root Core Store. No path or
/// mode is transported over XPC; both are compiled into the Helper.
public enum CoreFileRole: String, Codable, CaseIterable, Sendable {
    case infoPlist
    case executable
    case codeResources
    case license
    case notice
    case source
    case compatibility
}

public struct PrepareCoreInstallRequest: HelperPayload, Equatable {
    public static let allowedKeys: Set<String> = [
        "schemaVersion", "requestID", "sessionID", "transactionID", "ownerUID",
        "rawCatalogData", "signatureEnvelopeData", "selectedCoreID",
    ]

    public let schemaVersion: Int
    public let requestID: UUID
    public let sessionID: UUID
    public let transactionID: UUID
    public let ownerUID: UInt32
    public let rawCatalogData: Data
    public let signatureEnvelopeData: Data
    public let selectedCoreID: CoreID

    public init(
        schemaVersion: Int = VelaIPCConstants.schemaVersion,
        requestID: UUID = UUID(),
        sessionID: UUID,
        transactionID: UUID = UUID(),
        ownerUID: UInt32,
        rawCatalogData: Data,
        signatureEnvelopeData: Data,
        selectedCoreID: CoreID
    ) {
        self.schemaVersion = schemaVersion
        self.requestID = requestID
        self.sessionID = sessionID
        self.transactionID = transactionID
        self.ownerUID = ownerUID
        self.rawCatalogData = rawCatalogData
        self.signatureEnvelopeData = signatureEnvelopeData
        self.selectedCoreID = selectedCoreID
    }
}

public struct PrepareCoreInstallResponse: HelperPayload, Equatable {
    public static let allowedKeys: Set<String> = [
        "schemaVersion", "requestID", "transactionID", "coreID", "requiredRoles",
    ]
    public let schemaVersion: Int
    public let requestID: UUID
    public let transactionID: UUID
    public let coreID: CoreID
    public let requiredRoles: [CoreFileRole]

    public init(
        schemaVersion: Int = VelaIPCConstants.schemaVersion,
        requestID: UUID,
        transactionID: UUID,
        coreID: CoreID,
        requiredRoles: [CoreFileRole]
    ) {
        self.schemaVersion = schemaVersion
        self.requestID = requestID
        self.transactionID = transactionID
        self.coreID = coreID
        self.requiredRoles = requiredRoles
    }
}

public struct StageCoreFileRequest: HelperPayload, Equatable {
    public static let allowedKeys: Set<String> = [
        "schemaVersion", "requestID", "sessionID", "transactionID", "role",
        "expectedSize", "expectedSHA256",
    ]
    public let schemaVersion: Int
    public let requestID: UUID
    public let sessionID: UUID
    public let transactionID: UUID
    public let role: CoreFileRole
    public let expectedSize: Int
    public let expectedSHA256: String

    public init(
        schemaVersion: Int = VelaIPCConstants.schemaVersion,
        requestID: UUID = UUID(),
        sessionID: UUID,
        transactionID: UUID,
        role: CoreFileRole,
        expectedSize: Int,
        expectedSHA256: String
    ) {
        self.schemaVersion = schemaVersion
        self.requestID = requestID
        self.sessionID = sessionID
        self.transactionID = transactionID
        self.role = role
        self.expectedSize = expectedSize
        self.expectedSHA256 = expectedSHA256
    }
}

public struct CommitCoreInstallRequest: HelperPayload, Equatable {
    public static let allowedKeys: Set<String> = [
        "schemaVersion", "requestID", "sessionID", "transactionID",
    ]
    public let schemaVersion: Int
    public let requestID: UUID
    public let sessionID: UUID
    public let transactionID: UUID

    public init(
        schemaVersion: Int = VelaIPCConstants.schemaVersion,
        requestID: UUID = UUID(),
        sessionID: UUID,
        transactionID: UUID
    ) {
        self.schemaVersion = schemaVersion
        self.requestID = requestID
        self.sessionID = sessionID
        self.transactionID = transactionID
    }
}

public typealias AbortCoreInstallRequest = CommitCoreInstallRequest

public struct ListInstalledCoresRequest: HelperPayload, Equatable {
    public static let allowedKeys: Set<String> = ["schemaVersion", "requestID", "sessionID"]
    public let schemaVersion: Int
    public let requestID: UUID
    public let sessionID: UUID

    public init(
        schemaVersion: Int = VelaIPCConstants.schemaVersion,
        requestID: UUID = UUID(),
        sessionID: UUID
    ) {
        self.schemaVersion = schemaVersion
        self.requestID = requestID
        self.sessionID = sessionID
    }
}

/// Refreshes only Helper-owned signed policy/checkpoint state. The request has
/// no URL, path, executable, shell, PID, ownership, or mode capability.
public struct RefreshCoreCatalogRequest: HelperPayload, Equatable {
    public static let allowedKeys: Set<String> = [
        "schemaVersion", "requestID", "sessionID", "rawCatalogData",
        "signatureEnvelopeData",
    ]
    public let schemaVersion: Int
    public let requestID: UUID
    public let sessionID: UUID
    public let rawCatalogData: Data
    public let signatureEnvelopeData: Data

    public init(
        schemaVersion: Int = VelaIPCConstants.schemaVersion,
        requestID: UUID = UUID(),
        sessionID: UUID,
        rawCatalogData: Data,
        signatureEnvelopeData: Data
    ) {
        self.schemaVersion = schemaVersion
        self.requestID = requestID
        self.sessionID = sessionID
        self.rawCatalogData = rawCatalogData
        self.signatureEnvelopeData = signatureEnvelopeData
    }
}

public struct RefreshCoreCatalogResponse: HelperPayload, Equatable {
    public static let allowedKeys: Set<String> = [
        "schemaVersion", "requestID", "acceptedSequence", "catalogSHA256",
        "updatedCoreIDs",
    ]
    public let schemaVersion: Int
    public let requestID: UUID
    public let acceptedSequence: UInt64
    public let catalogSHA256: String
    public let updatedCoreIDs: [CoreID]

    public init(
        schemaVersion: Int = VelaIPCConstants.schemaVersion,
        requestID: UUID,
        acceptedSequence: UInt64,
        catalogSHA256: String,
        updatedCoreIDs: [CoreID]
    ) {
        self.schemaVersion = schemaVersion
        self.requestID = requestID
        self.acceptedSequence = acceptedSequence
        self.catalogSHA256 = catalogSHA256
        self.updatedCoreIDs = updatedCoreIDs
    }
}

public struct InstalledCoreDescriptor: Codable, Equatable, Sendable {
    public static let allowedKeys: Set<String> = [
        "coreID", "upstreamVersion", "packageRevision", "catalogSequence",
        "installedAt", "lastValidatedAt",
    ]
    public let coreID: CoreID
    public let upstreamVersion: String
    public let packageRevision: Int
    public let catalogSequence: UInt64
    public let installedAt: Date
    public let lastValidatedAt: Date

    public init(
        coreID: CoreID,
        upstreamVersion: String,
        packageRevision: Int,
        catalogSequence: UInt64,
        installedAt: Date,
        lastValidatedAt: Date
    ) {
        self.coreID = coreID
        self.upstreamVersion = upstreamVersion
        self.packageRevision = packageRevision
        self.catalogSequence = catalogSequence
        self.installedAt = installedAt
        self.lastValidatedAt = lastValidatedAt
    }
}

public struct ListInstalledCoresResponse: HelperPayload, Equatable {
    public static let allowedKeys: Set<String> = [
        "schemaVersion", "requestID", "cores", "activeCoreID", "previousCoreID",
        "highestCatalogSequence",
    ]
    public static let nestedArrayObjectAllowedKeys: [String: Set<String>] = [
        "cores": InstalledCoreDescriptor.allowedKeys
    ]
    public let schemaVersion: Int
    public let requestID: UUID
    public let cores: [InstalledCoreDescriptor]
    public let activeCoreID: CoreID?
    public let previousCoreID: CoreID?
    public let highestCatalogSequence: UInt64

    public init(
        schemaVersion: Int = VelaIPCConstants.schemaVersion,
        requestID: UUID,
        cores: [InstalledCoreDescriptor],
        activeCoreID: CoreID?,
        previousCoreID: CoreID?,
        highestCatalogSequence: UInt64
    ) {
        self.schemaVersion = schemaVersion
        self.requestID = requestID
        self.cores = cores
        self.activeCoreID = activeCoreID
        self.previousCoreID = previousCoreID
        self.highestCatalogSequence = highestCatalogSequence
    }
}

public struct CoreIDRequest: HelperPayload, Equatable {
    public static let allowedKeys: Set<String> = [
        "schemaVersion", "requestID", "sessionID", "coreID",
    ]
    public let schemaVersion: Int
    public let requestID: UUID
    public let sessionID: UUID
    public let coreID: CoreID

    public init(
        schemaVersion: Int = VelaIPCConstants.schemaVersion,
        requestID: UUID = UUID(),
        sessionID: UUID,
        coreID: CoreID
    ) {
        self.schemaVersion = schemaVersion
        self.requestID = requestID
        self.sessionID = sessionID
        self.coreID = coreID
    }
}

public typealias RemoveCoreRequest = CoreIDRequest
public typealias ValidateCoreRequest = CoreIDRequest

public struct ValidateCoreResponse: HelperPayload, Equatable {
    public static let allowedKeys: Set<String> = [
        "schemaVersion", "requestID", "coreID", "valid", "validatedAt",
    ]
    public let schemaVersion: Int
    public let requestID: UUID
    public let coreID: CoreID
    public let valid: Bool
    public let validatedAt: Date

    public init(
        schemaVersion: Int = VelaIPCConstants.schemaVersion,
        requestID: UUID,
        coreID: CoreID,
        valid: Bool,
        validatedAt: Date
    ) {
        self.schemaVersion = schemaVersion
        self.requestID = requestID
        self.coreID = coreID
        self.valid = valid
        self.validatedAt = validatedAt
    }
}
