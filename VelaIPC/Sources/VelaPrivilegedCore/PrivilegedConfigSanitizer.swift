import CryptoKit
import Foundation
import Security
import VelaIPC
import Yams

public enum PrivilegedLaunchMode: Equatable, Sendable {
    case tunEnabled
    /// Only privileged integration tests may use this mode. It is not an IPC field.
    case preflightWithoutTun
}

public enum SanitizerChangeAction: String, Codable, Sendable {
    case removed
    case overwritten
    case replaced
    case resourceRewritten
}

public struct SanitizerChange: Codable, Equatable, Sendable {
    public let path: String
    public let action: SanitizerChangeAction

    public init(path: String, action: SanitizerChangeAction) {
        self.path = path
        self.action = action
    }
}

public struct SanitizedRuntimeConfiguration: Sendable,
    CustomStringConvertible, CustomDebugStringConvertible
{
    public let data: Data
    public let sha256: String
    public let controllerPort: UInt16
    public let controllerSecret: SecretValue
    public let changes: [SanitizerChange]

    public var description: String {
        "SanitizedRuntimeConfiguration(sha256: \(sha256.prefix(12)), secret: <redacted>)"
    }

    public var debugDescription: String { description }
}

public protocol ControllerSecretGenerating: Sendable {
    func makeSecret() throws -> SecretValue
}

public struct SecureControllerSecretGenerator: ControllerSecretGenerating {
    public init() {}

    public func makeSecret() throws -> SecretValue {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw PrivilegedConfigSanitizerError.randomSecretUnavailable
        }
        let value = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return SecretValue(value)
    }
}

public enum PrivilegedConfigSanitizerError: Error, Equatable, Sendable {
    case configurationTooLarge
    case invalidUTF8
    case invalidYAML
    case rootIsNotMapping
    case complexityLimitExceeded
    case aliasesLimitExceeded
    case unsafeInbound(String)
    case invalidControllerPort
    case localMixedPortConflictsWithController
    case dnsPreconditionFailed
    case unsupportedLocalResource(String)
    case missingStagedResource(String)
    case duplicateStagedResource(String)
    case unusedStagedResource(String)
    case serializationFailed
    case randomSecretUnavailable
}

extension PrivilegedConfigSanitizerError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .configurationTooLarge:
            "The privileged configuration exceeds its size limit."
        case .invalidUTF8:
            "The privileged configuration is not valid UTF-8."
        case .invalidYAML, .rootIsNotMapping:
            "The privileged configuration is not a single YAML mapping."
        case .complexityLimitExceeded, .aliasesLimitExceeded:
            "The privileged configuration is too complex."
        case .unsafeInbound:
            "The privileged configuration requested an unsafe inbound listener."
        case .invalidControllerPort, .localMixedPortConflictsWithController:
            "The privileged controller port is invalid."
        case .dnsPreconditionFailed:
            "DNS hijacking requires enabled Mihomo DNS with at least one nameserver."
        case .unsupportedLocalResource, .missingStagedResource,
            .duplicateStagedResource, .unusedStagedResource:
            "The privileged configuration contains an unsupported local resource."
        case .serializationFailed:
            "The privileged configuration could not be serialized safely."
        case .randomSecretUnavailable:
            "The privileged controller secret could not be generated."
        }
    }
}

public struct PrivilegedConfigSanitizer: Sendable {
    private static let maximumNodeCount = 100_000
    private static let maximumDepth = 128
    private static let maximumAliasIndicators = 16

    private let secretGenerator: any ControllerSecretGenerating

    public init(
        secretGenerator: any ControllerSecretGenerating = SecureControllerSecretGenerator()
    ) {
        self.secretGenerator = secretGenerator
    }

