import CryptoKit
import Darwin
import Foundation
import ServiceManagement
import XCTest
@testable import Vela
import VelaIPC
import VelaPrivilegedCore

/// These tests are intentionally hosted by the signed Vela application and are
/// never a registration mechanism. The operator must install/approve the helper
/// in Vela before running the dedicated, double-opt-in integration harness.
@MainActor
final class PrivilegedHandshakeStatusIntegrationTests: XCTestCase {
    func testSignedEnabledHelperHandshakeAndStatusAreReadOnly() async throws {
        try Self.requireExplicitOptIn()

        let context = try await Self.requireApprovedHelper(requireIdle: false)
        addTeardownBlock { await context.client.invalidate() }

        XCTAssertFalse(context.signatures.teamIdentifier.isEmpty)
        XCTAssertTrue(context.handshake.hasCompatibleProtocol)
        XCTAssertEqual(context.handshake.daemonUID, 0)
        XCTAssertEqual(context.handshake.currentOwnerUID, getuid())
        XCTAssertEqual(context.handshake.mihomoVersion, VelaIPCConstants.expectedMihomoVersion)
        XCTAssertEqual(context.handshake.mihomoPlatform, "darwin")
        XCTAssertEqual(context.handshake.mihomoArchitecture, "arm64")
        XCTAssertEqual(context.handshake.sessionID, context.sessionID)
        XCTAssertTrue(context.initialStatus.health.helperReachable)
        XCTAssertEqual(context.initialStatus.currentOwnerUID, getuid())
    }

