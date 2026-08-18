import Foundation

nonisolated struct HelpUIStrings: Sendable {
    let locale: HelpLocale

    var helpCenter: String { localized("Help Center", "帮助中心") }
    var searchPrompt: String { localized("Search Help", "搜索帮助") }
    var loading: String { localized("Loading local Help index…", "正在载入本地帮助索引…") }
    var loadingArticle: String { localized("Loading article…", "正在载入文章…") }
    var loadFailed: String { localized("Help Content Could Not Be Loaded", "无法载入帮助内容") }
    var tryAgain: String { localized("Try Again", "重试") }
    var noSelection: String { localized("Choose a Help Topic", "选择一个帮助主题") }
    var noSelectionDetail: String {
        localized("Select an article from the list to read it offline.", "从列表中选择文章以离线阅读。")
    }
    var noResults: String { localized("No Matching Topics", "没有匹配的主题") }
    var noResultsDetail: String {
        localized("Try a different title, keyword, or phrase.", "尝试其他标题、关键词或短语。")
    }
    var relatedTopics: String { localized("Related Topics", "相关主题") }
    var topics: String { localized("Topics", "主题") }
    var category: String { localized("Category", "分类") }
    var allCategories: String { localized("All Categories", "所有分类") }
    var availableOffline: String { localized("Available offline", "可离线使用") }
    var offlineHelpAvailable: String { localized("Offline help available", "离线帮助可用") }
    var supportTools: String { localized("Support Tools", "支持工具") }
    var guidedSupport: String { localized("Start Guided Support", "开始引导式支持") }
    var exportSupportBundle: String { localized("Export Support Bundle", "导出支持包") }
    var copyVersionInformation: String { localized("Copy Version Information", "复制版本信息") }
    var supportPolicy: String { localized("Support Policy", "支持政策") }
    var reportSecurityIssue: String { localized("Report a Security Issue", "报告安全问题") }
    var clearSearch: String { localized("Clear Search", "清除搜索") }
    var emptyCatalog: String { localized("Help Content Is Unavailable", "帮助内容不可用") }
    var emptyCatalogDetail: String {
        localized("No verified bundled topics were found.", "未找到已验证的内置帮助主题。")
    }
    var indexUnavailable: String { localized("Index unavailable", "索引不可用") }
    var lastGoodContent: String {
        localized("Last verified content remains readable.", "上次验证的内容仍可阅读。")
    }
    var back: String { localized("Back", "后退") }
    var forward: String { localized("Forward", "前进") }
    var fallbackNotice: String {
        localized(
            "This article is shown in English because the requested Help locale is unavailable.",
            "请求的帮助语言不可用，当前显示英文内容。"
        )
    }

    func topicCount(_ count: Int) -> String {
        localized("\(count) topics · Available offline", "\(count) 个主题 · 可离线使用")
    }

    func resultCount(_ count: Int) -> String {
        localized("\(count) results", "\(count) 个结果")
    }

    func noResultsDetail(query: String) -> String {
        localized(
            "No topics match “\(query)”. Try another term or category.",
            "没有与“\(query)”匹配的主题。请尝试其他关键词或分类。"
        )
    }

    func categoryTitle(_ id: HelpCategoryID) -> String {
        switch id.rawValue {
        case "getting-started": localized("Getting Started", "开始使用")
        case "networking": localized("Networking", "网络")
        case "configuration": localized("Configuration", "配置")
        case "automation": localized("Automation", "自动化")
        case "maintenance": localized("Maintenance", "维护")
        case "troubleshooting": localized("Troubleshooting", "故障排查")
        case "reference": localized("Reference", "参考")
        default: id.rawValue.replacingOccurrences(of: "-", with: " ").capitalized
        }
    }

    func categorySystemImage(_ id: HelpCategoryID) -> String {
        switch id.rawValue {
        case "getting-started": "sparkles"
        case "networking": "network"
        case "configuration": "doc.text"
        case "automation": "bolt"
        case "maintenance": "wrench.and.screwdriver"
        case "troubleshooting": "stethoscope"
        default: "book.closed"
        }
    }

    private func localized(_ english: String, _ simplifiedChinese: String) -> String {
        locale == .simplifiedChinese ? simplifiedChinese : english
    }
}