    public func sanitize(
        configuration: Data,
        tunSettings: TunSettings,
        resources: [SanitizerResource],
        controllerPort: UInt16,
        launchMode: PrivilegedLaunchMode = .tunEnabled
    ) throws -> SanitizedRuntimeConfiguration {
        guard configuration.count <= VelaIPCConstants.maximumConfigurationBytes else {
            throw PrivilegedConfigSanitizerError.configurationTooLarge
        }
        guard let yaml = String(data: configuration, encoding: .utf8),
            !yaml.unicodeScalars.contains(where: { $0.value == 0 })
        else {
            throw PrivilegedConfigSanitizerError.invalidUTF8
        }
        guard controllerPort >= 1_024 else {
            throw PrivilegedConfigSanitizerError.invalidControllerPort
        }

        try YAMLSecurityBudget.validate(
            yaml,
            maximumDepth: Self.maximumDepth,
            maximumAliasIndicators: Self.maximumAliasIndicators
        )

        let composed: Node
        do {
            guard let node = try compose(yaml: yaml) else {
                throw PrivilegedConfigSanitizerError.invalidYAML
            }
            composed = node
        } catch let error as PrivilegedConfigSanitizerError {
            throw error
        } catch {
            // `compose` uses Yams' single-root parser and therefore rejects a
            // multi-document stream before any trusted output is produced.
            throw PrivilegedConfigSanitizerError.invalidYAML
        }

        var budget = YAMLNodeBudget(
            remainingNodes: Self.maximumNodeCount,
            maximumDepth: Self.maximumDepth
        )
        let decoded = try SecureYAMLValue(node: composed, depth: 0, budget: &budget)
        guard case var .mapping(root) = decoded else {
            throw PrivilegedConfigSanitizerError.rootIsNotMapping
        }

        let settings = try tunSettings.validated()
        if let mixedPort = settings.localMixedPort, mixedPort == controllerPort {
            throw PrivilegedConfigSanitizerError.localMixedPortConflictsWithController
        }
        if settings.dnsHijack {
            try Self.validateDNS(in: root)
        }

        let secret = try secretGenerator.makeSecret()
        var changes: [SanitizerChange] = []
        try Self.rejectServerInbounds(in: root)
        Self.removeControllerExpansionFields(from: &root, changes: &changes)
        Self.removeRootPrivilegeSurfaces(from: &root, changes: &changes)
        try Self.rewriteProviders(
            in: &root,
            resources: resources,
            changes: &changes
        )
        try Self.rejectUnsupportedPathDependencies(in: .mapping(root), path: [])

        Self.force(
            .string("127.0.0.1:\(controllerPort)"),
            key: "external-controller",
            into: &root,
            changes: &changes
        )
        secret.withValue {
            Self.force(.string($0), key: "secret", into: &root, changes: &changes)
        }
        Self.force(.bool(false), key: "allow-lan", into: &root, changes: &changes)
        Self.force(.string("127.0.0.1"), key: "bind-address", into: &root, changes: &changes)
        Self.force(.bool(false), key: "geo-auto-update", into: &root, changes: &changes)
        for key in ["port", "socks-port", "redir-port", "tproxy-port"] {
            Self.force(.integer(0), key: key, into: &root, changes: &changes)
        }
        Self.force(
            .integer(Int(settings.localMixedPort ?? 0)),
            key: "mixed-port",
            into: &root,
            changes: &changes
        )
        Self.force(
            .mapping(Self.tunMapping(settings: settings, launchMode: launchMode)),
            key: "tun",
            into: &root,
            changes: &changes,
            action: .replaced
        )

        let serialized: String
        do {
            serialized = try Yams.dump(object: SecureYAMLValue.mapping(root).foundationValue)
        } catch {
            throw PrivilegedConfigSanitizerError.serializationFailed
        }
        guard let data = serialized.data(using: .utf8),
            data.count <= VelaIPCConstants.maximumConfigurationBytes
        else {
            throw PrivilegedConfigSanitizerError.serializationFailed
        }

        return SanitizedRuntimeConfiguration(
            data: data,
            sha256: IntegrityValue.sha256Hex(of: data),
            controllerPort: controllerPort,
            controllerSecret: secret,
            changes: changes.sorted {
                ($0.path, $0.action.rawValue) < ($1.path, $1.action.rawValue)
            }
        )
    }