    func testMalformedCommandPayloadIsRejectedBeforeEngineStart() async throws {
        try Self.requireExplicitOptIn()

        let context = try await Self.requireApprovedHelper(requireIdle: true)
        let cleanup = PrivilegedLifecycleCleanupHarness(
            client: context.client,
            sessionID: context.sessionID
        )
        addTeardownBlock { try await cleanup.stopCleanupVerifyAndInvalidate() }

        let rawConnection = RawPrivilegedXPCConnection()
        addTeardownBlock { rawConnection.invalidate() }

        let requestID = UUID()
        let payload = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": VelaIPCConstants.schemaVersion,
            "requestID": requestID.uuidString,
            "sessionID": context.sessionID.uuidString,
            "configurationSize": 0,
            "configurationSHA256": Self.sha256(Data()),
            "resources": [],
            "tunSettings": try Self.jsonObject(TunSettings.defaults),
            // RPC intentionally has no command/shell/executable vocabulary.
            "command": "/bin/sh",
        ])

        do {
            _ = try await rawConnection.prepareStart(payload, requestID: requestID)
            XCTFail("An unknown command field must be rejected by the real Helper transport")
        } catch {
            Self.assertHelperFailure(error, equals: .invalidPayload)
        }

        try Self.assertNoOwnedRuntime(try await context.client.status())
    }

    func testUnsafeResourceTraversalIsRejectedBeforeEngineStart() async throws {
        try Self.requireExplicitOptIn()

        let context = try await Self.requireApprovedHelper(requireIdle: true)
        let cleanup = PrivilegedLifecycleCleanupHarness(
            client: context.client,
            sessionID: context.sessionID
        )
        addTeardownBlock { try await cleanup.stopCleanupVerifyAndInvalidate() }

        let configuration = Self.minimalConfiguration(dnsEnabled: true)
        let request = PrepareStartRequest(
            sessionID: context.sessionID,
            configurationSize: configuration.count,
            configurationSHA256: Self.sha256(configuration),
            resources: [
                PrivilegedResourceDescriptor(
                    logicalID: "proxyProvider:escape",
                    relativeDestination: "providers/../../etc/passwd",
                    expectedSize: 0,
                    expectedSHA256: Self.sha256(Data()),
                    kind: .proxyProvider
                )
            ],
            tunSettings: .defaults
        )

        do {
            _ = try await context.client.prepareStart(request)
            XCTFail("A traversal destination must be rejected before staging or process start")
        } catch {
            Self.assertHelperFailure(error, equals: .unsafePath)
        }

        try Self.assertNoOwnedRuntime(try await context.client.status())
    }

    func testUnsafeConfigurationIsRejectedBeforeEngineStart() async throws {
        try Self.requireExplicitOptIn()

        let context = try await Self.requireApprovedHelper(requireIdle: true)
        let cleanup = PrivilegedLifecycleCleanupHarness(
            client: context.client,
            sessionID: context.sessionID
        )
        addTeardownBlock { try await cleanup.stopCleanupVerifyAndInvalidate() }

        let configuration = Data(
            """
            mode: rule
            log-level: warning
            dns:
              enable: true
              nameserver: [1.1.1.1]
            listeners:
              - name: forbidden-root-inbound
                type: http
                port: 80
                listen: 0.0.0.0
            proxies: []
            proxy-groups: []
            rules: [MATCH,DIRECT]
            """.utf8
        )
        let transaction = try await Self.prepareAndStage(
            configuration,
            settings: .defaults,
            context: context
        )

        do {
            let runtime = try await context.client.commitStart(
                CommitStartRequest(
                    sessionID: context.sessionID,
                    transactionID: transaction
                )
            )
            await cleanup.record(instanceID: runtime.instanceID)
            XCTFail("A forbidden listener must be rejected by the sanitizer before Mihomo starts")
        } catch {
            Self.assertHelperFailure(error, equals: .unsafeConfiguration)
        }

        try Self.assertNoOwnedRuntime(try await context.client.status())
    }

    func testMinimalTunLifecycleForMixedSystemAndGVisorStacks() async throws {
        try Self.requireExplicitOptIn()

        let context = try await Self.requireApprovedHelper(requireIdle: true)
        let cleanup = PrivilegedLifecycleCleanupHarness(
            client: context.client,
            sessionID: context.sessionID
        )
        addTeardownBlock { try await cleanup.stopCleanupVerifyAndInvalidate() }

        let cases: [TunLifecycleCase] = [
            TunLifecycleCase(stack: .mixed, dnsHijack: true),
            TunLifecycleCase(stack: .system, dnsHijack: false),
            TunLifecycleCase(stack: .gvisor, dnsHijack: true),
        ]

        for testCase in cases {
            try await context.client.renewLease(
                RenewLeaseRequest(
                    sessionID: context.sessionID,
                    instanceID: nil
                )
            )
            var settings = TunSettings.defaults
            settings.stack = testCase.stack
            settings.dnsHijack = testCase.dnsHijack
            settings.allowLocalNetwork = true
            settings.routeExcludeCIDRs = ["127.0.0.0/8", "::1/128"]
            settings.mtu = 1_500

            let configuration = Self.minimalConfiguration(
                dnsEnabled: testCase.dnsHijack
            )
            let transaction = try await Self.prepareAndStage(
                configuration,
                settings: settings,
                context: context
            )
            let runtime = try await context.client.commitStart(
                CommitStartRequest(
                    sessionID: context.sessionID,
                    transactionID: transaction
                )
            )
            await cleanup.record(instanceID: runtime.instanceID)

            XCTAssertEqual(runtime.controllerHost, "127.0.0.1")
            XCTAssertGreaterThanOrEqual(runtime.controllerPort, 1_024)
            XCTAssertFalse(runtime.controllerSecret.isEmpty)
            XCTAssertEqual(runtime.tunInterface?.hasPrefix("utun"), true)

            let running = try await Self.waitForHealthyRuntime(
                client: context.client,
                instanceID: runtime.instanceID,
                timeout: .seconds(15)
            )
            XCTAssertEqual(running.state, .running, "stack=\(testCase.stack.rawValue)")
            XCTAssertEqual(running.processID, runtime.processID)
            XCTAssertEqual(running.instanceID, runtime.instanceID)
            XCTAssertEqual(running.configurationSHA256, runtime.configurationSHA256)
            XCTAssertTrue(running.health.controllerReachable)
            XCTAssertTrue(running.health.configurationHashMatches)
            XCTAssertTrue(running.health.tunEnabledInController)
            XCTAssertTrue(running.health.tunInterfacePresent)
            XCTAssertTrue(running.health.routeApplied)
            XCTAssertTrue(running.health.dnsReady)
            XCTAssertTrue(running.health.ownerLeaseValid)
            XCTAssertEqual(running.health.tunInterface, runtime.tunInterface)

            try await cleanup.stopCleanupAndVerify()
        }
    }

    private static func requireExplicitOptIn() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["VELA_RUN_PRIVILEGED_TESTS"] == "1",
            environment["VELA_PRIVILEGED_TESTS_CONFIRM"] == "YES"
        else {
            throw XCTSkip(
                "Privileged integration tests require VELA_RUN_PRIVILEGED_TESTS=1 "
                    + "and VELA_PRIVILEGED_TESTS_CONFIRM=YES"
            )
        }
    }

    private static func requireApprovedHelper(
        requireIdle: Bool
    ) async throws -> ApprovedHelperContext {
        guard geteuid() != 0 else {
            throw PrivilegedIntegrationPrerequisiteError.rootExecutionForbidden
        }

        let layout = try requireExactHostedApplication()
        let signatures = try requireTrustedSameTeamSignatures(layout: layout)
        let service = SMAppService.daemon(
            plistName: VelaIPCConstants.launchDaemonPlistName
        )
        guard service.status == .enabled else {
            throw PrivilegedIntegrationPrerequisiteError.helperNotEnabled(
                String(describing: service.status)
            )
        }

        let client = PrivilegedHelperClient(requestTimeout: .seconds(45))
        do {
            let handshake = try await client.handshake(
                clientVersion: bundleValue("CFBundleShortVersionString", fallback: "0.5.0"),
                clientBuild: bundleValue("CFBundleVersion", fallback: "2026071301"),
                requestedSessionID: nil
            )
            guard let sessionID = handshake.sessionID else {
                await client.invalidate()
                throw PrivilegedIntegrationPrerequisiteError.missingOwnerSession
            }
            let status = try await client.status()
            if requireIdle {
                do {
                    try assertNoOwnedRuntime(status)
                    guard status.state == .stopped else {
                        throw PrivilegedIntegrationPrerequisiteError.helperNotIdle(
                            String(describing: status.state)
                        )
                    }
                } catch {
                    await client.invalidate()
                    throw error
                }
            }
            return ApprovedHelperContext(
                client: client,
                sessionID: sessionID,
                handshake: handshake,
                initialStatus: status,
                signatures: signatures
            )
        } catch {
            await client.invalidate()
            throw error
        }
    }

    private static func requireExactHostedApplication() throws
        -> FixedPrivilegedBundleLayout
    {
        guard Bundle.main.bundleIdentifier == VelaIPCConstants.mainBundleIdentifier,
            let executableURL = Bundle.main.executableURL
        else {
            throw PrivilegedIntegrationPrerequisiteError.notHostedByVela
        }

        let expectedExecutable = Bundle.main.bundleURL
            .appending(path: "Contents/MacOS/Vela")
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let currentExecutable = URL(
            fileURLWithPath: CommandLine.arguments[0],
            isDirectory: false
        ).standardizedFileURL.resolvingSymlinksInPath()
        guard executableURL.standardizedFileURL.resolvingSymlinksInPath()
                == expectedExecutable,
            currentExecutable == expectedExecutable
        else {
            throw PrivilegedIntegrationPrerequisiteError.notHostedByVela
        }
        return try FixedPrivilegedBundleLayout(applicationURL: Bundle.main.bundleURL)
    }

    private static func requireTrustedSameTeamSignatures(
        layout: FixedPrivilegedBundleLayout
    ) throws -> SignaturePrerequisites {
        let inspector = SecurityPrivilegedCodeSigningInspector()
        let application = try inspector.inspect(
            at: layout.applicationURL,
            validateNestedCode: true
        )
        let helper = try inspector.inspect(at: layout.helperURL, validateNestedCode: false)
        let mihomo = try inspector.inspect(at: layout.mihomoURL, validateNestedCode: false)

        guard application.signingIdentifier == VelaIPCConstants.mainBundleIdentifier,
            helper.signingIdentifier == VelaIPCConstants.helperIdentifier,
            mihomo.signingIdentifier == VelaIPCConstants.expectedMihomoSigningIdentifier,
            application.teamIdentifier == helper.teamIdentifier,
            helper.teamIdentifier == mihomo.teamIdentifier,
            !application.teamIdentifier.isEmpty
        else {
            throw PrivilegedIntegrationPrerequisiteError.signatureMismatch
        }
        return SignaturePrerequisites(teamIdentifier: application.teamIdentifier)
    }

    private static func prepareAndStage(
        _ configuration: Data,
        settings: TunSettings,
        context: ApprovedHelperContext
    ) async throws -> UUID {
        let hash = sha256(configuration)
        let prepared = try await context.client.prepareStart(
            PrepareStartRequest(
                sessionID: context.sessionID,
                configurationSize: configuration.count,
                configurationSHA256: hash,
                resources: [],
                tunSettings: settings
            )
        )
        try await context.client.stageConfiguration(
            StageConfigurationRequest(
                sessionID: context.sessionID,
                transactionID: prepared.transactionID,
                expectedSize: configuration.count,
                expectedSHA256: hash
            ),
            data: configuration
        )
        return prepared.transactionID
    }

    private static func minimalConfiguration(dnsEnabled: Bool) -> Data {
        let dns = dnsEnabled
            ? """
              dns:
                enable: true
                enhanced-mode: fake-ip
                nameserver: [1.1.1.1]
              """
            : """
              dns:
                enable: false
              """
        return Data(
            """
            mode: rule
            log-level: warning
            \(dns)
            proxies: []
            proxy-groups:
              - name: PROXY
                type: select
                proxies: [DIRECT]
            rules: [MATCH,DIRECT]
            """.utf8
        )
    }

    private static func waitForHealthyRuntime(
        client: PrivilegedHelperClient,
        instanceID: UUID,
        timeout: Duration
    ) async throws -> HelperStatusResponse {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        var last = try await client.status()
        while ContinuousClock.now < deadline {
            if last.instanceID == instanceID,
                last.state == .running,
                last.health.processRunning,
                last.health.controllerReachable,
                last.health.configurationHashMatches,
                last.health.tunEnabledInController,
                last.health.tunInterfacePresent,
                last.health.routeApplied,
                last.health.dnsReady,
                last.health.ownerLeaseValid
            {
                return last
            }
            try await Task.sleep(for: .milliseconds(200))
            last = try await client.status()
        }
        throw PrivilegedIntegrationPrerequisiteError.runtimeDidNotBecomeHealthy(
            String(describing: last.state)
        )
    }

    private static func assertNoOwnedRuntime(_ status: HelperStatusResponse) throws {
        guard !status.health.processRunning,
            !status.health.tunInterfacePresent,
            !status.health.routeApplied,
            status.processID == nil,
            status.instanceID == nil,
            status.health.tunInterface == nil
        else {
            throw PrivilegedIntegrationPrerequisiteError.helperNotIdle(
                String(describing: status.state)
            )
        }
    }

    private static func assertHelperFailure(
        _ error: Error,
        equals expected: VelaHelperErrorCode,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if let failure = error as? VelaHelperFailure {
            XCTAssertEqual(failure.code, expected, file: file, line: line)
            return
        }
        let nsError = error as NSError
        XCTAssertEqual(nsError.domain, VelaHelperErrorDomain, file: file, line: line)
        XCTAssertEqual(nsError.code, expected.rawValue, file: file, line: line)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func jsonObject<Value: Encodable>(_ value: Value) throws -> Any {
        let data = try JSONEncoder().encode(value)
        return try JSONSerialization.jsonObject(with: data)
    }

    private static func bundleValue(_ key: String, fallback: String) -> String {
        Bundle.main.object(forInfoDictionaryKey: key) as? String ?? fallback
    }
}

