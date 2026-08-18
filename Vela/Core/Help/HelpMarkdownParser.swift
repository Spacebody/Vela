import Foundation

nonisolated enum HelpMarkdownError: Error, LocalizedError, Equatable, Sendable {
    case invalidUTF8(String)
    case oversized(String, maximumBytes: Int)
    case emptyDocument(String)
    case forbiddenUnicode(String)
    case rawHTML(String)
    case image(String)
    case malformedLink(String)
    case unsafeLink(String)
    case malformedFence(String)
    case invalidCodeLanguage(String)
    case missingTitle(String)

    var errorDescription: String? {
        switch self {
        case let .invalidUTF8(path):
            "Help article is not valid UTF-8: \(path)"
        case let .oversized(path, maximumBytes):
            "Help article exceeds \(maximumBytes) bytes: \(path)"
        case let .emptyDocument(path):
            "Help article is empty: \(path)"
        case let .forbiddenUnicode(path):
            "Help article contains a control or bidirectional formatting character: \(path)"
        case let .rawHTML(path):
            "Raw HTML is not allowed in Help articles: \(path)"
        case let .image(path):
            "Images are not allowed in Help articles: \(path)"
        case let .malformedLink(value):
            "Help article contains malformed link syntax: \(value)"
        case let .unsafeLink(value):
            "Help article contains an unsafe link: \(value)"
        case let .malformedFence(path):
            "Help article contains an unterminated code fence: \(path)"
        case let .invalidCodeLanguage(language):
            "Help article contains an invalid code language: \(language)"
        case let .missingTitle(path):
            "Help article must begin with one level-one heading: \(path)"
        }
    }
}

nonisolated enum HelpLinkPolicy {
    static func destination(for rawValue: String) throws -> HelpLinkDestination {
        guard !rawValue.isEmpty, rawValue.count <= 2_048,
            rawValue == rawValue.trimmingCharacters(in: .whitespacesAndNewlines),
            !rawValue.contains(where: \.isWhitespace),
            !rawValue.contains("\\"),
            !HelpUnicodeSafety.containsForbiddenScalar(rawValue)
        else {
            throw HelpMarkdownError.unsafeLink(rawValue)
        }
        if rawValue.hasPrefix("help:") {
            let topicValue = String(rawValue.dropFirst("help:".count))
            guard let topicID = HelpTopicID(rawValue: topicValue) else {
                throw HelpMarkdownError.unsafeLink(rawValue)
            }
            return .topic(topicID)
        }

        guard let decoded = rawValue.removingPercentEncoding,
            !HelpUnicodeSafety.containsForbiddenScalar(decoded),
            !decoded.contains(where: \.isWhitespace),
            !decoded.contains("\\"),
            let components = URLComponents(string: rawValue),
            components.scheme?.lowercased() == "https",
            let host = components.host,
            !host.isEmpty,
            components.user == nil,
            components.password == nil,
            let url = components.url
        else {
            throw HelpMarkdownError.unsafeLink(rawValue)
        }
        return .external(url)
    }

    static func destination(for url: URL) -> HelpLinkDestination? {
        try? destination(for: url.absoluteString)
    }
}

