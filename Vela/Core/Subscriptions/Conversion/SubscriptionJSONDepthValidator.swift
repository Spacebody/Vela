import Foundation

/// Applies a bounded nesting check before Foundation parses untrusted JSON.
///
/// This is intentionally not a JSON parser. It only counts object and array
/// delimiters outside quoted strings so deeply nested subscription payloads
/// are rejected before `JSONSerialization` or `JSONDecoder` allocates their
/// full object graph.
nonisolated enum SubscriptionJSONDepthValidator {
    static func validate(_ content: String, maximumDepth: Int) throws {
        guard maximumDepth > 0 else {
            throw SubscriptionConversionError.invalidSingBoxConfiguration(
                "The JSON nesting limit is invalid."
            )
        }

        var depth = 0
        var isInsideString = false
        var isEscaped = false

        for scalar in content.unicodeScalars {
            if isInsideString {
                if isEscaped {
                    isEscaped = false
                } else if scalar == "\\" {
                    isEscaped = true
                } else if scalar == "\"" {
                    isInsideString = false
                }
                continue
            }

            switch scalar {
            case "\"":
                isInsideString = true
            case "{", "[":
                depth += 1
                guard depth <= maximumDepth else {
                    throw SubscriptionConversionError.invalidSingBoxConfiguration(
                        "The JSON nesting exceeds the \(maximumDepth)-level safety limit."
                    )
                }
            case "}", "]":
                depth = max(0, depth - 1)
            default:
                continue
            }
        }
    }
}
