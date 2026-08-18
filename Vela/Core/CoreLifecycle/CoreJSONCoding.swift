import Foundation

nonisolated enum CoreJSONCoding {
    static func encoder(prettyPrinted: Bool = true) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(canonicalTimestamp(date))
        }
        encoder.outputFormatting = prettyPrinted ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            guard let date = parseTimestamp(value) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Expected a canonical ISO-8601 timestamp."
                )
            }
            return date
        }
        return decoder
    }

    private static func canonicalTimestamp(_ date: Date) throws -> String {
        guard date.timeIntervalSince1970.isFinite else {
            throw EncodingError.invalidValue(
                date,
                .init(codingPath: [], debugDescription: "Core lifecycle dates must be finite.")
            )
        }
        return date.formatted(
            .iso8601
                .year().month().day()
                .time(includingFractionalSeconds: false)
                .timeZone(separator: .omitted)
        )
    }

    private static func parseTimestamp(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }
}

nonisolated struct CoreJSONShape: Sendable {
    let allowedKeys: Set<String>
    let objects: [String: CoreJSONShape]
    let arrays: [String: CoreJSONShape]

    init(
        allowedKeys: Set<String>,
        objects: [String: CoreJSONShape] = [:],
        arrays: [String: CoreJSONShape] = [:]
    ) {
        self.allowedKeys = allowedKeys
        self.objects = objects
        self.arrays = arrays
    }
}

nonisolated enum CoreStrictJSON {
    static func validateObject(_ data: Data, shape: CoreJSONShape) throws {
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw CoreJSONError.invalidJSON
        }
        guard let object = value as? [String: Any] else {
            throw CoreJSONError.rootIsNotObject
        }
        try validate(object, shape: shape, path: "$")
    }

    private static func validate(
        _ object: [String: Any],
        shape: CoreJSONShape,
        path: String
    ) throws {
        let unknown = Set(object.keys).subtracting(shape.allowedKeys)
        guard unknown.isEmpty else {
            throw CoreJSONError.unknownFields(path: path, fields: unknown.sorted())
        }
        for (key, nestedShape) in shape.objects {
            guard let value = object[key], !(value is NSNull) else { continue }
            guard let nested = value as? [String: Any] else {
                throw CoreJSONError.expectedObject(path: "\(path).\(key)")
            }
            try validate(nested, shape: nestedShape, path: "\(path).\(key)")
        }
        for (key, nestedShape) in shape.arrays {
            guard let value = object[key], !(value is NSNull) else { continue }
            guard let array = value as? [Any] else {
                throw CoreJSONError.expectedArray(path: "\(path).\(key)")
            }
            for (index, item) in array.enumerated() {
                guard let nested = item as? [String: Any] else {
                    throw CoreJSONError.expectedObject(path: "\(path).\(key)[\(index)]")
                }
                try validate(nested, shape: nestedShape, path: "\(path).\(key)[\(index)]")
            }
        }
    }
}

nonisolated enum CoreJSONError: Error, Equatable, Sendable {
    case invalidJSON
    case rootIsNotObject
    case unknownFields(path: String, fields: [String])
    case expectedObject(path: String)
    case expectedArray(path: String)
}