private struct ApprovedHelperContext: Sendable {
    let client: PrivilegedHelperClient
    let sessionID: UUID
    let handshake: HelperHandshakeResponse
    let initialStatus: HelperStatusResponse
    let signatures: SignaturePrerequisites
}

private struct SignaturePrerequisites: Sendable {
    let teamIdentifier: String
}

private struct TunLifecycleCase: Sendable {
    let stack: TunStack
    let dnsHijack: Bool
}

private enum PrivilegedIntegrationPrerequisiteError: Error, LocalizedError {
    case rootExecutionForbidden
    case notHostedByVela
    case signatureMismatch
    case helperNotEnabled(String)
    case missingOwnerSession
    case helperNotIdle(String)
    case runtimeDidNotBecomeHealthy(String)

    var errorDescription: String? {
        switch self {
        case .rootExecutionForbidden:
            "Privileged integration tests must run as the signed-in user, never root"
        case .notHostedByVela:
            "The test bundle is not hosted by the exact Vela application executable"
        case .signatureMismatch:
            "Vela, VelaHelper, and Mihomo require valid non-ad-hoc same-Team signatures"
        case let .helperNotEnabled(status):
            "Approve the privileged helper in Vela before testing (status: \(status)); tests never register it"
        case .missingOwnerSession:
            "The approved helper did not grant an owner session"
        case let .helperNotIdle(state):
            "The helper must be idle before a mutating integration test (state: \(state)); no existing runtime was stopped"
        case let .runtimeDidNotBecomeHealthy(state):
            "The privileged runtime did not reach complete Controller/TUN/route/DNS health (last state: \(state))"
        }
    }
}

