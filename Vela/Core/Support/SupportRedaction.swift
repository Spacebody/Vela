import Foundation

nonisolated enum SupportSecretKind: String, Codable, CaseIterable, Hashable, Sendable {
    case authorization
    case tokenQuery
    case privateKey
    case controllerSecret
    case password
    case ssid
    case subscriptionURL
    case networkAddress
    case host
    case processPath
    case userHome
    case bidirectionalControl
}

nonisolated struct SupportSecretFinding: Equatable, Sendable {
    let kind: SupportSecretKind
    let line: Int?
}

nonisolated struct SupportSecretScanner: Sendable {
    private struct Rule: @unchecked Sendable {
        let kind: SupportSecretKind
        let expression: NSRegularExpression?

        init(_ kind: SupportSecretKind, _ pattern: String, options: NSRegularExpression.Options = []) {
            self.kind = kind
            expression = try? NSRegularExpression(pattern: pattern, options: options)
        }
    }

    private static let rules: [Rule] = [
        // Support payloads include JSON documents. Match quoted JSON keys as
        // well as the line-oriented `key=value` forms below so the second
        // bundle scan cannot be bypassed merely by changing serialization.
        Rule(
            .authorization,
            #""authorization"\s*:\s*"(?!\[REDACTED\])(?:\\.|[^"\\])*""#,
            options: [.caseInsensitive]
        ),
        Rule(
            .controllerSecret,
            #""(?:controller[-_ ]?secret|secret)"\s*:\s*"(?!\[REDACTED\])(?:\\.|[^"\\])*""#,
            options: [.caseInsensitive]
        ),
        Rule(
            .password,
            #""password"\s*:\s*"(?!\[REDACTED\])(?:\\.|[^"\\])*""#,
            options: [.caseInsensitive]
        ),
        Rule(
            .ssid,
            #""ssid"\s*:\s*"(?!\[REDACTED\])(?:\\.|[^"\\])*""#,
            options: [.caseInsensitive]
        ),
        Rule(
            .host,
            #""(?:host|destination)"\s*:\s*"(?!\[REDACTED\])(?:\\.|[^"\\])*""#,
            options: [.caseInsensitive]
        ),
        Rule(
            .processPath,
            #""processPath"\s*:\s*"(?!\[REDACTED\])(?:\\.|[^"\\])*""#,
            options: [.caseInsensitive]
        ),
        Rule(.authorization, #"authorization\s*:\s*(?:bearer|basic)\s+\S+"#, options: [.caseInsensitive]),
        Rule(.tokenQuery, #"[?&](?:token|key|secret|auth|password)=[^&\s]+"#, options: [.caseInsensitive]),
        Rule(.privateKey, #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#, options: [.caseInsensitive]),
        Rule(.controllerSecret, #"(?:controller[-_ ]?secret|secret)\s*[:=]\s*(?!\[REDACTED\])\S+"#, options: [.caseInsensitive]),
        Rule(.password, #"password\s*[:=]\s*(?!\[REDACTED\])\S+"#, options: [.caseInsensitive]),
        Rule(.ssid, #"\bSSID\s*[:=]\s*(?!\[REDACTED\]).+"#, options: [.caseInsensitive]),
        Rule(.subscriptionURL, #"(?:https?|ss|ssr|vmess|vless|trojan)://\S+"#, options: [.caseInsensitive]),
        Rule(.networkAddress, #"(?<![A-Za-z0-9])(?:\d{1,3}\.){3}\d{1,3}(?![A-Za-z0-9])"#),
        Rule(.networkAddress, #"(?<![A-Za-z0-9])(?:[0-9A-Fa-f]{0,4}:){2,}[0-9A-Fa-f]{0,4}(?![A-Za-z0-9])"#),
        Rule(.host, #"\b(?:host|destination)\s*[:=]\s*(?!\[REDACTED\])\S+"#, options: [.caseInsensitive]),
        Rule(.processPath, #"\bprocessPath\s*[:=]\s*(?!\[REDACTED\])\S+"#, options: [.caseInsensitive]),
        Rule(.userHome, #"/Users/(?!USER/)[^/\s]+/"#),
        // ICU regular expressions use the four-hex-digit `\uFFFF` spelling.
        // Swift's `\u{FFFF}` scalar syntax is not valid in an ICU pattern and
        // would make this lazily initialized rule trap through `try!`.
        Rule(.bidirectionalControl, #"[\u202A-\u202E\u2066-\u2069]"#),
    ]

    static var rulesAreValid: Bool {
        Self.rules.allSatisfy { $0.expression != nil }
    }

    func scan(_ text: String) -> [SupportSecretFinding] {
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        var findings: [SupportSecretFinding] = []
        for rule in Self.rules {
            guard let expression = rule.expression else { continue }
            for match in expression.matches(in: text, range: fullRange) {
                let prefix = (text as NSString).substring(to: match.range.location)
                let line = prefix.reduce(into: 1) { count, character in
                    if character == "\n" { count += 1 }
                }
                findings.append(SupportSecretFinding(kind: rule.kind, line: line))
            }
        }
        return findings
    }

    func scan(_ data: Data) throws -> [SupportSecretFinding] {
        guard let text = String(data: data, encoding: .utf8) else {
            throw SupportBundleError.invalidUTF8
        }
        return scan(text)
    }
}

nonisolated struct SupportTextRedactor: Sendable {
    private struct ReplacementRule: @unchecked Sendable {
        let expression: NSRegularExpression?
        let replacement: String

        init(_ pattern: String, replacement: String, options: NSRegularExpression.Options = []) {
            expression = try? NSRegularExpression(pattern: pattern, options: options)
            self.replacement = replacement
        }
    }

    private static let rules: [ReplacementRule] = [
        ReplacementRule(
            #"("(?:authorization|controller[-_ ]?secret|secret|password|ssid|host|destination|processPath)"\s*:\s*")(?:\\.|[^"\\])*(")"#,
            replacement: "$1[REDACTED]$2",
            options: [.caseInsensitive]
        ),
        ReplacementRule(
            #"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"#,
            replacement: "[PRIVATE KEY REDACTED]",
            options: [.caseInsensitive]
        ),
        ReplacementRule(
            #"authorization\s*:\s*(?:bearer|basic)\s+\S+"#,
            replacement: "Authorization: [REDACTED]",
            options: [.caseInsensitive]
        ),
        ReplacementRule(
            #"(?:https?|ss|ssr|vmess|vless|trojan)://\S+"#,
            replacement: "[URL REDACTED]",
            options: [.caseInsensitive]
        ),
        ReplacementRule(
            #"((?:controller[-_ ]?secret|secret|password|token|auth|key)\s*[:=]\s*)\S+"#,
            replacement: "$1[REDACTED]",
            options: [.caseInsensitive]
        ),
        ReplacementRule(
            #"(\bSSID\s*[:=]\s*).+"#,
            replacement: "$1[REDACTED]",
            options: [.caseInsensitive]
        ),
        ReplacementRule(
            #"(\b(?:host|destination|processPath)\s*[:=]\s*)\S+"#,
            replacement: "$1[REDACTED]",
            options: [.caseInsensitive]
        ),
        ReplacementRule(
            #"(?<![A-Za-z0-9])(?:\d{1,3}\.){3}\d{1,3}(?![A-Za-z0-9])"#,
            replacement: "[ADDRESS REDACTED]"
        ),
        ReplacementRule(
            #"(?<![A-Za-z0-9])(?:[0-9A-Fa-f]{0,4}:){2,}[0-9A-Fa-f]{0,4}(?![A-Za-z0-9])"#,
            replacement: "[ADDRESS REDACTED]"
        ),
        ReplacementRule(#"/Users/[^/\s]+/"#, replacement: "/Users/USER/"),
        ReplacementRule(#"[\u202A-\u202E\u2066-\u2069]"#, replacement: ""),
    ]

    static var rulesAreValid: Bool {
        Self.rules.allSatisfy { $0.expression != nil }
    }

    func redact(_ text: String) -> String {
        Self.rules.reduce(text) { value, rule in
            guard let expression = rule.expression else { return value }
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            return expression.stringByReplacingMatches(
                in: value,
                range: range,
                withTemplate: rule.replacement
            )
        }
    }
}
