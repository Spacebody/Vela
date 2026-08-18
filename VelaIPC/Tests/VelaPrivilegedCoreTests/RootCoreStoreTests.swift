import CryptoKit
import Darwin
import Foundation
import Testing
import VelaIPC
@testable import VelaPrivilegedCore

@Suite("Root signed core store")
struct RootCoreStoreTests {
    @Test("FileHandle staging builds the fixed bundle atomically and protects active Core")
    func installAndProtectActive() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        let store = harness.store()
        try await store.prepareAtStartup()
        let session = UUID()
        let transaction = UUID()
        let coreID = try #require(CoreID(rawValue: "v1.19.28-r1"))
        let response = try await store.prepareInstall(
            PrepareCoreInstallRequest(
                sessionID: session,
                transactionID: transaction,
                ownerUID: 501,
                rawCatalogData: Data("catalog".utf8),
                signatureEnvelopeData: Data("signature".utf8),
                selectedCoreID: coreID
            ),
            authenticatedOwnerUID: 501
        )
        #expect(response.requiredRoles == CoreFileRole.allCases)

        for role in CoreFileRole.allCases {
            let data = harness.bytes[role]!
            let file = try harness.fileHandle(data: data)
            defer { try? file.close() }
            try await store.stageFile(
                StageCoreFileRequest(
                    sessionID: session,
                    transactionID: transaction,
                    role: role,
                    expectedSize: data.count,
                    expectedSHA256: Self.hash(data)
                ),
                file: file
            )
        }
        let installed = try await store.commitInstall(
            CommitCoreInstallRequest(sessionID: session, transactionID: transaction)
        )
        #expect(installed.coreID == coreID)
        #expect(try await store.list(requestID: UUID()).cores.map(\.coreID) == [coreID])
        #expect(try await store.validate(coreID, requestID: UUID()).valid)
        try await store.recordActivation(coreID)
        await #expect(throws: RootCoreStoreError.protectedCore) {
            try await store.remove(coreID)
        }
    }

    @Test("Owner mismatch and catalog descriptor substitution are rejected")
    func rejectsBoundarySubstitution() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        let store = harness.store()
        try await store.prepareAtStartup()
        let session = UUID()
        let transaction = UUID()
        let coreID = try #require(CoreID(rawValue: "v1.19.28-r1"))
        let prepare = PrepareCoreInstallRequest(
            sessionID: session,
            transactionID: transaction,
            ownerUID: 501,
            rawCatalogData: Data(),
            signatureEnvelopeData: Data(),
            selectedCoreID: coreID
        )
        await #expect(throws: RootCoreStoreError.ownerMismatch) {
            try await store.prepareInstall(prepare, authenticatedOwnerUID: 502)
        }
        _ = try await store.prepareInstall(prepare, authenticatedOwnerUID: 501)
        let data = harness.bytes[.infoPlist]!
        let file = try harness.fileHandle(data: data)
        defer { try? file.close() }
        await #expect(throws: RootCoreStoreError.descriptorMismatch) {
            try await store.stageFile(
                StageCoreFileRequest(
                    sessionID: session,
                    transactionID: transaction,
                    role: .infoPlist,
                    expectedSize: data.count,
                    expectedSHA256: String(repeating: "f", count: 64)
                ),
                file: file
            )
        }
    }

    @Test("Abort removes an executable staged with root trusted mode")
    func abortExecutableStaging() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        let store = harness.store()
        try await store.prepareAtStartup()
        let session = UUID()
        let transaction = UUID()
        _ = try await store.prepareInstall(
            PrepareCoreInstallRequest(
                sessionID: session,
                transactionID: transaction,
                ownerUID: 501,
                rawCatalogData: Data(),
                signatureEnvelopeData: Data(),
                selectedCoreID: try #require(CoreID(rawValue: "v1.19.28-r1"))
            ),
            authenticatedOwnerUID: 501
        )
        let data = harness.bytes[.executable]!
        let file = try harness.fileHandle(data: data)
        defer { try? file.close() }
        try await store.stageFile(
            StageCoreFileRequest(
                sessionID: session,
                transactionID: transaction,
                role: .executable,
                expectedSize: data.count,
                expectedSHA256: Self.hash(data)
            ),
            file: file
        )
        try await store.abortInstall(
            AbortCoreInstallRequest(sessionID: session, transactionID: transaction)
        )
        #expect(try await store.list(requestID: UUID()).cores.isEmpty)
    }

    @Test("Rollback to previous known-good never promotes the failed candidate")
    func rollbackDoesNotPromoteFailedCandidate() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        let store = harness.store()
        try await store.prepareAtStartup()
        let session = UUID()
        let transaction = UUID()
        let candidate = try #require(CoreID(rawValue: "v1.19.28-r1"))
        _ = try await store.prepareInstall(
            PrepareCoreInstallRequest(
                sessionID: session,
                transactionID: transaction,
                ownerUID: 501,
                rawCatalogData: Data("catalog".utf8),
                signatureEnvelopeData: Data("signature".utf8),
                selectedCoreID: candidate
            ),
            authenticatedOwnerUID: 501
        )
        for role in CoreFileRole.allCases {
            let data = try #require(harness.bytes[role])
            let file = try harness.fileHandle(data: data)
            defer { try? file.close() }
            try await store.stageFile(
                StageCoreFileRequest(
                    sessionID: session,
                    transactionID: transaction,
                    role: role,
                    expectedSize: data.count,
                    expectedSHA256: Self.hash(data)
                ),
                file: file
            )
        }
        _ = try await store.commitInstall(
            CommitCoreInstallRequest(sessionID: session, transactionID: transaction)
        )

        try await store.recordActivation(candidate)
        var state = try await store.list(requestID: UUID())
        #expect(state.activeCoreID == candidate)
        #expect(state.previousCoreID == .factoryV11928)

        try await store.recordActivation(.factoryV11928)
        state = try await store.list(requestID: UUID())
        #expect(state.activeCoreID == .factoryV11928)
        #expect(state.previousCoreID == nil)
        try await store.remove(candidate)
        #expect(try await store.list(requestID: UUID()).cores.isEmpty)
    }

    @Test("A fourth Core evicts only the least-recently-used unprotected Core")
    func fourthInstallEvictsUnprotectedLRU() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        let clock = TestNow(Date(timeIntervalSince1970: 1_000))
        let store = harness.store(now: { clock.value() })
        try await store.prepareAtStartup()
        let core1 = try #require(CoreID(rawValue: "v1.19.28-r1"))
        let core2 = try #require(CoreID(rawValue: "v1.19.28-r2"))
        let core3 = try #require(CoreID(rawValue: "v1.19.28-r3"))
        let core4 = try #require(CoreID(rawValue: "v1.19.28-r4"))
        clock.set(Date(timeIntervalSince1970: 1_001))
        _ = try await install(core1, in: store, harness: harness)
        clock.set(Date(timeIntervalSince1970: 1_002))
        _ = try await install(core2, in: store, harness: harness)
        clock.set(Date(timeIntervalSince1970: 1_003))
        _ = try await install(core3, in: store, harness: harness)
        // Refresh core1 after core2 so core2 becomes the true LRU candidate.
        clock.set(Date(timeIntervalSince1970: 1_004))
        _ = try await store.validate(core1, requestID: UUID())
        clock.set(Date(timeIntervalSince1970: 1_005))
        try await store.recordActivation(core3)

        clock.set(Date(timeIntervalSince1970: 1_006))
        _ = try await install(core4, in: store, harness: harness)

        let state = try await store.list(requestID: UUID())
        #expect(state.activeCoreID == core3)
        #expect(state.previousCoreID == .factoryV11928)
        #expect(state.cores.map(\.coreID) == [core1, core3, core4])
        #expect(!FileManager.default.fileExists(
            atPath: harness.installedURL(core2).path
        ))
        #expect(FileManager.default.fileExists(atPath: harness.installedURL(core4).path))
    }

    @Test("A fourth Core fails closed when active, previous and pinned protect all slots")
    func fourthInstallFailsWhenEveryCoreIsProtected() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        let store = harness.store()
        try await store.prepareAtStartup()
        let core1 = try #require(CoreID(rawValue: "v1.19.28-r1"))
        let core2 = try #require(CoreID(rawValue: "v1.19.28-r2"))
        let core3 = try #require(CoreID(rawValue: "v1.19.28-r3"))
        let core4 = try #require(CoreID(rawValue: "v1.19.28-r4"))
        for coreID in [core1, core2, core3] {
            _ = try await install(coreID, in: store, harness: harness)
        }
        try await store.recordActivation(core1)
        try await store.recordActivation(core2)
        try harness.pinOnDisk(core3)

        let restarted = harness.store()
        try await restarted.prepareAtStartup()
        await #expect(throws: RootCoreStoreError.storeLimit) {
            _ = try await restarted.prepareInstall(
                PrepareCoreInstallRequest(
                    sessionID: UUID(),
                    transactionID: UUID(),
                    ownerUID: 501,
                    rawCatalogData: Data("catalog".utf8),
                    signatureEnvelopeData: Data("signature".utf8),
                    selectedCoreID: core4
                ),
                authenticatedOwnerUID: 501
            )
        }

        let state = try await restarted.list(requestID: UUID())
        #expect(state.activeCoreID == core2)
        #expect(state.previousCoreID == core1)
        #expect(state.cores.map(\.coreID) == [core1, core2, core3])
        #expect(try FileManager.default.contentsOfDirectory(
            atPath: harness.root.appending(path: "cores/staging").path
        ).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(
            atPath: harness.root.appending(path: "cores/transactions").path
        ).isEmpty)
    }

    @Test("A signed blocked refresh preserves the active Core but rejects its next start")
    func blockedRefreshPreservesActiveAndRejectsNextStart() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        let now = Self.date("2026-07-20T00:00:00Z")
        let roots = try Self.roots(oldStatus: .active, newStatus: .active)
        let store = harness.store(trustRoots: roots, now: { now })
        try await store.prepareAtStartup()
        let coreID = try #require(CoreID(rawValue: "v1.19.28-r1"))
        let initial = try Self.catalog(
            harness: harness,
            coreID: coreID,
            sequence: 1,
            status: "recommended",
            signers: [Self.oldSigner]
        )
        _ = try await installSigned(
            coreID,
            evidence: initial,
            in: store,
            harness: harness
        )
        try await store.recordActivation(coreID)

        let blocked = try Self.catalog(
            harness: harness,
            coreID: coreID,
            sequence: 2,
            status: "blocked",
            blockReason: "Signed security incident",
            signers: [Self.oldSigner, Self.newSigner]
        )
        let response = try await store.refreshSignedPolicy(
            RefreshCoreCatalogRequest(
                sessionID: UUID(),
                rawCatalogData: blocked.catalog,
                signatureEnvelopeData: blocked.envelope
            )
        )
        #expect(response.acceptedSequence == 2)
        #expect(response.updatedCoreIDs == [coreID])
        #expect(try await store.list(requestID: UUID()).activeCoreID == coreID)
        await #expect(throws: RootCoreStoreError.policyRejected) {
            _ = try await store.executableSourceURL(for: coreID)
        }

        let restarted = harness.store(trustRoots: roots, now: { now })
        try await restarted.prepareAtStartup()
        #expect(try await restarted.list(requestID: UUID()).activeCoreID == coreID)
    }

    @Test("A signed incompatible refresh rejects the next explicit start")
    func incompatibleRefreshRejectsNextStart() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        let now = Self.date("2026-07-20T00:00:00Z")
        let roots = try Self.roots(oldStatus: .active, newStatus: .active)
        let store = harness.store(trustRoots: roots, now: { now })
        try await store.prepareAtStartup()
        let coreID = try #require(CoreID(rawValue: "v1.19.28-r1"))
        _ = try await installSigned(
            coreID,
            evidence: Self.catalog(
                harness: harness,
                coreID: coreID,
                sequence: 1,
                status: "recommended",
                signers: [Self.oldSigner]
            ),
            in: store,
            harness: harness
        )
        let incompatible = try Self.catalog(
            harness: harness,
            coreID: coreID,
            sequence: 2,
            status: "available",
            minimumVelaBuild: 9_999_999_999,
            signers: [Self.oldSigner, Self.newSigner]
        )
        _ = try await store.refreshSignedPolicy(
            RefreshCoreCatalogRequest(
                sessionID: UUID(),
                rawCatalogData: incompatible.catalog,
                signatureEnvelopeData: incompatible.envelope
            )
        )
        await #expect(throws: RootCoreStoreError.policyRejected) {
            _ = try await store.validate(coreID, requestID: UUID())
        }
    }

    @Test("Installed Core remains valid after Catalog and signing-key natural expiry")
    func expiredInstalledEvidenceRemainsValid() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        let installNow = Self.date("2026-07-20T00:00:00Z")
        let keyExpiry = Self.date("2026-07-25T00:00:00Z")
        let roots = try Self.roots(
            oldStatus: .active,
            newStatus: .active,
            oldNotAfter: keyExpiry
        )
        let store = harness.store(trustRoots: roots, now: { installNow })
        try await store.prepareAtStartup()
        let coreID = try #require(CoreID(rawValue: "v1.19.28-r1"))
        _ = try await installSigned(
            coreID,
            evidence: Self.catalog(
                harness: harness,
                coreID: coreID,
                sequence: 1,
                status: "recommended",
                expiresAt: "2026-07-21T00:00:00Z",
                signers: [Self.oldSigner]
            ),
            in: store,
            harness: harness
        )

        let afterExpiry = Self.date("2026-08-20T00:00:00Z")
        let restarted = harness.store(trustRoots: roots, now: { afterExpiry })
        try await restarted.prepareAtStartup()
        #expect(try await restarted.validate(coreID, requestID: UUID()).valid)
    }

    @Test("Current keyring rejects revoked old-only evidence but accepts dual-signed evidence")
    func keyRotationAndRevocationAtStart() async throws {
        let now = Self.date("2026-07-20T00:00:00Z")
        let originalRoots = try Self.roots(oldStatus: .active, newStatus: .next)
        let rotatedRoots = try Self.roots(oldStatus: .revoked, newStatus: .active)
        let coreID = try #require(CoreID(rawValue: "v1.19.28-r1"))

        let oldOnlyHarness = try Harness()
        defer { oldOnlyHarness.cleanup() }
        let oldOnlyStore = oldOnlyHarness.store(trustRoots: originalRoots, now: { now })
        try await oldOnlyStore.prepareAtStartup()
        _ = try await installSigned(
            coreID,
            evidence: Self.catalog(
                harness: oldOnlyHarness,
                coreID: coreID,
                sequence: 1,
                status: "recommended",
                signers: [Self.oldSigner]
            ),
            in: oldOnlyStore,
            harness: oldOnlyHarness
        )
        let oldRevoked = oldOnlyHarness.store(trustRoots: rotatedRoots, now: { now })
        try await oldRevoked.prepareAtStartup()
        await #expect(throws: PrivilegedCoreCatalogError.signatureRejected) {
            _ = try await oldRevoked.validate(coreID, requestID: UUID())
        }

        let dualHarness = try Harness()
        defer { dualHarness.cleanup() }
        let dualStore = dualHarness.store(trustRoots: originalRoots, now: { now })
        try await dualStore.prepareAtStartup()
        _ = try await installSigned(
            coreID,
            evidence: Self.catalog(
                harness: dualHarness,
                coreID: coreID,
                sequence: 1,
                status: "recommended",
                signers: [Self.oldSigner, Self.newSigner]
            ),
            in: dualStore,
            harness: dualHarness
        )
        let dualRotated = dualHarness.store(trustRoots: rotatedRoots, now: { now })
        try await dualRotated.prepareAtStartup()
        #expect(try await dualRotated.validate(coreID, requestID: UUID()).valid)
    }

    @Test("Tampered persistent Catalog evidence fails closed on restart")
    func tamperedPersistentEvidenceFailsClosed() async throws {
        let harness = try Harness()
        defer { harness.cleanup() }
        let now = Self.date("2026-07-20T00:00:00Z")
        let roots = try Self.roots(oldStatus: .active, newStatus: .next)
        let store = harness.store(trustRoots: roots, now: { now })
        try await store.prepareAtStartup()
        let coreID = try #require(CoreID(rawValue: "v1.19.28-r1"))
        _ = try await installSigned(
            coreID,
            evidence: Self.catalog(
                harness: harness,
                coreID: coreID,
                sequence: 1,
                status: "recommended",
                signers: [Self.oldSigner]
            ),
            in: store,
            harness: harness
        )
        try harness.tamperInstalledCatalogEvidence()

        let restarted = harness.store(trustRoots: roots, now: { now })
        await #expect(throws: RootCoreStoreError.invalidState) {
            try await restarted.prepareAtStartup()
        }
    }

    private struct SignedEvidence {
        let catalog: Data
        let envelope: Data
    }

    private struct Signer {
        let keyID: String
        let seed: Data
    }

    private static let oldSigner = Signer(
        keyID: "TEST-ONLY-core-old",
        seed: Data((0 ... 31).map(UInt8.init))
    )
    private static let newSigner = Signer(
        keyID: "TEST-ONLY-core-new",
        seed: Data((32 ... 63).map(UInt8.init))
    )

    private static func roots(
        oldStatus: CoreCatalogTrustRoot.Status,
        newStatus: CoreCatalogTrustRoot.Status,
        oldNotAfter: Date? = nil
    ) throws -> [CoreCatalogTrustRoot] {
        let oldKey = try Curve25519.Signing.PrivateKey(rawRepresentation: oldSigner.seed)
        let newKey = try Curve25519.Signing.PrivateKey(rawRepresentation: newSigner.seed)
        let notBefore = date("2026-07-01T00:00:00Z")
        return [
            CoreCatalogTrustRoot(
                keyID: oldSigner.keyID,
                rawPublicKey: oldKey.publicKey.rawRepresentation,
                status: oldStatus,
                notBefore: notBefore,
                notAfter: oldNotAfter
            ),
            CoreCatalogTrustRoot(
                keyID: newSigner.keyID,
                rawPublicKey: newKey.publicKey.rawRepresentation,
                status: newStatus,
                notBefore: notBefore,
                notAfter: nil
            ),
        ]
    }

    private static func catalog(
        harness: Harness,
        coreID: CoreID,
        sequence: UInt64,
        status: String,
        blockReason: String? = nil,
        minimumVelaBuild: UInt64 = 1,
        expiresAt: String = "2026-08-20T00:00:00Z",
        signers: [Signer]
    ) throws -> SignedEvidence {
        var entry: [String: Any] = [
            "coreID": coreID.rawValue,
            "upstreamVersion": coreID.upstreamVersion,
            "packageRevision": try #require(coreID.packageRevision),
            "status": status,
            "publishedAt": "2026-07-19T00:00:00Z",
            "releaseNotesURL": "https://cores.example.invalid/release-notes.md",
            "upstream": [
                "repositoryURL": "https://github.com/MetaCubeX/mihomo",
                "tag": coreID.upstreamVersion,
                "commit": "cbd11db",
                "assetName": "mihomo-darwin-arm64.gz",
                "assetURL": "https://cores.example.invalid/mihomo.gz",
                "archiveSHA256": hash(try #require(harness.bytes[.executable])),
                "archiveSizeBytes": try #require(harness.bytes[.executable]).count,
                "sourceURL": "https://github.com/MetaCubeX/mihomo/tree/v1.19.28",
                "license": "GPL-3.0",
            ],
            "vela": [
                "minimumVelaVersion": "0.6.0",
                "minimumVelaBuild": minimumVelaBuild,
                "maximumVelaBuild": NSNull(),
                "minimumMacOS": "15.0",
                "architectures": ["arm64"],
                "helperProtocolMinimum": VelaIPCConstants.protocolMinimum,
                "helperProtocolMaximum": VelaIPCConstants.protocolMaximum,
                "dataSchemaMinimum": VelaIPCConstants.coreDataSchemaVersion,
                "dataSchemaMaximum": VelaIPCConstants.coreDataSchemaVersion,
                "controllerAPIProfile": VelaIPCConstants.currentControllerAPIProfile,
                "bundleIdentifier": VelaIPCConstants.expectedExternalCoreSigningIdentifier,
                "compatibilitySuiteVersion": 1,
                "compatibilityReportSHA256": hash(
                    try #require(harness.bytes[.compatibility])
                ),
            ],
            "files": try CoreFileRole.allCases.map { role -> [String: Any] in
                let data = try #require(harness.bytes[role])
                return [
                    "role": role.rawValue,
                    "relativePath": role.requiredRelativePath,
                    "mode": role.requiredPublishedMode,
                    "size": data.count,
                    "sha256": hash(data),
                    "url": "https://cores.example.invalid/\(role.rawValue)",
                ]
            },
        ]
        if let blockReason { entry["blockReason"] = blockReason }
        let object: [String: Any] = [
            "schemaVersion": 1,
            "sequence": sequence,
            "generatedAt": "2026-07-19T00:00:00Z",
            "expiresAt": expiresAt,
            "catalogKeySetVersion": 1,
            "entries": [entry],
        ]
        let catalog = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let signatures: [[String: Any]] = try signers.map { signer in
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: signer.seed)
            return [
                "keyID": signer.keyID,
                "algorithm": "ed25519",
                "signature": try key.signature(for: catalog).base64EncodedString(),
            ]
        }
        let envelope = try JSONSerialization.data(
            withJSONObject: [
                "schemaVersion": 1,
                "catalogSHA256": hash(catalog),
                "signatures": signatures,
            ],
            options: [.sortedKeys]
        )
        return SignedEvidence(catalog: catalog, envelope: envelope)
    }

    private static func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }

    private func installSigned(
        _ coreID: CoreID,
        evidence: SignedEvidence,
        in store: RootCoreStore,
        harness: Harness
    ) async throws -> InstalledCoreDescriptor {
        let sessionID = UUID()
        let transactionID = UUID()
        _ = try await store.prepareInstall(
            PrepareCoreInstallRequest(
                sessionID: sessionID,
                transactionID: transactionID,
                ownerUID: 501,
                rawCatalogData: evidence.catalog,
                signatureEnvelopeData: evidence.envelope,
                selectedCoreID: coreID
            ),
            authenticatedOwnerUID: 501
        )
        for role in CoreFileRole.allCases {
            let data = try #require(harness.bytes[role])
            let file = try harness.fileHandle(data: data)
            defer { try? file.close() }
            try await store.stageFile(
                StageCoreFileRequest(
                    sessionID: sessionID,
                    transactionID: transactionID,
                    role: role,
                    expectedSize: data.count,
                    expectedSHA256: Self.hash(data)
                ),
                file: file
            )
        }
        return try await store.commitInstall(
            CommitCoreInstallRequest(sessionID: sessionID, transactionID: transactionID)
        )
    }

    private func install(
        _ coreID: CoreID,
        in store: RootCoreStore,
        harness: Harness
    ) async throws -> InstalledCoreDescriptor {
        let sessionID = UUID()
        let transactionID = UUID()
        _ = try await store.prepareInstall(
            PrepareCoreInstallRequest(
                sessionID: sessionID,
                transactionID: transactionID,
                ownerUID: 501,
                rawCatalogData: Data("catalog".utf8),
                signatureEnvelopeData: Data("signature".utf8),
                selectedCoreID: coreID
            ),
            authenticatedOwnerUID: 501
        )
        for role in CoreFileRole.allCases {
            let data = try #require(harness.bytes[role])
            let file = try harness.fileHandle(data: data)
            defer { try? file.close() }
            try await store.stageFile(
                StageCoreFileRequest(
                    sessionID: sessionID,
                    transactionID: transactionID,
                    role: role,
                    expectedSize: data.count,
                    expectedSHA256: Self.hash(data)
                ),
                file: file
            )
        }
        return try await store.commitInstall(
            CommitCoreInstallRequest(
                sessionID: sessionID,
                transactionID: transactionID
            )
        )
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private final class Harness: @unchecked Sendable {
        let root: URL
        let fileSystem: POSIXRootFileSystem
        let bytes: [CoreFileRole: Data]

        init() throws {
            root = URL.temporaryDirectory.appending(path: "VelaRootCoreStore-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            guard chmod(root.path, 0o700) == 0 else { throw POSIXRootFileSystemError.systemCall(operation: "chmod", code: errno) }
            fileSystem = try POSIXRootFileSystem.openExisting(
                at: root,
                policy: PrivilegedOwnershipPolicy(
                    userID: getuid(),
                    groupID: getgid(),
                    directoryMode: 0o700,
                    fileMode: 0o600
                )
            )
            bytes = Dictionary(uniqueKeysWithValues: CoreFileRole.allCases.map { role in
                (role, Data("fixed-\(role.rawValue)".utf8))
            })
        }

        func store(
            now: @escaping @Sendable () -> Date = { .now }
        ) -> RootCoreStore {
            RootCoreStore(
                fileSystem: fileSystem,
                verifier: StubVerifier(files: bytes.map {
                    VerifiedCoreFile(
                        role: $0.key,
                        expectedSize: $0.value.count,
                        expectedSHA256: RootCoreStoreTests.hash($0.value)
                    )
                }.sorted { $0.role.rawValue < $1.role.rawValue }),
                preflight: AcceptingPreflight(),
                now: now
            )
        }

        func store(
            trustRoots: [CoreCatalogTrustRoot],
            now: @escaping @Sendable () -> Date
        ) -> RootCoreStore {
            RootCoreStore(
                fileSystem: fileSystem,
                verifier: PrivilegedCoreCatalogVerifier(
                    trustRoots: trustRoots,
                    keySetVersion: 1,
                    now: now
                ),
                preflight: AcceptingPreflight(),
                now: now
            )
        }

        func fileHandle(data: Data) throws -> FileHandle {
            let url = root.deletingLastPathComponent().appending(path: "vela-core-input-\(UUID())")
            try data.write(to: url, options: .atomic)
            return try FileHandle(forReadingFrom: url)
        }

        func installedURL(_ coreID: CoreID) -> URL {
            root.appending(path: "cores/installed/\(coreID.rawValue)")
        }

        func pinOnDisk(_ coreID: CoreID) throws {
            let path = try SafeRelativePath("cores/state.json")
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            var value = try decoder.decode(
                RootCoreStoreState.self,
                from: fileSystem.readData(
                    at: path,
                    maximumBytes: VelaIPCConstants.maximumPayloadBytes
                )
            )
            value.pinnedCoreID = coreID
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            try fileSystem.writeDataAtomically(
                encoder.encode(value),
                to: path,
                replacingExisting: true
            )
        }

        func tamperInstalledCatalogEvidence() throws {
            let path = try SafeRelativePath("cores/state.json")
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            var value = try decoder.decode(
                RootCoreStoreState.self,
                from: fileSystem.readData(
                    at: path,
                    maximumBytes: VelaIPCConstants.maximumCoreStoreStateBytes
                )
            )
            let existing = try #require(value.installed.first)
            value.installed[0] = RootInstalledCoreRecord(
                descriptor: existing.descriptor,
                catalogSHA256: existing.catalogSHA256,
                rawCatalogData: existing.rawCatalogData + Data([0x20]),
                signatureEnvelopeData: existing.signatureEnvelopeData,
                status: existing.status,
                blockReason: existing.blockReason,
                compatibility: existing.compatibility,
                files: existing.files
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            try fileSystem.writeDataAtomically(
                encoder.encode(value),
                to: path,
                replacingExisting: true
            )
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }

    private struct StubVerifier: PrivilegedCoreCatalogVerifying {
        let files: [VerifiedCoreFile]
        func verify(
            rawCatalog: Data,
            signatureEnvelope _: Data,
            selectedCoreID: CoreID,
            highestAcceptedSequence _: UInt64,
            highestAcceptedSHA256 _: String?
        ) throws -> VerifiedCoreCatalogSelection {
            VerifiedCoreCatalogSelection(
                coreID: selectedCoreID,
                upstreamVersion: selectedCoreID.upstreamVersion,
                packageRevision: selectedCoreID.packageRevision!,
                sequence: 1,
                catalogSHA256: RootCoreStoreTests.hash(rawCatalog),
                files: files
            )
        }
    }

    private struct AcceptingPreflight: RootCoreBundlePreflighting {
        func validate(
            bundleRelativePath _: SafeRelativePath,
            selection _: VerifiedCoreCatalogSelection
        ) async throws {}
    }

    private final class TestNow: @unchecked Sendable {
        private let lock = NSLock()
        private var instant: Date

        init(_ instant: Date) { self.instant = instant }

        func set(_ value: Date) {
            lock.lock()
            instant = value
            lock.unlock()
        }

        func value() -> Date {
            lock.lock()
            defer { lock.unlock() }
            return instant
        }
    }
}