    private static func rejectServerInbounds(in root: [String: SecureYAMLValue]) throws {
        for key in ["listeners", "tunnels", "tuic-server", "ss-config", "vmess-config"] {
            if root[key] != nil {
                throw PrivilegedConfigSanitizerError.unsafeInbound(key)
            }
        }
    }

    private static func removeControllerExpansionFields(
        from root: inout [String: SecureYAMLValue],
        changes: inout [SanitizerChange]
    ) {
        let removedKeys = [
            "external-controller-tls", "external-controller-unix",
            "external-controller-pipe", "external-ui", "external-ui-url",
            "external-ui-name", "external-doh-server", "external-controller-cors",
        ]
        for key in removedKeys where root.removeValue(forKey: key) != nil {
            changes.append(SanitizerChange(path: key, action: .removed))
        }
    }

    /// Removes configuration surfaces whose effects would be amplified by the
    /// Helper's root identity. Vela does not expose typed controls for these
    /// capabilities, so retaining them would let an otherwise ordinary profile
    /// bind another local service, change system time, load host files, select
    /// an arbitrary host interface, or request kernel routing side effects.
    private static func removeRootPrivilegeSurfaces(
        from root: inout [String: SecureYAMLValue],
        changes: inout [SanitizerChange]
    ) {
        let removedRootKeys = [
            "ntp",
            "tls",
            "iptables",
            "external-controller-routing-mark",
            "routing-mark",
            "geox-url",
            "interface-name",
        ]
        for key in removedRootKeys where root.removeValue(forKey: key) != nil {
            changes.append(SanitizerChange(path: key, action: .removed))
        }

        guard case var .mapping(dns)? = root["dns"] else { return }
        for key in ["listen", "listen-routing-mark"] where dns.removeValue(forKey: key) != nil {
            changes.append(SanitizerChange(path: "dns.\(key)", action: .removed))
        }
        root["dns"] = .mapping(dns)
    }

    private static func validateDNS(in root: [String: SecureYAMLValue]) throws {
        guard case let .mapping(dns)? = root["dns"],
            dns["enable"] == .bool(true),
            case let .sequence(nameservers)? = dns["nameserver"],
            !nameservers.isEmpty
        else {
            throw PrivilegedConfigSanitizerError.dnsPreconditionFailed
        }
    }

    private static func rewriteProviders(
        in root: inout [String: SecureYAMLValue],
        resources: [SanitizerResource],
        changes: inout [SanitizerChange]
    ) throws {
        var indexed: [String: SanitizerResource] = [:]
        for resource in resources {
            guard indexed[resource.logicalID] == nil else {
                throw PrivilegedConfigSanitizerError.duplicateStagedResource(
                    resource.logicalID
                )
            }
            indexed[resource.logicalID] = resource
        }
        var used = Set<String>()

        try rewriteProviderGroup(
            key: "proxy-providers",
            kind: .proxyProvider,
            root: &root,
            resources: indexed,
            used: &used,
            changes: &changes
        )
        try rewriteProviderGroup(
            key: "rule-providers",
            kind: .ruleProvider,
            root: &root,
            resources: indexed,
            used: &used,
            changes: &changes
        )

        if let unused = indexed.keys.first(where: { !used.contains($0) }) {
            throw PrivilegedConfigSanitizerError.unusedStagedResource(unused)
        }
    }

    private static func rewriteProviderGroup(
        key: String,
        kind: PrivilegedResourceKind,
        root: inout [String: SecureYAMLValue],
        resources: [String: SanitizerResource],
        used: inout Set<String>,
        changes: inout [SanitizerChange]
    ) throws {
        guard let groupValue = root[key] else { return }
        guard case var .mapping(group) = groupValue else {
            throw PrivilegedConfigSanitizerError.invalidYAML
        }

        for (name, value) in group {
            guard case var .mapping(provider) = value else {
                throw PrivilegedConfigSanitizerError.invalidYAML
            }
            let path = "\(key).*.path"
            if provider["type"] == .string("file") {
                let compositeLogicalID = "\(kind.rawValue):\(name)"
                let resource = resources[compositeLogicalID] ?? resources[name]
                guard let resource, resource.kind == kind,
                    !used.contains(resource.logicalID)
                else {
                    throw PrivilegedConfigSanitizerError.missingStagedResource(name)
                }
                provider["path"] = .string(resource.runtimeRelativePath.description)
                used.insert(resource.logicalID)
                changes.append(SanitizerChange(path: path, action: .resourceRewritten))
            } else if provider["path"] != nil {
                let cacheName = IntegrityValue.sha256Hex(
                    of: Data("\(key):\(name)".utf8)
                )
                provider["path"] = .string("provider-cache/\(cacheName).yaml")
                changes.append(SanitizerChange(path: path, action: .resourceRewritten))
            }
            group[name] = .mapping(provider)
        }
        root[key] = .mapping(group)
    }

