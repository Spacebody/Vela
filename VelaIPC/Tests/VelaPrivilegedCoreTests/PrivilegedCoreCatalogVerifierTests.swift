import CryptoKit
import Foundation
import Testing
import VelaIPC
@testable import VelaPrivilegedCore

@Suite("Independent privileged core catalog verification")
struct PrivilegedCoreCatalogVerifierTests {
    @Test("Controller compatibility is a fixed Vela API profile, not the upstream version")
    func controllerAPIProfileIsIndependentOfUpstreamVersion() {
        let current = VerifiedCoreCompatibilityConstraints.current(
            coreVersion: "v1.19.29"
        )
        #expect(PrivilegedCoreCompatibilityPolicy.isSatisfied(current))

        let unknown = VerifiedCoreCompatibilityConstraints(
            minimumVelaVersion: current.minimumVelaVersion,
            minimumVelaBuild: current.minimumVelaBuild,
            maximumVelaBuild: current.maximumVelaBuild,
            minimumMacOS: current.minimumMacOS,
            architectures: current.architectures,
            helperProtocolMinimum: current.helperProtocolMinimum,
            helperProtocolMaximum: current.helperProtocolMaximum,
            dataSchemaMinimum: current.dataSchemaMinimum,
            dataSchemaMaximum: current.dataSchemaMaximum,
            controllerAPIProfile: "mihomo-v999",
            bundleIdentifier: current.bundleIdentifier,
            compatibilitySuiteVersion: current.compatibilitySuiteVersion,
            compatibilityReportSHA256: current.compatibilityReportSHA256
        )
        #expect(!PrivilegedCoreCompatibilityPolicy.isSatisfied(unknown))
    }

    @Test("The signed fixture verifies against an injected test-only public root")
    func validFixture() throws {
        let result = try verifier().verify(
            rawCatalog: fixture("core-catalog-test.json"),
            signatureEnvelope: fixture("core-catalog-test.signatures.json"),
            selectedCoreID: try #require(CoreID(rawValue: "v1.19.28-r1")),
            highestAcceptedSequence: 0,
            highestAcceptedSHA256: nil
        )
        #expect(result.sequence == 1)
        #expect(result.files.map(\.role) == CoreFileRole.allCases)
        #expect(result.files.count == 7)
    }

