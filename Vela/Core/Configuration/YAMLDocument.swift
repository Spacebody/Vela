import Foundation
import Yams

nonisolated struct YAMLDocument: Equatable, Sendable {
    private(set) var root: OrderedYAMLMapping

    init(root: [String: YAMLValue]) {
        self.root = OrderedYAMLMapping(root)
    }

    init(root: OrderedYAMLMapping) {
        self.root = root
    }

    init(yaml: String) throws {
        do {
            guard let loaded = try Yams.load(yaml: yaml) else {
                throw YAMLDocumentError.emptyDocument
            }

            let value = try YAMLValue(foundationValue: loaded, path: "$")
            guard case let .mapping(mapping) = value else {
                throw YAMLDocumentError.rootIsNotMapping
            }

            root = mapping
        } catch let error as YAMLDocumentError {
            throw error
        } catch {
            throw YAMLDocumentError.parsingFailed(reason: String(describing: error))
        }
    }

    subscript(key: String) -> YAMLValue? {
        get { root[key] }
        set { root[key] = newValue }
    }

    func value(at path: [String]) throws -> YAMLValue? {
        guard !path.isEmpty else {
            throw YAMLDocumentError.emptyPath
        }

        var value: YAMLValue = .mapping(root)
        var traversed: [String] = []

        for component in path {
            guard !component.isEmpty else {
                throw YAMLDocumentError.emptyPathComponent(path: path)
            }
            guard case let .mapping(mapping) = value else {
                throw YAMLDocumentError.pathComponentIsNotMapping(
                    path: traversed.joined(separator: ".")
                )
            }
            guard let next = mapping[component] else {
                return nil
            }
            traversed.append(component)
            value = next
        }

        return value
    }

    mutating func setValue(_ value: YAMLValue, at path: [String]) throws {
        guard !path.isEmpty else {
            throw YAMLDocumentError.emptyPath
        }
        guard !path.contains(where: \.isEmpty) else {
            throw YAMLDocumentError.emptyPathComponent(path: path)
        }

        root = try Self.setting(
            value,
            in: root,
            remainingPath: ArraySlice(path),
            traversedPath: []
        )
    }

    @discardableResult
    mutating func removeValue(at path: [String]) throws -> YAMLValue? {
        guard !path.isEmpty else {
            throw YAMLDocumentError.emptyPath
        }
        guard !path.contains(where: \.isEmpty) else {
            throw YAMLDocumentError.emptyPathComponent(path: path)
        }

        let removal = try Self.removing(
            from: root,
            remainingPath: ArraySlice(path),
            traversedPath: []
        )
        root = removal.mapping
        return removal.removedValue
    }

    func serialized() throws -> String {
        do {
            return try Yams.dump(
                object: YAMLValue.mapping(root).foundationValue,
                allowUnicode: true,
                sortKeys: true
            )
        } catch {
            throw YAMLDocumentError.serializationFailed(reason: String(describing: error))
        }
    }

    private static func setting(
        _ value: YAMLValue,
        in mapping: OrderedYAMLMapping,
        remainingPath: ArraySlice<String>,
        traversedPath: [String]
    ) throws -> OrderedYAMLMapping {
        guard let component = remainingPath.first else {
            return mapping
        }

        var updated = mapping
        let nextPath = remainingPath.dropFirst()
        if nextPath.isEmpty {
            updated[component] = value
            return updated
        }

        let childMapping: OrderedYAMLMapping
        if let existing = mapping[component] {
            guard case let .mapping(existingMapping) = existing else {
                throw YAMLDocumentError.pathComponentIsNotMapping(
                    path: (traversedPath + [component]).joined(separator: ".")
                )
            }
            childMapping = existingMapping
        } else {
            childMapping = OrderedYAMLMapping()
        }

        updated[component] = .mapping(
            try setting(
                value,
                in: childMapping,
                remainingPath: nextPath,
                traversedPath: traversedPath + [component]
            )
        )
        return updated
    }

    private static func removing(
        from mapping: OrderedYAMLMapping,
        remainingPath: ArraySlice<String>,
        traversedPath: [String]
    ) throws -> (mapping: OrderedYAMLMapping, removedValue: YAMLValue?) {
        guard let component = remainingPath.first else {
            return (mapping, nil)
        }

        var updated = mapping
        let nextPath = remainingPath.dropFirst()
        if nextPath.isEmpty {
            let removedValue = updated.removeValue(forKey: component)
            return (updated, removedValue)
        }

        guard let existing = mapping[component] else {
            return (mapping, nil)
        }
        guard case let .mapping(childMapping) = existing else {
            throw YAMLDocumentError.pathComponentIsNotMapping(
                path: (traversedPath + [component]).joined(separator: ".")
            )
        }

        let removal = try removing(
            from: childMapping,
            remainingPath: nextPath,
            traversedPath: traversedPath + [component]
        )
        updated[component] = .mapping(removal.mapping)
        return (updated, removal.removedValue)
    }
}

