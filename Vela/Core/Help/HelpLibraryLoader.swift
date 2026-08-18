import CryptoKit
import Darwin
import Foundation

nonisolated enum HelpLibraryError: Error, LocalizedError, Equatable, Sendable {
    case missingResourceRoot
    case unsafeResourceRoot
    case missingResource(String)
    case unsafeResourcePath(String)
    case unsafeResource(String)
    case resourceTooLarge(String, maximumBytes: Int)
    case invalidUTF8(String)
    case invalidIndex(String)
    case unsupportedSchema(String)
    case unsupportedLocale(String)
    case integrityMismatch(String)
    case unknownTopic(HelpTopicID)

    var errorDescription: String? {
        switch self {
        case .missingResourceRoot:
            "The bundled Help resources are missing."
        case .unsafeResourceRoot:
            "The bundled Help resource directory is unsafe."
        case let .missingResource(path):
            "A bundled Help resource is missing: \(path)"
        case let .unsafeResourcePath(path):
            "A bundled Help resource path is unsafe: \(path)"
        case let .unsafeResource(path):
            "A bundled Help resource is not a regular file: \(path)"
        case let .resourceTooLarge(path, maximumBytes):
            "A bundled Help resource exceeds \(maximumBytes) bytes: \(path)"
        case let .invalidUTF8(path):
            "A bundled Help resource is not valid UTF-8: \(path)"
        case let .invalidIndex(reason):
            "The bundled Help index is invalid: \(reason)"
        case let .unsupportedSchema(name):
            "The bundled Help schema is unsupported: \(name)"
        case let .unsupportedLocale(locale):
            "The bundled Help locale is unsupported: \(locale)"
        case let .integrityMismatch(path):
            "A bundled Help resource failed its integrity check: \(path)"
        case let .unknownTopic(topicID):
            "The Help topic does not exist: \(topicID.rawValue)"
        }
    }
}

nonisolated enum HelpBundleResources {
    static func rootURL(in bundle: Bundle = .main) -> URL? {
        if let direct = bundle.url(forResource: "Help", withExtension: nil) {
            return direct
        }
        guard let resources = bundle.resourceURL else { return nil }
        let candidate = resources.appending(path: "Help", directoryHint: .isDirectory)
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }
}

