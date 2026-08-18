import Foundation

nonisolated struct HelpTopicID: RawRepresentable, Codable, Hashable, Identifiable, Sendable {
    let rawValue: String

    var id: String { rawValue }

    init?(rawValue: String) {
        guard Self.isValid(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    init(_ rawValue: String) throws {
        guard let value = Self(rawValue: rawValue) else {
            throw HelpModelError.invalidTopicID(rawValue)
        }
        self = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let value = Self(rawValue: rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid Help topic ID: \(rawValue)"
            )
        }
        self = value
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    private static func isValid(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 80 else { return false }
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.allSatisfy({ !$0.isEmpty }) else { return false }
        return parts.allSatisfy { part in
            part.unicodeScalars.allSatisfy { scalar in
                (scalar.value >= 97 && scalar.value <= 122)
                    || (scalar.value >= 48 && scalar.value <= 57)
            }
        }
    }
}

nonisolated struct HelpCategoryID: RawRepresentable, Codable, Hashable, Identifiable, Sendable {
    let rawValue: String

    var id: String { rawValue }

    init?(rawValue: String) {
        guard let topic = HelpTopicID(rawValue: rawValue) else { return nil }
        self.rawValue = topic.rawValue
    }

    init(from decoder: Decoder) throws {
        let topic = try HelpTopicID(from: decoder)
        rawValue = topic.rawValue
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

nonisolated enum HelpLocale: String, Codable, CaseIterable, Sendable {
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    var languageCode: String { rawValue }
}

nonisolated enum HelpLocaleFallbackReason: Equatable, Sendable {
    case exact
    case languageMatch(requested: String)
    case sourceLanguage(requested: String?)
}

nonisolated struct HelpLocaleResolution: Equatable, Sendable {
    let locale: HelpLocale
    let reason: HelpLocaleFallbackReason

    var usedFallback: Bool {
        if case .exact = reason { return false }
        return true
    }

    var fellBackToSourceLanguage: Bool {
        if case .sourceLanguage = reason { return true }
        return false
    }
}

nonisolated enum HelpLocaleResolver {
    static func resolve(
        preferredLanguages: [String],
        supportedLocales: Set<HelpLocale>,
        sourceLanguage: HelpLocale
    ) -> HelpLocaleResolution {
        guard let requested = preferredLanguages.first else {
            return HelpLocaleResolution(
                locale: sourceLanguage,
                reason: .sourceLanguage(requested: nil)
            )
        }
        let normalized = requested.replacingOccurrences(of: "_", with: "-").lowercased()
        if normalized == "en" || normalized.hasPrefix("en-") {
            if supportedLocales.contains(.english) {
                return HelpLocaleResolution(
                    locale: .english,
                    reason: normalized == "en" ? .exact : .languageMatch(requested: requested)
                )
            }
        }
        if normalized == "zh-hans" {
            if supportedLocales.contains(.simplifiedChinese) {
                return HelpLocaleResolution(locale: .simplifiedChinese, reason: .exact)
            }
        }
        if normalized == "zh-cn" || normalized == "zh-sg"
            || normalized.hasPrefix("zh-hans-")
        {
            if supportedLocales.contains(.simplifiedChinese) {
                return HelpLocaleResolution(
                    locale: .simplifiedChinese,
                    reason: .languageMatch(requested: requested)
                )
            }
        }
        return HelpLocaleResolution(
            locale: sourceLanguage,
            reason: .sourceLanguage(requested: preferredLanguages.first)
        )
    }
}

nonisolated struct HelpCategory: Identifiable, Hashable, Sendable {
    let id: HelpCategoryID
    let order: Int
}

nonisolated struct HelpArticleSummary: Identifiable, Hashable, Sendable {
    let id: HelpTopicID
    let categoryID: HelpCategoryID
    let order: Int
    let title: String
    let keywords: [String]
    let relatedTopicIDs: [HelpTopicID]
    let resourcePath: String
    let sha256: String
}

nonisolated struct HelpLibrary: Sendable {
    let localeResolution: HelpLocaleResolution
    let categories: [HelpCategory]
    let articles: [HelpArticleSummary]

    var locale: HelpLocale { localeResolution.locale }

    func article(id: HelpTopicID) -> HelpArticleSummary? {
        articles.first { $0.id == id }
    }

    func articles(in categoryID: HelpCategoryID) -> [HelpArticleSummary] {
        articles.filter { $0.categoryID == categoryID }
    }
}

nonisolated struct HelpArticle: Sendable, Equatable {
    let summary: HelpArticleSummary
    let blocks: [HelpMarkdownBlock]
}

nonisolated struct HelpSearchResult: Identifiable, Equatable, Sendable {
    let id: HelpTopicID
    let categoryID: HelpCategoryID
    let title: String
    let excerpt: String
    let score: Int
}

nonisolated enum HelpLinkDestination: Equatable, Sendable {
    case topic(HelpTopicID)
    case external(URL)
}

nonisolated enum HelpInlineFragment: Equatable, Sendable {
    case text(String)
    case emphasis(String)
    case strong(String)
    case code(String)
    case link(label: String, destination: HelpLinkDestination)
}

nonisolated struct HelpInlineContent: Equatable, Sendable {
    let fragments: [HelpInlineFragment]

    var plainText: String {
        fragments.map { fragment in
            switch fragment {
            case let .text(value), let .emphasis(value), let .strong(value), let .code(value):
                value
            case let .link(label, _):
                label
            }
        }.joined()
    }
}

nonisolated enum HelpMarkdownBlock: Equatable, Sendable {
    case heading(level: Int, content: HelpInlineContent)
    case paragraph(HelpInlineContent)
    case unorderedList([HelpInlineContent])
    case orderedList(start: Int, items: [HelpInlineContent])
    case callout(HelpInlineContent)
    case code(language: String?, text: String)
}

nonisolated enum HelpModelError: Error, LocalizedError, Equatable, Sendable {
    case invalidTopicID(String)

    var errorDescription: String? {
        switch self {
        case let .invalidTopicID(value):
            "Invalid Help topic ID: \(value)"
        }
    }
}

nonisolated enum HelpNavigationDirection: Sendable {
    case back
    case forward
}

nonisolated struct HelpNavigationHistory: Equatable, Sendable {
    private(set) var current: HelpTopicID?
    private(set) var backStack: [HelpTopicID] = []
    private(set) var forwardStack: [HelpTopicID] = []

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    mutating func replaceCurrent(with topicID: HelpTopicID?) {
        current = topicID
        backStack.removeAll()
        forwardStack.removeAll()
    }

    mutating func navigate(to topicID: HelpTopicID) {
        guard topicID != current else { return }
        if let current {
            backStack.append(current)
        }
        current = topicID
        forwardStack.removeAll()
    }

    mutating func move(_ direction: HelpNavigationDirection) -> HelpTopicID? {
        switch direction {
        case .back:
            guard let destination = backStack.popLast() else { return nil }
            if let current { forwardStack.append(current) }
            current = destination
            return destination
        case .forward:
            guard let destination = forwardStack.popLast() else { return nil }
            if let current { backStack.append(current) }
            current = destination
            return destination
        }
    }
}