private enum PrivilegedIntegrationCleanupError: Error, LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case let .failed(message): message
        }
    }
}

/// A teardown-owned cleanup capability. It can only address the session and
/// instance IDs returned by the authenticated helper; it cannot name a PID,
/// interface, route, executable, shell command, or arbitrary filesystem path.
private actor PrivilegedLifecycleCleanupHarness {
    private let client: PrivilegedHelperClient
    private let sessionID: UUID
    private var instanceID: UUID?
    private var invalidated = false

    init(client: PrivilegedHelperClient, sessionID: UUID) {
        self.client = client
        self.sessionID = sessionID
    }

    func record(instanceID: UUID) {
        self.instanceID = instanceID
    }

    func stopCleanupAndVerify() async throws {
        guard !invalidated else { return }
        var failures: [String] = []
        let statusBefore = try? await client.status()
        let ownedInstanceID = statusBefore?.instanceID ?? instanceID

        do {
            try await client.stop(
                StopHelperRequest(
                    sessionID: sessionID,
                    instanceID: ownedInstanceID,
                    reason: .recovery
                )
            )
        } catch {
            failures.append("authenticated stop failed")
        }

        do {
            try await client.cleanup(
                CleanupHelperRequest(sessionID: sessionID, mode: .runtimeOnly)
            )
        } catch {
            failures.append("bounded runtime cleanup failed")
        }

        do {
            try await verifyStopped()
            instanceID = nil
        } catch {
            failures.append("post-cleanup status still reports an owned process, interface, or route")
        }

        if !failures.isEmpty {
            throw PrivilegedIntegrationCleanupError.failed(failures.joined(separator: "; "))
        }
    }

    func stopCleanupVerifyAndInvalidate() async throws {
        do {
            try await stopCleanupAndVerify()
        } catch {
            await client.invalidate()
            invalidated = true
            throw error
        }
        await client.invalidate()
        invalidated = true
    }

    private func verifyStopped() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        var status = try await client.status()
        while ContinuousClock.now < deadline {
            if !status.health.processRunning,
                !status.health.tunInterfacePresent,
                !status.health.routeApplied,
                status.processID == nil,
                status.instanceID == nil,
                status.health.tunInterface == nil
            {
                return
            }
            try await Task.sleep(for: .milliseconds(200))
            status = try await client.status()
        }
        throw PrivilegedIntegrationCleanupError.failed("cleanup verification timed out")
    }
}

