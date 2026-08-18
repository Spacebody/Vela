import Darwin
import Foundation
import Testing
import VelaIPC
@testable import VelaPrivilegedCore

@Suite("Root Core bundle preflight")
struct RootCoreBundlePreflightTests {
    @Test("Privileged Core requirement has exact Apple anchor and parses")
    func requirementIsExactAndParsable() throws {
        let requirement = try PrivilegedCodeSigningRequirement.appleGeneric(
            identifier: VelaIPCConstants.expectedExternalCoreSigningIdentifier,
            teamIdentifier: "TEAM123456"
        )
        #expect(
            requirement.text
                == "identifier \"dev.yilin.Vela.MihomoCore\" and anchor apple generic and certificate leaf[subject.OU] = \"TEAM123456\""
        )
        try requirement.validateSyntax()
        #expect(throws: PrivilegedCodeSigningError.invalidRequirement) {
            try PrivilegedCodeSigningRequirement.appleGeneric(
                identifier: VelaIPCConstants.expectedExternalCoreSigningIdentifier,
                teamIdentifier: "TEAM123456\" or true"
            )
        }
    }

    @Test("Preflight accepts the canonical release-template CFBundleName")
    func acceptsCanonicalBundleName() async throws {
        try await withBundle(bundleName: "Vela Mihomo Core") { preflight, selection in
            try await preflight.validate(
                bundleRelativePath: try SafeRelativePath("VelaMihomoCore.bundle"),
                selection: selection
            )
        }
    }

    @Test("Preflight rejects the old non-canonical CFBundleName")
    func rejectsLegacyBundleName() async throws {
        try await withBundle(bundleName: "VelaMihomoCore") { preflight, selection in
            await #expect(throws: RootCoreStoreError.preflightFailed) {
                try await preflight.validate(
                    bundleRelativePath: try SafeRelativePath("VelaMihomoCore.bundle"),
                    selection: selection
                )
            }
        }
    }

    @Test("Root preflight applies the exact Core requirement on both checks")
    func appliesExactRequirementTwice() async throws {
        let inspector = CanonicalBundleSigningInspector()
        try await withBundle(
            bundleName: "Vela Mihomo Core",
            signingInspector: inspector
        ) { preflight, selection in
            try await preflight.validate(
                bundleRelativePath: try SafeRelativePath("VelaMihomoCore.bundle"),
                selection: selection
            )
        }

        let expected = "identifier \"dev.yilin.Vela.MihomoCore\" and anchor apple generic and certificate leaf[subject.OU] = \"TEAM123456\""
        #expect(inspector.requirementTexts() == [expected, expected])
    }

    @Test("Root preflight rejects wrong identifier and wrong Team")
    func rejectsWrongSignatureIdentity() async throws {
        let wrongIdentifier = CanonicalBundleSigningInspector(
            signingIdentifier: "dev.yilin.Vela.NotTheCore"
        )
        await #expect(throws: RootCoreStoreError.preflightFailed) {
            try await withBundle(
                bundleName: "Vela Mihomo Core",
                signingInspector: wrongIdentifier
            ) { preflight, selection in
                try await preflight.validate(
                    bundleRelativePath: try SafeRelativePath("VelaMihomoCore.bundle"),
                    selection: selection
                )
            }
        }

        let wrongTeam = CanonicalBundleSigningInspector(teamIdentifier: "OTHERTEAM1")
        await #expect(throws: RootCoreStoreError.preflightFailed) {
            try await withBundle(
                bundleName: "Vela Mihomo Core",
                signingInspector: wrongTeam
            ) { preflight, selection in
                try await preflight.validate(
                    bundleRelativePath: try SafeRelativePath("VelaMihomoCore.bundle"),
                    selection: selection
                )
            }
        }
    }

    @Test("Root preflight rejects a hashed but non-passing compatibility report")
    func rejectsNonPassingCompatibilityReport() async throws {
        try await withBundle(
            bundleName: "Vela Mihomo Core",
            mutateReport: { report in
                report["knownDeviations"] = ["unreviewed-tun-regression"]
            }
        ) { preflight, selection in
            await #expect(throws: RootCoreStoreError.preflightFailed) {
                try await preflight.validate(
                    bundleRelativePath: try SafeRelativePath("VelaMihomoCore.bundle"),
                    selection: selection
                )
            }
        }
    }

    @Test("Root preflight rejects compatibility evidence for different upstream bytes")
    func rejectsDifferentUpstreamPayloadIdentity() async throws {
        try await withBundle(
            bundleName: "Vela Mihomo Core",
            mutateReport: { report in
                var artifacts = report["artifacts"] as! [String: Any]
                artifacts["upstreamPayloadSHA256"] = String(repeating: "f", count: 64)
                report["artifacts"] = artifacts
            }
        ) { preflight, selection in
            await #expect(throws: RootCoreStoreError.preflightFailed) {
                try await preflight.validate(
                    bundleRelativePath: try SafeRelativePath("VelaMihomoCore.bundle"),
                    selection: selection
                )
            }
        }
    }

    private func withBundle(
        bundleName: String,
        signingInspector: any PrivilegedCodeSigningInspecting = CanonicalBundleSigningInspector(),
        mutateReport: ((inout [String: Any]) -> Void)? = nil,
        _ operation: (
            RootCoreBundlePreflight,
            VerifiedCoreCatalogSelection
        ) async throws -> Void
    ) async throws {
        let root = URL.temporaryDirectory
            .appending(path: "VelaCoreBundlePreflight-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        guard chmod(root.path, 0o700) == 0 else {
            throw POSIXRootFileSystemError.systemCall(operation: "chmod", code: errno)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let fileSystem = try POSIXRootFileSystem.openExisting(
            at: root,
            policy: PrivilegedOwnershipPolicy(userID: getuid(), groupID: getgid())
        )
        let bundle = try SafeRelativePath("VelaMihomoCore.bundle")
        let contents = try bundle.appending("Contents")
        let macOS = try contents.appending("MacOS")
        try fileSystem.createDirectory(macOS)

        let info: [String: Any] = [
            "CFBundleIdentifier": VelaIPCConstants.expectedExternalCoreSigningIdentifier,
            "CFBundleName": bundleName,
            "CFBundlePackageType": "BNDL",
            "CFBundleExecutable": "mihomo",
            "CFBundleShortVersionString": "1.19.28",
            "CFBundleVersion": "1",
            "LSMinimumSystemVersion": "15.0",
            "VelaCoreVersion": "v1.19.28",
            "VelaCorePackageRevision": 1,
            "VelaCoreArchitecture": "arm64",
        ]
        let infoData = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try fileSystem.writeDataAtomically(
            infoData,
            to: try contents.appending("Info.plist"),
            replacingExisting: false
        )

        var magic = UInt32(MH_MAGIC_64).littleEndian
        var cpu = Int32(CPU_TYPE_ARM64).littleEndian
        var executable = withUnsafeBytes(of: &magic) { Data($0) }
        executable.append(withUnsafeBytes(of: &cpu) { Data($0) })
        let executablePath = try macOS.appending("mihomo")
        try fileSystem.writeDataAtomically(
            executable,
            to: executablePath,
            replacingExisting: false
        )
        let executableURL = root
            .appending(path: "VelaMihomoCore.bundle/Contents/MacOS/mihomo")
        guard chmod(executableURL.path, 0o500) == 0 else {
            throw POSIXRootFileSystemError.systemCall(operation: "chmod", code: errno)
        }

        let resources = try contents.appending("Resources")
        try fileSystem.createDirectory(resources)
        let executableSHA256 = IntegrityValue.sha256Hex(of: executable)
        var reportObject: [String: Any] = [
            "schemaVersion": 1,
            "suiteVersion": 1,
            "coreID": "v1.19.28-r1",
            "result": "passed",
            "generatedAt": "2026-07-13T00:00:00Z",
            "environment": [
                "macOS": "15.0", "architecture": "arm64", "vela": "0.6.0",
                "hostClass": "dedicated-release-lab", "userDataAccessed": false,
            ],
            "tests": [
                "version", "config-corpus", "controller-api", "websockets",
                "user-backend", "system-proxy", "tun-backend", "sleep-network",
                "rollback", "performance", "artifact-integrity",
            ].map { ["id": $0, "result": "passed"] },
            "knownDeviations": [],
            "evidenceVersion": 1,
            "artifacts": [
                "upstreamPayloadSHA256": executableSHA256,
                "candidateExecutableSHA256": executableSHA256,
                "factoryExecutableSHA256": String(repeating: "1", count: 64),
                "suiteSHA256": String(repeating: "2", count: 64),
                "corpusSHA256": String(repeating: "3", count: 64),
                "apiContractSHA256": String(repeating: "4", count: 64),
                "dedicatedHostEvidenceSHA256": String(repeating: "5", count: 64),
                "performanceReviewSHA256": String(repeating: "6", count: 64),
            ],
            "evidence": [
                "candidateVersion": [:], "factoryVersion": [:], "configCorpus": [:],
                "controllerAPI": [:], "webSockets": [:], "userBackend": [:],
                "dedicatedHost": [:], "rollback": [:], "performance": [:],
            ],
            "metrics": ["candidate": [:], "factory": [:], "ratios": [:]],
        ]
        mutateReport?(&reportObject)
        let compatibilityData = try JSONSerialization.data(
            withJSONObject: reportObject,
            options: [.sortedKeys]
        )
        try fileSystem.writeDataAtomically(
            compatibilityData,
            to: try resources.appending("compatibility.json"),
            replacingExisting: false
        )
        let compatibilitySHA256 = IntegrityValue.sha256Hex(of: compatibilityData)

        let selection = VerifiedCoreCatalogSelection(
            coreID: try #require(CoreID(rawValue: "v1.19.28-r1")),
            upstreamVersion: "v1.19.28",
            packageRevision: 1,
            sequence: 1,
            catalogSHA256: String(repeating: "a", count: 64),
            compatibility: VerifiedCoreCompatibilityConstraints(
                minimumVelaVersion: "0.6.0",
                minimumVelaBuild: 1,
                maximumVelaBuild: nil,
                minimumMacOS: "15.0",
                architectures: ["arm64"],
                helperProtocolMinimum: VelaIPCConstants.protocolMinimum,
                helperProtocolMaximum: VelaIPCConstants.protocolMaximum,
                dataSchemaMinimum: VelaIPCConstants.coreDataSchemaVersion,
                dataSchemaMaximum: VelaIPCConstants.coreDataSchemaVersion,
                controllerAPIProfile: "mihomo-v1.19.28",
                bundleIdentifier: VelaIPCConstants.expectedExternalCoreSigningIdentifier,
                compatibilitySuiteVersion: 1,
                compatibilityReportSHA256: compatibilitySHA256
            ),
            files: [
                VerifiedCoreFile(
                    role: .executable,
                    expectedSize: executable.count,
                    expectedSHA256: executableSHA256
                ),
                VerifiedCoreFile(
                    role: .compatibility,
                    expectedSize: compatibilityData.count,
                    expectedSHA256: compatibilitySHA256
                ),
            ]
        )
        let preflight = RootCoreBundlePreflight(
            fileSystem: fileSystem,
            expectedTeamIdentifier: "TEAM123456",
            signingInspector: signingInspector,
            versionProbe: CanonicalBundleVersionProbe()
        )
        try await operation(preflight, selection)
    }
}

