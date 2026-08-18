import Foundation
import Testing
@testable import VelaIPC

@Suite("Vela privileged IPC")
struct VelaIPCTests {
    @Test("Handshake fixture decodes and round trips with schema v1")
    func handshakeFixtureRoundTrip() throws {
        let data = try fixtureData("helper-handshake-request.json")
        let request = try HelperPayloadCodec.decode(HelperHandshakeRequest.self, from: data)

        #expect(request.schemaVersion == 1)
        #expect(request.clientProtocolMinimum == 1)
        #expect(request.clientProtocolMaximum == 1)
        #expect(request.requestedSessionID == nil)

        let encoded = try HelperPayloadCodec.encode(request)
        #expect(try HelperPayloadCodec.decode(HelperHandshakeRequest.self, from: encoded) == request)
    }

    @Test("A v1 Helper response is incompatible after the v2 protocol bump")
    func handshakeResponseCompatibility() throws {
        let response = try HelperPayloadCodec.decode(
            HelperHandshakeResponse.self,
            from: fixtureData("helper-handshake-response.json")
        )
        #expect(!response.hasCompatibleProtocol)
        #expect(response.daemonUID == 0)
        #expect(response.mihomoVersion == "v1.19.28")
    }

    @Test("CoreID accepts only canonical factory and installed forms")
    func strictCoreIDGrammar() throws {
        let factory = try CoreID.factory(version: "v1.19.28")
        #expect(factory == .factoryV11928)
        #expect(factory.isFactory)
        #expect(factory.upstreamVersion == "v1.19.28")
        #expect(factory.packageRevision == nil)

        let installed = try #require(CoreID(rawValue: "v1.19.28-r2"))
        #expect(!installed.isFactory)
        #expect(installed.packageRevision == 2)
        for invalid in [
            "factory", "factory:1.19.28", "factory:v01.19.28", "v1.19.28-r0",
            "v1.19.28-r01", "v1.19-r1", "../v1.19.28-r1", "v1.19.28/r1",
            "v1.19.28-r1 --shell",
        ] {
            #expect(CoreID(rawValue: invalid) == nil)
        }
    }