private final class RawPrivilegedXPCConnection: @unchecked Sendable {
    private let connection: NSXPCConnection

    init() {
        connection = NSXPCConnection(
            machServiceName: VelaIPCConstants.machServiceName,
            options: .privileged
        )
        connection.remoteObjectInterface = VelaHelperXPCInterface.make()
        connection.activate()
    }

    func prepareStart(_ payload: Data, requestID: UUID) async throws -> Data {
        let gate = XPCReplyGate<Data>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                gate.install(continuation)
                gate.scheduleTimeout(after: .seconds(5), requestID: requestID)
                guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                    gate.fail(error)
                }) as? any VelaHelperProtocol else {
                    gate.fail(
                        VelaHelperFailure(
                            code: .helperUnavailable,
                            requestID: requestID,
                            safeMessage: "The privileged component proxy is unavailable."
                        )
                    )
                    return
                }
                proxy.prepareStart(payload) { data, error in
                    if let error {
                        gate.fail(error)
                    } else if let data {
                        gate.succeed(data)
                    } else {
                        gate.fail(
                            VelaHelperFailure(
                                code: .invalidPayload,
                                requestID: requestID,
                                safeMessage: "The privileged component returned an empty response."
                            )
                        )
                    }
                }
            }
        } onCancel: {
            gate.fail(CancellationError())
        }
    }

    func invalidate() {
        connection.invalidate()
    }
}
