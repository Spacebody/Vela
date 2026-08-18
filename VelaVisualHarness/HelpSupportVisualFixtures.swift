#if DEBUG
  import SwiftUI

  nonisolated struct HelpSupportVisualTopic: Identifiable, Equatable, Sendable {
    let id: HelpTopicID
    let title: String
    let category: String
    let excerpt: String
  }

  nonisolated struct HelpSupportVisualSnapshot: Equatable, Sendable {
    enum ContentState: Equatable, Sendable {
      case loading
      case loaded
      case noSearchResults(String)
      case emptyCatalog
      case offline
      case indexFailureWithLastGood(String)
      case fullFailure(String)
    }

    let state: ContentState
    let topics: [HelpSupportVisualTopic]
    let selectedTopicID: HelpTopicID?
    let article: HelpArticle?
    let relatedTopics: [HelpSupportVisualTopic]
    let supportScenario: String?
  }

  nonisolated enum HelpSupportVisualFixtureFactory {
    static func snapshot(
      for configuration: VisualUITestConfiguration
    ) -> HelpSupportVisualSnapshot {
      let copy = VisualFixtureLocalizedCopy(locale: configuration.localeIdentifier)
      let topics = makeTopics(copy)
      let selectedID = HelpTopicID(rawValue: "diagnostics-and-support")!
      let article = makeArticle(copy, topics: topics, selectedID: selectedID)
      let related = topics.filter {
        ["troubleshooting-network", "privacy-and-security", "app-and-core-updates"]
          .contains($0.id.rawValue)
      }

      if let scenario = launchValue("-VelaHelpScenario") {
        switch scenario {
        case "noSearchResults":
          return snapshot(
            .noSearchResults("wireguard cloud"),
            topics: topics,
            article: article,
            related: related,
            selectedID: selectedID
          )
        case "emptyCatalog":
          return snapshot(
            .emptyCatalog,
            topics: [],
            article: nil,
            related: [],
            selectedID: nil
          )
        case "fullFailure":
          return snapshot(
            .fullFailure("HELP_CONTENT_INTEGRITY_FAILED"),
            topics: [],
            article: nil,
            related: [],
            selectedID: nil
          )
        case "guidedCategory", "diagnosticsRunning", "repairConfirmation",
          "unresolved", "bundleCollecting", "bundleBlocked", "bundleReady",
          "saveCancelled":
          return snapshot(
            .loaded,
            topics: topics,
            article: article,
            related: related,
            selectedID: selectedID,
            supportScenario: scenario
          )
        default:
          break
        }
      }

      let state: HelpSupportVisualSnapshot.ContentState =
        switch configuration.state {
        case .loading:
          .loading
        case .loaded:
          .loaded
        case .empty:
          .noSearchResults(copy.text("wireguard cloud", "远程云服务"))
        case .offline:
          .offline
        case .failure:
          .indexFailureWithLastGood("HELP_SEARCH_INDEX_UNAVAILABLE")
        case .refreshing, .pendingMutation, .partialFailure, .stale,
          .permissionRequired, .transitioning, .rollbackFailed:
          .loaded
        }
      return snapshot(
        state,
        topics: topics,
        article: article,
        related: related,
        selectedID: selectedID
      )
    }

    private static func snapshot(
      _ state: HelpSupportVisualSnapshot.ContentState,
      topics: [HelpSupportVisualTopic],
      article: HelpArticle?,
      related: [HelpSupportVisualTopic],
      selectedID: HelpTopicID?,
      supportScenario: String? = nil
    ) -> HelpSupportVisualSnapshot {
      HelpSupportVisualSnapshot(
        state: state,
        topics: topics,
        selectedTopicID: selectedID,
        article: article,
        relatedTopics: related,
        supportScenario: supportScenario
      )
    }

    private static func makeTopics(
      _ copy: VisualFixtureLocalizedCopy
    ) -> [HelpSupportVisualTopic] {
      [
        topic(
          "getting-started", copy.text("Getting Started", "开始使用"),
          copy.text("Getting Started", "开始使用"),
          copy.text(
            "Choose a configuration and understand the first-run workflow.", "选择配置并了解首次使用流程。")),
        topic(
          "configurations-and-subscriptions",
          copy.text("Configurations and Subscriptions", "配置与订阅"),
          copy.text("Getting Started", "开始使用"),
          copy.text("Add, validate, and update local or remote configurations.", "添加、验证和更新本地或远程配置。")
        ),
        topic(
          "system-proxy-vs-tun", copy.text("System Proxy and TUN", "系统代理与 TUN"),
          copy.text("Networking", "网络"),
          copy.text("Compare backends, permissions, and recovery boundaries.", "比较后端、权限和恢复边界。")),
        topic(
          "connections-and-routing", copy.text("Connections and Routing", "连接与路由"),
          copy.text("Networking", "网络"),
          copy.text(
            "Inspect routes, rules, proxy chains, and live connections.", "检查路由、规则、代理链和实时连接。")),
        topic(
          "configuration-workbench", copy.text("Configuration Workbench", "配置工作台"),
          copy.text("Configuration", "配置"),
          copy.text(
            "Review effective values, provenance, and validation results.", "查看生效值、来源和验证结果。")),
        topic(
          "scenes-and-automation", copy.text("Scenes and Automation", "场景与自动化"),
          copy.text("Automation", "自动化"),
          copy.text("Switch reviewed scenes without hidden network changes.", "通过已审核场景切换，避免隐藏网络变更。")
        ),
        topic(
          "app-and-core-updates", copy.text("App and Core Updates", "应用与内核更新"),
          copy.text("Maintenance", "维护"),
          copy.text(
            "Understand signed catalogs, activation, and recovery points.", "了解签名目录、激活和恢复点。")),
        topic(
          "diagnostics-and-support", copy.text("Diagnostics and Support", "诊断与支持"),
          copy.text("Troubleshooting", "故障排查"),
          copy.text(
            "Run local checks and prepare a private redacted support bundle.",
            "运行本地检查并准备隐私保护的脱敏支持包。")),
        topic(
          "troubleshooting-network", copy.text("Troubleshooting Network Problems", "排查网络问题"),
          copy.text("Troubleshooting", "故障排查"),
          copy.text(
            "Use evidence-first recovery for controller, DNS, and route failures.",
            "基于证据恢复 Controller、DNS 和路由故障。")),
        topic(
          "cli-and-shortcuts", copy.text("CLI and Shortcuts", "CLI 与快捷指令"),
          copy.text("Reference", "参考"),
          copy.text(
            "Use stable commands, JSON output, and App Intents.", "使用稳定命令、JSON 输出和 App Intents。")),
        topic(
          "privacy-and-security", copy.text("Privacy and Security", "隐私与安全"),
          copy.text("Reference", "参考"),
          copy.text(
            "Review local data, secret handling, and private support channels.",
            "查看本地数据、Secret 处理和私密支持渠道。")),
      ]
    }

    private static func topic(
      _ id: String,
      _ title: String,
      _ category: String,
      _ excerpt: String
    ) -> HelpSupportVisualTopic {
      HelpSupportVisualTopic(
        id: HelpTopicID(rawValue: id)!,
        title: title,
        category: category,
        excerpt: excerpt
      )
    }

    private static func makeArticle(
      _ copy: VisualFixtureLocalizedCopy,
      topics: [HelpSupportVisualTopic],
      selectedID: HelpTopicID
    ) -> HelpArticle {
      let selected = topics.first { $0.id == selectedID }!
      let relatedIDs = [
        HelpTopicID(rawValue: "troubleshooting-network")!,
        HelpTopicID(rawValue: "privacy-and-security")!,
        HelpTopicID(rawValue: "app-and-core-updates")!,
      ]
      let summary = HelpArticleSummary(
        id: selected.id,
        categoryID: HelpCategoryID(rawValue: "troubleshooting")!,
        order: 10,
        title: selected.title,
        keywords: [],
        relatedTopicIDs: relatedIDs,
        resourcePath: "DEBUG/diagnostics-and-support.md",
        sha256: String(repeating: "0", count: 64)
      )
      return HelpArticle(
        summary: summary,
        blocks: [
          .heading(level: 1, content: inline(selected.title)),
          .paragraph(
            inline(
              copy.text(
                "Vela's support flow stays on this Mac. Start with read-only diagnostics, review the evidence, and choose a repair only when one is explicitly available.",
                "Vela 的支持流程完全在此 Mac 上运行。请先执行只读诊断、查看证据，仅在明确提供修复操作时再选择执行。"
              ))),
          .callout(
            inline(
              copy.text(
                "Search terms, support answers, and bundle previews are not uploaded or recorded as raw telemetry.",
                "搜索词、支持回答和支持包预览不会上传，也不会作为原始遥测记录。"
              ))),
          .heading(level: 2, content: inline(copy.text("Start with evidence", "先查看证据"))),
          .orderedList(
            start: 1,
            items: [
              inline(copy.text("Choose the category that matches the symptom.", "选择与症状匹配的分类。")),
              inline(copy.text("Run the related local diagnostic checks.", "运行相关的本地诊断检查。")),
              inline(
                copy.text("Confirm an allowlisted repair, then verify again.", "确认白名单修复操作，然后重新验证。")),
            ]),
          .heading(level: 2, content: inline(copy.text("Useful status command", "实用状态命令"))),
          .code(language: "text", text: "vela status --json"),
          .heading(level: 2, content: inline(copy.text("Private support bundle", "隐私保护的支持包"))),
          .paragraph(
            inline(
              copy.text(
                "Preview the .velasupport archive before saving. Configuration content, credentials, subscription URLs, destinations, and Keychain values are excluded.",
                "保存前请预览 .velasupport 归档。配置内容、凭据、订阅地址、目标地址和钥匙串内容始终排除。"
              ))),
        ]
      )
    }

    private static func inline(_ text: String) -> HelpInlineContent {
      HelpInlineContent(fragments: [.text(text)])
    }

    private static func launchValue(_ key: String) -> String? {
      let arguments = ProcessInfo.processInfo.arguments
      guard let index = arguments.lastIndex(of: key) else { return nil }
      let valueIndex = arguments.index(after: index)
      guard valueIndex < arguments.endIndex else { return nil }
      return arguments[valueIndex]
    }
  }

  struct HelpSupportVisualFixtureView: View {
    let configuration: VisualUITestConfiguration

    private var snapshot: HelpSupportVisualSnapshot {
      HelpSupportVisualFixtureFactory.snapshot(for: configuration)
    }

    private var copy: VisualFixtureLocalizedCopy {
      VisualFixtureLocalizedCopy(locale: configuration.localeIdentifier)
    }

    private var strings: HelpUIStrings {
      HelpUIStrings(
        locale: configuration.localeIdentifier == .simplifiedChinese
          ? .simplifiedChinese
          : .english
      )
    }

    var body: some View {
      GeometryReader { proxy in
        let metrics = HelpCenterLayoutMetrics(availableWidth: proxy.size.width)
        VStack(spacing: 0) {
          header
          HStack(spacing: VelaSpacing.medium) {
            navigation(metrics: metrics)
              .frame(width: metrics.navigationWidth)
              .velaPanelSurface()
            reader(metrics: metrics)
              .frame(maxWidth: .infinity, maxHeight: .infinity)
              .velaPanelSurface()
            if metrics.showsSupportToolsColumn {
              relatedAndSupport
                .frame(width: metrics.supportToolsWidth)
                .velaPanelSurface()
            }
          }
          .padding(VelaSpacing.standard)
        }
      }
      .background(VelaPageCanvas())
      .environment(\.velaAccessibilityOverrides, accessibilityOverrides)
      .overlay(alignment: .topLeading) {
        VisualReadyMarker(fixtureID: configuration.fixtureID)
        VisualSurfaceMarker(identifier: "help.window.root", label: "Independent Vela Help root")
      }
      .accessibilityIdentifier("help.fixture.root")
    }

    private var header: some View {
      HStack(spacing: VelaSpacing.medium) {
        Text(copy.text("Vela Help", "Vela 帮助"))
          .font(VelaTypography.pageTitle)
          .accessibilityAddTraits(.isHeader)
        Button {
        } label: {
          Image(systemName: "chevron.left")
        }
        .disabled(true)
        .help(strings.back)
        Button {
        } label: {
          Image(systemName: "chevron.right")
        }
        .disabled(true)
        .help(strings.forward)
        Spacer()
        VelaStatusPill(status: statusSemantic, label: statusText)
        TextField(strings.searchPrompt, text: .constant(searchQuery))
          .textFieldStyle(.roundedBorder)
          .frame(width: 230)
          .accessibilityIdentifier("help.fixture.search")
      }
      .padding(.horizontal, VelaSpacing.section)
      .padding(.vertical, VelaSpacing.medium)
      .background(.ultraThinMaterial)
    }

    private func navigation(metrics: HelpCenterLayoutMetrics) -> some View {
      VStack(spacing: 0) {
        HStack {
          Label(strings.allCategories, systemImage: "line.3.horizontal.decrease.circle")
            .font(VelaTypography.body)
          Spacer()
          Image(systemName: "chevron.up.chevron.down")
            .font(VelaTypography.caption)
            .foregroundStyle(.secondary)
        }
        .padding(VelaSpacing.medium)
        Divider()
        ScrollView {
          LazyVStack(alignment: .leading, spacing: VelaSpacing.xSmall) {
            Text(strings.topics)
              .font(VelaTypography.caption.weight(.semibold))
              .foregroundStyle(.secondary)
              .padding(.horizontal, VelaSpacing.medium)
              .padding(.top, VelaSpacing.small)
            navigationContent
            if !metrics.showsSupportToolsColumn {
              Divider().padding(.vertical, VelaSpacing.small)
              Text(strings.supportTools)
                .font(VelaTypography.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, VelaSpacing.medium)
              supportToolButtons
            }
          }
        }
        Divider()
        Label(statusText, systemImage: statusSystemImage)
          .font(VelaTypography.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
          .padding(VelaSpacing.medium)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .accessibilityIdentifier("help.fixture.navigation")
    }

    @ViewBuilder
    private var navigationContent: some View {
      switch snapshot.state {
      case .loading:
        ForEach(0..<6, id: \.self) { _ in
          Text("Loading local Help topic")
            .redacted(reason: .placeholder)
            .padding(.horizontal, VelaSpacing.medium)
            .padding(.vertical, VelaSpacing.small)
        }
      case .emptyCatalog, .fullFailure:
        Label(strings.emptyCatalog, systemImage: "book.closed")
          .foregroundStyle(.secondary)
          .padding(VelaSpacing.medium)
      case .noSearchResults:
        Label(strings.noResults, systemImage: "magnifyingglass")
          .foregroundStyle(.secondary)
          .padding(VelaSpacing.medium)
      case .loaded, .offline, .indexFailureWithLastGood:
        ForEach(snapshot.topics) { topic in
          VStack(alignment: .leading, spacing: VelaSpacing.micro) {
            Text(topic.title)
              .font(VelaTypography.body.weight(.medium))
              .lineLimit(2)
            Text(topic.category)
              .font(VelaTypography.caption)
              .foregroundStyle(.secondary)
          }
          .padding(.horizontal, VelaSpacing.medium)
          .padding(.vertical, VelaSpacing.small)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(
            topic.id == snapshot.selectedTopicID
              ? Color.accentColor.opacity(0.16)
              : Color.clear,
            in: RoundedRectangle(cornerRadius: VelaRadius.small)
          )
          .padding(.horizontal, VelaSpacing.xSmall)
        }
      }
    }

    @ViewBuilder
    private func reader(metrics: HelpCenterLayoutMetrics) -> some View {
      if let scenario = snapshot.supportScenario {
        supportScenarioView(scenario)
      } else {
        switch snapshot.state {
        case .loading:
          VStack(alignment: .leading, spacing: VelaSpacing.medium) {
            Text(strings.loadingArticle).font(VelaTypography.pageTitle)
            ForEach(0..<6, id: \.self) { index in
              RoundedRectangle(cornerRadius: VelaRadius.small)
                .fill(VelaAppearance.secondarySurface)
                .frame(maxWidth: index.isMultiple(of: 2) ? 620 : 480)
                .frame(height: index == 0 ? 28 : 16)
            }
            Spacer()
          }
          .padding(VelaSpacing.large)
          .redacted(reason: .placeholder)
        case .noSearchResults(let query):
          ContentUnavailableView {
            Label(strings.noResults, systemImage: "magnifyingglass")
          } description: {
            Text(strings.noResultsDetail(query: query))
          } actions: {
            Button(strings.clearSearch) {}
          }
        case .emptyCatalog:
          ContentUnavailableView(
            strings.emptyCatalog,
            systemImage: "book.closed",
            description: Text(strings.emptyCatalogDetail)
          )
        case .fullFailure(let code):
          ContentUnavailableView {
            Label(strings.loadFailed, systemImage: "exclamationmark.triangle")
          } description: {
            Text(code)
          } actions: {
            Button(strings.tryAgain) {}
          }
        case .loaded, .offline, .indexFailureWithLastGood:
          VStack(spacing: 0) {
            if case .indexFailureWithLastGood(let code) = snapshot.state {
              VelaStateBanner(
                kind: .warning,
                title: strings.indexUnavailable,
                detail: "\(strings.lastGoodContent) \(code)"
              )
              .padding(.horizontal, VelaSpacing.medium)
              .padding(.top, VelaSpacing.medium)
            }
            if let article = snapshot.article {
              HelpArticleView(
                article: article,
                relatedArticles: metrics.showsSupportToolsColumn
                  ? []
                  : snapshot.relatedTopics.map(articleSummary),
                strings: strings,
                showsLocaleFallback: false,
                navigate: { _ in }
              )
            }
          }
        }
      }
    }

    private func supportScenarioView(_ scenario: String) -> some View {
      ScrollView {
        VStack(alignment: .leading, spacing: VelaSpacing.section) {
          Label(
            scenario.hasPrefix("bundle") || scenario == "saveCancelled"
              ? strings.exportSupportBundle
              : strings.guidedSupport,
            systemImage: scenario.hasPrefix("bundle") || scenario == "saveCancelled"
              ? "doc.zipper"
              : "lifepreserver"
          )
          .font(VelaTypography.pageTitle)

          supportScenarioBanner(scenario)

          if ["guidedCategory", "diagnosticsRunning", "repairConfirmation", "unresolved"]
            .contains(scenario)
          {
            VelaSectionHeader(copy.text("What needs attention?", "需要处理什么问题？"))
            Picker("", selection: .constant("tun")) {
              Text("TUN").tag("tun")
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 300)

            VStack(spacing: 0) {
              supportCheck(
                copy.text("Privileged Component", "特权组件"),
                copy.text("Ready and authenticated", "已就绪并通过身份验证"),
                .success
              )
              Divider()
              supportCheck(
                copy.text("TUN Runtime", "TUN 运行时"),
                scenario == "unresolved"
                  ? copy.text("Verification still failed", "重新验证仍然失败")
                  : copy.text("Waiting for local verification", "等待本地验证"),
                scenario == "unresolved" ? .error : .pending
              )
            }
            .velaPanelSurface()
          } else {
            VelaSectionHeader(copy.text("Preparation", "准备过程"))
            HStack(spacing: VelaSpacing.small) {
              bundleStage(copy.text("Collecting", "收集"), complete: true)
              bundleStage(copy.text("Redacting", "脱敏"), complete: scenario != "bundleCollecting")
              bundleStage(
                copy.text("Validating", "验证"),
                complete: scenario == "bundleReady" || scenario == "saveCancelled")
              bundleStage(
                copy.text("Preview Ready", "预览就绪"),
                complete: scenario == "bundleReady" || scenario == "saveCancelled")
            }
            VelaSectionHeader(copy.text("Privacy", "隐私"))
            Label(
              copy.text(
                "10 MiB · 100 files · no automatic upload",
                "10 MiB · 100 个文件 · 不会自动上传"
              ),
              systemImage: "checkmark.shield"
            )
            if scenario == "bundleReady" {
              Button(copy.text("Save Support Bundle…", "保存支持包…")) {}
                .buttonStyle(.borderedProminent)
            }
          }
        }
        .padding(VelaSpacing.large)
        .frame(maxWidth: 760, alignment: .topLeading)
        .frame(maxWidth: .infinity)
      }
      .accessibilityIdentifier("help.fixture.support.\(scenario)")
    }

    private func supportScenarioBanner(_ scenario: String) -> some View {
      let presentation: (VelaStateBannerKind, String, String) =
        switch scenario {
        case "diagnosticsRunning":
          (
            .info,
            copy.text("Running local diagnostics", "正在运行本地诊断"),
            copy.text("No data is uploaded.", "不会上传任何数据。")
          )
        case "repairConfirmation":
          (
            .permission,
            copy.text("Confirmation required", "需要确认"),
            copy.text("Only the selected allowlisted repair will run.", "只会运行所选的白名单修复操作。")
          )
        case "unresolved":
          (
            .warning,
            copy.text("More attention is needed", "仍需进一步处理"),
            copy.text(
              "Verification still reports a failure; preview a private bundle if needed.",
              "重新验证仍报告失败；如需支持，可预览隐私保护的支持包。")
          )
        case "bundleCollecting":
          (
            .info,
            copy.text("Collecting bounded local evidence", "正在收集有限的本地证据"),
            copy.text("You can cancel safely at any time.", "你可以随时安全取消。")
          )
        case "bundleBlocked":
          (
            .error,
            copy.text("Export blocked", "导出已阻止"),
            copy.text("High-risk content remained after redaction.", "脱敏后仍检测到高风险内容。")
          )
        case "bundleReady":
          (
            .info,
            copy.text("Preview ready", "预览已就绪"),
            copy.text(
              "Review every included file before choosing a Save location.", "选择保存位置前，请检查所有包含的文件。")
          )
        case "saveCancelled":
          (
            .info,
            copy.text("Save cancelled", "已取消保存"),
            copy.text("The temporary staging directory was cleaned.", "临时暂存目录已清理。")
          )
        default:
          (
            .info,
            copy.text("Choose a support category", "选择支持分类"),
            copy.text("Guidance and diagnostics stay local.", "指南与诊断完全保留在本地。")
          )
        }
      return VelaStateBanner(
        kind: presentation.0,
        title: presentation.1,
        detail: presentation.2
      )
    }

    private func supportCheck(
      _ title: String,
      _ detail: String,
      _ status: VelaSemanticStatus
    ) -> some View {
      HStack(alignment: .top, spacing: VelaSpacing.medium) {
        VelaStatusPill(status: status, label: status.accessibilityValue)
        VStack(alignment: .leading, spacing: VelaSpacing.micro) {
          Text(title).font(VelaTypography.sectionTitle)
          Text(detail).font(VelaTypography.body).foregroundStyle(.secondary)
        }
        Spacer()
      }
      .padding(VelaSpacing.medium)
    }

    private func bundleStage(_ title: String, complete: Bool) -> some View {
      Label(title, systemImage: complete ? "checkmark.circle.fill" : "circle")
        .font(VelaTypography.caption)
        .foregroundStyle(complete ? Color.accentColor : Color.secondary)
    }

    private var relatedAndSupport: some View {
      ScrollView {
        VStack(alignment: .leading, spacing: VelaSpacing.section) {
          VelaSectionHeader(strings.relatedTopics)
          ForEach(snapshot.relatedTopics) { topic in
            Button(topic.title) {}
              .buttonStyle(.plain)
              .multilineTextAlignment(.leading)
          }
          Divider()
          VelaSectionHeader(strings.supportTools)
          supportToolButtons
          VelaStateBanner(
            kind: .info,
            title: copy.text("Local and private", "本地且私密"),
            detail: copy.text(
              "No remote AI or automatic upload.",
              "不使用远程 AI，也不会自动上传。"
            )
          )
        }
        .padding(VelaSpacing.medium)
        .frame(maxWidth: .infinity, alignment: .topLeading)
      }
    }

    private var supportToolButtons: some View {
      VStack(alignment: .leading, spacing: VelaSpacing.small) {
        tool(strings.guidedSupport, "lifepreserver")
        tool(strings.exportSupportBundle, "doc.zipper")
        tool(strings.copyVersionInformation, "doc.on.doc")
        tool(strings.supportPolicy, "text.document")
        tool(strings.reportSecurityIssue, "lock.shield")
      }
    }

    private func tool(_ title: String, _ systemImage: String) -> some View {
      Button {
      } label: {
        Label(title, systemImage: systemImage)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .buttonStyle(.plain)
      .controlSize(.regular)
    }

    private var statusText: String {
      switch snapshot.state {
      case .loading: strings.loading
      case .loaded: strings.topicCount(snapshot.topics.count)
      case .noSearchResults: strings.resultCount(0)
      case .emptyCatalog: strings.emptyCatalog
      case .offline: strings.offlineHelpAvailable
      case .indexFailureWithLastGood: strings.indexUnavailable
      case .fullFailure: strings.loadFailed
      }
    }

    private var statusSemantic: VelaSemanticStatus {
      switch snapshot.state {
      case .loaded, .offline: .success
      case .loading: .pending
      case .noSearchResults, .emptyCatalog: .neutral
      case .indexFailureWithLastGood: .warning
      case .fullFailure: .error
      }
    }

    private var statusSystemImage: String {
      switch statusSemantic {
      case .success: "arrow.down.circle"
      case .pending: "clock"
      case .warning: "clock.arrow.circlepath"
      case .error: "exclamationmark.triangle"
      default: "info.circle"
      }
    }

    private var searchQuery: String {
      if case .noSearchResults(let query) = snapshot.state { return query }
      return ""
    }

    private func articleSummary(_ topic: HelpSupportVisualTopic) -> HelpArticleSummary {
      HelpArticleSummary(
        id: topic.id,
        categoryID: HelpCategoryID(rawValue: "reference")!,
        order: 0,
        title: topic.title,
        keywords: [],
        relatedTopicIDs: [],
        resourcePath: "DEBUG/related.md",
        sha256: String(repeating: "0", count: 64)
      )
    }

    private var accessibilityOverrides: VelaAccessibilityOverrides {
      VelaAccessibilityOverrides(
        reduceMotion: launchFlag("-VelaHelpReduceMotion"),
        increasedContrast: launchFlag("-VelaHelpIncreaseContrast")
      )
    }

    private func launchFlag(_ key: String) -> Bool? {
      let arguments = ProcessInfo.processInfo.arguments
      guard let index = arguments.lastIndex(of: key) else { return nil }
      let valueIndex = arguments.index(after: index)
      guard valueIndex < arguments.endIndex else { return nil }
      return switch arguments[valueIndex].lowercased() {
      case "yes", "true", "1": true
      case "no", "false", "0": false
      default: nil
      }
    }
  }
#endif