    @Test("Unknown keys, wrong signatures and sequence attacks fail closed")
    func rejectsCatalogAttacks() throws {
        let catalog = fixture("core-catalog-test.json")
        let envelope = fixture("core-catalog-test.signatures.json")
        let coreID = try #require(CoreID(rawValue: "v1.19.28-r1"))

        #expect(throws: PrivilegedCoreCatalogError.self) {
            try PrivilegedCoreCatalogVerifier(
                trustRoots: [],
                now: { self.fixedNow }
            ).verify(
                rawCatalog: catalog,
                signatureEnvelope: envelope,
                selectedCoreID: coreID,
                highestAcceptedSequence: 0,
                highestAcceptedSHA256: nil
            )
        }
        #expect(throws: PrivilegedCoreCatalogError.replayedSequence) {
            try verifier().verify(
                rawCatalog: catalog,
                signatureEnvelope: envelope,
                selectedCoreID: coreID,
                highestAcceptedSequence: 2,
                highestAcceptedSHA256: nil
            )
        }

        var object = try #require(JSONSerialization.jsonObject(with: catalog) as? [String: Any])
        object["executablePath"] = "/bin/sh"
        let malicious = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: PrivilegedCoreCatalogError.self) {
            try verifier().verify(
                rawCatalog: malicious,
                signatureEnvelope: envelope,
                selectedCoreID: coreID,
                highestAcceptedSequence: 0,
                highestAcceptedSHA256: nil
            )
        }
    }

    @Test("Blocked catalog entries cannot be selected for installation")
    func blockedEntry() throws {
        #expect(throws: PrivilegedCoreCatalogError.coreBlocked) {
            try verifier().verify(
                rawCatalog: fixture("core-catalog-blocked.json"),
                signatureEnvelope: fixture("core-catalog-blocked.signatures.json"),
                selectedCoreID: try #require(CoreID(rawValue: "v1.19.28-r1")),
                highestAcceptedSequence: 1,
                highestAcceptedSHA256: nil
            )
        }
    }

    @Test("Blocked and withdrawn require reasons while installable statuses forbid them")
    func statusReasonPolicy() throws {
        let coreID = try #require(CoreID(rawValue: "v1.19.28-r1"))
        for status in ["blocked", "withdrawn"] {
            let catalog = try catalog(status: status, blockReason: nil)
            #expect(throws: PrivilegedCoreCatalogError.invalidEntry) {
                try verifier().verifyInstalledEvidence(
                    rawCatalog: catalog,
                    signatureEnvelope: try signedEnvelope(for: catalog),
                    selectedCoreID: coreID,
                    expectedSequence: 1,
                    expectedSHA256: SHA256.hash(data: catalog)
                        .map { String(format: "%02x", $0) }.joined()
                )
            }
        }
        for status in ["recommended", "available"] {
            let catalog = try catalog(status: status, blockReason: "not allowed")
            #expect(throws: PrivilegedCoreCatalogError.invalidEntry) {
                try verifier().verifyInstalledEvidence(
                    rawCatalog: catalog,
                    signatureEnvelope: try signedEnvelope(for: catalog),
                    selectedCoreID: coreID,
                    expectedSequence: 1,
                    expectedSHA256: SHA256.hash(data: catalog)
                        .map { String(format: "%02x", $0) }.joined()
                )
            }
        }
    }

    @Test("The raw catalog is authenticated before any catalog JSON parsing")
    func authenticatesBeforeCatalogParsing() throws {
        let malformedCatalog = Data("{".utf8)
        let coreID = try #require(CoreID(rawValue: "v1.19.28-r1"))

        #expect(throws: PrivilegedCoreCatalogError.catalogHashMismatch) {
            try verifier().verify(
                rawCatalog: malformedCatalog,
                signatureEnvelope: fixture("core-catalog-test.signatures.json"),
                selectedCoreID: coreID,
                highestAcceptedSequence: 0,
                highestAcceptedSHA256: nil
            )
        }

        let matchingEnvelope = try signedEnvelope(for: malformedCatalog)
        #expect(throws: PrivilegedCoreCatalogError.signatureRejected) {
            try verifier(trustRoots: []).verify(
                rawCatalog: malformedCatalog,
                signatureEnvelope: matchingEnvelope,
                selectedCoreID: coreID,
                highestAcceptedSequence: 0,
                highestAcceptedSHA256: nil
            )
        }
        #expect(throws: PrivilegedCoreCatalogError.invalidJSON) {
            try verifier().verify(
                rawCatalog: malformedCatalog,
                signatureEnvelope: matchingEnvelope,
                selectedCoreID: coreID,
                highestAcceptedSequence: 0,
                highestAcceptedSHA256: nil
            )
        }
    }

    @Test("The signature envelope is strict before the raw catalog is inspected")
    func strictEnvelopeFirst() throws {
        var envelope = try #require(
            JSONSerialization.jsonObject(
                with: fixture("core-catalog-test.signatures.json")
            ) as? [String: Any]
        )
        envelope["unexpected"] = true
        let malformedEnvelope = try JSONSerialization.data(withJSONObject: envelope)

        #expect(throws: PrivilegedCoreCatalogError.invalidJSON) {
            try verifier().verify(
                rawCatalog: Data("{".utf8),
                signatureEnvelope: malformedEnvelope,
                selectedCoreID: try #require(CoreID(rawValue: "v1.19.28-r1")),
                highestAcceptedSequence: 0,
                highestAcceptedSHA256: nil
            )
        }
    }

    @Test("A signing root must be valid both now and at catalog generation time")
    func trustRootValidityWindows() throws {
        let catalog = fixture("core-catalog-test.json")
        let envelope = fixture("core-catalog-test.signatures.json")
        let coreID = try #require(CoreID(rawValue: "v1.19.28-r1"))
        let july15 = try #require(
            ISO8601DateFormatter().date(from: "2026-07-15T00:00:00Z")
        )

        #expect(throws: PrivilegedCoreCatalogError.signatureRejected) {
            try verifier(rootNotBefore: july15, rootNotAfter: .distantFuture).verify(
                rawCatalog: catalog,
                signatureEnvelope: envelope,
                selectedCoreID: coreID,
                highestAcceptedSequence: 0,
                highestAcceptedSHA256: nil
            )
        }
        #expect(throws: PrivilegedCoreCatalogError.signatureRejected) {
            try verifier(rootNotBefore: .distantPast, rootNotAfter: july15).verify(
                rawCatalog: catalog,
                signatureEnvelope: envelope,
                selectedCoreID: coreID,
                highestAcceptedSequence: 0,
                highestAcceptedSHA256: nil
            )
        }
    }

    @Test("Every catalog URL rejects query, fragment, credentials and an empty host")
    func rejectsUnsafeHTTPSURLs() throws {
        let unsafeURLs = [
            "https://cores.example.invalid/release-notes.md?tracking=1",
            "https://cores.example.invalid/release-notes.md#fragment",
            "https://user:password@cores.example.invalid/release-notes.md",
            "https:///release-notes.md",
        ]
        let coreID = try #require(CoreID(rawValue: "v1.19.28-r1"))

        for unsafeURL in unsafeURLs {
            let catalog = try catalog(withReleaseNotesURL: unsafeURL)
            #expect(throws: PrivilegedCoreCatalogError.invalidEntry) {
                try verifier().verify(
                    rawCatalog: catalog,
                    signatureEnvelope: try signedEnvelope(for: catalog),
                    selectedCoreID: coreID,
                    highestAcceptedSequence: 0,
                    highestAcceptedSHA256: nil
                )
            }
        }
    }

    private var fixedNow: Date {
        ISO8601DateFormatter().date(from: "2026-07-20T00:00:00Z")!
    }

    private func verifier(
        trustRoots: [CoreCatalogTrustRoot]? = nil,
        rootNotBefore: Date = .distantPast,
        rootNotAfter: Date? = .distantFuture
    ) -> PrivilegedCoreCatalogVerifier {
        PrivilegedCoreCatalogVerifier(
            trustRoots: trustRoots ?? [
                CoreCatalogTrustRoot(
                    keyID: "TEST-ONLY-core-catalog-2026-a",
                    rawPublicKey: Data(base64Encoded: "A6EHv/POEL4dcN0Y50vAmWfk1jCbpQ1fHdyGZBJVMbg=")!,
                    status: .active,
                    notBefore: rootNotBefore,
                    notAfter: rootNotAfter
                )
            ],
            now: { self.fixedNow }
        )
    }

    private func catalog(withReleaseNotesURL url: String) throws -> Data {
        var object = try #require(
            JSONSerialization.jsonObject(with: fixture("core-catalog-test.json"))
                as? [String: Any]
        )
        var entries = try #require(object["entries"] as? [[String: Any]])
        entries[0]["releaseNotesURL"] = url
        object["entries"] = entries
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func catalog(status: String, blockReason: String?) throws -> Data {
        var object = try #require(
            JSONSerialization.jsonObject(with: fixture("core-catalog-test.json"))
                as? [String: Any]
        )
        var entries = try #require(object["entries"] as? [[String: Any]])
        entries[0]["status"] = status
        if let blockReason {
            entries[0]["blockReason"] = blockReason
        } else {
            entries[0].removeValue(forKey: "blockReason")
        }
        object["entries"] = entries
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func signedEnvelope(for catalog: Data) throws -> Data {
        let seed = Data((0 ... 31).map(UInt8.init))
        let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        let signature = try privateKey.signature(for: catalog)
        let digest = SHA256.hash(data: catalog)
            .map { String(format: "%02x", $0) }
            .joined()
        let envelope: [String: Any] = [
            "schemaVersion": 1,
            "catalogSHA256": digest,
            "signatures": [[
                "keyID": "TEST-ONLY-core-catalog-2026-a",
                "algorithm": "ed25519",
                "signature": signature.base64EncodedString(),
            ]],
        ]
        return try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
    }

    private func fixture(_ name: String) -> Data {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let repositoryRoot = packageRoot.deletingLastPathComponent()
        return try! Data(contentsOf: repositoryRoot
            .appending(path: "Docs/V1/Vela-v0.6-Signed-Core-Lifecycle-Codex-Pack/fixtures")
            .appending(path: name))
    }
}
