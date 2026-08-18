import Foundation

nonisolated enum OverrideValue<Value: Codable & Sendable>: Codable, Sendable {
    case inherit
    case set(Value)
    case remove

    private enum CodingKeys: String, CodingKey {
        case mode
        case value
    }

    private enum Mode: String, Codable {
        case inherit
        case set
        case remove
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let mode = try container.decode(Mode.self, forKey: .mode)

        switch mode {
        case .inherit:
            guard !container.contains(.value) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .value,
                    in: container,
                    debugDescription: "An inherited override must not contain a value."
                )
            }
            self = .inherit
        case .set:
            self = .set(try container.decode(Value.self, forKey: .value))
        case .remove:
            guard !container.contains(.value) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .value,
                    in: container,
                    debugDescription: "A removed override must not contain a value."
                )
            }
            self = .remove
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .inherit:
            try container.encode(Mode.inherit, forKey: .mode)
        case let .set(value):
            try container.encode(Mode.set, forKey: .mode)
            try container.encode(value, forKey: .value)
        case .remove:
            try container.encode(Mode.remove, forKey: .mode)
        }
    }
}

extension OverrideValue: Equatable where Value: Equatable {}

nonisolated enum DNSEnhancedMode: String, Codable, CaseIterable, Sendable {
    case fakeIP = "fake-ip"
    case redirHost = "redir-host"
}

nonisolated enum DNSFakeIPFilterMode: String, Codable, CaseIterable, Sendable {
    case blacklist
    case whitelist
    case rule
}

nonisolated struct NameserverPolicyEntry: Codable, Equatable, Sendable {
    var pattern: String
    var servers: [String]

    init(pattern: String, servers: [String]) {
        self.pattern = pattern
        self.servers = servers
    }
}

nonisolated struct DNSOverrides: Codable, Equatable, Sendable {
    var enable: OverrideValue<Bool>
    var ipv6: OverrideValue<Bool>
    var enhancedMode: OverrideValue<DNSEnhancedMode>
    var fakeIPRange: OverrideValue<String>
    var fakeIPFilterMode: OverrideValue<DNSFakeIPFilterMode>
    var fakeIPFilter: OverrideValue<[String]>
    var useHosts: OverrideValue<Bool>
    var useSystemHosts: OverrideValue<Bool>
    var respectRules: OverrideValue<Bool>
    var defaultNameserver: OverrideValue<[String]>
    var nameserver: OverrideValue<[String]>
    var fallback: OverrideValue<[String]>
    var proxyServerNameserver: OverrideValue<[String]>
    var directNameserver: OverrideValue<[String]>
    var directNameserverFollowPolicy: OverrideValue<Bool>
    var nameserverPolicy: OverrideValue<[NameserverPolicyEntry]>

    init(
        enable: OverrideValue<Bool> = .inherit,
        ipv6: OverrideValue<Bool> = .inherit,
        enhancedMode: OverrideValue<DNSEnhancedMode> = .inherit,
        fakeIPRange: OverrideValue<String> = .inherit,
        fakeIPFilterMode: OverrideValue<DNSFakeIPFilterMode> = .inherit,
        fakeIPFilter: OverrideValue<[String]> = .inherit,
        useHosts: OverrideValue<Bool> = .inherit,
        useSystemHosts: OverrideValue<Bool> = .inherit,
        respectRules: OverrideValue<Bool> = .inherit,
        defaultNameserver: OverrideValue<[String]> = .inherit,
        nameserver: OverrideValue<[String]> = .inherit,
        fallback: OverrideValue<[String]> = .inherit,
        proxyServerNameserver: OverrideValue<[String]> = .inherit,
        directNameserver: OverrideValue<[String]> = .inherit,
        directNameserverFollowPolicy: OverrideValue<Bool> = .inherit,
        nameserverPolicy: OverrideValue<[NameserverPolicyEntry]> = .inherit
    ) {
        self.enable = enable
        self.ipv6 = ipv6
        self.enhancedMode = enhancedMode
        self.fakeIPRange = fakeIPRange
        self.fakeIPFilterMode = fakeIPFilterMode
        self.fakeIPFilter = fakeIPFilter
        self.useHosts = useHosts
        self.useSystemHosts = useSystemHosts
        self.respectRules = respectRules
        self.defaultNameserver = defaultNameserver
        self.nameserver = nameserver
        self.fallback = fallback
        self.proxyServerNameserver = proxyServerNameserver
        self.directNameserver = directNameserver
        self.directNameserverFollowPolicy = directNameserverFollowPolicy
        self.nameserverPolicy = nameserverPolicy
    }

    private enum CodingKeys: String, CodingKey {
        case enable
        case ipv6
        case enhancedMode = "enhanced-mode"
        case fakeIPRange = "fake-ip-range"
        case fakeIPFilterMode = "fake-ip-filter-mode"
        case fakeIPFilter = "fake-ip-filter"
        case useHosts = "use-hosts"
        case useSystemHosts = "use-system-hosts"
        case respectRules = "respect-rules"
        case defaultNameserver = "default-nameserver"
        case nameserver
        case fallback
        case proxyServerNameserver = "proxy-server-nameserver"
        case directNameserver = "direct-nameserver"
        case directNameserverFollowPolicy = "direct-nameserver-follow-policy"
        case nameserverPolicy = "nameserver-policy"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enable = try container.decodeOverride(forKey: .enable)
        ipv6 = try container.decodeOverride(forKey: .ipv6)
        enhancedMode = try container.decodeOverride(forKey: .enhancedMode)
        fakeIPRange = try container.decodeOverride(forKey: .fakeIPRange)
        fakeIPFilterMode = try container.decodeOverride(forKey: .fakeIPFilterMode)
        fakeIPFilter = try container.decodeOverride(forKey: .fakeIPFilter)
        useHosts = try container.decodeOverride(forKey: .useHosts)
        useSystemHosts = try container.decodeOverride(forKey: .useSystemHosts)
        respectRules = try container.decodeOverride(forKey: .respectRules)
        defaultNameserver = try container.decodeOverride(forKey: .defaultNameserver)
        nameserver = try container.decodeOverride(forKey: .nameserver)
        fallback = try container.decodeOverride(forKey: .fallback)
        proxyServerNameserver = try container.decodeOverride(forKey: .proxyServerNameserver)
        directNameserver = try container.decodeOverride(forKey: .directNameserver)
        directNameserverFollowPolicy = try container.decodeOverride(
            forKey: .directNameserverFollowPolicy
        )
        nameserverPolicy = try container.decodeOverride(forKey: .nameserverPolicy)
    }
}