nonisolated enum HelpMarkdownParser {
    static let maximumArticleBytes = 256 * 1024

    static func parse(
        data: Data,
        resourcePath: String = "article.md"
    ) throws -> [HelpMarkdownBlock] {
        guard data.count <= maximumArticleBytes else {
            throw HelpMarkdownError.oversized(
                resourcePath,
                maximumBytes: maximumArticleBytes
            )
        }
        guard let source = String(data: data, encoding: .utf8) else {
            throw HelpMarkdownError.invalidUTF8(resourcePath)
        }
        return try parse(source, resourcePath: resourcePath)
    }

    static func parse(
        _ source: String,
        resourcePath: String = "article.md"
    ) throws -> [HelpMarkdownBlock] {
        let byteCount = source.lengthOfBytes(using: .utf8)
        guard byteCount <= maximumArticleBytes else {
            throw HelpMarkdownError.oversized(
                resourcePath,
                maximumBytes: maximumArticleBytes
            )
        }
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw HelpMarkdownError.emptyDocument(resourcePath)
        }
        guard !HelpUnicodeSafety.containsForbiddenScalar(source) else {
            throw HelpMarkdownError.forbiddenUnicode(resourcePath)
        }
        guard !source.contains("<") else {
            throw HelpMarkdownError.rawHTML(resourcePath)
        }
        guard !source.contains("![") else {
            throw HelpMarkdownError.image(resourcePath)
        }
        try validateLinkSyntax(in: source)

        let normalized = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var blocks: [HelpMarkdownBlock] = []
        var index = 0

        while index < lines.count {
            let line = lines[index]
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                index += 1
                continue
            }
            if line.hasPrefix("```") {
                let language = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                guard language.isEmpty || isValidCodeLanguage(language) else {
                    throw HelpMarkdownError.invalidCodeLanguage(language)
                }
                index += 1
                var codeLines: [String] = []
                while index < lines.count, lines[index] != "```" {
                    codeLines.append(lines[index])
                    index += 1
                }
                guard index < lines.count else {
                    throw HelpMarkdownError.malformedFence(resourcePath)
                }
                index += 1
                blocks.append(.code(
                    language: language.isEmpty ? nil : language,
                    text: codeLines.joined(separator: "\n")
                ))
                continue
            }
            if let heading = headingContent(line) {
                blocks.append(.heading(
                    level: heading.level,
                    content: try parseInline(heading.content)
                ))
                index += 1
                continue
            }
            if let item = unorderedItem(line) {
                var items = [try parseInline(item)]
                index += 1
                while index < lines.count, let next = unorderedItem(lines[index]) {
                    items.append(try parseInline(next))
                    index += 1
                }
                blocks.append(.unorderedList(items))
                continue
            }
            if let item = orderedItem(line) {
                let start = item.number
                var expected = start
                var items: [HelpInlineContent] = []
                while index < lines.count, let next = orderedItem(lines[index]), next.number == expected {
                    items.append(try parseInline(next.content))
                    index += 1
                    guard expected < Int.max else { break }
                    expected += 1
                }
                blocks.append(.orderedList(start: start, items: items))
                continue
            }
            if line.hasPrefix("> ") {
                blocks.append(.callout(try parseInline(String(line.dropFirst(2)))))
                index += 1
                continue
            }

            var paragraphLines = [line.trimmingCharacters(in: .whitespaces)]
            index += 1
            while index < lines.count {
                let next = lines[index]
                if next.trimmingCharacters(in: .whitespaces).isEmpty || isBlockStart(next) {
                    break
                }
                paragraphLines.append(next.trimmingCharacters(in: .whitespaces))
                index += 1
            }
            blocks.append(.paragraph(try parseInline(paragraphLines.joined(separator: " "))))
        }

        guard case .heading(level: 1, _) = blocks.first else {
            throw HelpMarkdownError.missingTitle(resourcePath)
        }
        return blocks
    }

    private static func validateLinkSyntax(in source: String) throws {
        let characters = Array(source)
        var index = 0
        while index + 1 < characters.count {
            if characters[index] == "]", characters[index + 1] == "(" {
                guard characters[..<index].lastIndex(of: "[") != nil else {
                    throw HelpMarkdownError.malformedLink(String(source.prefix(80)))
                }
                let destinationStart = index + 2
                guard let destinationEnd = characters[destinationStart...].firstIndex(of: ")") else {
                    throw HelpMarkdownError.malformedLink(String(source.prefix(80)))
                }
                let destination = String(characters[destinationStart..<destinationEnd])
                _ = try HelpLinkPolicy.destination(for: destination)
                index = destinationEnd + 1
                continue
            }
            index += 1
        }
        if source.contains("](") {
            let count = source.components(separatedBy: "](").count - 1
            let validated = characters.indices.filter {
                $0 + 1 < characters.count && characters[$0] == "]" && characters[$0 + 1] == "("
            }.count
            guard count == validated else {
                throw HelpMarkdownError.malformedLink(String(source.prefix(80)))
            }
        }
    }

    private static func parseInline(_ source: String) throws -> HelpInlineContent {
        let characters = Array(source)
        var fragments: [HelpInlineFragment] = []
        var plain = ""
        var index = 0

        func flushPlain() {
            guard !plain.isEmpty else { return }
            fragments.append(.text(plain))
            plain.removeAll(keepingCapacity: true)
        }

        while index < characters.count {
            if characters[index] == "\\", index + 1 < characters.count {
                plain.append(characters[index + 1])
                index += 2
                continue
            }
            if hasSequence("**", at: index, in: characters),
                let end = firstSequence("**", after: index + 2, in: characters)
            {
                flushPlain()
                fragments.append(.strong(String(characters[(index + 2)..<end])))
                index = end + 2
                continue
            }
            if characters[index] == "`",
                let end = characters[(index + 1)...].firstIndex(of: "`")
            {
                flushPlain()
                fragments.append(.code(String(characters[(index + 1)..<end])))
                index = end + 1
                continue
            }
            if characters[index] == "*",
                let end = characters[(index + 1)...].firstIndex(of: "*")
            {
                flushPlain()
                fragments.append(.emphasis(String(characters[(index + 1)..<end])))
                index = end + 1
                continue
            }
            if characters[index] == "_",
                let end = characters[(index + 1)...].firstIndex(of: "_")
            {
                flushPlain()
                fragments.append(.emphasis(String(characters[(index + 1)..<end])))
                index = end + 1
                continue
            }
            if characters[index] == "[",
                let labelEnd = characters[(index + 1)...].firstIndex(of: "]"),
                labelEnd + 1 < characters.count,
                characters[labelEnd + 1] == "("
            {
                let destinationStart = labelEnd + 2
                guard let destinationEnd = characters[destinationStart...].firstIndex(of: ")") else {
                    throw HelpMarkdownError.malformedLink(source)
                }
                let label = String(characters[(index + 1)..<labelEnd])
                let destinationValue = String(characters[destinationStart..<destinationEnd])
                guard !label.isEmpty, !label.contains("[") else {
                    throw HelpMarkdownError.malformedLink(source)
                }
                flushPlain()
                fragments.append(.link(
                    label: label,
                    destination: try HelpLinkPolicy.destination(for: destinationValue)
                ))
                index = destinationEnd + 1
                continue
            }
            plain.append(characters[index])
            index += 1
        }
        flushPlain()
        return HelpInlineContent(fragments: fragments)
    }

    private static func headingContent(_ line: String) -> (level: Int, content: String)? {
        let characters = Array(line)
        var level = 0
        while level < characters.count, characters[level] == "#" { level += 1 }
        guard (1...6).contains(level), level < characters.count, characters[level] == " " else {
            return nil
        }
        let content = String(characters.dropFirst(level + 1))
        return content.isEmpty ? nil : (level, content)
    }

    private static func unorderedItem(_ line: String) -> String? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            let content = String(line.dropFirst(marker.count))
            return content.isEmpty ? nil : content
        }
        return nil
    }

    private static func orderedItem(_ line: String) -> (number: Int, content: String)? {
        let characters = Array(line)
        var cursor = 0
        while cursor < characters.count, characters[cursor].isNumber { cursor += 1 }
        guard cursor > 0, cursor + 1 < characters.count,
            characters[cursor] == ".", characters[cursor + 1] == " ",
            let number = Int(String(characters[..<cursor])), number > 0
        else {
            return nil
        }
        let content = String(characters.dropFirst(cursor + 2))
        return content.isEmpty ? nil : (number, content)
    }

    private static func isBlockStart(_ line: String) -> Bool {
        line.hasPrefix("```") || headingContent(line) != nil || unorderedItem(line) != nil
            || orderedItem(line) != nil || line.hasPrefix("> ")
    }

    private static func isValidCodeLanguage(_ value: String) -> Bool {
        value.count <= 32 && value.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 65 && scalar.value <= 90)
                || (scalar.value >= 97 && scalar.value <= 122)
                || (scalar.value >= 48 && scalar.value <= 57)
                || scalar == "-" || scalar == "_"
        }
    }

    private static func hasSequence(
        _ sequence: String,
        at index: Int,
        in characters: [Character]
    ) -> Bool {
        let expected = Array(sequence)
        guard index + expected.count <= characters.count else { return false }
        return Array(characters[index..<(index + expected.count)]) == expected
    }

    private static func firstSequence(
        _ sequence: String,
        after start: Int,
        in characters: [Character]
    ) -> Int? {
        guard start < characters.count else { return nil }
        for index in start..<characters.count where hasSequence(sequence, at: index, in: characters) {
            return index
        }
        return nil
    }
}
