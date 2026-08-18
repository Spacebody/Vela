import Foundation
import Testing

@Suite("Connections and Rules localization")
struct ConnectionsRulesLocalizationTests {
    @Test("Production Connections and Rules views have no raw English UI sinks")
    func productionViewsHaveNoRawEnglishUISinks() throws {
        let rawSinkPatterns = [
            #"\b(?:title|subtitle|description|label|statusLabel|secondaryText|detail|help|placeholder)\s*:\s*\"[A-Za-z]"#,
            #"\b(?:Text|Button|Label|ProgressView)\(\s*\"[A-Za-z]"#,
            #"\breturn\s+\"[A-Za-z]"#,
            #"\bcase\s+\.[A-Za-z0-9_]+\s*:\s*\"[A-Za-z]"#,
        ]

        for relativePath in [
            "Vela/Features/Connections/ConnectionsView.swift",
            "Vela/Features/Rules/RulesView.swift",
        ] {
            var source = try String(
                contentsOf: Self.repositoryRoot.appending(path: relativePath),
                encoding: .utf8
            )
            // `label` is an intentionally language-independent test oracle;
            // production UI renders the adjacent localizedLabel property.
            if relativePath.hasSuffix("ConnectionsView.swift"),
               let start = source.range(of: "    var label: String {"),
               let end = source.range(
                   of: "    var localizedLabel: String {",
                   range: start.upperBound..<source.endIndex
               )
            {
                source.removeSubrange(start.lowerBound..<end.lowerBound)
            }
            for pattern in rawSinkPatterns {
                let regex = try NSRegularExpression(pattern: pattern)
                #expect(
                    regex.firstMatch(
                        in: source,
                        range: NSRange(source.startIndex..., in: source)
                    ) == nil,
                    "Raw English UI copy remains in \(relativePath): \(pattern)"
                )
            }
        }
    }

    @Test("Connections and Rules semantic copy has explicit Simplified Chinese translations")
    func semanticCopyHasSimplifiedChineseTranslations() throws {
        let data = try Data(
            contentsOf: Self.repositoryRoot.appending(
                path: "Vela/Resources/Localization/Localizable.xcstrings"
            )
        )
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(root["strings"] as? [String: Any])
        let expected = [
            "connections.empty.offline.title": "Controller 已断开",
            "connections.error.title": "连接不可用",
            "connections.inspector.empty.title": "连接检查器",
            "connections.inspector.route.title": "为何使用此路由？",
            "connections.status.paused": "已暂停",
            "rules.empty.configuration.title": "没有运行时规则",
            "rules.error.title": "规则不可用",
            "rules.filter.source.all": "全部来源",
            "rules.inspector.empty.title": "规则详情",
            "rules.inspector.matches.title": "匹配证据",
            "rules.inspector.provenance.title": "来源与溯源",
            "rules.phase.partialFailure.title": "最后确认的规则",
            "rules.phase.temporaryMutation.title": "正在应用临时规则更改",
            "rules.confidence.exact": "精确来源",
            "rules.source.provider": "供应商",
            "rules.value.unavailable": "不可用",
        ]

        for (key, expectedValue) in expected {
            let record = try #require(strings[key] as? [String: Any])
            let localizations = try #require(record["localizations"] as? [String: Any])
            let chinese = try #require(localizations["zh-Hans"] as? [String: Any])
            let unit = try #require(chinese["stringUnit"] as? [String: Any])
            #expect(unit["value"] as? String == expectedValue, "Unexpected zh-Hans copy for \(key)")
        }
    }

    @Test("Rules filters use semantic copy while opaque runtime values remain verbatim")
    func dynamicRuleLabelsUseSemanticLocalizationKeys() throws {
        let source = try String(
            contentsOf: Self.repositoryRoot.appending(
                path: "Vela/Features/Rules/RulesView.swift"
            ),
            encoding: .utf8
        )

        for key in [
            "rules.filter.source.all",
            "rules.filter.source.help",
            "rules.filter.source.unavailable",
            "rules.filter.source.unavailable.help",
            "rules.count.filteredFormat",
        ] {
            #expect(source.contains("\"\(key)\""), "Missing dynamic Rules localization key: \(key)")
        }

        #expect(source.contains("Text(verbatim: value).tag(Optional(value))"))
        #expect(!source.contains("rules.sort.field."))
        #expect(!source.contains("rules.filter.state."))
    }

    private static var repositoryRoot: URL {
        if let staged = ProcessInfo.processInfo.environment["VELA_TEST_REPOSITORY_ROOT"],
           !staged.isEmpty
        {
            return URL(fileURLWithPath: staged, isDirectory: true)
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