nonisolated enum SnifferPort: Codable, Equatable, Hashable, Sendable {
    case single(Int)
    case range(start: Int, end: Int)

    init(parsing input: String) throws {
        guard !input.contains(where: { $0.isNewline }) else {
            throw SnifferPortParseError.invalidSyntax(input)
        }

        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            throw SnifferPortParseError.invalidSyntax(input)
        }

        let separators = ["...", "-", ":"]
        if let separator = separators.first(where: { value.contains($0) }) {
            let pieces = value.components(separatedBy: separator)
            guard pieces.count == 2,
                let start = Int(pieces[0]),
                let end = Int(pieces[1])
            else {
                throw SnifferPortParseError.invalidSyntax(input)
            }
            guard (1...65_535).contains(start), (1...65_535).contains(end) else {
                throw SnifferPortParseError.outOfRange(start: start, end: end)
            }
            guard start <= end else {
                throw SnifferPortParseError.rangeIsDescending(start: start, end: end)
            }
            self = .range(start: start, end: end)
        } else if let port = Int(value) {
            guard (1...65_535).contains(port) else {
                throw SnifferPortParseError.outOfRange(start: port, end: port)
            }
            self = .single(port)
        } else {
            throw SnifferPortParseError.invalidSyntax(input)
        }
    }

    var lowerBound: Int {
        switch self {
        case let .single(port): port
        case let .range(start, _): start
        }
    }

    var upperBound: Int {
        switch self {
        case let .single(port): port
        case let .range(_, end): end
        }
    }

    var canonicalText: String {
        switch self {
        case let .single(port): String(port)
        case let .range(start, end): "\(start)-\(end)"
        }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self = try SnifferPort(parsing: container.decode(String.self))
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(canonicalText)
    }
}

nonisolated enum SnifferPortParseError: Error, Equatable, Sendable {
    case invalidSyntax(String)
    case outOfRange(start: Int, end: Int)
    case rangeIsDescending(start: Int, end: Int)
}