nonisolated struct HelpRepository: Sendable {
    static let maximumArticleBytes = 256 * 1024
    static let maximumAllArticlesBytes = 5 * 1024 * 1024

    let library: HelpLibrary
    let searchEngine: HelpSearchEngine
    private let reader: HelpSecureResourceReader
    private let knownTopicIDs: Set<HelpTopicID>

    static func open(
        resourceRoot: URL,
        preferredLanguages: [String]
    ) throws -> HelpRepository {
        let reader = try HelpSecureResourceReader(rootURL: resourceRoot)
        let decoder = JSONDecoder()

        let indexData = try reader.read(relativePath: "help-index.json", maximumBytes: 1024 * 1024)
        let index: HelpIndexDocument
        do {
            index = try decoder.decode(HelpIndexDocument.self, from: indexData)
        } catch {
            throw HelpLibraryError.invalidIndex("help-index.json: \(error)")
        }
        try index.validate()

        let hashesData = try reader.read(relativePath: "article-hashes.json", maximumBytes: 1024 * 1024)
        let hashes: HelpArticleHashesDocument
        do {
            hashes = try decoder.decode(HelpArticleHashesDocument.self, from: hashesData)
        } catch {
            throw HelpLibraryError.invalidIndex("article-hashes.json: \(error)")
        }
        try hashes.validate(index: index)

        let supported = Set(index.supportedLocales)
        let resolution = HelpLocaleResolver.resolve(
            preferredLanguages: preferredLanguages,
            supportedLocales: supported,
            sourceLanguage: index.sourceLanguage
        )

        let knownTopicIDs = Set(index.articles.map(\.id))
        var totalHelpBytes = indexData.count + hashesData.count
        var selectedSearchDocument: HelpSearchIndexDocument?
        for locale in index.supportedLocales {
            let searchPath = "search-index-\(locale.rawValue).json"
            let searchData = try reader.read(
                relativePath: searchPath,
                maximumBytes: maximumAllArticlesBytes
            )
            totalHelpBytes += searchData.count
            guard totalHelpBytes <= maximumAllArticlesBytes else {
                throw HelpLibraryError.resourceTooLarge(
                    "Help",
                    maximumBytes: maximumAllArticlesBytes
                )
            }
            let searchDocument: HelpSearchIndexDocument
            do {
                searchDocument = try decoder.decode(HelpSearchIndexDocument.self, from: searchData)
            } catch {
                throw HelpLibraryError.invalidIndex("\(searchPath): \(error)")
            }
            try searchDocument.validate(index: index, hashes: hashes, locale: locale)
            if locale == resolution.locale {
                selectedSearchDocument = searchDocument
            }
        }

        for article in index.articles {
            for locale in index.supportedLocales {
                guard let localized = article.locales[locale.rawValue],
                    hashes.hashes[article.id.rawValue]?[locale.rawValue] != nil
                else {
                    throw HelpLibraryError.invalidIndex(
                        "Missing \(locale.rawValue) metadata for \(article.id.rawValue)"
                    )
                }
                totalHelpBytes += try reader.fileSize(
                    relativePath: localized.path,
                    maximumBytes: maximumArticleBytes
                )
                guard totalHelpBytes <= maximumAllArticlesBytes else {
                    throw HelpLibraryError.resourceTooLarge(
                        "Help",
                        maximumBytes: maximumAllArticlesBytes
                    )
                }
            }
        }

        guard let searchDocument = selectedSearchDocument else {
            throw HelpLibraryError.invalidIndex("Selected Help search index is missing")
        }

        let categoryOrder = Dictionary(uniqueKeysWithValues: index.categories.map { ($0.id, $0.order) })
        let searchByID = Dictionary(uniqueKeysWithValues: searchDocument.articles.map { ($0.id, $0) })
        let summaries = try index.articles.map { article -> HelpArticleSummary in
            guard let localized = article.locales[resolution.locale.rawValue],
                let hash = hashes.hashes[article.id.rawValue]?[resolution.locale.rawValue],
                let search = searchByID[article.id]
            else {
                throw HelpLibraryError.invalidIndex(
                    "Selected locale metadata is missing for \(article.id.rawValue)"
                )
            }
            guard search.title == localized.title else {
                throw HelpLibraryError.invalidIndex(
                    "Search title differs for \(article.id.rawValue)"
                )
            }
            return HelpArticleSummary(
                id: article.id,
                categoryID: article.category,
                order: article.order,
                title: localized.title,
                keywords: localized.keywords,
                relatedTopicIDs: article.related,
                resourcePath: localized.path,
                sha256: hash
            )
        }.sorted { lhs, rhs in
            let leftCategory = categoryOrder[lhs.categoryID] ?? .max
            let rightCategory = categoryOrder[rhs.categoryID] ?? .max
            if leftCategory != rightCategory { return leftCategory < rightCategory }
            if lhs.order != rhs.order { return lhs.order < rhs.order }
            return lhs.id.rawValue < rhs.id.rawValue
        }

        var categories = index.categories.map { category in
            HelpCategory(id: category.id, order: category.order)
        }
        categories.sort { lhs, rhs in
            if lhs.order != rhs.order { return lhs.order < rhs.order }
            return lhs.id.rawValue < rhs.id.rawValue
        }
        let library = HelpLibrary(
            localeResolution: resolution,
            categories: categories,
            articles: summaries
        )
        return HelpRepository(
            library: library,
            searchEngine: HelpSearchEngine(document: searchDocument),
            reader: reader,
            knownTopicIDs: knownTopicIDs
        )
    }

    func loadArticle(id: HelpTopicID) throws -> HelpArticle {
        guard let summary = library.article(id: id) else {
            throw HelpLibraryError.unknownTopic(id)
        }
        let data = try reader.read(
            relativePath: summary.resourcePath,
            maximumBytes: Self.maximumArticleBytes
        )
        guard HelpDigest.sha256(data) == summary.sha256 else {
            throw HelpLibraryError.integrityMismatch(summary.resourcePath)
        }
        let blocks = try HelpMarkdownParser.parse(data: data, resourcePath: summary.resourcePath)
        for topicID in blocks.internalTopicLinks where !knownTopicIDs.contains(topicID) {
            throw HelpLibraryError.invalidIndex(
                "Article \(summary.id.rawValue) links to unknown topic \(topicID.rawValue)"
            )
        }
        return HelpArticle(summary: summary, blocks: blocks)
    }
}