    @Test("A v2 start request requires an explicit CoreID on the wire")
    func startRequiresCoreIDWhenDecoding() throws {
        let request = PrepareStartRequest(
            sessionID: UUID(),
            configurationSize: 1,
            configurationSHA256: String(repeating: "0", count: 64),
            resources: [],
            tunSettings: .defaults,
            coreID: .factoryV11928
        )
        let data = try HelperPayloadCodec.encode(request)
        let decoded = try HelperPayloadCodec.decode(PrepareStartRequest.self, from: data)
        #expect(decoded.coreID == .factoryV11928)

        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "coreID")
        let missing = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: VelaHelperFailure.self) {
            try HelperPayloadCodec.decode(PrepareStartRequest.self, from: missing)
        }
    }

    @Test("Core RPC DTOs cannot carry open-ended root capabilities")
    func coreRPCBoundary() {
        let forbidden = Set([
            "url", "path", "executable", "shell", "pid", "chmod", "chown",
            "teamIdentifier", "teamID",
        ])
        let keySets: [Set<String>] = [
            PrepareCoreInstallRequest.allowedKeys,
            StageCoreFileRequest.allowedKeys,
            CommitCoreInstallRequest.allowedKeys,
            ListInstalledCoresRequest.allowedKeys,
            RefreshCoreCatalogRequest.allowedKeys,
            RefreshCoreCatalogResponse.allowedKeys,
            CoreIDRequest.allowedKeys,
        ]
        for keys in keySets {
            #expect(keys.isDisjoint(with: forbidden))
        }
        #expect(Set(CoreFileRole.allCases) == [
            .infoPlist, .executable, .codeResources, .license, .notice, .source,
            .compatibility,
        ])
    }

    @Test("Unknown schema and fields fail closed")
    func strictSchemaAndKeys() throws {
        let unknownSchema = Data(
            #"{"schemaVersion":2,"requestID":"C02E8573-7B1C-4AF0-B034-952849B2E28C","sessionID":null}"#.utf8
        )
        #expect(throws: VelaHelperFailure.self) {
            try HelperPayloadCodec.decode(HelperStatusRequest.self, from: unknownSchema)
        }

        let unknownField = Data(
            #"{"schemaVersion":1,"requestID":"C02E8573-7B1C-4AF0-B034-952849B2E28C","sessionID":null,"command":"/bin/sh"}"#.utf8
        )
        do {
            _ = try HelperPayloadCodec.decode(HelperStatusRequest.self, from: unknownField)
            Issue.record("Unknown IPC fields must be rejected")
        } catch let failure as VelaHelperFailure {
            #expect(failure.code == .invalidPayload)
        }
    }

    @Test("Nested TUN fields fail closed")
    func strictNestedKeys() throws {
        let sessionID = UUID()
        let request = PrepareStartRequest(
            sessionID: sessionID,
            configurationSize: 1,
            configurationSHA256: String(repeating: "0", count: 64),
            resources: [],
            tunSettings: .defaults
        )
        let encoded = try HelperPayloadCodec.encode(request)
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        var tun = try #require(object["tunSettings"] as? [String: Any])
        tun["linuxUID"] = 0
        object["tunSettings"] = tun
        let malicious = try JSONSerialization.data(withJSONObject: object)

        #expect(throws: VelaHelperFailure.self) {
            try HelperPayloadCodec.decode(PrepareStartRequest.self, from: malicious)
        }
    }

    @Test("Payload limits and invalid JSON are rejected")
    func sizeAndJSONLimits() {
        let oversized = Data(repeating: 0x20, count: 65)
        #expect(throws: VelaHelperFailure.self) {
            try HelperPayloadCodec.decode(
                HelperStatusRequest.self,
                from: oversized,
                maximumBytes: 64
            )
        }
        #expect(throws: VelaHelperFailure.self) {
            try HelperPayloadCodec.decode(
                HelperStatusRequest.self,
                from: Data("not-json".utf8)
            )
        }
    }

    @Test("SecretValue never reveals its storage through standard presentation")
    func secretRedaction() {
        let raw = "controller-secret-should-never-appear"
        let secret = SecretValue(raw)
        #expect(secret.description == "<redacted>")
        #expect(secret.debugDescription == "SecretValue(<redacted>)")
        let reflected = String(reflecting: secret.customMirror.children.first?.value)
        #expect(!reflected.contains(raw))
        #expect(secret.withValue { $0 } == raw)
    }

    @Test("Privileged runtime presentation and reflection redact its Controller secret")
    func privilegedRuntimeRedaction() {
        let raw = "runtime-controller-secret"
        let runtime = PrivilegedEngineRuntime(
            requestID: UUID(),
            instanceID: UUID(),
            controllerHost: "127.0.0.1",
            controllerPort: 9_090,
            controllerSecret: raw,
            processID: 42,
            startedAt: .now,
            configurationSHA256: String(repeating: "a", count: 64),
            tunInterface: "utun9"
        )
        #expect(!runtime.description.contains(raw))
        #expect(!runtime.debugDescription.contains(raw))
        #expect(!String(reflecting: runtime).contains(raw))
        #expect(String(reflecting: runtime).contains("<redacted>"))
    }

    @Test("TUN settings validate device, interface, ports, MTU and CIDRs")
    func tunValidation() throws {
        var settings = TunSettings.defaults
        settings.device = "utun12"
        settings.routeExcludeCIDRs = ["192.168.1.0/24", "2001:db8::/32"]
        settings.localMixedPort = 7_890
        #expect(try settings.validated().routeExcludeCIDRs.count == 2)

        settings.device = "en0"
        #expect(throws: TunSettingsValidationError.self) {
            try settings.validated()
        }
        settings.device = "utun"
        #expect(throws: TunSettingsValidationError.self) {
            try settings.validated()
        }
        settings.device = "utun123456789012"
        #expect(throws: TunSettingsValidationError.self) {
            try settings.validated()
        }
        settings.device = nil
        settings.mtu = 9_001
        #expect(throws: TunSettingsValidationError.self) {
            try settings.validated()
        }
        settings.mtu = nil
        settings.routeExcludeCIDRs = ["../../etc/passwd"]
        #expect(throws: TunSettingsValidationError.self) {
            try settings.validated()
        }
    }

    @Test("Helper errors use stable domain and code without an underlying secret")
    func stableNSError() {
        let failure = VelaHelperFailure(
            code: .unsafeConfiguration,
            requestID: UUID(),
            safeMessage: "The root configuration was rejected."
        )
        let error = failure.nsError
        #expect(error.domain == VelaHelperErrorDomain)
        #expect(error.code == VelaHelperErrorCode.unsafeConfiguration.rawValue)
        #expect(error.userInfo[NSUnderlyingErrorKey] == nil)
    }

    @Test("Mapping a stable failure fills a missing request identifier")
    func stableFailureRequestID() {
        let requestID = UUID()
        let mapped = VelaHelperFailure.from(
            VelaHelperFailure(
                code: .invalidSession,
                safeMessage: "The session is invalid."
            ),
            requestID: requestID
        )
        #expect(mapped.requestID == requestID)
        #expect(mapped.code == .invalidSession)
    }

    private func fixtureData(_ name: String) throws -> Data {
        let packageDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let repositoryRoot = packageDirectory.deletingLastPathComponent()
        let url = repositoryRoot
            .appendingPathComponent("Docs/V1/Vela-v0.3-Privileged-TUN-Codex-Pack/fixtures")
            .appendingPathComponent(name)
        return try Data(contentsOf: url)
    }
}