extension SnifferPortParseError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .invalidSyntax(value):
            "The sniffer port \(value.debugDescription) must be a port or a port range."
        case let .outOfRange(start, end):
            "Sniffer ports must be between 1 and 65535; got \(start)-\(end)."
        case let .rangeIsDescending(start, end):
            "The sniffer port range must be ascending; got \(start)-\(end)."
        }
    }
}

nonisolated struct SnifferProtocolOverrides: Codable, Equatable, Sendable {
    var ports: OverrideValue<[SnifferPort]>
    var overrideDestination: OverrideValue<Bool>

    init(
        ports: OverrideValue<[SnifferPort]> = .inherit,
        overrideDestination: OverrideValue<Bool> = .inherit
    ) {
        self.ports = ports
        self.overrideDestination = overrideDestination
    }

    private enum CodingKeys: String, CodingKey {
        case ports
        case overrideDestination = "override-destination"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ports = try container.decodeOverride(forKey: .ports)
        overrideDestination = try container.decodeOverride(forKey: .overrideDestination)
    }
}

nonisolated struct SnifferProtocolSetOverrides: Codable, Equatable, Sendable {
    var http: SnifferProtocolOverrides
    var tls: SnifferProtocolOverrides
    var quic: SnifferProtocolOverrides

    init(
        http: SnifferProtocolOverrides = SnifferProtocolOverrides(),
        tls: SnifferProtocolOverrides = SnifferProtocolOverrides(),
        quic: SnifferProtocolOverrides = SnifferProtocolOverrides()
    ) {
        self.http = http
        self.tls = tls
        self.quic = quic
    }

    private enum CodingKeys: String, CodingKey {
        case http = "HTTP"
        case tls = "TLS"
        case quic = "QUIC"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        http = try container.decodeIfPresent(SnifferProtocolOverrides.self, forKey: .http)
            ?? SnifferProtocolOverrides()
        tls = try container.decodeIfPresent(SnifferProtocolOverrides.self, forKey: .tls)
            ?? SnifferProtocolOverrides()
        quic = try container.decodeIfPresent(SnifferProtocolOverrides.self, forKey: .quic)
            ?? SnifferProtocolOverrides()
    }
}

nonisolated struct SnifferOverrides: Codable, Equatable, Sendable {
    var enable: OverrideValue<Bool>
    var forceDNSMapping: OverrideValue<Bool>
    var parsePureIP: OverrideValue<Bool>
    var overrideDestination: OverrideValue<Bool>
    var sniff: SnifferProtocolSetOverrides
    var forceDomain: OverrideValue<[String]>
    var skipDomain: OverrideValue<[String]>
    var skipSourceAddress: OverrideValue<[String]>
    var skipDestinationAddress: OverrideValue<[String]>

    init(
        enable: OverrideValue<Bool> = .inherit,
        forceDNSMapping: OverrideValue<Bool> = .inherit,
        parsePureIP: OverrideValue<Bool> = .inherit,
        overrideDestination: OverrideValue<Bool> = .inherit,
        sniff: SnifferProtocolSetOverrides = SnifferProtocolSetOverrides(),
        forceDomain: OverrideValue<[String]> = .inherit,
        skipDomain: OverrideValue<[String]> = .inherit,
        skipSourceAddress: OverrideValue<[String]> = .inherit,
        skipDestinationAddress: OverrideValue<[String]> = .inherit
    ) {
        self.enable = enable
        self.forceDNSMapping = forceDNSMapping
        self.parsePureIP = parsePureIP
        self.overrideDestination = overrideDestination
        self.sniff = sniff
        self.forceDomain = forceDomain
        self.skipDomain = skipDomain
        self.skipSourceAddress = skipSourceAddress
        self.skipDestinationAddress = skipDestinationAddress
    }

    private enum CodingKeys: String, CodingKey {
        case enable
        case forceDNSMapping = "force-dns-mapping"
        case parsePureIP = "parse-pure-ip"
        case overrideDestination = "override-destination"
        case sniff
        case forceDomain = "force-domain"
        case skipDomain = "skip-domain"
        case skipSourceAddress = "skip-src-address"
        case skipDestinationAddress = "skip-dst-address"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enable = try container.decodeOverride(forKey: .enable)
        forceDNSMapping = try container.decodeOverride(forKey: .forceDNSMapping)
        parsePureIP = try container.decodeOverride(forKey: .parsePureIP)
        overrideDestination = try container.decodeOverride(forKey: .overrideDestination)
        sniff = try container.decodeIfPresent(SnifferProtocolSetOverrides.self, forKey: .sniff)
            ?? SnifferProtocolSetOverrides()
        forceDomain = try container.decodeOverride(forKey: .forceDomain)
        skipDomain = try container.decodeOverride(forKey: .skipDomain)
        skipSourceAddress = try container.decodeOverride(forKey: .skipSourceAddress)
        skipDestinationAddress = try container.decodeOverride(forKey: .skipDestinationAddress)
    }
}