    private static func rejectUnsupportedPathDependencies(
        in value: SecureYAMLValue,
        path: [String]
    ) throws {
        switch value {
        case let .mapping(mapping):
            for (key, child) in mapping {
                let childPath = path + [key]
                if [
                    "certificate", "private-key", "ca-file", "client-certificate",
                    "client-key", "script", "script-path",
                ].contains(key) {
                    throw PrivilegedConfigSanitizerError.unsupportedLocalResource(
                        childPath.joined(separator: ".")
                    )
                }
                if key == "path", !isSupportedProviderPath(childPath) {
                    throw PrivilegedConfigSanitizerError.unsupportedLocalResource(
                        childPath.joined(separator: ".")
                    )
                }
                try rejectUnsupportedPathDependencies(in: child, path: childPath)
            }
        case let .sequence(values):
            for child in values {
                try rejectUnsupportedPathDependencies(in: child, path: path)
            }
        case .null, .bool, .integer, .floatingPoint, .string:
            return
        }
    }

    private static func isSupportedProviderPath(_ path: [String]) -> Bool {
        guard path.count == 3, path[2] == "path" else { return false }
        return path[0] == "proxy-providers" || path[0] == "rule-providers"
    }

    private static func tunMapping(
        settings: TunSettings,
        launchMode: PrivilegedLaunchMode
    ) -> [String: SecureYAMLValue] {
        var tun: [String: SecureYAMLValue] = [
            "enable": .bool(launchMode == .tunEnabled),
            "stack": .string(settings.stack.rawValue),
            "auto-route": .bool(true),
            "auto-detect-interface": .bool(settings.autoDetectInterface),
        ]
        if settings.dnsHijack {
            tun["dns-hijack"] = .sequence([
                .string("any:53"),
                .string("tcp://any:53"),
            ])
        }
        if let device = settings.device { tun["device"] = .string(device) }
        if let interface = settings.outboundInterface {
            tun["include-interface"] = .sequence([.string(interface)])
        }
        if !settings.excludedInterfaces.isEmpty {
            tun["exclude-interface"] = .sequence(settings.excludedInterfaces.map {
                .string($0)
            })
        }
        if !settings.routeExcludeCIDRs.isEmpty {
            tun["route-exclude-address"] = .sequence(settings.routeExcludeCIDRs.map {
                .string($0)
            })
        }
        if let mtu = settings.mtu { tun["mtu"] = .integer(mtu) }
        if let endpointIndependentNAT = settings.endpointIndependentNAT {
            tun["endpoint-independent-nat"] = .bool(endpointIndependentNAT)
        }
        if let udpTimeout = settings.udpTimeoutSeconds {
            tun["udp-timeout"] = .integer(udpTimeout)
        }
        return tun
    }

    private static func force(
        _ value: SecureYAMLValue,
        key: String,
        into root: inout [String: SecureYAMLValue],
        changes: inout [SanitizerChange],
        action: SanitizerChangeAction = .overwritten
    ) {
        if root[key] != value {
            changes.append(SanitizerChange(path: key, action: action))
        }
        root[key] = value
    }
}

private struct YAMLNodeBudget {
    var remainingNodes: Int
    let maximumDepth: Int
}