actor HelpContentStore {
    private static let articleCacheLimit = 6

    private var repository: HelpRepository?
    private var articleCache: [HelpTopicID: HelpArticle] = [:]
    private var articleCacheOrder: [HelpTopicID] = []

    func open(resourceRoot: URL, preferredLanguages: [String]) throws -> HelpLibrary {
        let repository = try HelpRepository.open(
            resourceRoot: resourceRoot,
            preferredLanguages: preferredLanguages
        )
        self.repository = repository
        articleCache.removeAll()
        articleCacheOrder.removeAll()
        return repository.library
    }

    func article(id: HelpTopicID) throws -> HelpArticle {
        if let cached = articleCache[id] {
            markRecentlyUsed(id)
            return cached
        }
        guard let repository else { throw HelpLibraryError.missingResourceRoot }
        let article = try repository.loadArticle(id: id)
        articleCache[id] = article
        markRecentlyUsed(id)
        if articleCacheOrder.count > Self.articleCacheLimit {
            let evicted = articleCacheOrder.removeFirst()
            articleCache.removeValue(forKey: evicted)
        }
        return article
    }

    func search(_ query: String) throws -> [HelpSearchResult] {
        guard let repository else { throw HelpLibraryError.missingResourceRoot }
        return try repository.searchEngine.search(query)
    }

    private func markRecentlyUsed(_ id: HelpTopicID) {
        articleCacheOrder.removeAll { $0 == id }
        articleCacheOrder.append(id)
    }
}

nonisolated private struct HelpIndexDocument: Decodable, Sendable {
    let schemaVersion: Int
    let contentSchemaVersion: Int
    let sourceLanguage: HelpLocale
    let supportedLocales: [HelpLocale]
    let categories: [HelpCategoryDocument]
    let articles: [HelpArticleDocument]

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, contentSchemaVersion, sourceLanguage, supportedLocales, categories, articles
    }

    init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        contentSchemaVersion = try container.decode(Int.self, forKey: .contentSchemaVersion)
        sourceLanguage = try container.decode(HelpLocale.self, forKey: .sourceLanguage)
        supportedLocales = try container.decode([HelpLocale].self, forKey: .supportedLocales)
        categories = try container.decode([HelpCategoryDocument].self, forKey: .categories)
        articles = try container.decode([HelpArticleDocument].self, forKey: .articles)
    }

    func validate() throws {
        guard schemaVersion == 1, contentSchemaVersion == 1 else {
            throw HelpLibraryError.unsupportedSchema("help-index")
        }
        guard sourceLanguage == .english else {
            throw HelpLibraryError.unsupportedLocale(sourceLanguage.rawValue)
        }
        guard Set(supportedLocales) == Set(HelpLocale.allCases),
            supportedLocales.count == HelpLocale.allCases.count
        else {
            throw HelpLibraryError.invalidIndex("Supported locales must be exactly en and zh-Hans")
        }
        guard !categories.isEmpty, !articles.isEmpty else {
            throw HelpLibraryError.invalidIndex("Categories and articles must not be empty")
        }
        guard Set(categories.map(\.id)).count == categories.count,
            Set(categories.map(\.order)).count == categories.count,
            categories.allSatisfy({ $0.order > 0 })
        else {
            throw HelpLibraryError.invalidIndex("Category IDs and orders must be positive and unique")
        }
        let categoryIDs = Set(categories.map(\.id))
        let topicIDs = Set(articles.map(\.id))
        guard topicIDs.count == articles.count else {
            throw HelpLibraryError.invalidIndex("Article IDs must be unique")
        }
        var ordersByCategory: [HelpCategoryID: Set<Int>] = [:]
        for article in articles {
            guard categoryIDs.contains(article.category), article.order > 0 else {
                throw HelpLibraryError.invalidIndex("Invalid category or order for \(article.id.rawValue)")
            }
            guard ordersByCategory[article.category, default: []].insert(article.order).inserted else {
                throw HelpLibraryError.invalidIndex("Duplicate article order in \(article.category.rawValue)")
            }
            guard Set(article.related).count == article.related.count,
                !article.related.contains(article.id),
                article.related.allSatisfy(topicIDs.contains)
            else {
                throw HelpLibraryError.invalidIndex("Invalid related topics for \(article.id.rawValue)")
            }
            guard Set(article.locales.keys) == Set(supportedLocales.map(\.rawValue)),
                article.locales.count == supportedLocales.count
            else {
                throw HelpLibraryError.invalidIndex("Locale coverage differs for \(article.id.rawValue)")
            }
            for locale in supportedLocales {
                guard let localized = article.locales[locale.rawValue] else { continue }
                try HelpMetadataValidator.validate(localized.title, label: "title")
                guard !localized.keywords.isEmpty, localized.keywords.count <= 32 else {
                    throw HelpLibraryError.invalidIndex("Invalid keywords for \(article.id.rawValue)")
                }
                for keyword in localized.keywords {
                    try HelpMetadataValidator.validate(keyword, label: "keyword", maximumLength: 80)
                }
                let expectedPath = "\(locale.rawValue)/\(article.id.rawValue).md"
                guard localized.path == expectedPath else {
                    throw HelpLibraryError.unsafeResourcePath(localized.path)
                }
                try HelpSecureResourceReader.validateRelativePath(localized.path)
            }
        }
    }
}

