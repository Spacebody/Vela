import Foundation
import NaturalLanguage

nonisolated struct HelpSearchEngine: Sendable {
    private let locale: HelpLocale
    private let articles: [HelpSearchArticleDocument]

    init(document: HelpSearchIndexDocument) {
        locale = document.locale
        articles = document.articles
    }

    init(locale: HelpLocale, articles: [HelpSearchArticleDocument]) {
        self.locale = locale
        self.articles = articles
    }

    func search(_ query: String, limit: Int = 50) throws -> [HelpSearchResult] {
        try Task.checkCancellation()
        let terms = HelpSearchNormalizer.queryTerms(query, locale: locale)
        guard !terms.isEmpty, limit > 0 else { return [] }

        var scored: [(document: HelpSearchArticleDocument, score: Int)] = []
        scored.reserveCapacity(articles.count)
        for document in articles {
            try Task.checkCancellation()
            let title = HelpSearchNormalizer.indexTerms(document.title, locale: locale)
            let keywords = Set(document.keywords.flatMap {
                HelpSearchNormalizer.indexTerms($0, locale: locale)
            })
            let headings = Set(document.headings.flatMap {
                HelpSearchNormalizer.indexTerms($0, locale: locale)
            })
            let body = Set(document.tokens.flatMap {
                HelpSearchNormalizer.indexTerms($0, locale: locale)
            })

            var score = 0
            var matchedAllTerms = true
            for term in terms {
                try Task.checkCancellation()
                let termScore = max(
                    Self.score(term, in: title, exact: 120, prefix: 90),
                    Self.score(term, in: keywords, exact: 100, prefix: 75),
                    Self.score(term, in: headings, exact: 75, prefix: 55),
                    Self.score(term, in: body, exact: 35, prefix: 20)
                )
                guard termScore > 0 else {
                    matchedAllTerms = false
                    break
                }
                score += termScore
            }
            if matchedAllTerms {
                let normalizedQuery = HelpSearchNormalizer.fold(query, locale: locale)
                let normalizedTitle = HelpSearchNormalizer.fold(document.title, locale: locale)
                if normalizedTitle == normalizedQuery {
                    score += 180
                } else if normalizedTitle.hasPrefix(normalizedQuery) {
                    score += 100
                } else if normalizedTitle.contains(normalizedQuery) {
                    score += 60
                }
                scored.append((document, score))
            }
        }

        return scored.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.document.order != rhs.document.order {
                return lhs.document.order < rhs.document.order
            }
            return lhs.document.id.rawValue < rhs.document.id.rawValue
        }.prefix(limit).map { item in
            HelpSearchResult(
                id: item.document.id,
                categoryID: item.document.category,
                title: item.document.title,
                excerpt: item.document.excerpt,
                score: item.score
            )
        }
    }

    private static func score(
        _ term: String,
        in candidates: Set<String>,
        exact: Int,
        prefix: Int
    ) -> Int {
        if candidates.contains(term) { return exact }
        if candidates.contains(where: { $0.hasPrefix(term) }) { return prefix }
        return 0
    }
}

nonisolated enum HelpSearchNormalizer {
    static func fold(_ value: String, locale: HelpLocale) -> String {
        let foundationLocale = Locale(identifier: locale.rawValue)
        return value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: foundationLocale
        ).lowercased(with: foundationLocale).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func queryTerms(_ value: String, locale: HelpLocale) -> [String] {
        let normalized = fold(value, locale: locale)
        guard !normalized.isEmpty else { return [] }
        switch locale {
        case .english:
            return stableUnique(alphanumericTerms(normalized))
        case .simplifiedChinese:
            var terms: [String] = []
            for segment in scriptSegments(normalized) {
                if segment.isHan {
                    let characters = Array(segment.value)
                    if characters.count == 1 {
                        terms.append(segment.value)
                    } else {
                        for index in 0..<(characters.count - 1) {
                            terms.append(String(characters[index...index + 1]))
                        }
                    }
                } else {
                    terms.append(contentsOf: alphanumericTerms(segment.value))
                }
            }
            return stableUnique(terms)
        }
    }

    static func indexTerms(_ value: String, locale: HelpLocale) -> Set<String> {
        let normalized = fold(value, locale: locale)
        guard !normalized.isEmpty else { return [] }
        var terms = alphanumericTerms(normalized)
        if locale == .simplifiedChinese {
            let tokenizer = NLTokenizer(unit: .word)
            tokenizer.string = normalized
            tokenizer.enumerateTokens(in: normalized.startIndex..<normalized.endIndex) { range, _ in
                let token = String(normalized[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !token.isEmpty { terms.append(token) }
                return true
            }
            for segment in scriptSegments(normalized) where segment.isHan {
                terms.append(segment.value)
                let characters = Array(segment.value)
                if characters.count > 1 {
                    for index in 0..<(characters.count - 1) {
                        terms.append(String(characters[index...index + 1]))
                    }
                }
            }
        }
        return Set(terms.filter { !$0.isEmpty })
    }

    private static func alphanumericTerms(_ value: String) -> [String] {
        value.split { character in
            !character.isLetter && !character.isNumber
        }.map(String.init)
    }

    private static func scriptSegments(_ value: String) -> [(value: String, isHan: Bool)] {
        var result: [(String, Bool)] = []
        var current = ""
        var currentIsHan: Bool?
        func flush() {
            guard let isHan = currentIsHan, !current.isEmpty else { return }
            result.append((current, isHan))
            current.removeAll(keepingCapacity: true)
        }

        for character in value {
            let isHan = character.unicodeScalars.contains(where: isHanScalar)
            let isContent = isHan || character.isLetter || character.isNumber
            guard isContent else {
                flush()
                currentIsHan = nil
                continue
            }
            if currentIsHan != nil, currentIsHan != isHan { flush() }
            currentIsHan = isHan
            current.append(character)
        }
        flush()
        return result
    }

    private static func isHanScalar(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        return (0x3400...0x4DBF).contains(value)
            || (0x4E00...0x9FFF).contains(value)
            || (0xF900...0xFAFF).contains(value)
            || (0x20000...0x2FA1F).contains(value)
    }

    private static func stableUnique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }
}

nonisolated extension HelpSearchIndexDocument {
    init(locale: HelpLocale, articles: [HelpSearchArticleDocument]) {
        schemaVersion = 1
        self.locale = locale
        self.articles = articles
    }
}

nonisolated extension HelpSearchArticleDocument {
    init(
        id: HelpTopicID,
        category: HelpCategoryID,
        order: Int,
        title: String,
        keywords: [String],
        headings: [String],
        tokens: [String],
        excerpt: String,
        sha256: String = String(repeating: "0", count: 64)
    ) {
        self.id = id
        self.category = category
        self.order = order
        self.title = title
        self.keywords = keywords
        self.headings = headings
        self.tokens = tokens
        self.excerpt = excerpt
        self.sha256 = sha256
    }
}