nonisolated struct ProfileStructuredOverrides: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    var dns: DNSOverrides
    var sniffer: SnifferOverrides
    var prependedRules: [String]

    init(
        schemaVersion: Int = currentSchemaVersion,
        dns: DNSOverrides = DNSOverrides(),
        sniffer: SnifferOverrides = SnifferOverrides(),
        prependedRules: [String] = []
    ) {
        self.schemaVersion = schemaVersion
        self.dns = dns
        self.sniffer = sniffer
        self.prependedRules = prependedRules
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case dns
        case sniffer
        case prependedRules
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        dns = try container.decodeIfPresent(DNSOverrides.self, forKey: .dns) ?? DNSOverrides()
        sniffer = try container.decodeIfPresent(SnifferOverrides.self, forKey: .sniffer)
            ?? SnifferOverrides()
        prependedRules = try container.decodeIfPresent([String].self, forKey: .prependedRules)
            ?? []
    }
}

nonisolated struct ConfigurationForcedField: Equatable, Sendable {
    let path: [String]
    let value: YAMLValue

    init(path: [String], value: YAMLValue) {
        self.path = path
        self.value = value
    }
}

nonisolated enum ConfigurationValueSource: String, Codable, Equatable, Sendable {
    case upstream
    case velaOverride
    case velaForced
}

nonisolated enum ConfigurationDiffOperation: String, Codable, Equatable, Sendable {
    case add
    case change
    case remove
}

nonisolated struct ConfigurationSemanticDiffEntry: Equatable, Sendable {
    let path: String
    let operation: ConfigurationDiffOperation
    let source: ConfigurationValueSource
    let before: YAMLValue?
    let after: YAMLValue?

    var beforeDescription: String? {
        before?.stableDescription
    }

    var afterDescription: String? {
        after?.stableDescription
    }
}

nonisolated struct ConfigurationPreview: Equatable, Sendable {
    let rawYAML: String
    let finalYAML: String
    let semanticDiff: [ConfigurationSemanticDiffEntry]
    let validation: ConfigurationOverrideValidationResult
}

nonisolated struct ConfigurationOverrideResult: Equatable, Sendable {
    let finalDocument: YAMLDocument
    let finalYAML: String
    let normalizedOverrides: ProfileStructuredOverrides
    let preview: ConfigurationPreview
}

nonisolated enum ConfigurationOverrideProcessingError: Error, Equatable, Sendable {
    case validationFailed([ConfigurationOverrideValidationIssue])
}

extension ConfigurationOverrideProcessingError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .validationFailed(issues):
            issues.map { "\($0.path): \($0.message)" }.joined(separator: "\n")
        }
    }
}