nonisolated private struct HelpCategoryDocument: Decodable, Sendable {
    let id: HelpCategoryID
    let order: Int

    private enum CodingKeys: String, CodingKey, CaseIterable { case id, order }

    init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(HelpCategoryID.self, forKey: .id)
        order = try container.decode(Int.self, forKey: .order)
    }
}

nonisolated private struct HelpArticleDocument: Decodable, Sendable {
    let id: HelpTopicID
    let category: HelpCategoryID
    let order: Int
    let related: [HelpTopicID]
    let locales: [String: HelpLocalizedArticleDocument]

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id, category, order, related, locales
    }

    init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(HelpTopicID.self, forKey: .id)
        category = try container.decode(HelpCategoryID.self, forKey: .category)
        order = try container.decode(Int.self, forKey: .order)
        related = try container.decode([HelpTopicID].self, forKey: .related)
        locales = try container.decode([String: HelpLocalizedArticleDocument].self, forKey: .locales)
    }
}

nonisolated private struct HelpLocalizedArticleDocument: Decodable, Sendable {
    let path: String
    let title: String
    let keywords: [String]

    private enum CodingKeys: String, CodingKey, CaseIterable { case path, title, keywords }

    init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        title = try container.decode(String.self, forKey: .title)
        keywords = try container.decode([String].self, forKey: .keywords)
    }
}

nonisolated private struct HelpArticleHashesDocument: Decodable, Sendable {
    let schemaVersion: Int
    let hashes: [String: [String: String]]

    private enum CodingKeys: String, CodingKey, CaseIterable { case schemaVersion, hashes }

    init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        hashes = try container.decode([String: [String: String]].self, forKey: .hashes)
    }

    func validate(index: HelpIndexDocument) throws {
        guard schemaVersion == 1 else {
            throw HelpLibraryError.unsupportedSchema("article-hashes")
        }
        let expectedTopics = Set(index.articles.map { $0.id.rawValue })
        guard Set(hashes.keys) == expectedTopics else {
            throw HelpLibraryError.invalidIndex("Article hash topic coverage differs")
        }
        let expectedLocales = Set(index.supportedLocales.map(\.rawValue))
        for (topic, localized) in hashes {
            guard Set(localized.keys) == expectedLocales else {
                throw HelpLibraryError.invalidIndex("Article hash locale coverage differs for \(topic)")
            }
            guard localized.values.allSatisfy(HelpDigest.isSHA256) else {
                throw HelpLibraryError.invalidIndex("Invalid article hash for \(topic)")
            }
        }
    }
}

