import Darwin
import Foundation

nonisolated enum ConfigurationOverrideIssueSeverity: String, Codable, Equatable, Sendable {
    case error
    case warning
}

nonisolated enum ConfigurationOverrideIssueCode: String, Codable, Equatable, Sendable {
    case unsupportedSchemaVersion
    case emptyEntry
    case multilineEntry
    case invalidEnhancedMode
    case invalidFakeIPFilterMode
    case invalidIPv4CIDR
    case invalidCIDR
    case invalidPort
    case invalidDomainPattern
    case duplicateNameserverPolicy
    case emptyNameserverPolicy
    case missingProxyNameserver
}

nonisolated struct ConfigurationOverrideValidationIssue: Codable, Equatable, Sendable {
    let severity: ConfigurationOverrideIssueSeverity
    let code: ConfigurationOverrideIssueCode
    let path: String
    let message: String
}

nonisolated struct ConfigurationOverrideValidationResult: Equatable, Sendable {
    let issues: [ConfigurationOverrideValidationIssue]

    init(issues: [ConfigurationOverrideValidationIssue] = []) {
        self.issues = issues.sorted(by: Self.issueOrdering)
    }

    var errors: [ConfigurationOverrideValidationIssue] {
        issues.filter { $0.severity == .error }
    }

    var warnings: [ConfigurationOverrideValidationIssue] {
        issues.filter { $0.severity == .warning }
    }

    var isValid: Bool {
        errors.isEmpty
    }

    func appending(warnings newWarnings: [ConfigurationOverrideValidationIssue]) -> Self {
        let unique = (issues + newWarnings).reduce(into: [IssueIdentity: ConfigurationOverrideValidationIssue]()) {
            result, issue in
            result[IssueIdentity(issue)] = issue
        }
        return Self(issues: Array(unique.values))
    }

    private static func issueOrdering(
        _ lhs: ConfigurationOverrideValidationIssue,
        _ rhs: ConfigurationOverrideValidationIssue
    ) -> Bool {
        if lhs.path != rhs.path {
            return lhs.path < rhs.path
        }
        if lhs.severity != rhs.severity {
            return lhs.severity.rawValue < rhs.severity.rawValue
        }
        if lhs.code != rhs.code {
            return lhs.code.rawValue < rhs.code.rawValue
        }
        return lhs.message < rhs.message
    }

    private struct IssueIdentity: Hashable {
        let severity: ConfigurationOverrideIssueSeverity
        let code: ConfigurationOverrideIssueCode
        let path: String
        let message: String

        init(_ issue: ConfigurationOverrideValidationIssue) {
            severity = issue.severity
            code = issue.code
            path = issue.path
            message = issue.message
        }
    }
}

nonisolated enum IPAddressFamily: String, Codable, Equatable, Sendable {
    case ipv4
    case ipv6
}

nonisolated struct IPCIDR: Equatable, Sendable {
    let address: String
    let prefixLength: Int
    let family: IPAddressFamily

    init(parsing input: String, requiresIPv4: Bool = false) throws {
        guard !input.contains(where: { $0.isNewline }) else {
            throw IPCIDRParseError.invalidSyntax(input)
        }

        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let pieces = value.split(separator: "/", omittingEmptySubsequences: false)
        guard pieces.count == 2 else {
            throw IPCIDRParseError.invalidSyntax(input)
        }

        let address = String(pieces[0])
        let prefixText = String(pieces[1])
        guard !address.isEmpty,
            !prefixText.isEmpty,
            prefixText.allSatisfy(\.isNumber),
            let prefixLength = Int(prefixText)
        else {
            throw IPCIDRParseError.invalidSyntax(input)
        }

        let family: IPAddressFamily
        var ipv4Address = in_addr()
        let isIPv4 = address.withCString { pointer in
            inet_pton(AF_INET, pointer, &ipv4Address) == 1
        }
        if isIPv4 {
            family = .ipv4
            guard (0...32).contains(prefixLength) else {
                throw IPCIDRParseError.prefixOutOfRange(prefixLength, family: .ipv4)
            }
        } else {
            var ipv6Address = in6_addr()
            let isIPv6 = address.withCString { pointer in
                inet_pton(AF_INET6, pointer, &ipv6Address) == 1
            }
            guard isIPv6 else {
                throw IPCIDRParseError.invalidAddress(address)
            }
            family = .ipv6
            guard !requiresIPv4 else {
                throw IPCIDRParseError.ipv4Required(address)
            }
            guard (0...128).contains(prefixLength) else {
                throw IPCIDRParseError.prefixOutOfRange(prefixLength, family: .ipv6)
            }
        }

        self.address = address
        self.prefixLength = prefixLength
        self.family = family
    }
}