nonisolated indirect enum YAMLValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case integer(Int)
    case floatingPoint(Double)
    case string(String)
    case sequence([YAMLValue])
    case mapping(OrderedYAMLMapping)

    fileprivate init(foundationValue value: Any, path: String) throws {
        switch value {
        case is NSNull:
            self = .null
        case let value as Bool:
            self = .bool(value)
        case let value as Int:
            self = .integer(value)
        case let value as Int8:
            self = .integer(Int(value))
        case let value as Int16:
            self = .integer(Int(value))
        case let value as Int32:
            self = .integer(Int(value))
        case let value as Int64:
            guard let converted = Int(exactly: value) else {
                throw YAMLDocumentError.unsupportedValue(
                    path: path,
                    type: String(describing: type(of: value))
                )
            }
            self = .integer(converted)
        case let value as UInt:
            guard let converted = Int(exactly: value) else {
                throw YAMLDocumentError.unsupportedValue(
                    path: path,
                    type: String(describing: type(of: value))
                )
            }
            self = .integer(converted)
        case let value as UInt8:
            self = .integer(Int(value))
        case let value as UInt16:
            self = .integer(Int(value))
        case let value as UInt32:
            self = .integer(Int(value))
        case let value as UInt64:
            guard let converted = Int(exactly: value) else {
                throw YAMLDocumentError.unsupportedValue(
                    path: path,
                    type: String(describing: type(of: value))
                )
            }
            self = .integer(converted)
        case let value as Float:
            guard value.isFinite else {
                throw YAMLDocumentError.nonFiniteNumber(path: path)
            }
            self = .floatingPoint(Double(value))
        case let value as Double:
            guard value.isFinite else {
                throw YAMLDocumentError.nonFiniteNumber(path: path)
            }
            self = .floatingPoint(value)
        case let value as String:
            self = .string(value)
        case let values as [Any]:
            self = try .sequence(
                values.enumerated().map { index, value in
                    try YAMLValue(foundationValue: value, path: "\(path)[\(index)]")
                }
            )
        case let values as [String: Any]:
            var mapping = OrderedYAMLMapping()
            mapping.reserveCapacity(values.count)
            for (key, value) in values {
                mapping[key] = try YAMLValue(
                    foundationValue: value,
                    path: "\(path).\(key)"
                )
            }
            self = .mapping(mapping)
        case let values as [AnyHashable: Any]:
            var mapping = OrderedYAMLMapping()
            mapping.reserveCapacity(values.count)
            for (key, value) in values {
                guard let stringKey = key as? String else {
                    throw YAMLDocumentError.nonStringKey(
                        path: path,
                        key: String(describing: key)
                    )
                }
                mapping[stringKey] = try YAMLValue(
                    foundationValue: value,
                    path: "\(path).\(stringKey)"
                )
            }
            self = .mapping(mapping)
        default:
            throw YAMLDocumentError.unsupportedValue(
                path: path,
                type: String(describing: type(of: value))
            )
        }
    }

    fileprivate var foundationValue: Any {
        switch self {
        case .null:
            NSNull()
        case let .bool(value):
            value
        case let .integer(value):
            value
        case let .floatingPoint(value):
            value
        case let .string(value):
            value
        case let .sequence(values):
            values.map(\.foundationValue)
        case let .mapping(values):
            Dictionary(uniqueKeysWithValues: values.map { key, value in
                (key, value.foundationValue)
            })
        }
    }
}

