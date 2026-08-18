import Foundation

public protocol HelperPayload: Codable, Sendable {
    static var allowedKeys: Set<String> { get }
    static var nestedObjectAllowedKeys: [String: Set<String>] { get }
    static var nestedArrayObjectAllowedKeys: [String: Set<String>] { get }

    var schemaVersion: Int { get }
    var requestID: UUID { get }
}
extension HelperPayload {
    public static var nestedObjectAllowedKeys: [String: Set<String>] { [:] }
    public static var nestedArrayObjectAllowedKeys: [String: Set<String>] { [:] }
}

public enum HelperPayloadCodec {
    public static func encode<Value: HelperPayload>(
        _ value: Value,
        maximumBytes: Int = VelaIPCConstants.maximumPayloadBytes
    ) throws -> Data {
        guard value.schemaVersion == VelaIPCConstants.schemaVersion else {
            throw VelaHelperFailure(
                code: .unsupportedSchema,
                requestID: value.requestID,
                safeMessage: "The privileged request schema is unsupported."
            )
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard data.count <= maximumBytes else {
            throw VelaHelperFailure(
                code: .payloadTooLarge,
                requestID: value.requestID,
                safeMessage: "The privileged request exceeds its size limit."
            )
        }
        return data
    }

    public static func decode<Value: HelperPayload>(
        _ type: Value.Type,
        from data: Data,
        maximumBytes: Int = VelaIPCConstants.maximumPayloadBytes
    ) throws -> Value {
        guard data.count <= maximumBytes else {
            throw VelaHelperFailure(
                code: .payloadTooLarge,
                safeMessage: "The privileged request exceeds its size limit."
            )
        }

        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw VelaHelperFailure(
                code: .invalidPayload,
                safeMessage: "The privileged request is not valid JSON."
            )
        }
        guard let dictionary = object as? [String: Any] else {
            throw VelaHelperFailure(
                code: .invalidPayload,
                safeMessage: "The privileged request must be a JSON object."
            )
        }

        try validateKeys(in: dictionary, allowed: type.allowedKeys)
        for (key, allowed) in type.nestedObjectAllowedKeys {
            guard let nested = dictionary[key] else { continue }
            guard let nestedDictionary = nested as? [String: Any] else {
                throw invalidPayload("The privileged request contains an invalid \(key) object.")
            }
            try validateKeys(in: nestedDictionary, allowed: allowed)
        }
        for (key, allowed) in type.nestedArrayObjectAllowedKeys {
            guard let nested = dictionary[key] else { continue }
            guard let nestedArray = nested as? [Any] else {
                throw invalidPayload("The privileged request contains an invalid \(key) list.")
            }
            for element in nestedArray {
                guard let nestedDictionary = element as? [String: Any] else {
                    throw invalidPayload("The privileged request contains an invalid \(key) entry.")
                }
                try validateKeys(in: nestedDictionary, allowed: allowed)
            }
        }

        guard let schemaNumber = dictionary["schemaVersion"] as? NSNumber,
            String(cString: schemaNumber.objCType) != "c",
            schemaNumber.intValue == VelaIPCConstants.schemaVersion
        else {
            throw VelaHelperFailure(
                code: .unsupportedSchema,
                safeMessage: "The privileged request schema is unsupported."
            )
        }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(type, from: data)
        } catch let failure as VelaHelperFailure {
            throw failure
        } catch {
            throw VelaHelperFailure(
                code: .invalidPayload,
                safeMessage: "The privileged request payload is invalid."
            )
        }
    }

    private static func validateKeys(
        in dictionary: [String: Any],
        allowed: Set<String>
    ) throws {
        let unknown = Set(dictionary.keys).subtracting(allowed)
        guard unknown.isEmpty else {
            throw invalidPayload("The privileged request contains unknown fields.")
        }
    }

    private static func invalidPayload(_ message: String) -> VelaHelperFailure {
        VelaHelperFailure(code: .invalidPayload, safeMessage: message)
    }
}