nonisolated enum IPCIDRParseError: Error, Equatable, Sendable {
    case invalidSyntax(String)
    case invalidAddress(String)
    case prefixOutOfRange(Int, family: IPAddressFamily)
    case ipv4Required(String)
}

extension IPCIDRParseError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .invalidSyntax(value):
            "The CIDR \(value.debugDescription) must contain one address and prefix length."
        case let .invalidAddress(address):
            "The CIDR address \(address.debugDescription) is not valid IPv4 or IPv6."
        case let .prefixOutOfRange(prefix, family):
            "The prefix length \(prefix) is outside the range for \(family.rawValue)."
        case let .ipv4Required(address):
            "The address \(address.debugDescription) is not IPv4."
        }
    }
}

nonisolated struct ConfigurationOverrideValidator: Sendable {
    func validate(_ overrides: ProfileStructuredOverrides) -> ConfigurationOverrideValidationResult {
        var issues: [ConfigurationOverrideValidationIssue] = []

        if overrides.schemaVersion != ProfileStructuredOverrides.currentSchemaVersion {
            issues.append(
                error(
                    .unsupportedSchemaVersion,
                    path: "schemaVersion",
                    "Unsupported override schema version \(overrides.schemaVersion)."
                )
            )
        }

        validateDNS(overrides.dns, issues: &issues)
        validateSniffer(overrides.sniffer, issues: &issues)
        validateRules(overrides.prependedRules, issues: &issues)
        return ConfigurationOverrideValidationResult(issues: issues)
    }

    func normalized(_ overrides: ProfileStructuredOverrides) -> ProfileStructuredOverrides {
        var normalized = overrides
        normalized.dns.fakeIPRange = normalizeString(overrides.dns.fakeIPRange)
        normalized.dns.fakeIPFilter = normalizeStringList(overrides.dns.fakeIPFilter)
        normalized.dns.defaultNameserver = normalizeStringList(overrides.dns.defaultNameserver)
        normalized.dns.nameserver = normalizeStringList(overrides.dns.nameserver)
        normalized.dns.fallback = normalizeStringList(overrides.dns.fallback)
        normalized.dns.proxyServerNameserver = normalizeStringList(
            overrides.dns.proxyServerNameserver
        )
        normalized.dns.directNameserver = normalizeStringList(overrides.dns.directNameserver)
        normalized.dns.nameserverPolicy = normalizeNameserverPolicy(
            overrides.dns.nameserverPolicy
        )

        normalized.sniffer.forceDomain = normalizeStringList(overrides.sniffer.forceDomain)
        normalized.sniffer.skipDomain = normalizeStringList(overrides.sniffer.skipDomain)
        normalized.sniffer.skipSourceAddress = normalizeStringList(
            overrides.sniffer.skipSourceAddress
        )
        normalized.sniffer.skipDestinationAddress = normalizeStringList(
            overrides.sniffer.skipDestinationAddress
        )
        normalized.sniffer.sniff.http.ports = normalizePorts(overrides.sniffer.sniff.http.ports)
        normalized.sniffer.sniff.tls.ports = normalizePorts(overrides.sniffer.sniff.tls.ports)
        normalized.sniffer.sniff.quic.ports = normalizePorts(overrides.sniffer.sniff.quic.ports)
        normalized.prependedRules = normalizeRules(overrides.prependedRules)
        return normalized
    }

    private func validateRules(
        _ rules: [String],
        issues: inout [ConfigurationOverrideValidationIssue]
    ) {
        for (index, rule) in rules.enumerated() {
            let path = "prependedRules[\(index)]"
            if rule.contains(where: { $0.isNewline }) {
                issues.append(error(.multilineEntry, path: path, "Rules must not contain line breaks."))
                continue
            }
            let fields = rule.split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count >= 2, fields.allSatisfy({ !$0.isEmpty }) else {
                issues.append(
                    error(
                        .emptyEntry,
                        path: path,
                        "A rule must contain a type and target separated by commas."
                    )
                )
                continue
            }
            let type = fields[0].uppercased()
            let expectedCount = type == "MATCH" ? 2 : 3
            if fields.count < expectedCount {
                issues.append(
                    error(
                        .emptyEntry,
                        path: path,
                        "The rule does not contain all fields required by its type."
                    )
                )
            }
        }
    }

    private func normalizeRules(_ rules: [String]) -> [String] {
        var seen = Set<String>()
        return rules.compactMap { rule in
            let normalized = rule
                .split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .joined(separator: ",")
            return seen.insert(normalized).inserted ? normalized : nil
        }
    }

    func effectiveWarnings(
        in document: YAMLDocument
    ) -> [ConfigurationOverrideValidationIssue] {
        let respectRules: YAMLValue?
        let proxyNameservers: YAMLValue?
        do {
            respectRules = try document.value(at: ["dns", "respect-rules"])
            proxyNameservers = try document.value(at: ["dns", "proxy-server-nameserver"])
        } catch {
            return []
        }

        guard respectRules == .bool(true) else {
            return []
        }

        let isEmpty: Bool
        switch proxyNameservers {
        case nil:
            isEmpty = true
        case let .sequence(values):
            isEmpty = values.isEmpty
        default:
            isEmpty = false
        }

        guard isEmpty else { return [] }
        return [
            warning(
                .missingProxyNameserver,
                path: "dns.proxy-server-nameserver",
                "respect-rules is enabled without a proxy-server-nameserver; DNS resolution may loop or fail."
            )
        ]
    }

    private func validateDNS(
        _ dns: DNSOverrides,
        issues: inout [ConfigurationOverrideValidationIssue]
    ) {
        if case let .set(range) = dns.fakeIPRange {
            do {
                _ = try IPCIDR(parsing: range, requiresIPv4: true)
            } catch {
                issues.append(
                    self.error(
                        .invalidIPv4CIDR,
                        path: "dns.fake-ip-range",
                        "fake-ip-range must be a valid IPv4 CIDR."
                    )
                )
            }
        }

        validateEntries(
            dns.fakeIPFilter,
            path: "dns.fake-ip-filter",
            kind: .generic,
            issues: &issues
        )
        for (override, path) in [
            (dns.defaultNameserver, "dns.default-nameserver"),
            (dns.nameserver, "dns.nameserver"),
            (dns.fallback, "dns.fallback"),
            (dns.proxyServerNameserver, "dns.proxy-server-nameserver"),
            (dns.directNameserver, "dns.direct-nameserver"),
        ] {
            validateEntries(override, path: path, kind: .nameserver, issues: &issues)
        }

        if case let .set(entries) = dns.nameserverPolicy {
            var seenPatterns = Set<String>()
            for (index, entry) in entries.enumerated() {
                let path = "dns.nameserver-policy[\(index)]"
                let pattern = entry.pattern.trimmingCharacters(in: .whitespacesAndNewlines)
                validateEntry(pattern, path: "\(path).pattern", kind: .domain, issues: &issues)

                if !seenPatterns.insert(pattern).inserted {
                    issues.append(
                        error(
                            .duplicateNameserverPolicy,
                            path: "\(path).pattern",
                            "Each nameserver-policy key must be unique."
                        )
                    )
                }

                if entry.servers.isEmpty {
                    issues.append(
                        error(
                            .emptyNameserverPolicy,
                            path: "\(path).servers",
                            "A nameserver-policy entry must contain at least one server."
                        )
                    )
                }
                for (serverIndex, server) in entry.servers.enumerated() {
                    validateEntry(
                        server,
                        path: "\(path).servers[\(serverIndex)]",
                        kind: .nameserver,
                        issues: &issues
                    )
                }
            }
        }
    }

    private func validateSniffer(
        _ sniffer: SnifferOverrides,
        issues: inout [ConfigurationOverrideValidationIssue]
    ) {
        validateProtocol(sniffer.sniff.http, name: "HTTP", issues: &issues)
        validateProtocol(sniffer.sniff.tls, name: "TLS", issues: &issues)
        validateProtocol(sniffer.sniff.quic, name: "QUIC", issues: &issues)

        validateEntries(
            sniffer.forceDomain,
            path: "sniffer.force-domain",
            kind: .domain,
            issues: &issues
        )
        validateEntries(
            sniffer.skipDomain,
            path: "sniffer.skip-domain",
            kind: .domain,
            issues: &issues
        )
        validateEntries(
            sniffer.skipSourceAddress,
            path: "sniffer.skip-src-address",
            kind: .cidr,
            issues: &issues
        )
        validateEntries(
            sniffer.skipDestinationAddress,
            path: "sniffer.skip-dst-address",
            kind: .cidr,
            issues: &issues
        )
    }

    private func validateProtocol(
        _ protocolOverride: SnifferProtocolOverrides,
        name: String,
        issues: inout [ConfigurationOverrideValidationIssue]
    ) {
        guard case let .set(ports) = protocolOverride.ports else { return }
        guard !ports.isEmpty else {
            issues.append(
                error(
                    .emptyEntry,
                    path: "sniffer.sniff.\(name).ports",
                    "An overridden port list must contain at least one port."
                )
            )
            return
        }
        for (index, port) in ports.enumerated() {
            let path = "sniffer.sniff.\(name).ports[\(index)]"
            guard (1...65_535).contains(port.lowerBound),
                (1...65_535).contains(port.upperBound),
                port.lowerBound <= port.upperBound
            else {
                issues.append(
                    error(
                        .invalidPort,
                        path: path,
                        "Ports must be between 1 and 65535 and ranges must be ascending."
                    )
                )
                continue
            }
        }
    }

    private func validateEntries(
        _ override: OverrideValue<[String]>,
        path: String,
        kind: EntryKind,
        issues: inout [ConfigurationOverrideValidationIssue]
    ) {
        guard case let .set(entries) = override else { return }
        for (index, entry) in entries.enumerated() {
            validateEntry(entry, path: "\(path)[\(index)]", kind: kind, issues: &issues)
        }
    }

    private func validateEntry(
        _ entry: String,
        path: String,
        kind: EntryKind,
        issues: inout [ConfigurationOverrideValidationIssue]
    ) {
        if entry.contains(where: { $0.isNewline }) {
            issues.append(
                error(.multilineEntry, path: path, "Entries must not contain line breaks.")
            )
            return
        }

        let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            issues.append(error(.emptyEntry, path: path, "Entries must not be empty."))
            return
        }

        switch kind {
        case .generic, .nameserver:
            return
        case .domain:
            if trimmed.contains(where: \.isWhitespace) {
                issues.append(
                    error(
                        .invalidDomainPattern,
                        path: path,
                        "Domain patterns must not contain whitespace."
                    )
                )
            }
        case .cidr:
            do {
                _ = try IPCIDR(parsing: trimmed)
            } catch let parseError {
                _ = parseError
                issues.append(error(.invalidCIDR, path: path, "The value must be a valid IPv4 or IPv6 CIDR."))
            }
        }
    }

    private func normalizeString(_ override: OverrideValue<String>) -> OverrideValue<String> {
        guard case let .set(value) = override else { return override }
        return .set(value.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func normalizeStringList(
        _ override: OverrideValue<[String]>
    ) -> OverrideValue<[String]> {
        guard case let .set(values) = override else { return override }
        var seen = Set<String>()
        let normalized = values.compactMap { value -> String? in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return seen.insert(trimmed).inserted ? trimmed : nil
        }
        return .set(normalized)
    }

    private func normalizeNameserverPolicy(
        _ override: OverrideValue<[NameserverPolicyEntry]>
    ) -> OverrideValue<[NameserverPolicyEntry]> {
        guard case let .set(entries) = override else { return override }
        return .set(
            entries.map { entry in
                let servers: [String]
                if case let .set(normalized) = normalizeStringList(.set(entry.servers)) {
                    servers = normalized
                } else {
                    servers = entry.servers
                }
                return NameserverPolicyEntry(
                    pattern: entry.pattern.trimmingCharacters(in: .whitespacesAndNewlines),
                    servers: servers
                )
            }
        )
    }

    private func normalizePorts(
        _ override: OverrideValue<[SnifferPort]>
    ) -> OverrideValue<[SnifferPort]> {
        guard case let .set(ports) = override else { return override }
        return .set(
            Array(Set(ports)).sorted { lhs, rhs in
                if lhs.lowerBound == rhs.lowerBound {
                    return lhs.upperBound < rhs.upperBound
                }
                return lhs.lowerBound < rhs.lowerBound
            }
        )
    }

    private func error(
        _ code: ConfigurationOverrideIssueCode,
        path: String,
        _ message: String
    ) -> ConfigurationOverrideValidationIssue {
        ConfigurationOverrideValidationIssue(
            severity: .error,
            code: code,
            path: path,
            message: message
        )
    }

    private func warning(
        _ code: ConfigurationOverrideIssueCode,
        path: String,
        _ message: String
    ) -> ConfigurationOverrideValidationIssue {
        ConfigurationOverrideValidationIssue(
            severity: .warning,
            code: code,
            path: path,
            message: message
        )
    }

    private enum EntryKind {
        case generic
        case nameserver
        case domain
        case cidr
    }
}