nonisolated extension YAMLValue: Codable {
    nonisolated init(from decoder: any Decoder) throws {
        if let container = try? decoder.container(keyedBy: YAMLCodingKey.self),
            container.contains(YAMLCodingKey.taggedType),
            Set(container.allKeys.map(\.stringValue)).isSubset(of: [
                YAMLCodingKey.taggedType.stringValue,
                YAMLCodingKey.taggedValue.stringValue,
            ])
        {
            let rawKind = try container.decode(
                TaggedYAMLValueKind.self,
                forKey: .taggedType
            )
            switch rawKind {
            case .null:
                self = .null
            case .bool:
                self = .bool(try container.decode(Bool.self, forKey: .taggedValue))
            case .integer:
                self = .integer(try container.decode(Int.self, forKey: .taggedValue))
            case .floatingPoint:
                let value = try container.decode(Double.self, forKey: .taggedValue)
                guard value.isFinite else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .taggedValue,
                        in: container,
                        debugDescription: "YAML numbers must be finite."
                    )
                }
                self = .floatingPoint(value)
            case .string:
                self = .string(try container.decode(String.self, forKey: .taggedValue))
            case .sequence:
                self = .sequence(
                    try container.decode([YAMLValue].self, forKey: .taggedValue)
                )
            case .mapping:
                let nested = try container.nestedContainer(
                    keyedBy: YAMLCodingKey.self,
                    forKey: .taggedValue
                )
                var mapping = OrderedYAMLMapping()
                for key in nested.allKeys.sorted(by: { $0.stringValue < $1.stringValue }) {
                    mapping[key.stringValue] = try nested.decode(YAMLValue.self, forKey: key)
                }
                self = .mapping(mapping)
            }
            return
        }

        // Pack fixtures and imported v1 layer JSON use native JSON values.
        // Continue accepting that representation while all newly persisted
        // values use the tagged form below so integral doubles round-trip.
        if var container = try? decoder.unkeyedContainer() {
            var values: [YAMLValue] = []
            while !container.isAtEnd {
                values.append(try container.decode(YAMLValue.self))
            }
            self = .sequence(values)
            return
        }

        if let container = try? decoder.container(keyedBy: YAMLCodingKey.self) {
            var mapping = OrderedYAMLMapping()
            for key in container.allKeys.sorted(by: { $0.stringValue < $1.stringValue }) {
                mapping[key.stringValue] = try container.decode(YAMLValue.self, forKey: key)
            }
            self = .mapping(mapping)
            return
        }

        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            guard value.isFinite else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "YAML numbers must be finite."
                )
            }
            self = .floatingPoint(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    nonisolated func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: YAMLCodingKey.self)
        switch self {
        case .null:
            try container.encode(TaggedYAMLValueKind.null, forKey: .taggedType)
        case let .bool(value):
            try container.encode(TaggedYAMLValueKind.bool, forKey: .taggedType)
            try container.encode(value, forKey: .taggedValue)
        case let .integer(value):
            try container.encode(TaggedYAMLValueKind.integer, forKey: .taggedType)
            try container.encode(value, forKey: .taggedValue)
        case let .floatingPoint(value):
            guard value.isFinite else {
                throw EncodingError.invalidValue(
                    value,
                    EncodingError.Context(
                        codingPath: encoder.codingPath,
                        debugDescription: "YAML numbers must be finite."
                    )
                )
            }
            try container.encode(TaggedYAMLValueKind.floatingPoint, forKey: .taggedType)
            try container.encode(value, forKey: .taggedValue)
        case let .string(value):
            try container.encode(TaggedYAMLValueKind.string, forKey: .taggedType)
            try container.encode(value, forKey: .taggedValue)
        case let .sequence(values):
            try container.encode(TaggedYAMLValueKind.sequence, forKey: .taggedType)
            try container.encode(values, forKey: .taggedValue)
        case let .mapping(mapping):
            try container.encode(TaggedYAMLValueKind.mapping, forKey: .taggedType)
            var nested = container.nestedContainer(
                keyedBy: YAMLCodingKey.self,
                forKey: .taggedValue
            )
            for (key, value) in mapping {
                try nested.encode(value, forKey: YAMLCodingKey(key))
            }
        }
    }
}

nonisolated private enum TaggedYAMLValueKind: String, Codable {
    case null
    case bool
    case integer
    case floatingPoint
    case string
    case sequence
    case mapping
}

nonisolated private struct YAMLCodingKey: CodingKey {
    static let taggedType = YAMLCodingKey("$velaYAMLType")
    static let taggedValue = YAMLCodingKey("$velaYAMLValue")

    let stringValue: String
    let intValue: Int? = nil

    init(_ stringValue: String) {
        self.stringValue = stringValue
    }

    init?(stringValue: String) {
        self.init(stringValue)
    }

    init?(intValue: Int) {
        return nil
    }
}

nonisolated enum YAMLDocumentError: Error, Equatable, Sendable {
    case emptyDocument
    case rootIsNotMapping
    case emptyPath
    case emptyPathComponent(path: [String])
    case pathComponentIsNotMapping(path: String)
    case nonStringKey(path: String, key: String)
    case unsupportedValue(path: String, type: String)
    case nonFiniteNumber(path: String)
    case parsingFailed(reason: String)
    case serializationFailed(reason: String)
}

extension YAMLDocumentError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .emptyDocument:
            "The YAML document is empty."
        case .rootIsNotMapping:
            "The YAML document root must be a mapping."
        case .emptyPath:
            "A YAML path must contain at least one component."
        case let .emptyPathComponent(path):
            "The YAML path \(path.joined(separator: ".")) contains an empty component."
        case let .pathComponentIsNotMapping(path):
            "The YAML value at \(path) is not a mapping and cannot contain a nested value."
        case let .nonStringKey(path, key):
            "The YAML key \(key) at \(path) is not a string."
        case let .unsupportedValue(path, type):
            "The YAML value at \(path) has unsupported type \(type)."
        case let .nonFiniteNumber(path):
            "The YAML value at \(path) is NaN or infinite."
        case let .parsingFailed(reason):
            "Could not parse YAML: \(reason)"
        case let .serializationFailed(reason):
            "Could not serialize YAML: \(reason)"
        }
    }
}
