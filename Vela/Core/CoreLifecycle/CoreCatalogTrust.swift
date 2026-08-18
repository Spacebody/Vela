import CryptoKit
import Foundation
import VelaIPC

nonisolated struct CoreCatalogTrustKeyring: Sendable {
    let version: Int
    let roots: [CoreCatalogTrustRoot]

    init(version: Int, roots: [CoreCatalogTrustRoot]) {
        self.version = version
        self.roots = roots
    }

    func root(for keyID: String) -> CoreCatalogTrustRoot? {
        roots.first { $0.keyID == keyID }
    }
}

nonisolated enum CoreCatalogSequenceDisposition: Equatable, Sendable {
    case firstAcceptance
    case advanced(from: UInt64, to: UInt64)
    case cached
}

nonisolated struct CoreCatalogSnapshot: Equatable, Sendable {
    let rawBytes: Data
    let rawEnvelopeBytes: Data
    let rawSHA256: String
    let catalog: CoreCatalog
    let envelope: CoreCatalogSignatureEnvelope
    let acceptedKeyIDs: [String]
    let sequenceDisposition: CoreCatalogSequenceDisposition
    let etag: String?

    init(
        rawBytes: Data,
        rawEnvelopeBytes: Data,
        rawSHA256: String,
        catalog: CoreCatalog,
        envelope: CoreCatalogSignatureEnvelope,
        acceptedKeyIDs: [String],
        sequenceDisposition: CoreCatalogSequenceDisposition,
        etag: String? = nil
    ) {
        self.rawBytes = rawBytes
        self.rawEnvelopeBytes = rawEnvelopeBytes
        self.rawSHA256 = rawSHA256
        self.catalog = catalog
        self.envelope = envelope
        self.acceptedKeyIDs = acceptedKeyIDs
        self.sequenceDisposition = sequenceDisposition
        self.etag = etag
    }
}

nonisolated struct CoreCatalogVerificationState: Equatable, Sendable {
    var highestSequence: UInt64
    var lastCatalogSHA256: String?

    init(highestSequence: UInt64 = 0, lastCatalogSHA256: String? = nil) {
        self.highestSequence = highestSequence
        self.lastCatalogSHA256 = lastCatalogSHA256
    }
}