nonisolated struct HelpSearchIndexDocument: Decodable, Sendable {
    let schemaVersion: Int
    let locale: HelpLocale
    let articles: [HelpSearchArticleDocument]

    private enum CodingKeys: String, CodingKey, CaseIterable { case schemaVersion, locale, articles }

    init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        locale = try container.decode(HelpLocale.self, forKey: .locale)
        articles = try container.decode([HelpSearchArticleDocument].self, forKey: .articles)
    }

    fileprivate func validate(
        index: HelpIndexDocument,
        hashes: HelpArticleHashesDocument,
        locale expectedLocale: HelpLocale
    ) throws {
        guard schemaVersion == 1 else {
            throw HelpLibraryError.unsupportedSchema("search-index")
        }
        guard locale == expectedLocale else {
            throw HelpLibraryError.unsupportedLocale(locale.rawValue)
        }
        let indexedByID = Dictionary(uniqueKeysWithValues: index.articles.map { ($0.id, $0) })
        guard Set(articles.map(\.id)) == Set(indexedByID.keys),
            Set(articles.map(\.id)).count == articles.count
        else {
            throw HelpLibraryError.invalidIndex("Search article coverage differs")
        }
        for article in articles {
            guard let indexed = indexedByID[article.id],
                let localized = indexed.locales[locale.rawValue],
                let expectedHash = hashes.hashes[article.id.rawValue]?[locale.rawValue]
            else {
                throw HelpLibraryError.invalidIndex("Search metadata is missing")
            }
            guard article.category == indexed.category,
                article.order == indexed.order,
                article.title == localized.title,
                article.keywords == localized.keywords,
                article.sha256 == expectedHash
            else {
                throw HelpLibraryError.invalidIndex("Search metadata differs for \(article.id.rawValue)")
            }
            try HelpMetadataValidator.validate(article.title, label: "search title")
            try HelpMetadataValidator.validate(article.excerpt, label: "search excerpt", maximumLength: 2_048)
            guard !article.tokens.isEmpty, article.tokens.count <= 50_000,
                article.tokens.allSatisfy({ !$0.isEmpty && $0.count <= 256 }),
                article.headings.count <= 128
            else {
                throw HelpLibraryError.invalidIndex("Search terms are invalid for \(article.id.rawValue)")
            }
            for value in article.tokens + article.headings {
                try HelpMetadataValidator.validate(value, label: "search term", maximumLength: 256)
            }
        }
    }
}

nonisolated struct HelpSearchArticleDocument: Decodable, Sendable {
    let id: HelpTopicID
    let category: HelpCategoryID
    let order: Int
    let title: String
    let keywords: [String]
    let headings: [String]
    let tokens: [String]
    let excerpt: String
    let sha256: String

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id, category, order, title, keywords, headings, tokens, excerpt, sha256
    }

    init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(HelpTopicID.self, forKey: .id)
        category = try container.decode(HelpCategoryID.self, forKey: .category)
        order = try container.decode(Int.self, forKey: .order)
        title = try container.decode(String.self, forKey: .title)
        keywords = try container.decode([String].self, forKey: .keywords)
        headings = try container.decode([String].self, forKey: .headings)
        tokens = try container.decode([String].self, forKey: .tokens)
        excerpt = try container.decode(String.self, forKey: .excerpt)
        sha256 = try container.decode(String.self, forKey: .sha256)
    }
}

