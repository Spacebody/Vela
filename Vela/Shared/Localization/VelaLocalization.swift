import Foundation

nonisolated enum VelaSupportedLocale: String, Codable, CaseIterable, Sendable {
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    static func resolve(_ locale: Locale = .current) -> Self {
        let identifier = locale.identifier.replacingOccurrences(of: "_", with: "-")
        if identifier.lowercased().hasPrefix("zh-hans")
            || identifier.lowercased().hasPrefix("zh-cn")
            || identifier.lowercased().hasPrefix("zh-sg")
        {
            return .simplifiedChinese
        }
        return .english
    }
}

nonisolated enum VelaL10n {
    /// Compatibility bridge for pre-v0.7 APIs that still accept plain strings.
    /// Static English copy maps to a stable legacy migration key; dynamic copy
    /// safely falls back until its call site adopts a typed semantic key.
    static func legacy(_ source: String, bundle: Bundle = .main) -> String {
        guard let key = legacyKey(for: source) else { return source }
        return string(key, defaultValue: source, bundle: bundle)
    }

    static func legacyKey(for source: String) -> String? {
        if stableKeyExpression?.firstMatch(
            in: source,
            range: NSRange(source.startIndex..., in: source)
        ) != nil {
            return source
        }

        let fullRange = NSRange(source.startIndex..., in: source)
        let stripped = placeholderExpression?.stringByReplacingMatches(
            in: source,
            range: fullRange,
            withTemplate: " "
        ) ?? source
        let words = asciiWords(in: stripped)
        guard let first = words.first else { return nil }

        var component = first.lowercased(with: englishLocale)
        for word in words.dropFirst() {
            component += word.prefix(1).uppercased(with: englishLocale)
            component += word.dropFirst().lowercased(with: englishLocale)
        }
        if component.first?.isNumber == true {
            component = "value" + component
        }

        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix("…") {
            component += "Dialog"
        } else if trimmed.hasSuffix("?") {
            component += "Question"
        }

        if source.contains("%"), let placeholderExpression {
            var kinds: [String] = []
            for match in placeholderExpression.matches(in: source, range: fullRange) {
                guard let range = Range(match.range, in: source),
                      let final = source[range].last
                else { continue }
                let kind: String
                switch final {
                case "@":
                    kind = "Object"
                case "d", "i", "u":
                    kind = "Integer"
                case "f", "e", "g":
                    kind = "Number"
                default:
                    kind = "Value"
                }
                if !kinds.contains(kind) {
                    kinds.append(kind)
                }
            }
            component += kinds.joined() + "Format"
        }

        return "legacy." + component
    }

    static func string(
        _ key: String,
        defaultValue: String,
        table: String? = nil,
        bundle: Bundle = .main
    ) -> String {
        bundle.localizedString(
            forKey: key,
            value: defaultValue,
            table: table
        )
    }

    static func string(
        _ key: String,
        defaultValue: String,
        arguments: CVarArg...,
        table: String? = nil,
        bundle: Bundle = .main,
        locale: Locale = .current
    ) -> String {
        let format = string(key, defaultValue: defaultValue, table: table, bundle: bundle)
        return String(
            format: format,
            locale: locale,
            arguments: arguments
        )
    }

    private static let englishLocale = Locale(identifier: "en_US_POSIX")
    private static let placeholderExpression = try? NSRegularExpression(
        pattern: #"%(?:[-+0-9$.*hlLzjt]*[A-Za-z@]|\{[^}]+\})"#
    )
    private static let stableKeyExpression = try? NSRegularExpression(
        pattern: #"^[a-z][A-Za-z0-9]*(?:\.[a-z][A-Za-z0-9]*)+$"#
    )

    private static func asciiWords(in value: String) -> [String] {
        var words: [String] = []
        var current = String.UnicodeScalarView()
        for scalar in value.unicodeScalars {
            let code = scalar.value
            let isASCIIWord = (48...57).contains(code)
                || (65...90).contains(code)
                || (97...122).contains(code)
            if isASCIIWord {
                current.append(scalar)
            } else if !current.isEmpty {
                words.append(String(current))
                current.removeAll(keepingCapacity: true)
            }
        }
        if !current.isEmpty {
            words.append(String(current))
        }
        return words
    }
}