nonisolated struct CoreCatalogVerifier: Sendable {
    private let keyring: CoreCatalogTrustKeyring
    private let decoder: CoreCatalogDecoder
    private let allowTestKeys: Bool
    private let maximumFutureSkew: TimeInterval

    init(
        keyring: CoreCatalogTrustKeyring = CoreCatalogTrustKeyring(
            version: VelaCoreCatalogTrustRoots.version,
            roots: VelaCoreCatalogTrustRoots.all
        ),
        decoder: CoreCatalogDecoder = CoreCatalogDecoder(),
        allowTestKeys: Bool = false,
        maximumFutureSkew: TimeInterval = 5 * 60
    ) {
        self.keyring = keyring
        self.decoder = decoder
#if DEBUG
        self.allowTestKeys = allowTestKeys
#else
        self.allowTestKeys = false
#endif
        self.maximumFutureSkew = max(0, maximumFutureSkew)
    }

    func verify(
        catalogBytes: Data,
        envelopeBytes: Data,
        state: CoreCatalogVerificationState,
        now: Date = .now,
        etag: String? = nil
    ) throws -> CoreCatalogSnapshot {
        // The envelope and raw-byte digest are intentionally validated before catalog decoding.
        let envelope = try decoder.decodeEnvelope(envelopeBytes)
        let digest = Self.sha256(catalogBytes)
        guard digest == envelope.catalogSHA256 else {
            throw CoreCatalogVerificationError.catalogDigestMismatch
        }

        var acceptedRoots: [CoreCatalogTrustRoot] = []
        for signature in envelope.signatures {
            if signature.keyID.hasPrefix("TEST-ONLY-") && !allowTestKeys { continue }
            guard let root = keyring.root(for: signature.keyID),
                root.status != .revoked,
                now >= root.notBefore,
                root.notAfter.map({ now <= $0 }) ?? true,
                let signatureBytes = Data(base64Encoded: signature.signature),
                let publicKey = try? root.publicKey(),
                publicKey.isValidSignature(signatureBytes, for: catalogBytes)
            else {
                continue
            }
            acceptedRoots.append(root)
        }
        guard !acceptedRoots.isEmpty else {
            throw CoreCatalogVerificationError.noValidSignature
        }

        let catalog = try decoder.decodeCatalog(catalogBytes)
        guard catalog.catalogKeySetVersion <= keyring.version else {
            throw CoreCatalogVerificationError.unsupportedKeySetVersion(
                catalog.catalogKeySetVersion
            )
        }
        acceptedRoots = acceptedRoots.filter { root in
            catalog.generatedAt >= root.notBefore
                && (root.notAfter.map { catalog.generatedAt <= $0 } ?? true)
        }
        guard !acceptedRoots.isEmpty else {
            throw CoreCatalogVerificationError.noValidSignature
        }
        guard catalog.generatedAt <= now.addingTimeInterval(maximumFutureSkew) else {
            throw CoreCatalogVerificationError.generatedInFuture
        }
        guard catalog.expiresAt > now else {
            throw CoreCatalogVerificationError.expired
        }

        let disposition: CoreCatalogSequenceDisposition
        if state.highestSequence == 0 {
            disposition = .firstAcceptance
        } else if catalog.sequence < state.highestSequence {
            throw CoreCatalogVerificationError.replayedSequence(
                received: catalog.sequence,
                highest: state.highestSequence
            )
        } else if catalog.sequence == state.highestSequence {
            guard state.lastCatalogSHA256 == digest else {
                throw CoreCatalogVerificationError.sameSequenceSubstitution(catalog.sequence)
            }
            disposition = .cached
        } else {
            disposition = .advanced(from: state.highestSequence, to: catalog.sequence)
        }

        return CoreCatalogSnapshot(
            rawBytes: catalogBytes,
            rawEnvelopeBytes: envelopeBytes,
            rawSHA256: digest,
            catalog: catalog,
            envelope: envelope,
            acceptedKeyIDs: acceptedRoots.map(\.keyID).sorted(),
            sequenceDisposition: disposition,
            etag: etag
        )
    }

    /// Re-verifies immutable evidence for an already installed core. Catalog
    /// expiry and the global sequence checkpoint intentionally do not disable an
    /// installed core, but raw-byte signature, expected hash, key revocation and
    /// the key's signing-time validity remain mandatory.
    func verifyInstalledEvidence(
        catalogBytes: Data,
        envelopeBytes: Data,
        expectedSHA256: String
    ) throws -> CoreCatalogSnapshot {
        let envelope = try decoder.decodeEnvelope(envelopeBytes)
        let digest = Self.sha256(catalogBytes)
        guard digest == expectedSHA256, digest == envelope.catalogSHA256 else {
            throw CoreCatalogVerificationError.catalogDigestMismatch
        }

        var cryptographicallyValid: [CoreCatalogTrustRoot] = []
        for signature in envelope.signatures {
            if signature.keyID.hasPrefix("TEST-ONLY-") && !allowTestKeys { continue }
            guard let root = keyring.root(for: signature.keyID),
                root.status != .revoked,
                let signatureBytes = Data(base64Encoded: signature.signature),
                let publicKey = try? root.publicKey(),
                publicKey.isValidSignature(signatureBytes, for: catalogBytes)
            else { continue }
            cryptographicallyValid.append(root)
        }
        guard !cryptographicallyValid.isEmpty else {
            throw CoreCatalogVerificationError.noValidSignature
        }
        let catalog = try decoder.decodeCatalog(catalogBytes)
        guard catalog.catalogKeySetVersion <= keyring.version else {
            throw CoreCatalogVerificationError.unsupportedKeySetVersion(
                catalog.catalogKeySetVersion
            )
        }
        let accepted = cryptographicallyValid.filter { root in
            catalog.generatedAt >= root.notBefore
                && (root.notAfter.map { catalog.generatedAt <= $0 } ?? true)
        }
        guard !accepted.isEmpty else {
            throw CoreCatalogVerificationError.noValidSignature
        }
        return CoreCatalogSnapshot(
            rawBytes: catalogBytes,
            rawEnvelopeBytes: envelopeBytes,
            rawSHA256: digest,
            catalog: catalog,
            envelope: envelope,
            acceptedKeyIDs: accepted.map(\.keyID).sorted(),
            sequenceDisposition: .cached
        )
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

nonisolated enum CoreCatalogVerificationError: Error, Equatable, Sendable {
    case catalogDigestMismatch
    case noValidSignature
    case unsupportedKeySetVersion(Int)
    case generatedInFuture
    case expired
    case replayedSequence(received: UInt64, highest: UInt64)
    case sameSequenceSubstitution(UInt64)
}

extension CoreCatalogVerificationError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .catalogDigestMismatch:
            "The Core Catalog bytes do not match the signed digest."
        case .noValidSignature:
            "The Core Catalog has no valid signature from a trusted key."
        case let .unsupportedKeySetVersion(version):
            "The Core Catalog requires unsupported trust-root set version \(version)."
        case .generatedInFuture:
            "The signed Core Catalog appears to come from the future. Check this Mac's date, time, and time zone."
        case .expired:
            "The signed Core Catalog has expired."
        case let .replayedSequence(received, highest):
            "The Core Catalog sequence was replayed (received \(received), highest accepted \(highest))."
        case let .sameSequenceSubstitution(sequence):
            "The Core Catalog changed bytes without advancing sequence \(sequence)."
        }
    }
}