private final class CanonicalBundleSigningInspector: PrivilegedCodeSigningInspecting,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let signingIdentifier: String
    private let teamIdentifier: String
    private var requirements: [String] = []

    init(
        signingIdentifier: String = VelaIPCConstants.expectedExternalCoreSigningIdentifier,
        teamIdentifier: String = "TEAM123456"
    ) {
        self.signingIdentifier = signingIdentifier
        self.teamIdentifier = teamIdentifier
    }

    func inspect(
        at _: URL,
        validateNestedCode _: Bool,
        requirement: PrivilegedCodeSigningRequirement?
    ) throws -> PrivilegedCodeSignature {
        lock.lock()
        requirements.append(requirement?.text ?? "missing")
        lock.unlock()
        return PrivilegedCodeSignature(
            signingIdentifier: signingIdentifier,
            teamIdentifier: teamIdentifier
        )
    }

    func requirementTexts() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return requirements
    }
}

private struct CanonicalBundleVersionProbe: FixedMihomoVersionProbing {
    func probe(executableURL _: URL, workingDirectoryURL _: URL) async throws
        -> MihomoVersionProbeResult
    {
        MihomoVersionProbeResult(
            status: 0,
            output: "Mihomo Meta v1.19.28 darwin arm64\n",
            timedOut: false
        )
    }
}
