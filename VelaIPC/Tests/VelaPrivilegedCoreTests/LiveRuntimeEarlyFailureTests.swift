import Darwin
import Foundation
import Testing
import VelaIPC
@testable import VelaPrivilegedCore

@Suite("Live runtime early launch failure recovery")
struct LiveRuntimeEarlyFailureTests {
    @Test("An immediate child exit before identity capture restores a clean journal")
    func immediateExitDoesNotLeavePermanentDirtyJournal() async throws {
        let root = URL.temporaryDirectory.appending(path: "VelaEarlyExit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: root.path
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let fileSystem = try POSIXRootFileSystem.openExisting(
            at: root,
            policy: PrivilegedOwnershipPolicy(userID: getuid(), groupID: getgid())
        )
        let directories = PrivilegedDirectories(fileSystem: fileSystem)
        let transactions = RootTransactionStore(fileSystem: fileSystem)
        let journal = RootJournalStore(fileSystem: fileSystem)
        try await journal.prepare()
        let sessionID = UUID()
        let input = Data("mode: rule\n".utf8)
        let inputHash = IntegrityValue.sha256Hex(of: input)
        let prepared = try await transactions.prepare(
            request: PrepareStartRequest(
                sessionID: sessionID,
                configurationSize: input.count,
                configurationSHA256: inputHash,
                resources: [],
                tunSettings: TunSettings(dnsHijack: false)
            ),
            ownerUID: UInt32(getuid())
        )
        try await transactions.stageConfiguration(
            request: StageConfigurationRequest(
                sessionID: sessionID,
                transactionID: prepared.transactionID,
                expectedSize: input.count,
                expectedSHA256: inputHash
            ),
            configuration: input
        )
        let sanitizedData = Data("mode: rule\ntun:\n  enable: false\n".utf8)
        let sanitizedHash = IntegrityValue.sha256Hex(of: sanitizedData)
        try await transactions.markSanitized(
            transactionID: prepared.transactionID,
            sessionID: sessionID,
            data: sanitizedData,
            sha256: sanitizedHash
        )
        let runtimePackage = try await transactions.promoteSanitized(
            transactionID: prepared.transactionID,
            sessionID: sessionID
        )
        let sanitized = SanitizedRuntimeConfiguration(
            data: sanitizedData,
            sha256: sanitizedHash,
            controllerPort: 54_321,
            controllerSecret: SecretValue("test-secret"),
            changes: []
        )

        let executableStore = TrustedMihomoExecutableStore(fileSystem: fileSystem)
        let executable = try executableStore.installBundledExecutable(
            from: URL(fileURLWithPath: "/usr/bin/true")
        )
        let signature = PrivilegedCodeSignature(
            signingIdentifier: VelaIPCConstants.expectedMihomoSigningIdentifier,
            teamIdentifier: "TEAM123456"
        )
        let preflight = SuccessfulEarlyFailurePreflight(signature: signature)
        let engine = LivePrivilegedRuntimeController(
            directories: directories,
            executableStore: executableStore,
            expectedHelperSignature: PrivilegedCodeSignature(
                signingIdentifier: VelaIPCConstants.helperIdentifier,
                teamIdentifier: signature.teamIdentifier
            ),
            journalStore: journal,
            transactionStore: transactions,
            trustedExecutable: executable,
            preflight: preflight,
            commandRunner: SuccessfulValidationRunner(),
            processInspector: AlwaysUnavailableProcessInspector(),
            tunInterfaceLister: EarlyFailureTunInterfaceLister(),
            effectiveUserID: { 0 }
        )

        await #expect(throws: ProcessIdentityError.processUnavailable) {
            _ = try await engine.start(
                PrivilegedEngineStartContext(
                    transaction: runtimePackage.transaction,
                    sanitizedConfiguration: sanitized
                )
            )
        }
        let recoveredJournal = try #require(await journal.load())
        #expect(recoveredJournal.lastCleanShutdown)
        #expect(recoveredJournal.processIdentity == nil)
    }
}

private struct SuccessfulEarlyFailurePreflight: FixedMihomoPreflighting {
    let signature: PrivilegedCodeSignature
    func run(
        executable: TrustedMihomoExecutable,
        expectedHelperSignature: PrivilegedCodeSignature,
        workingDirectoryURL _: URL
    ) async throws -> FixedMihomoPreflightResult {
        FixedMihomoPreflightResult(
            executable: executable,
            helperSignature: expectedHelperSignature,
            mihomoSignature: signature,
            executableIdentity: executable.identity,
            versionOutput: "Mihomo Meta v1.19.28 darwin arm64\n"
        )
    }
}

private struct SuccessfulValidationRunner: FixedMihomoCommandRunning {
    func validateConfiguration(
        executableURL _: URL,
        dataDirectoryURL _: URL,
        configurationURL _: URL
    ) async throws -> FixedMihomoCommandResult {
        FixedMihomoCommandResult(status: 0, output: "", timedOut: false)
    }
}

private struct AlwaysUnavailableProcessInspector: LiveProcessInspecting {
    func inspect(
        processID _: Int32,
        expectedExecutableURL _: URL
    ) throws -> LiveProcessSnapshot {
        throw ProcessIdentityError.processUnavailable
    }
}

private struct EarlyFailureTunInterfaceLister: PrivilegedTunInterfaceListing {
    func currentInterfaces() -> Set<String>? { [] }
}
