import Foundation

nonisolated enum SensitiveTextRedactionContext: Sendable {
    case validation
    case log
    case error
}

/// Redacts untrusted text before it crosses into user-visible or persistent
/// diagnostics. The policy intentionally favors losing detail over exposing
/// configuration, credentials, network peers, or local filesystem identity.
nonisolated struct SensitiveTextRedactor: Sendable {
    private static let redactedURL = "<redacted-url>"

    let context: SensitiveTextRedactionContext

    init(context: SensitiveTextRedactionContext) {
        self.context = context
    }

    func redact(_ output: String) -> String {
        guard !output.isEmpty else { return output }

        return output
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .map { redact($0, lineNumberHint: nil) }
            .joined(separator: "\n")
    }

    func redact(_ line: String, lineNumberHint: Int?) -> String {
        guard !line.isEmpty else { return line }

        var sanitized = replacingMatches(
            in: line,
            pattern: #"(?i)\b[A-Z][A-Z0-9+.-]*://[^\s<>\"']+"#,
            with: Self.redactedURL
        )
        sanitized = replacingMatches(
            in: sanitized,
            pattern: #"\x{001B}\[[0-?]*[ -/]*[@-~]"#,
            with: ""
        )

        let lineNumber = lineNumberHint ?? detectedLineNumber(in: sanitized)
        if containsSensitiveMaterial(sanitized)
            || containsPrivatePath(sanitized)
            || containsPrivateNetworkDetail(sanitized)
            || containsPrivateLogField(sanitized)
            || looksLikeRawConfigurationLine(sanitized)
        {
            return placeholder(lineNumber: lineNumber)
        }

        return sanitized
    }

    private func placeholder(lineNumber: Int?) -> String {
        switch context {
        case .validation:
            if let lineNumber {
                return "Mihomo validation output at line \(lineNumber) was redacted."
            }
            return "Mihomo validation output was redacted."
        case .log:
            return "Mihomo log details were redacted for privacy."
        case .error:
            return "Sensitive technical details were redacted."
        }
    }

    private func containsSensitiveMaterial(_ line: String) -> Bool {
        containsMatch(
            in: line,
            pattern: #"(?i)\b(?:proxy[-_ ]?authorization|authorization|username|password|passwd|secret|token|access[-_ ]?token|api[-_ ]?key|credential)\b\s*(?:[:=]|\x{22}\s*:)"#
        )
            || containsMatch(
                in: line,
                pattern: #"(?i)\b(?:bearer|basic)\s+[^\s,;]+"#
            )
            || containsMatch(
                in: line,
                pattern: #"\?[A-Za-z0-9._~%+\-]+=[^\s]*"#
            )
    }

    private func containsPrivatePath(_ line: String) -> Bool {
        containsMatch(
            in: line,
            pattern: #"(?:^|[\s=\"'(:\[])\/(?!\/)[A-Za-z0-9._~+\-]+(?:\/[^\s\"'<>]*)?"#
        )
            || containsMatch(
                in: line,
                pattern: #"(?i)(?:^|[\s=\"'(:\[])\b[A-Z]:\\(?:Users|Documents|Temp)\\[^\s\"'<>]*"#
            )
    }

    private func containsPrivateNetworkDetail(_ line: String) -> Bool {
        containsMatch(
            in: line,
            pattern: #"\b(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?::[0-9]{1,5})?\b"#
        )
            || containsMatch(
                in: line,
                pattern: #"(?:\[[0-9A-Fa-f:]+\]|\b(?:[0-9A-Fa-f]{1,4}:){2,}[0-9A-Fa-f:]{1,4}\b)"#
            )
            || containsMatch(
                in: line,
                pattern: #"(?i)\b(?:[A-Z0-9](?:[A-Z0-9-]{0,61}[A-Z0-9])?\.)+[A-Z]{2,63}\b"#
            )
            || containsMatch(
                in: line,
                pattern: #"(?i)\blocalhost(?::[0-9]{1,5})?\b"#
            )
            || containsMatch(
                in: line,
                pattern: #"\b[A-Za-z][A-Za-z0-9-]{1,62}:[0-9]{1,5}\b"#
            )
    }

    private func containsPrivateLogField(_ line: String) -> Bool {
        containsMatch(
            in: line,
            pattern: #"(?i)\b(?:process(?:path)?|source(?:ip)?|destination(?:ip)?|rule(?:payload)?|payload|host)\b\s*[:=]"#
        )
    }

    private func looksLikeRawConfigurationLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            return true
        }
        if line.first?.isWhitespace == true, trimmed.hasPrefix("- ") {
            return true
        }
        guard detectedLineNumber(in: line) == nil else {
            return false
        }
        return containsMatch(
            in: trimmed,
            pattern: #"^(?:-\s*)?[\"']?[A-Za-z0-9_.-]+[\"']?\s*:\s*.*$"#
        )
    }

    private func detectedLineNumber(in message: String) -> Int? {
        guard let expression = try? NSRegularExpression(
            pattern: #"(?i)\bline\s*(?::|#)?\s*([0-9]+)"#
        ) else {
            return nil
        }
        let range = NSRange(message.startIndex..<message.endIndex, in: message)
        guard let match = expression.firstMatch(in: message, range: range),
              let numberRange = Range(match.range(at: 1), in: message)
        else {
            return nil
        }
        return Int(message[numberRange])
    }

    private func containsMatch(in string: String, pattern: String) -> Bool {
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return true
        }
        let range = NSRange(string.startIndex..<string.endIndex, in: string)
        return expression.firstMatch(in: string, range: range) != nil
    }

    private func replacingMatches(
        in string: String,
        pattern: String,
        with replacement: String
    ) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return placeholder(lineNumber: nil)
        }
        let range = NSRange(string.startIndex..<string.endIndex, in: string)
        return expression.stringByReplacingMatches(
            in: string,
            range: range,
            withTemplate: replacement
        )
    }
}

nonisolated enum DiagnosticTextSanitizer {
    static func redact(_ text: String) -> String {
        SensitiveTextRedactor(context: .error).redact(text)
    }
}