private indirect enum SecureYAMLValue: Equatable {
    case null
    case bool(Bool)
    case integer(Int)
    case floatingPoint(Double)
    case string(String)
    case sequence([SecureYAMLValue])
    case mapping([String: SecureYAMLValue])

    init(node: Node, depth: Int, budget: inout YAMLNodeBudget) throws {
        guard depth <= budget.maximumDepth, budget.remainingNodes > 0 else {
            throw PrivilegedConfigSanitizerError.complexityLimitExceeded
        }
        budget.remainingNodes -= 1

        switch node {
        case .alias:
            throw PrivilegedConfigSanitizerError.aliasesLimitExceeded
        case let .scalar(scalar):
            if node.null != nil {
                self = .null
            } else if let value = node.bool {
                self = .bool(value)
            } else if let value = node.int {
                self = .integer(value)
            } else if let value = node.float {
                self = .floatingPoint(value)
            } else {
                self = .string(scalar.string)
            }
        case let .sequence(sequence):
            var values: [SecureYAMLValue] = []
            values.reserveCapacity(sequence.count)
            for child in sequence {
                values.append(try SecureYAMLValue(node: child, depth: depth + 1, budget: &budget))
            }
            self = .sequence(values)
        case let .mapping(mapping):
            var values: [String: SecureYAMLValue] = [:]
            values.reserveCapacity(mapping.count)
            for pair in mapping {
                guard let key = pair.key.string, values[key] == nil else {
                    throw PrivilegedConfigSanitizerError.invalidYAML
                }
                values[key] = try SecureYAMLValue(
                    node: pair.value,
                    depth: depth + 1,
                    budget: &budget
                )
            }
            self = .mapping(values)
        }
    }

    var foundationValue: Any {
        switch self {
        case .null: NSNull()
        case let .bool(value): value
        case let .integer(value): value
        case let .floatingPoint(value): value
        case let .string(value): value
        case let .sequence(values): values.map(\.foundationValue)
        case let .mapping(values): values.mapValues(\.foundationValue)
        }
    }
}

private enum YAMLSecurityBudget {
    static func validate(
        _ yaml: String,
        maximumDepth: Int,
        maximumAliasIndicators: Int
    ) throws {
        var flowDepth = 0
        var aliases = 0
        var inSingleQuote = false
        var inDoubleQuote = false
        var escaped = false
        var inComment = false
        var previousWasSeparation = true

        for scalar in yaml.unicodeScalars {
            if inComment {
                if scalar == "\n" {
                    inComment = false
                    previousWasSeparation = true
                }
                continue
            }
            if inSingleQuote {
                if scalar == "'" { inSingleQuote = false }
                continue
            }
            if inDoubleQuote {
                if escaped {
                    escaped = false
                } else if scalar == "\\" {
                    escaped = true
                } else if scalar == "\"" {
                    inDoubleQuote = false
                }
                continue
            }

            switch scalar {
            case "'": inSingleQuote = true
            case "\"": inDoubleQuote = true
            case "#" where previousWasSeparation: inComment = true
            case "[", "{":
                flowDepth += 1
                guard flowDepth <= maximumDepth else {
                    throw PrivilegedConfigSanitizerError.complexityLimitExceeded
                }
            case "]", "}": flowDepth = max(0, flowDepth - 1)
            case "&" where previousWasSeparation,
                "*" where previousWasSeparation:
                aliases += 1
                guard aliases <= maximumAliasIndicators else {
                    throw PrivilegedConfigSanitizerError.aliasesLimitExceeded
                }
            default: break
            }

            previousWasSeparation = scalar.properties.isWhitespace
                || scalar == "[" || scalar == "{" || scalar == "," || scalar == ":"
        }

        var indentationStack: [Int] = [0]
        for rawLine in yaml.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let indentation = line.prefix { $0 == " " }.count
            while let last = indentationStack.last, indentation < last {
                indentationStack.removeLast()
            }
            if indentation > (indentationStack.last ?? 0) {
                indentationStack.append(indentation)
                guard indentationStack.count <= maximumDepth else {
                    throw PrivilegedConfigSanitizerError.complexityLimitExceeded
                }
            }
        }
    }
}
