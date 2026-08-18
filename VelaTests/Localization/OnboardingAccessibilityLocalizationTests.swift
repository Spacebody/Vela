import Foundation
import Testing

@Suite("Onboarding localization and Settings motion accessibility")
struct OnboardingAccessibilityLocalizationTests {
    @Test("Onboarding informational cards use semantic localization keys")
    func onboardingCardsUseSemanticLocalizationKeys() throws {
        let source = try String(
            contentsOf: Self.repositoryRoot.appending(
                path: "Vela/Features/Onboarding/OnboardingFlowView.swift"
            ),
            encoding: .utf8
        )

        let expectedKeys = [
            "onboarding.welcome.control.title",
            "onboarding.welcome.control.detail",
            "onboarding.welcome.resume.title",
            "onboarding.welcome.resume.detail",
            "onboarding.privacy.local.title",
            "onboarding.privacy.local.detail",
            "onboarding.privacy.permission.title",
            "onboarding.privacy.permission.detail",
            "legacy.systemProxy",
            "onboarding.network.systemProxy.detail",
            "legacy.tunMode",
            "onboarding.network.tun.detail",
        ]

        for key in expectedKeys {
            #expect(source.contains("\"\(key)\""), "Missing onboarding localization key: \(key)")
        }
    }

    @Test("Onboarding informational copy has explicit Simplified Chinese translations")
    func onboardingCopyHasSimplifiedChineseTranslations() throws {
        let data = try Data(
            contentsOf: Self.repositoryRoot.appending(
                path: "Vela/Resources/Localization/Localizable.xcstrings"
            )
        )
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(root["strings"] as? [String: Any])
        let expected = [
            "onboarding.welcome.control.title": "一切由你掌控",
            "onboarding.welcome.resume.title": "可随时暂停",
            "onboarding.privacy.local.title": "进度仅保存在本地",
            "onboarding.privacy.permission.title": "权限请求会先说明原因",
            "legacy.systemProxy": "系统代理",
            "legacy.tunMode": "TUN 模式",
        ]

        for (key, expectedValue) in expected {
            let record = try #require(strings[key] as? [String: Any])
            let localizations = try #require(record["localizations"] as? [String: Any])
            let chinese = try #require(localizations["zh-Hans"] as? [String: Any])
            let unit = try #require(chinese["stringUnit"] as? [String: Any])
            #expect(unit["value"] as? String == expectedValue, "Unexpected zh-Hans copy for \(key)")
        }
    }

    @Test("Settings navigation and disclosure animations respect Reduce Motion")
    func settingsAnimationsRespectReduceMotion() throws {
        let source = try String(
            contentsOf: Self.repositoryRoot.appending(
                path: "Vela/Features/Settings/SettingsLiquidGlassView.swift"
            ),
            encoding: .utf8
        )

        #expect(source.contains("@Environment(\\.accessibilityReduceMotion) private var reduceMotion"))
        #expect(
            source.components(separatedBy: "reduceMotion: reduceMotion").count - 1 >= 2,
            "Both Settings animations must use the Reduce Motion environment value"
        )
        #expect(!source.contains("withAnimation(.easeInOut"))
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
