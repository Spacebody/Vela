import Foundation
import Testing
@testable import Vela

@Suite("Configuration and Diagnostics localization boundaries")
struct ConfigurationDiagnosticsLocalizationTests {
    @Test("Configuration validation snapshots keep dynamic detail without fixed UI copy")
    func validationSnapshotsKeepOnlyDynamicDetail() {
        let profile = Profile(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000021")!,
            name: "Main",
            originalFileName: "main.yaml",
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0)
        )
        let loadingStatus = ConfigurationWorkbenchStatus(
            kind: .loading,
            changeCount: 0,
            issueCount: 0
        )
        let loading = ConfigurationWorkbenchSnapshot.resolve(
            profiles: [profile],
            selectedProfileID: profile.id,
            preview: nil,
            status: loadingStatus,
            isLoading: true,
            errorMessage: nil,
            hasChanges: false,
            canApply: false
        )

        #expect(loading.validation.kind == .validating)
        #expect(loading.validation.detail == nil)

        let issueMessage = "Invalid enhanced mode."
        let preview = ConfigurationPreview(
            rawYAML: "mode: rule",
            finalYAML: "mode: rule",
            semanticDiff: [],
            validation: .init(issues: [
                .init(
                    severity: .error,
                    code: .invalidEnhancedMode,
                    path: "dns.enhanced-mode",
                    message: issueMessage
                ),
            ])
        )
        let invalid = ConfigurationWorkbenchSnapshot.resolve(
            profiles: [profile],
            selectedProfileID: profile.id,
            preview: preview,
            status: .init(kind: .invalid, changeCount: 0, issueCount: 1),
            isLoading: false,
            errorMessage: nil,
            hasChanges: false,
            canApply: false
        )

        #expect(invalid.validation.kind == .invalid(1))
        #expect(invalid.validation.detail == issueMessage)
    }

    @Test("Diagnostics progress summary formats localized dynamic values")
    func diagnosticsProgressFormatsLocalizedDynamicValues() {
        let summary = DiagnosticsRunProgressPresentation.summary(
            format: "运行 %1$@ · %2$lld / %3$lld · %4$@ · %5$@",
            locale: Locale(identifier: "zh-Hans"),
            runID: "A1B2C3D4",
            completedStepCount: 2,
            totalStepCount: 5,
            duration: "3 秒",
            currentStep: "检查内核"
        )

        #expect(summary == "运行 A1B2C3D4 · 2 / 5 · 3 秒 · 检查内核")
    }

    @Test("Diagnostics progress format has explicit English and Simplified Chinese values")
    func diagnosticsProgressFormatHasRequiredLocalizations() throws {
        let data = try Data(
            contentsOf: Self.repositoryRoot.appending(
                path: "Vela/Resources/Localization/Localizable.xcstrings"
            )
        )
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(root["strings"] as? [String: Any])
        let record = try #require(
            strings["diagnostics.workspace.run.progressFormat"] as? [String: Any]
        )
        let localizations = try #require(record["localizations"] as? [String: Any])

        #expect(Self.value(in: localizations, locale: "en") == "Run %1$@ · %2$lld / %3$lld · %4$@ · %5$@")
        #expect(Self.value(in: localizations, locale: "zh-Hans") == "运行 %1$@ · %2$lld / %3$lld · %4$@ · %5$@")
    }

    private static func value(
        in localizations: [String: Any],
        locale: String
    ) -> String? {
        guard let localization = localizations[locale] as? [String: Any],
              let unit = localization["stringUnit"] as? [String: Any]
        else { return nil }
        return unit["value"] as? String
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
