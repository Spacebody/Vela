import Foundation

nonisolated struct CoreCatalogDecoder: Sendable {
    static let maximumCatalogBytes = 2 * 1_024 * 1_024
    static let maximumEnvelopeBytes = 64 * 1_024

    func decodeCatalog(_ rawBytes: Data) throws -> CoreCatalog {
        guard !rawBytes.isEmpty, rawBytes.count <= Self.maximumCatalogBytes else {
            throw CoreCatalogDecodeError.catalogSizeLimitExceeded(rawBytes.count)
        }
        do {
            try CoreStrictJSON.validateObject(rawBytes, shape: Self.catalogShape)
            let catalog = try CoreJSONCoding.decoder().decode(CoreCatalog.self, from: rawBytes)
            try catalog.validate()
            return catalog
        } catch let error as CoreCatalogDecodeError {
            throw error
        } catch let error as CoreJSONError {
            throw CoreCatalogDecodeError.invalidStructure(error)
        } catch let error as CoreCatalogValidationError {
            throw CoreCatalogDecodeError.invalidCatalog(error)
        } catch {
            throw CoreCatalogDecodeError.decodingFailed
        }
    }

    func decodeEnvelope(_ rawBytes: Data) throws -> CoreCatalogSignatureEnvelope {
        guard !rawBytes.isEmpty, rawBytes.count <= Self.maximumEnvelopeBytes else {
            throw CoreCatalogDecodeError.envelopeSizeLimitExceeded(rawBytes.count)
        }
        do {
            try CoreStrictJSON.validateObject(rawBytes, shape: Self.envelopeShape)
            let envelope = try CoreJSONCoding.decoder().decode(
                CoreCatalogSignatureEnvelope.self,
                from: rawBytes
            )
            try envelope.validate()
            return envelope
        } catch let error as CoreJSONError {
            throw CoreCatalogDecodeError.invalidStructure(error)
        } catch let error as CoreCatalogValidationError {
            throw CoreCatalogDecodeError.invalidCatalog(error)
        } catch {
            throw CoreCatalogDecodeError.decodingFailed
        }
    }

    private static let signatureShape = CoreJSONShape(
        allowedKeys: ["keyID", "algorithm", "signature"]
    )
    private static let envelopeShape = CoreJSONShape(
        allowedKeys: ["schemaVersion", "catalogSHA256", "signatures"],
        arrays: ["signatures": signatureShape]
    )
    private static let fileShape = CoreJSONShape(
        allowedKeys: ["role", "relativePath", "url", "sha256", "size", "mode"]
    )
    private static let upstreamShape = CoreJSONShape(
        allowedKeys: [
            "repositoryURL", "tag", "commit", "assetURL", "assetName",
            "archiveSHA256", "archiveSizeBytes", "sourceURL", "license",
        ]
    )
    private static let compatibilityShape = CoreJSONShape(
        allowedKeys: [
            "minimumVelaVersion", "minimumVelaBuild", "maximumVelaBuild",
            "helperProtocolMinimum", "helperProtocolMaximum", "dataSchemaMinimum",
            "dataSchemaMaximum", "controllerAPIProfile", "minimumMacOS",
            "architectures", "bundleIdentifier", "compatibilitySuiteVersion",
            "compatibilityReportSHA256",
        ]
    )
    private static let entryShape = CoreJSONShape(
        allowedKeys: [
            "coreID", "upstreamVersion", "packageRevision", "status", "publishedAt",
            "releaseNotesURL", "upstream", "vela", "files", "blockReason",
        ],
        objects: ["upstream": upstreamShape, "vela": compatibilityShape],
        arrays: ["files": fileShape]
    )
    private static let catalogShape = CoreJSONShape(
        allowedKeys: [
            "schemaVersion", "sequence", "generatedAt", "expiresAt",
            "catalogKeySetVersion", "entries",
        ],
        arrays: ["entries": entryShape]
    )
}

nonisolated enum CoreCatalogDecodeError: Error, Equatable, Sendable {
    case catalogSizeLimitExceeded(Int)
    case envelopeSizeLimitExceeded(Int)
    case invalidStructure(CoreJSONError)
    case invalidCatalog(CoreCatalogValidationError)
    case decodingFailed
}
