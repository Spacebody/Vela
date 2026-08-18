import AppKit
import SwiftUI

@MainActor
struct HelpCenterSupportDependencies {
  let diagnosticsAdapter: SupportDiagnosticsAdapter
  let publicBetaEvidence: PublicBetaEvidenceController?
}

@MainActor
struct HelpCenterView: View {
  private enum PresentedTool: Identifiable {
    case guidedSupport
    case supportBundle
    case policy(PublicPolicyDocument)

    var id: String {
      switch self {
      case .guidedSupport: "guided-support"
      case .supportBundle: "support-bundle"
      case .policy(let document): "policy-\(document.rawValue.lowercased())"
      }
    }
  }

  @State private var model: HelpCenterModel
  @State private var isSearchPresented = false
  @State private var presentedTool: PresentedTool?
  private let navigationCoordinator: HelpNavigationCoordinator?
  private let supportDependencies: HelpCenterSupportDependencies?

  init() {
    navigationCoordinator = nil
    supportDependencies = nil
    _model = State(
      initialValue: HelpCenterModel(
        resourceRoot: HelpBundleResources.rootURL(),
        preferredLanguages: Locale.preferredLanguages
      )
    )
  }

  init(
    navigationCoordinator: HelpNavigationCoordinator,
    supportDependencies: HelpCenterSupportDependencies? = nil
  ) {
    self.navigationCoordinator = navigationCoordinator
    self.supportDependencies = supportDependencies
    _model = State(
      initialValue: HelpCenterModel(
        resourceRoot: HelpBundleResources.rootURL(),
        preferredLanguages: Locale.preferredLanguages
      )
    )
  }

  init(resourceRoot: URL, preferredLanguages: [String]) {
    navigationCoordinator = nil
    supportDependencies = nil
    _model = State(
      initialValue: HelpCenterModel(
        resourceRoot: resourceRoot,
        preferredLanguages: preferredLanguages
      )
    )
  }

  var body: some View {
    GeometryReader { proxy in
      let metrics = HelpCenterLayoutMetrics(availableWidth: proxy.size.width)
      NavigationSplitView {
        navigationColumn(metrics: metrics)
          .navigationSplitViewColumnWidth(
            min: 240,
            ideal: metrics.navigationWidth,
            max: 320
          )
      } detail: {
        detailColumn(metrics: metrics)
      }
      .background(VelaPageCanvas())
    }
    .navigationTitle(strings.helpCenter)
    .frame(minWidth: 900, minHeight: 620)
    .toolbar { helpToolbar }
    .environment(\.openURL, OpenURLAction { url in open(url) })
    .task {
      await model.loadIfNeeded()
      applyRequestedTopic()
    }
    .onChange(of: navigationCoordinator?.requestRevision) {
      applyRequestedTopic()
    }
    .onReceive(NotificationCenter.default.publisher(for: .velaFocusSearch)) { _ in
      isSearchPresented = true
    }
    .onExitCommand {
      if !trimmedSearchText.isEmpty {
        model.clearSearch()
        isSearchPresented = true
  }
    }
    .sheet(item: $presentedTool) { tool in
      presentedToolView(tool)
        }
    .onDisappear {
      model.cancelPendingWork()
      }
    .accessibilityIdentifier("help.center")
    }