nonisolated struct ConfigurationOverrideProcessor: Sendable {
    private let validator: ConfigurationOverrideValidator
    private let redactor: ConfigurationPreviewRedactor

    init(
        validator: ConfigurationOverrideValidator = ConfigurationOverrideValidator(),
        redactor: ConfigurationPreviewRedactor = ConfigurationPreviewRedactor()
    ) {
        self.validator = validator
        self.redactor = redactor
    }

    func process(
        upstreamYAML: String,
        overrides: ProfileStructuredOverrides,
        forcedFields: [ConfigurationForcedField] = []
    ) throws -> ConfigurationOverrideResult {
        try process(
            upstream: YAMLDocument(yaml: upstreamYAML),
            overrides: overrides,
            forcedFields: forcedFields
        )
    }

    func process(
        upstream: YAMLDocument,
        overrides: ProfileStructuredOverrides,
        forcedFields: [ConfigurationForcedField] = []
    ) throws -> ConfigurationOverrideResult {
        let validation = validator.validate(overrides)
        guard validation.errors.isEmpty else {
            throw ConfigurationOverrideProcessingError.validationFailed(validation.errors)
        }

        let normalized = validator.normalized(overrides)
        var finalDocument = upstream
        var sources: [[String]: ConfigurationValueSource] = [:]

        try applyDNS(normalized.dns, to: &finalDocument, sources: &sources)
        try applySniffer(normalized.sniffer, to: &finalDocument, sources: &sources)
        try applyPrependedRules(
            normalized.prependedRules,
            to: &finalDocument,
            sources: &sources
        )

        for field in forcedFields.sorted(by: { $0.path.lexicographicallyPrecedes($1.path) }) {
            try finalDocument.setValue(field.value, at: field.path)
            sources[field.path] = .velaForced
        }

        let effectiveWarnings = validator.effectiveWarnings(in: finalDocument)
        let completeValidation = validation.appending(warnings: effectiveWarnings)
        let rawPreviewDocument = redactor.redact(upstream)
        let finalPreviewDocument = redactor.redact(finalDocument)
        let semanticDiff = try makeDiff(
            upstream: upstream,
            final: finalDocument,
            sources: sources
        )

        return ConfigurationOverrideResult(
            finalDocument: finalDocument,
            finalYAML: try finalDocument.serialized(),
            normalizedOverrides: normalized,
            preview: ConfigurationPreview(
                rawYAML: try rawPreviewDocument.serialized(),
                finalYAML: try finalPreviewDocument.serialized(),
                semanticDiff: semanticDiff,
                validation: completeValidation
            )
        )
    }

    private func applyPrependedRules(
        _ rules: [String],
        to document: inout YAMLDocument,
        sources: inout [[String]: ConfigurationValueSource]
    ) throws {
        guard !rules.isEmpty else { return }
        let upstreamRules: [YAMLValue]
        switch try document.value(at: ["rules"]) {
        case let .sequence(values):
            upstreamRules = values
        case nil:
            upstreamRules = []
        default:
            throw ConfigurationOverrideProcessingError.validationFailed([
                ConfigurationOverrideValidationIssue(
                    severity: .error,
                    code: .emptyEntry,
                    path: "rules",
                    message: "The upstream rules value must be a YAML list."
                )
            ])
        }

        let existing = Set(upstreamRules.compactMap { value -> String? in
            guard case let .string(rule) = value else { return nil }
            return rule
        })
        let additions = rules
            .filter { !existing.contains($0) }
            .map(YAMLValue.string)
        guard !additions.isEmpty else { return }

        try document.setValue(.sequence(additions + upstreamRules), at: ["rules"])
        sources[["rules"]] = .velaOverride
    }

    private func applyDNS(
        _ dns: DNSOverrides,
        to document: inout YAMLDocument,
        sources: inout [[String]: ConfigurationValueSource]
    ) throws {
        try apply(dns.enable, path: ["dns", "enable"], to: &document, sources: &sources) {
            .bool($0)
        }
        try apply(dns.ipv6, path: ["dns", "ipv6"], to: &document, sources: &sources) {
            .bool($0)
        }
        try apply(
            dns.enhancedMode,
            path: ["dns", "enhanced-mode"],
            to: &document,
            sources: &sources
        ) { .string($0.rawValue) }
        try apply(
            dns.fakeIPRange,
            path: ["dns", "fake-ip-range"],
            to: &document,
            sources: &sources
        ) { .string($0) }
        try apply(
            dns.fakeIPFilterMode,
            path: ["dns", "fake-ip-filter-mode"],
            to: &document,
            sources: &sources
        ) { .string($0.rawValue) }
        try applyStringList(
            dns.fakeIPFilter,
            path: ["dns", "fake-ip-filter"],
            to: &document,
            sources: &sources
        )
        try apply(dns.useHosts, path: ["dns", "use-hosts"], to: &document, sources: &sources) {
            .bool($0)
        }
        try apply(
            dns.useSystemHosts,
            path: ["dns", "use-system-hosts"],
            to: &document,
            sources: &sources
        ) { .bool($0) }
        try apply(
            dns.respectRules,
            path: ["dns", "respect-rules"],
            to: &document,
            sources: &sources
        ) { .bool($0) }
        try applyStringList(
            dns.defaultNameserver,
            path: ["dns", "default-nameserver"],
            to: &document,
            sources: &sources
        )
        try applyStringList(
            dns.nameserver,
            path: ["dns", "nameserver"],
            to: &document,
            sources: &sources
        )
        try applyStringList(
            dns.fallback,
            path: ["dns", "fallback"],
            to: &document,
            sources: &sources
        )
        try applyStringList(
            dns.proxyServerNameserver,
            path: ["dns", "proxy-server-nameserver"],
            to: &document,
            sources: &sources
        )
        try applyStringList(
            dns.directNameserver,
            path: ["dns", "direct-nameserver"],
            to: &document,
            sources: &sources
        )
        try apply(
            dns.directNameserverFollowPolicy,
            path: ["dns", "direct-nameserver-follow-policy"],
            to: &document,
            sources: &sources
        ) { .bool($0) }
        try apply(
            dns.nameserverPolicy,
            path: ["dns", "nameserver-policy"],
            to: &document,
            sources: &sources
        ) { entries in
            var mapping = OrderedYAMLMapping()
            for entry in entries {
                mapping[entry.pattern] = .sequence(entry.servers.map(YAMLValue.string))
            }
            return .mapping(mapping)
        }
    }

    private func applySniffer(
        _ sniffer: SnifferOverrides,
        to document: inout YAMLDocument,
        sources: inout [[String]: ConfigurationValueSource]
    ) throws {
        try apply(
            sniffer.enable,
            path: ["sniffer", "enable"],
            to: &document,
            sources: &sources
        ) { .bool($0) }
        try apply(
            sniffer.forceDNSMapping,
            path: ["sniffer", "force-dns-mapping"],
            to: &document,
            sources: &sources
        ) { .bool($0) }
        try apply(
            sniffer.parsePureIP,
            path: ["sniffer", "parse-pure-ip"],
            to: &document,
            sources: &sources
        ) { .bool($0) }
        try apply(
            sniffer.overrideDestination,
            path: ["sniffer", "override-destination"],
            to: &document,
            sources: &sources
        ) { .bool($0) }

        try applyProtocol(
            sniffer.sniff.http,
            name: "HTTP",
            to: &document,
            sources: &sources
        )
        try applyProtocol(
            sniffer.sniff.tls,
            name: "TLS",
            to: &document,
            sources: &sources
        )
        try applyProtocol(
            sniffer.sniff.quic,
            name: "QUIC",
            to: &document,
            sources: &sources
        )

        try applyStringList(
            sniffer.forceDomain,
            path: ["sniffer", "force-domain"],
            to: &document,
            sources: &sources
        )
        try applyStringList(
            sniffer.skipDomain,
            path: ["sniffer", "skip-domain"],
            to: &document,
            sources: &sources
        )
        try applyStringList(
            sniffer.skipSourceAddress,
            path: ["sniffer", "skip-src-address"],
            to: &document,
            sources: &sources
        )
        try applyStringList(
            sniffer.skipDestinationAddress,
            path: ["sniffer", "skip-dst-address"],
            to: &document,
            sources: &sources
        )
    }

    private func applyProtocol(
        _ protocolOverride: SnifferProtocolOverrides,
        name: String,
        to document: inout YAMLDocument,
        sources: inout [[String]: ConfigurationValueSource]
    ) throws {
        try apply(
            protocolOverride.ports,
            path: ["sniffer", "sniff", name, "ports"],
            to: &document,
            sources: &sources
        ) { ports in
            .sequence(ports.map { port in
                switch port {
                case let .single(value): .integer(value)
                case .range: .string(port.canonicalText)
                }
            })
        }
        try apply(
            protocolOverride.overrideDestination,
            path: ["sniffer", "sniff", name, "override-destination"],
            to: &document,
            sources: &sources
        ) { .bool($0) }
    }

    private func applyStringList(
        _ override: OverrideValue<[String]>,
        path: [String],
        to document: inout YAMLDocument,
        sources: inout [[String]: ConfigurationValueSource]
    ) throws {
        try apply(override, path: path, to: &document, sources: &sources) {
            .sequence($0.map(YAMLValue.string))
        }
    }

    private func apply<Value: Codable & Sendable>(
        _ override: OverrideValue<Value>,
        path: [String],
        to document: inout YAMLDocument,
        sources: inout [[String]: ConfigurationValueSource],
        transform: (Value) -> YAMLValue
    ) throws {
        switch override {
        case .inherit:
            return
        case let .set(value):
            try document.setValue(transform(value), at: path)
        case .remove:
            try document.removeValue(at: path)
        }
        sources[path] = .velaOverride
    }

    private func makeDiff(
        upstream: YAMLDocument,
        final: YAMLDocument,
        sources: [[String]: ConfigurationValueSource]
    ) throws -> [ConfigurationSemanticDiffEntry] {
        try sources.compactMap { path, source in
            let before = try upstream.value(at: path)
            let after = try final.value(at: path)
            guard before != after else { return nil }

            let operation: ConfigurationDiffOperation
            if before == nil {
                operation = .add
            } else if after == nil {
                operation = .remove
            } else {
                operation = .change
            }

            return ConfigurationSemanticDiffEntry(
                path: path.joined(separator: "."),
                operation: operation,
                source: source,
                before: before.map { redactor.redact($0, at: path) },
                after: after.map { redactor.redact($0, at: path) }
            )
        }
        .sorted { lhs, rhs in
            if lhs.path == rhs.path {
                return lhs.source.rawValue < rhs.source.rawValue
            }
            return lhs.path < rhs.path
        }
    }
}

