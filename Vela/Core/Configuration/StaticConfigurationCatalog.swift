import Foundation

nonisolated struct StaticConfigurationCatalogSnapshot: Equatable, Sendable {
    let profileID: UUID
    let rules: [MihomoRule]
    let proxyCatalog: ProxyCatalog
    let providers: ProviderCatalogSnapshot
}

nonisolated protocol StaticConfigurationCatalogProviding: Sendable {
    func selectedSnapshot() async throws -> StaticConfigurationCatalogSnapshot?
}

actor StaticConfigurationCatalogService: StaticConfigurationCatalogProviding {
    private let profileStore: any ProfileManaging
    private let fileSystem: any FileSystemProviding

    init(
        profileStore: any ProfileManaging,
        fileSystem: any FileSystemProviding = LiveFileSystem()
    ) {
        self.profileStore = profileStore
        self.fileSystem = fileSystem
    }

    func selectedSnapshot() async throws -> StaticConfigurationCatalogSnapshot? {
        guard let profileID = try await profileStore.selectedProfileID() else {
            return nil
        }
        let configurationURL = await profileStore.configurationURL(for: profileID)
        let fileSystem = self.fileSystem
        return try await Task.detached(priority: .utility) {
            let data = try fileSystem.readData(at: configurationURL)
            guard let yaml = String(data: data, encoding: .utf8) else {
                throw StaticConfigurationCatalogError.invalidEncoding
            }
            return try StaticConfigurationCatalogParser.parse(
                yaml: yaml,
                profileID: profileID
            )
        }.value
    }
}

nonisolated enum StaticConfigurationCatalogError: Error, Equatable, Sendable {
    case invalidEncoding
}

