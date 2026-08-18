import Foundation

nonisolated enum UpdateJSONCoding {
    static func encoder(prettyPrinted: Bool = true) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(try canonicalDateString(date))
        }
        encoder.outputFormatting = prettyPrinted
            ? [.prettyPrinted, .sortedKeys]
            : [.sortedKeys]
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            guard let date = parseISO8601(value) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Expected an ISO-8601 timestamp."
                )
            }
            return date
        }
        return decoder
    }

    private static func canonicalDateString(_ date: Date) throws -> String {
        let timestamp = date.timeIntervalSince1970
        guard timestamp.isFinite else {
            throw EncodingError.invalidValue(
                date,
                EncodingError.Context(
                    codingPath: [],
                    debugDescription: "Update timestamps must be finite."
                )
            )
        }

        var wholeSeconds = floor(timestamp)
        var nanoseconds = Int64(((timestamp - wholeSeconds) * 1_000_000_000).rounded())
        if nanoseconds == 1_000_000_000 {
            wholeSeconds += 1
            nanoseconds = 0
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let base = formatter.string(from: Date(timeIntervalSince1970: wholeSeconds))
        guard nanoseconds != 0, base.last == "Z" else { return base }
        return String(base.dropLast()) + String(format: ".%09lldZ", nanoseconds)
    }

    private static func parseISO8601(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        if let decimal = value.lastIndex(of: ".") {
            let fractionStart = value.index(after: decimal)
            let remainder = value[fractionStart...]
            guard let zoneStart = remainder.firstIndex(where: {
                $0 == "Z" || $0 == "+" || $0 == "-"
            }) else {
                return nil
            }
            let digits = value[fractionStart..<zoneStart]
            guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return nil }
            let wholeValue = String(value[..<decimal]) + String(value[zoneStart...])
            guard let wholeDate = formatter.date(from: wholeValue) else { return nil }

            var fraction = 0.0
            var divisor = 10.0
            for digit in digits {
                guard let digitValue = digit.wholeNumberValue else { return nil }
                fraction += Double(digitValue) / divisor
                divisor *= 10
            }
            // Reconstruct through the Unix epoch rather than mutating the
            // formatter's reference-date value. This keeps the same Date bit
            // pattern when a parsed fractional timestamp is encoded and then
            // decoded again, avoiding a one-ULP drift at modern epoch values.
            return Date(
                timeIntervalSince1970: wholeDate.timeIntervalSince1970 + fraction
            )
        }

        return formatter.date(from: value)
    }
}

nonisolated struct StrictJSONShape: Sendable {
    let allowedKeys: Set<String>
    let objects: [String: StrictJSONShape]
    let arrays: [String: StrictJSONShape]

    init(
        allowedKeys: Set<String>,
        objects: [String: StrictJSONShape] = [:],
        arrays: [String: StrictJSONShape] = [:]
    ) {
        self.allowedKeys = allowedKeys
        self.objects = objects
        self.arrays = arrays
    }
}

nonisolated enum StrictJSONValidator {
    static func validateObject(_ data: Data, shape: StrictJSONShape) throws {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw StrictJSONValidationError.invalidJSON
        }
        guard let dictionary = object as? [String: Any] else {
            throw StrictJSONValidationError.rootIsNotObject
        }
        try validate(dictionary, shape: shape, path: "$" )
    }

    private static func validate(
        _ dictionary: [String: Any],
        shape: StrictJSONShape,
        path: String
    ) throws {
        let unknown = Set(dictionary.keys).subtracting(shape.allowedKeys)
        guard unknown.isEmpty else {
            throw StrictJSONValidationError.unknownFields(
                path: path,
                fields: unknown.sorted()
            )
        }

        for (key, nestedShape) in shape.objects {
            guard let value = dictionary[key], !(value is NSNull) else { continue }
            guard let nested = value as? [String: Any] else {
                throw StrictJSONValidationError.expectedObject(path: "\(path).\(key)")
            }
            try validate(nested, shape: nestedShape, path: "\(path).\(key)")
        }

        for (key, nestedShape) in shape.arrays {
            guard let value = dictionary[key], !(value is NSNull) else { continue }
            guard let array = value as? [Any] else {
                throw StrictJSONValidationError.expectedArray(path: "\(path).\(key)")
            }
            for (index, element) in array.enumerated() {
                guard let nested = element as? [String: Any] else {
                    throw StrictJSONValidationError.expectedObject(
                        path: "\(path).\(key)[\(index)]"
                    )
                }
                try validate(
                    nested,
                    shape: nestedShape,
                    path: "\(path).\(key)[\(index)]"
                )
            }
        }
    }
}

nonisolated enum StrictJSONValidationError: Error, Equatable, Sendable {
    case invalidJSON
    case rootIsNotObject
    case unknownFields(path: String, fields: [String])
    case expectedObject(path: String)
    case expectedArray(path: String)
}