nonisolated struct ConfigurationPreviewRedactor: Sendable {
    private static let replacement = "<redacted>"

    func redact(_ document: YAMLDocument) -> YAMLDocument {
        YAMLDocument(
            root: document.root.mapValuesWithKeys { key, value in
                redact(value, at: [key])
            }
        )
    }

    func redact(_ value: YAMLValue, at path: [String]) -> YAMLValue {
        guard !isSensitive(path: path) else {
            return .string(Self.replacement)
        }

        switch value {
        case let .mapping(mapping):
            return .mapping(
                mapping.mapValuesWithKeys { key, child in
                    redact(child, at: path + [key])
                }
            )
        case let .sequence(values):
            return .sequence(values.map { redact($0, at: path) })
        case let .string(string) where looksLikeAuthorization(string):
            return .string(Self.replacement)
        default:
            return value
        }
    }

    private func isSensitive(path: [String]) -> Bool {
        guard let key = path.last else { return false }
        let normalizedKey = key
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }

        if [
            "secret",
            "password",
            "passwd",
            "token",
            "authorization",
            "proxyauthorization",
        ].contains(normalizedKey) {
            return true
        }
        if normalizedKey.contains("subscription") && normalizedKey.contains("url") {
            return true
        }
        if normalizedKey == "url" {
            let normalizedParents = path.dropLast().map {
                $0.lowercased().filter { $0.isLetter || $0.isNumber }
            }
            return normalizedParents.contains("proxyproviders")
                || normalizedParents.contains("ruleproviders")
        }
        return false
    }

    private func looksLikeAuthorization(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.hasPrefix("bearer ") || trimmed.hasPrefix("basic ")
    }
}