nonisolated struct HelpSecureResourceReader: Sendable {
    let rootURL: URL

    init(rootURL: URL) throws {
        guard rootURL.isFileURL else { throw HelpLibraryError.unsafeResourceRoot }
        let resolved = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        let values = try? resolved.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values?.isDirectory == true, values?.isSymbolicLink != true else {
            throw HelpLibraryError.unsafeResourceRoot
        }
        self.rootURL = resolved
    }

    static func validateRelativePath(_ path: String) throws {
        guard !path.isEmpty, path.count <= 512, !path.hasPrefix("/"), !path.hasPrefix("~"),
            !path.contains("\\"), !path.contains(":"), !path.contains("\0")
        else {
            throw HelpLibraryError.unsafeResourcePath(path)
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
            components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else {
            throw HelpLibraryError.unsafeResourcePath(path)
        }
    }

    func read(relativePath: String, maximumBytes: Int) throws -> Data {
        let (candidate, expectedSize) = try verifiedResource(
            relativePath: relativePath,
            maximumBytes: maximumBytes
        )
        let descriptor = candidate.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            if errno == ENOENT {
                throw HelpLibraryError.missingResource(relativePath)
            }
            throw HelpLibraryError.unsafeResource(relativePath)
        }
        defer { Darwin.close(descriptor) }

        var before = stat()
        guard Darwin.fstat(descriptor, &before) == 0,
            before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
            before.st_size >= 0,
            UInt64(before.st_size) <= UInt64(maximumBytes),
            Int(before.st_size) == expectedSize
        else {
            if before.st_size > off_t(maximumBytes) {
                throw HelpLibraryError.resourceTooLarge(
                    relativePath,
                    maximumBytes: maximumBytes
                )
            }
            throw HelpLibraryError.unsafeResource(relativePath)
        }

        var data = Data()
        data.reserveCapacity(expectedSize)
        var buffer = [UInt8](
            repeating: 0,
            count: max(1, min(64 * 1024, maximumBytes + 1))
        )
        while data.count <= maximumBytes {
            let capacity = min(buffer.count, maximumBytes + 1 - data.count)
            let count = buffer.withUnsafeMutableBytes { bytes -> Int in
                guard let baseAddress = bytes.baseAddress else { return 0 }
                return Darwin.read(descriptor, baseAddress, capacity)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw HelpLibraryError.unsafeResource(relativePath)
            }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard data.count <= maximumBytes else {
            throw HelpLibraryError.resourceTooLarge(relativePath, maximumBytes: maximumBytes)
        }

        var after = stat()
        guard Darwin.fstat(descriptor, &after) == 0,
            before.st_dev == after.st_dev,
            before.st_ino == after.st_ino,
            before.st_size == after.st_size,
            data.count == Int(after.st_size)
        else {
            throw HelpLibraryError.unsafeResource(relativePath)
        }
        return data
    }

    func fileSize(relativePath: String, maximumBytes: Int) throws -> Int {
        try verifiedResource(relativePath: relativePath, maximumBytes: maximumBytes).size
    }

    private func verifiedResource(
        relativePath: String,
        maximumBytes: Int
    ) throws -> (url: URL, size: Int) {
        try Self.validateRelativePath(relativePath)
        let candidate = rootURL.appending(path: relativePath).standardizedFileURL
        let rootPath = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        let resolvedCandidate = candidate.resolvingSymlinksInPath()
        guard candidate.path.hasPrefix(rootPath),
            resolvedCandidate.path == candidate.path,
            resolvedCandidate.path.hasPrefix(rootPath)
        else {
            throw HelpLibraryError.unsafeResourcePath(relativePath)
        }
        let values: URLResourceValues
        do {
            values = try candidate.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
            ])
        } catch CocoaError.fileReadNoSuchFile {
            throw HelpLibraryError.missingResource(relativePath)
        } catch {
            throw HelpLibraryError.missingResource(relativePath)
        }
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw HelpLibraryError.unsafeResource(relativePath)
        }
        guard let size = values.fileSize, size <= maximumBytes else {
            throw HelpLibraryError.resourceTooLarge(relativePath, maximumBytes: maximumBytes)
        }
        return (candidate, size)
    }
}

nonisolated private enum HelpMetadataValidator {
    static func validate(
        _ value: String,
        label: String,
        maximumLength: Int = 256
    ) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            value.count <= maximumLength,
            !HelpUnicodeSafety.containsForbiddenScalar(value)
        else {
            throw HelpLibraryError.invalidIndex("Invalid \(label)")
        }
    }
}

nonisolated enum HelpUnicodeSafety {
    static func containsForbiddenScalar(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            let code = scalar.value
            let forbiddenControl = (code < 0x20 && code != 0x09 && code != 0x0A && code != 0x0D)
                || code == 0x7F
            let bidiControl = code == 0x061C || code == 0x200E || code == 0x200F
                || (0x202A...0x202E).contains(code)
                || (0x2066...0x2069).contains(code)
            return forbiddenControl || bidiControl
        }
    }
}

nonisolated enum HelpDigest {
    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 48 && scalar.value <= 57)
                || (scalar.value >= 97 && scalar.value <= 102)
        }
    }
}

nonisolated private struct HelpAnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

nonisolated private extension Decoder {
    func rejectUnknownKeys<Key>(_ keyType: Key.Type) throws
    where Key: CodingKey & CaseIterable, Key.AllCases: Sequence {
        let container = try container(keyedBy: HelpAnyCodingKey.self)
        let allowed = Set(keyType.allCases.map(\.stringValue))
        let unknown = container.allKeys.map(\.stringValue).filter { !allowed.contains($0) }.sorted()
        guard unknown.isEmpty else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: codingPath,
                    debugDescription: "Unknown keys: \(unknown.joined(separator: ", "))"
                )
            )
        }
    }
}

nonisolated extension Array where Element == HelpMarkdownBlock {
    var internalTopicLinks: [HelpTopicID] {
        flatMap { block -> [HelpTopicID] in
            let contents: [HelpInlineContent]
            switch block {
            case let .heading(_, content), let .paragraph(content), let .callout(content):
                contents = [content]
            case let .unorderedList(items), let .orderedList(_, items):
                contents = items
            case .code:
                contents = []
            }
            return contents.flatMap { content in
                content.fragments.compactMap { fragment in
                    guard case let .link(_, .topic(topicID)) = fragment else { return nil }
                    return topicID
                }
            }
        }
    }
}
