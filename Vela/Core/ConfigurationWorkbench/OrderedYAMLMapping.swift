import Foundation

/// A deterministic YAML mapping.
///
/// Mihomo mappings are semantically unordered, but configuration compilation must
/// produce byte-identical output. Keys are therefore kept in Unicode scalar
/// lexicographic order after every mutation. This also makes equality and
/// fingerprints independent from `Dictionary` iteration order.
nonisolated struct OrderedYAMLMapping: Equatable, Sendable {
    private var storage: [String: YAMLValue]
    private var orderedKeys: [String]

    init() {
        storage = [:]
        orderedKeys = []
    }

    init(_ values: [String: YAMLValue]) {
        storage = values
        orderedKeys = values.keys.sorted()
    }

    var count: Int { storage.count }
    var isEmpty: Bool { storage.isEmpty }
    var keys: [String] { orderedKeys }

    subscript(key: String) -> YAMLValue? {
        get { storage[key] }
        set {
            let existed = storage[key] != nil
            storage[key] = newValue
            if newValue == nil {
                if existed {
                    orderedKeys.removeAll { $0 == key }
                }
            } else if !existed {
                orderedKeys.append(key)
                orderedKeys.sort()
            }
        }
    }

    mutating func reserveCapacity(_ minimumCapacity: Int) {
        storage.reserveCapacity(minimumCapacity)
        orderedKeys.reserveCapacity(minimumCapacity)
    }

    @discardableResult
    mutating func removeValue(forKey key: String) -> YAMLValue? {
        let removed = storage.removeValue(forKey: key)
        if removed != nil {
            orderedKeys.removeAll { $0 == key }
        }
        return removed
    }

    func mapValuesWithKeys(
        _ transform: (String, YAMLValue) -> YAMLValue
    ) -> OrderedYAMLMapping {
        var result = OrderedYAMLMapping()
        result.reserveCapacity(count)
        for key in orderedKeys {
            guard let value = storage[key] else { continue }
            result[key] = transform(key, value)
        }
        return result
    }

    var dictionary: [String: YAMLValue] { storage }
}

nonisolated extension OrderedYAMLMapping: ExpressibleByDictionaryLiteral {
    init(dictionaryLiteral elements: (String, YAMLValue)...) {
        self.init(Dictionary(uniqueKeysWithValues: elements))
    }
}

nonisolated extension OrderedYAMLMapping: Sequence {
    typealias Element = (key: String, value: YAMLValue)

    func makeIterator() -> AnyIterator<Element> {
        var index = 0
        return AnyIterator {
            guard index < orderedKeys.count else { return nil }
            defer { index += 1 }
            let key = orderedKeys[index]
            guard let value = storage[key] else { return nil }
            return (key: key, value: value)
        }
    }
}