private extension KeyedDecodingContainer {
    nonisolated func decodeOverride<Value: Codable & Sendable>(
        forKey key: Key
    ) throws -> OverrideValue<Value> {
        try decodeIfPresent(OverrideValue<Value>.self, forKey: key) ?? .inherit
    }
}

private extension Dictionary where Key == String, Value == YAMLValue {
    nonisolated func mapValuesWithKeys(
        _ transform: (String, YAMLValue) -> YAMLValue
    ) -> [String: YAMLValue] {
        var transformed: [String: YAMLValue] = [:]
        transformed.reserveCapacity(count)
        for (key, value) in self {
            transformed[key] = transform(key, value)
        }
        return transformed
    }
}

extension YAMLValue {
    nonisolated var stableDescription: String {
        switch self {
        case .null:
            "null"
        case let .bool(value):
            value ? "true" : "false"
        case let .integer(value):
            String(value)
        case let .floatingPoint(value):
            String(value)
        case let .string(value):
            value.debugDescription
        case let .sequence(values):
            "[" + values.map(\.stableDescription).joined(separator: ", ") + "]"
        case let .mapping(mapping):
            "{" + mapping.keys.sorted().map { key in
                "\(key.debugDescription): \(mapping[key]?.stableDescription ?? "null")"
            }.joined(separator: ", ") + "}"
        }
    }
}