nonisolated private enum StaticConfigurationCatalogParser {
    static func parse(
        yaml: String,
        profileID: UUID
    ) throws -> StaticConfigurationCatalogSnapshot {
        let document = try YAMLDocument(yaml: yaml)
        let configuredNodes = proxyNodes(in: document)
        let configuredNodesByID = configuredNodes.reduce(into: [ProxyCatalogID: ProxyNode]()) {
            nodes, node in
            nodes[node.id] = node
        }
        return StaticConfigurationCatalogSnapshot(
            profileID: profileID,
            rules: rules(in: document),
            proxyCatalog: ProxyCatalog(
                groups: proxyGroups(in: document, configuredNodes: configuredNodes),
                nodes: configuredNodesByID,
                providers: [],
                updatedAt: nil
            ),
            providers: providers(in: document)
        )
    }

    private static func rules(in document: YAMLDocument) -> [MihomoRule] {
        guard case let .sequence(values)? = try? document.value(at: ["rules"]) else {
            return []
        }
        return values.enumerated().compactMap { index, value in
            guard case let .string(rawRule) = value,
                  let parsed = parseRule(rawRule)
            else { return nil }
            return MihomoRule(
                index: index,
                type: parsed.type,
                payload: parsed.payload,
                proxy: parsed.policy,
                size: -1,
                extra: nil
            )
        }
    }

    private static func parseRule(
        _ rawRule: String
    ) -> (type: String, payload: String, policy: String)? {
        let components = splitRuleComponents(rawRule).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard components.count >= 2,
              let type = components.first.flatMap(nonEmpty)
        else { return nil }

        let trailingOptions = Set(["no-resolve"])
        var policyIndex = components.index(before: components.endIndex)
        while policyIndex > components.startIndex,
              trailingOptions.contains(components[policyIndex].lowercased())
        {
            policyIndex = components.index(before: policyIndex)
        }
        guard policyIndex > components.startIndex,
              let policy = nonEmpty(components[policyIndex])
        else { return nil }

        let payloadStart = components.index(after: components.startIndex)
        let payload = payloadStart < policyIndex
            ? components[payloadStart ..< policyIndex].joined(separator: ",")
            : ""
        return (type, payload, policy)
    }

    /// Logical rules may contain commas inside parenthesized expressions. Only
    /// separators at the top level delimit Mihomo rule fields.
    private static func splitRuleComponents(_ value: String) -> [String] {
        var result: [String] = []
        var current = ""
        var nestingDepth = 0
        var quote: Character?
        var escaped = false

        for character in value {
            if escaped {
                current.append(character)
                escaped = false
                continue
            }
            if character == "\\" {
                current.append(character)
                escaped = true
                continue
            }
            if quote != nil {
                current.append(character)
                if character == quote { quote = nil }
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
                current.append(character)
            } else if character == "(" || character == "[" || character == "{" {
                nestingDepth += 1
                current.append(character)
            } else if character == ")" || character == "]" || character == "}" {
                nestingDepth = max(0, nestingDepth - 1)
                current.append(character)
            } else if character == ",", nestingDepth == 0 {
                result.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        result.append(current)
        return result
    }

    private static func proxyNodes(in document: YAMLDocument) -> [ProxyNode] {
        guard case let .sequence(values)? = try? document.value(at: ["proxies"]) else {
            return []
        }
        return values.compactMap { value in
            guard case let .mapping(mapping) = value,
                  let name = string(in: mapping, key: "name").flatMap(nonEmpty)
            else { return nil }
            return ProxyNode.configured(
                name: name,
                type: string(in: mapping, key: "type")
            )
        }
    }

    private static func proxyGroups(
        in document: YAMLDocument,
        configuredNodes: [ProxyNode]
    ) -> [ProxyGroup] {
        guard case let .sequence(values)? = try? document.value(at: ["proxy-groups"]) else {
            return []
        }
        let nodesByName = Dictionary(grouping: configuredNodes, by: \.name)
        return values.compactMap { value in
            guard case let .mapping(mapping) = value,
                  let name = string(in: mapping, key: "name").flatMap(nonEmpty),
                  let configuredType = string(in: mapping, key: "type").flatMap(nonEmpty)
            else { return nil }
            let members = stringList(in: mapping, key: "proxies").flatMap { memberName in
                nodesByName[memberName] ?? [ProxyNode.configured(name: memberName, type: nil)]
            }
            return ProxyGroup.configured(
                name: name,
                type: runtimeGroupType(configuredType),
                testURL: string(in: mapping, key: "url"),
                expectedStatus: string(in: mapping, key: "expected-status"),
                nodes: members
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func providers(in document: YAMLDocument) -> ProviderCatalogSnapshot {
        let proxyProviders = providerMappings(in: document, key: "proxy-providers").mapValues {
            provider in
            MihomoProxyProvider(
                name: provider.name,
                type: string(in: provider.mapping, key: "type"),
                vehicleType: vehicleType(in: provider.mapping),
                proxies: [],
                testURL: nestedString(in: provider.mapping, path: ["health-check", "url"]),
                expectedStatus: nestedString(
                    in: provider.mapping,
                    path: ["health-check", "expected-status"]
                ),
                updatedAt: nil
            )
        }
        let ruleProviders = providerMappings(in: document, key: "rule-providers").mapValues {
            provider in
            MihomoRuleProvider(
                behavior: string(in: provider.mapping, key: "behavior"),
                format: string(in: provider.mapping, key: "format"),
                name: provider.name,
                ruleCount: nil,
                type: string(in: provider.mapping, key: "type"),
                vehicleType: vehicleType(in: provider.mapping),
                updatedAt: nil,
                payload: nil
            )
        }
        return ProviderCatalogSnapshot(
            proxyProviders: proxyProviders,
            ruleProviders: ruleProviders
        )
    }

    private static func providerMappings(
        in document: YAMLDocument,
        key: String
    ) -> [String: (name: String, mapping: OrderedYAMLMapping)] {
        guard case let .mapping(mapping)? = try? document.value(at: [key]) else {
            return [:]
        }
        return mapping.reduce(into: [String: (name: String, mapping: OrderedYAMLMapping)]()) {
            providers, entry in
            guard case let .mapping(provider) = entry.value else { return }
            providers[entry.key] = (entry.key, provider)
        }
    }

    private static func vehicleType(in mapping: OrderedYAMLMapping) -> String? {
        if string(in: mapping, key: "url").flatMap(nonEmpty) != nil { return "HTTP" }
        if string(in: mapping, key: "path").flatMap(nonEmpty) != nil { return "File" }
        return nil
    }

    private static func nestedString(
        in mapping: OrderedYAMLMapping,
        path: [String]
    ) -> String? {
        guard let first = path.first else { return nil }
        guard path.count > 1 else { return string(in: mapping, key: first) }
        guard case let .mapping(child)? = mapping[first] else { return nil }
        return nestedString(in: child, path: Array(path.dropFirst()))
    }

    private static func string(
        in mapping: OrderedYAMLMapping,
        key: String
    ) -> String? {
        guard let value = mapping[key] else { return nil }
        return switch value {
        case let .string(value): value
        case let .integer(value): String(value)
        case let .floatingPoint(value): String(value)
        case let .bool(value): String(value)
        case .null, .sequence, .mapping: nil
        }
    }

    private static func stringList(
        in mapping: OrderedYAMLMapping,
        key: String
    ) -> [String] {
        guard case let .sequence(values)? = mapping[key] else { return [] }
        return values.compactMap { value in
            guard case let .string(value) = value else { return nil }
            return nonEmpty(value)
        }
    }

    private static func nonEmpty(_ value: String) -> String? {
        value.isEmpty ? nil : value
    }

    private static func runtimeGroupType(_ configuredType: String) -> String {
        switch configuredType.lowercased() {
        case "select": "Selector"
        case "url-test": "URLTest"
        case "fallback": "Fallback"
        case "load-balance": "LoadBalance"
        case "relay": "Relay"
        default: configuredType
        }
    }
}
