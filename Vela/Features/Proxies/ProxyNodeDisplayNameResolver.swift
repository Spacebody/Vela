import Foundation

/// Produces stable, presentation-only labels for country node families.
/// Controller identities remain untouched so selection and delay-test commands
/// continue to use the exact names supplied by Mihomo.
nonisolated enum ProxyNodeDisplayNameResolver {
    static func displayNames(
        for groups: [ProxyGroup]
    ) -> [ProxyCatalogID: String] {
        let nodes = uniqueNodes(in: groups)
        var result = Dictionary(
            uniqueKeysWithValues: nodes.map { ($0.id, $0.name) }
        )
        let countryGroups = Dictionary(grouping: nodes) { node in
            ProxyCountryFlagResolver.regionCode(for: node.name)
        }

        for (regionCode, countryNodes) in countryGroups {
            guard regionCode != nil, countryNodes.count > 1 else { continue }

            let reservedOrdinals = Set(
                countryNodes.compactMap { explicitOrdinal(in: $0.name) }
            )
            var nextOrdinal = 1
            for node in countryNodes where explicitOrdinal(in: node.name) == nil {
                while reservedOrdinals.contains(nextOrdinal) {
                    nextOrdinal += 1
                }
                result[node.id] = "\(node.name) | \(formatted(nextOrdinal))"
                nextOrdinal += 1
            }
        }
        return result
    }

    private static func uniqueNodes(in groups: [ProxyGroup]) -> [ProxyNode] {
        var seen = Set<ProxyCatalogID>()
        var result: [ProxyNode] = []
        for node in groups.lazy.flatMap(\.nodes) where seen.insert(node.id).inserted {
            result.append(node)
        }
        return result
    }

    private static func explicitOrdinal(in name: String) -> Int? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = trimmed.reversed().prefix(while: \.isNumber).reversed()
        guard !digits.isEmpty, digits.count <= 3,
            let value = Int(String(digits)), value > 0
        else {
            return nil
        }

        let prefix = trimmed.dropLast(digits.count)
        guard let preceding = prefix.last else { return nil }
        let separators = CharacterSet(charactersIn: "|#-_[]()")
        if preceding.isWhitespace
            || preceding.unicodeScalars.allSatisfy({ separators.contains($0) })
        {
            return value
        }

        // Compact provider labels such as HK01 or 香港01 are already numbered.
        return ProxyCountryFlagResolver.regionCode(for: trimmed) == nil ? nil : value
    }

    private static func formatted(_ ordinal: Int) -> String {
        String(format: "%02d", ordinal)
    }
}
