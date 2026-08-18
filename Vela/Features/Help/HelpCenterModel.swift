import Foundation
import Observation

@MainActor
@Observable
final class HelpCenterModel {
    enum Phase: Equatable {
        case idle
        case loading
        case ready
    case emptyCatalog
        case failed(String)
    }

    private let resourceRoot: URL?
    private let preferredLanguages: [String]
    private let searchDebounce: Duration
    private let store: HelpContentStore
    private var history = HelpNavigationHistory()
    private var articleTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var articleGeneration: UInt64 = 0
    private var searchGeneration: UInt64 = 0

    private(set) var phase: Phase = .idle
    private(set) var library: HelpLibrary?
    private(set) var article: HelpArticle?
    private(set) var isArticleLoading = false
    private(set) var isSearching = false
    private(set) var searchResults: [HelpSearchResult] = []
    private(set) var selectedCategoryID: HelpCategoryID?
    private(set) var selectedTopicID: HelpTopicID?
    private(set) var articleError: String?
    private(set) var searchError: String?
  private(set) var searchCategoryID: HelpCategoryID?

    var searchText = "" {
        didSet {
            guard searchText != oldValue else { return }
            scheduleSearch()
        }
    }

    var canGoBack: Bool { history.canGoBack }
    var canGoForward: Bool { history.canGoForward }

    var visibleArticles: [HelpArticleSummary] {
        guard let library, let selectedCategoryID else { return [] }
        return library.articles(in: selectedCategoryID)
    }

    var relatedArticles: [HelpArticleSummary] {
        guard let library, let article else { return [] }
        return article.summary.relatedTopicIDs.compactMap { library.article(id: $0) }
    }

  var filteredSearchResults: [HelpSearchResult] {
    guard let searchCategoryID else { return searchResults }
    return searchResults.filter { $0.categoryID == searchCategoryID }
  }

  var topicCount: Int { library?.articles.count ?? 0 }

    init(
        resourceRoot: URL?,
        preferredLanguages: [String],
        searchDebounce: Duration = .milliseconds(200),
        store: HelpContentStore = HelpContentStore()
    ) {
        self.resourceRoot = resourceRoot
        self.preferredLanguages = preferredLanguages
        self.searchDebounce = searchDebounce
        self.store = store
    }

    func loadIfNeeded() async {
        guard phase == .idle else { return }
        await load()
    }

    func retry() async {
        cancelPendingWork()
        phase = .idle
        library = nil
        article = nil
        selectedCategoryID = nil
        selectedTopicID = nil
    searchCategoryID = nil
    searchError = nil
        history.replaceCurrent(with: nil)
        await load()
    }

  func clearSearch() {
    searchText = ""
    searchCategoryID = nil
    searchError = nil
  }

  func selectSearchCategory(_ categoryID: HelpCategoryID?) {
    guard
      categoryID == nil
        || library?.categories.contains(where: { $0.id == categoryID }) == true
    else { return }
    searchCategoryID = categoryID
  }

    func selectCategory(_ categoryID: HelpCategoryID?) {
    guard let categoryID, library?.categories.contains(where: { $0.id == categoryID }) == true
    else {
            return
        }
        selectedCategoryID = categoryID
        guard searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if visibleArticles.contains(where: { $0.id == selectedTopicID }) { return }
        if let first = visibleArticles.first {
            navigate(to: first.id)
        }
    }

    func navigate(to topicID: HelpTopicID) {
        guard let summary = library?.article(id: topicID) else { return }
        history.navigate(to: topicID)
        selectedTopicID = topicID
        selectedCategoryID = summary.categoryID
        requestArticle(topicID)
    }

    func moveHistory(_ direction: HelpNavigationDirection) {
        guard let topicID = history.move(direction),
            let summary = library?.article(id: topicID)
        else { return }
        selectedTopicID = topicID
        selectedCategoryID = summary.categoryID
        requestArticle(topicID)
    }

    func cancelPendingWork() {
        articleGeneration &+= 1
        searchGeneration &+= 1
        articleTask?.cancel()
        articleTask = nil
        searchTask?.cancel()
        searchTask = nil
        isArticleLoading = false
        isSearching = false
    }

    private func load() async {
        guard let resourceRoot else {
            phase = .failed(HelpLibraryError.missingResourceRoot.localizedDescription)
            return
        }
        phase = .loading
        do {
            let library = try await store.open(
                resourceRoot: resourceRoot,
                preferredLanguages: preferredLanguages
            )
            try Task.checkCancellation()
            self.library = library
            guard let firstCategory = library.categories.first,
                let firstArticle = library.articles(in: firstCategory.id).first
            else {
        phase = .emptyCatalog
                return
            }
            selectedCategoryID = firstCategory.id
            selectedTopicID = firstArticle.id
            history.replaceCurrent(with: firstArticle.id)
            article = try await store.article(id: firstArticle.id)
            phase = .ready
        } catch is CancellationError {
            phase = .idle
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func requestArticle(_ topicID: HelpTopicID) {
        articleGeneration &+= 1
        let generation = articleGeneration
        articleTask?.cancel()
        articleError = nil
        isArticleLoading = true
        articleTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let article = try await store.article(id: topicID)
                try Task.checkCancellation()
                guard generation == articleGeneration, selectedTopicID == topicID else { return }
                self.article = article
                self.isArticleLoading = false
                self.articleTask = nil
            } catch is CancellationError {
                return
            } catch {
                guard generation == articleGeneration else { return }
                self.articleError = error.localizedDescription
                self.isArticleLoading = false
                self.articleTask = nil
            }
        }
    }

    private func scheduleSearch() {
        searchGeneration &+= 1
        let generation = searchGeneration
        searchTask?.cancel()
        searchError = nil
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            searchResults = []
            isSearching = false
            searchTask = nil
            return
        }
        isSearching = true
        searchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: searchDebounce)
                try Task.checkCancellation()
                let results = try await store.search(query)
                try Task.checkCancellation()
                guard generation == searchGeneration,
                    query == searchText.trimmingCharacters(in: .whitespacesAndNewlines)
                else { return }
                searchResults = results
        searchError = nil
                isSearching = false
                searchTask = nil
            } catch is CancellationError {
                return
            } catch {
                guard generation == searchGeneration else { return }
        // Keep the last verified local result set. A transient index
        // failure must not erase safe bundled content that is already
        // available in this Help session.
                searchError = error.localizedDescription
                isSearching = false
                searchTask = nil
            }
        }
    }
}