  private func navigationColumn(metrics: HelpCenterLayoutMetrics) -> some View {
    VStack(spacing: 0) {
      categoryFilter
      Divider()

      List(selection: topicSelection) {
        Section(strings.topics) {
          navigationRows
  }

        if !metrics.showsSupportToolsColumn {
          Section(strings.supportTools) {
            supportToolRows
      }
    }
      }
      .listStyle(.sidebar)
      .scrollContentBackground(.hidden)
      .accessibilityIdentifier("help.article-list")

      Divider()
      HStack(spacing: VelaSpacing.xSmall) {
        Image(systemName: statusSystemImage)
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
        Text(statusText)
          .font(VelaTypography.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, VelaSpacing.medium)
      .padding(.vertical, VelaSpacing.small)
      .accessibilityElement(children: .combine)
      .accessibilityIdentifier("help.status")
    }
    .searchable(
      text: searchBinding,
      isPresented: $isSearchPresented,
      prompt: Text(strings.searchPrompt)
    )
    .background(.ultraThinMaterial)
    .accessibilityIdentifier("help.navigation")
  }

  private var categoryFilter: some View {
    HStack(spacing: VelaSpacing.small) {
      Image(systemName: "line.3.horizontal.decrease.circle")
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      Picker(strings.category, selection: categorySelection) {
        if !trimmedSearchText.isEmpty {
          Text(strings.allCategories).tag(HelpCategoryID?.none)
        }
        ForEach(model.library?.categories ?? []) { category in
          Text(strings.categoryTitle(category.id))
            .tag(Optional(category.id))
      }
    }
      .labelsHidden()
      .pickerStyle(.menu)
      .disabled(model.library == nil)
      .accessibilityLabel(strings.category)
      .accessibilityIdentifier("help.category-filter")
      Spacer(minLength: 0)
    }
    .padding(.horizontal, VelaSpacing.medium)
    .padding(.vertical, VelaSpacing.small)
  }

  @ViewBuilder
  private var navigationRows: some View {
    switch model.phase {
    case .idle, .loading:
      ForEach(0..<5, id: \.self) { index in
        Label(
          index == 0 ? strings.loading : " ",
          systemImage: "doc.text"
        )
          .foregroundStyle(.secondary)
        .redacted(reason: .placeholder)
      }
    case .emptyCatalog, .failed:
      Label(strings.emptyCatalog, systemImage: "book.closed")
        .foregroundStyle(.secondary)
    case .ready:
      if !trimmedSearchText.isEmpty {
        if model.isSearching, model.filteredSearchResults.isEmpty {
          Label(strings.loading, systemImage: "hourglass")
            .foregroundStyle(.secondary)
        } else if model.filteredSearchResults.isEmpty {
          Label(strings.noResults, systemImage: "magnifyingglass")
            .foregroundStyle(.secondary)
    } else {
          ForEach(model.filteredSearchResults) { result in
            searchResultRow(result)
              .tag(result.id)
          }
        }
      } else {
        ForEach(model.visibleArticles) { article in
          VStack(alignment: .leading, spacing: VelaSpacing.micro) {
            Text(article.title)
              .font(VelaTypography.body.weight(.medium))
              .lineLimit(2)
            Text(strings.categoryTitle(article.categoryID))
              .font(VelaTypography.caption)
              .foregroundStyle(.secondary)
          }
          .padding(.vertical, VelaSpacing.micro)
          .tag(article.id)
          .accessibilityElement(children: .combine)
        }
      }
    }
  }

  private func searchResultRow(_ result: HelpSearchResult) -> some View {
    VStack(alignment: .leading, spacing: VelaSpacing.micro) {
            Text(result.title)
              .font(VelaTypography.body.weight(.medium))
              .lineLimit(2)
            Text(result.excerpt)
              .font(VelaTypography.caption)
              .foregroundStyle(.secondary)
              .lineLimit(3)
      Text(strings.categoryTitle(result.categoryID))
        .font(VelaTypography.caption)
        .foregroundStyle(.tertiary)
          }
          .padding(.vertical, VelaSpacing.xSmall)
    .accessibilityElement(children: .combine)
  }

  @ViewBuilder
  private var supportToolRows: some View {
    Button {
      presentedTool = .guidedSupport
    } label: {
      Label(strings.guidedSupport, systemImage: "lifepreserver")
        }
    .buttonStyle(.plain)
    .disabled(supportDependencies == nil)
    .accessibilityIdentifier("help.tool.guided-support")

    Button {
      presentedTool = .supportBundle
    } label: {
      Label(strings.exportSupportBundle, systemImage: "doc.zipper")
      }
    .buttonStyle(.plain)
    .disabled(supportDependencies == nil)
    .accessibilityIdentifier("help.tool.support-bundle")

    Button(action: copyVersionInformation) {
      Label(strings.copyVersionInformation, systemImage: "doc.on.doc")
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("help.tool.copy-version")

    Button {
      presentedTool = .policy(.privacy)
    } label: {
      Label(
        VelaL10n.string("policy.privacy.title", defaultValue: "Privacy Policy"),
        systemImage: "hand.raised"
      )
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("help.tool.privacy-policy")

    Button {
      presentedTool = .policy(.support)
    } label: {
      Label(strings.supportPolicy, systemImage: "text.document")
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("help.tool.support-policy")

    Button {
      presentedTool = .policy(.security)
    } label: {
      Label(strings.reportSecurityIssue, systemImage: "lock.shield")
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("help.tool.security")
  }

  private func detailColumn(metrics: HelpCenterLayoutMetrics) -> some View {
    HStack(spacing: VelaSpacing.medium) {
      articlePane(showsInlineRelatedTopics: !metrics.showsSupportToolsColumn)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .velaPanelSurface()

      if metrics.showsSupportToolsColumn {
        relatedAndSupportColumn
          .frame(width: metrics.supportToolsWidth)
          .frame(maxHeight: .infinity, alignment: .topLeading)
          .velaPanelSurface()
      }
    }
    .padding(VelaSpacing.standard)
    .background(VelaPageCanvas())
    .accessibilityIdentifier("help.reader-layout")
  }

  @ViewBuilder
  private func articlePane(showsInlineRelatedTopics: Bool) -> some View {
    switch model.phase {
    case .idle, .loading:
      stableLoadingReader
    case .emptyCatalog:
      unavailableReader(
        title: strings.emptyCatalog,
        detail: strings.emptyCatalogDetail,
        action: strings.tryAgain
      )
    case .failed(let message):
      unavailableReader(
        title: strings.loadFailed,
        detail: message,
        action: strings.tryAgain
      )
    case .ready:
      if !trimmedSearchText.isEmpty,
        !model.isSearching,
        model.filteredSearchResults.isEmpty
      {
        ContentUnavailableView {
          Label(strings.noResults, systemImage: "magnifyingglass")
        } description: {
          Text(strings.noResultsDetail(query: trimmedSearchText))
        } actions: {
          Button(strings.clearSearch) {
            model.clearSearch()
          }
          .keyboardShortcut(.defaultAction)
        }
        .accessibilityIdentifier("help.no-search-results")
      } else if model.isArticleLoading,
        model.article?.summary.id != model.selectedTopicID
      {
        stableLoadingReader
    } else if let article = model.article {
        VStack(spacing: 0) {
          if let error = model.searchError ?? model.articleError {
            VelaStateBanner(
              kind: .warning,
              title: strings.indexUnavailable,
              detail: "\(strings.lastGoodContent) \(DiagnosticTextSanitizer.redact(error))"
            )
            .padding(.horizontal, VelaSpacing.medium)
            .padding(.top, VelaSpacing.medium)
          }
      HelpArticleView(
        article: article,
            relatedArticles: showsInlineRelatedTopics ? model.relatedArticles : [],
        strings: strings,
            showsLocaleFallback:
              model.library?.localeResolution.fellBackToSourceLanguage == true,
            navigate: { topicID in model.navigate(to: topicID) }
      )
      .id(article.summary.id)
        }
    } else {
      ContentUnavailableView(
        strings.noSelection,
        systemImage: "book.closed",
        description: Text(strings.noSelectionDetail)
      )
    }
  }
    }

  private var stableLoadingReader: some View {
    VStack(alignment: .leading, spacing: VelaSpacing.standard) {
      Text(strings.loadingArticle)
        .font(VelaTypography.pageTitle)
        .redacted(reason: .placeholder)
      ForEach(0..<5, id: \.self) { index in
        RoundedRectangle(cornerRadius: VelaRadius.small)
          .fill(VelaAppearance.secondarySurface)
          .frame(height: index == 0 ? 26 : 16)
          .frame(maxWidth: index.isMultiple(of: 2) ? 520 : 680)
      }
      Spacer()
    }
    .padding(VelaSpacing.large)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(strings.loading)
    .accessibilityIdentifier("help.loading")
  }

  private func unavailableReader(
    title: String,
    detail: String,
    action: String
  ) -> some View {
    ContentUnavailableView {
      Label(title, systemImage: "exclamationmark.triangle")
    } description: {
      Text(DiagnosticTextSanitizer.redact(detail))
    } actions: {
      Button(action) {
        Task { await model.retry() }
      }
      .keyboardShortcut(.defaultAction)
    }
    .accessibilityIdentifier("help.failure")
  }

  private var relatedAndSupportColumn: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: VelaSpacing.section) {
        if !model.relatedArticles.isEmpty {
          VStack(alignment: .leading, spacing: VelaSpacing.small) {
            VelaSectionHeader(strings.relatedTopics)
            ForEach(model.relatedArticles) { article in
              Button {
                model.navigate(to: article.id)
              } label: {
                HStack(alignment: .firstTextBaseline) {
                  Text(article.title)
                    .multilineTextAlignment(.leading)
                  Spacer(minLength: VelaSpacing.xSmall)
                  Image(systemName: "chevron.right")
                    .font(VelaTypography.caption)
                    .accessibilityHidden(true)
                }
              }
              .buttonStyle(.plain)
            }
          }
        }

        VStack(alignment: .leading, spacing: VelaSpacing.small) {
          VelaSectionHeader(strings.supportTools)
          supportToolRows
        }
      }
      .padding(VelaSpacing.medium)
      .frame(maxWidth: .infinity, alignment: .topLeading)
    }
    .accessibilityIdentifier("help.related-support")
  }

  @ToolbarContentBuilder
  private var helpToolbar: some ToolbarContent {
    ToolbarItemGroup(placement: .navigation) {
      Button {
        model.moveHistory(.back)
      } label: {
        Label(strings.back, systemImage: "chevron.left")
      }
      .disabled(!model.canGoBack)
      .keyboardShortcut("[", modifiers: .command)
      .help(strings.back)
      .accessibilityIdentifier("help.back")

      Button {
        model.moveHistory(.forward)
      } label: {
        Label(strings.forward, systemImage: "chevron.right")
      }
      .disabled(!model.canGoForward)
      .keyboardShortcut("]", modifiers: .command)
      .help(strings.forward)
      .accessibilityIdentifier("help.forward")
    }

    ToolbarItem(placement: .primaryAction) {
      Button {
        isSearchPresented = true
      } label: {
        Label(strings.searchPrompt, systemImage: "magnifyingglass")
      }
      .keyboardShortcut("f", modifiers: .command)
      .help(strings.searchPrompt)
      .accessibilityIdentifier("help.focus-search")
    }
  }

  @ViewBuilder
  private func presentedToolView(_ tool: PresentedTool) -> some View {
    switch tool {
    case .guidedSupport:
      if let supportDependencies {
        GuidedSupportView(
          adapter: supportDependencies.diagnosticsAdapter,
          publicBetaEvidence: supportDependencies.publicBetaEvidence,
          openHelpTopic: { topic in
            guard let topicID = HelpTopicID(rawValue: topic) else { return }
            presentedTool = nil
            model.navigate(to: topicID)
          }
        )
      } else {
        ContentUnavailableView(strings.guidedSupport, systemImage: "lifepreserver")
      }
    case .supportBundle:
      if let supportDependencies {
        SupportBundleToolView(
          adapter: supportDependencies.diagnosticsAdapter,
          publicBetaEvidence: supportDependencies.publicBetaEvidence
        )
      } else {
        ContentUnavailableView(strings.exportSupportBundle, systemImage: "doc.zipper")
      }
    case .policy(let document):
      PublicPolicyDocumentView(document: document)
    }
  }

  private var strings: HelpUIStrings {
    HelpUIStrings(locale: model.library?.locale ?? requestedHelpLocale)
  }

  private var requestedHelpLocale: HelpLocale {
    VelaSupportedLocale.resolve() == .simplifiedChinese ? .simplifiedChinese : .english
  }

  private var trimmedSearchText: String {
    model.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var statusText: String {
    switch model.phase {
    case .idle, .loading:
      return strings.loading
    case .emptyCatalog:
      return strings.emptyCatalog
    case .failed:
      return strings.indexUnavailable
    case .ready:
      if model.searchError != nil {
        return "\(strings.indexUnavailable) · \(strings.lastGoodContent)"
      }
      if !trimmedSearchText.isEmpty {
        return strings.resultCount(model.filteredSearchResults.count)
      }
      return strings.topicCount(model.topicCount)
    }
  }

  private var statusSystemImage: String {
    switch model.phase {
    case .idle, .loading: "clock"
    case .emptyCatalog, .failed: "exclamationmark.triangle"
    case .ready: model.searchError == nil ? "arrow.down.circle" : "clock.arrow.circlepath"
    }
  }

  private var searchBinding: Binding<String> {
    Binding(get: { model.searchText }, set: { model.searchText = $0 })
  }

  private var categorySelection: Binding<HelpCategoryID?> {
    Binding(
      get: {
        trimmedSearchText.isEmpty
          ? model.selectedCategoryID
          : model.searchCategoryID
      },
      set: { categoryID in
        if trimmedSearchText.isEmpty {
        model.selectCategory(categoryID)
        } else {
          model.selectSearchCategory(categoryID)
        }
      }
    )
  }

  private var topicSelection: Binding<HelpTopicID?> {
    Binding(
      get: { model.selectedTopicID },
      set: { topicID in
        if let topicID { model.navigate(to: topicID) }
      }
    )
  }

  private func open(_ url: URL) -> OpenURLAction.Result {
    guard let destination = HelpLinkPolicy.destination(for: url) else { return .discarded }
    switch destination {
    case .topic(let topicID):
      model.navigate(to: topicID)
    case .external(let url):
      NSWorkspace.shared.open(url)
    }
    return .handled
  }

  private func applyRequestedTopic() {
    guard model.phase == .ready,
      let topicID = navigationCoordinator?.requestedTopicID
    else { return }
    model.navigate(to: topicID)
  }

  private func copyVersionInformation() {
    let version =
      Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
      ?? "unknown"
    let build =
      Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
      ?? "unknown"
    let architecture: String
    #if arch(arm64)
      architecture = "arm64"
    #elseif arch(x86_64)
      architecture = "x86_64"
    #else
      architecture = "unknown"
    #endif
    let value =
      "Vela \(version) (\(build)) · \(architecture) · macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(value, forType: .string)
  }
}
