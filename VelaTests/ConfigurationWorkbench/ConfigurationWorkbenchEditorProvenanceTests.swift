import Foundation
import Testing
@testable import Vela

@Suite("Configuration Workbench editor and provenance")
struct ConfigurationWorkbenchEditorProvenanceTests {
    @Test("Toolbar distinguishes empty catalog from an existing unselected catalog")
    func catalogStatesAreTruthful() {
        let empty = toolbarPresentation(
            profiles: [],
            selectedProfileID: nil,
            hasChanges: false,
            preview: nil
        )
        let available = [profile(name: "Main")]
        let noSelection = toolbarPresentation(
            profiles: available,
            selectedProfileID: nil,
            hasChanges: false,
            preview: nil
        )

        #expect(empty.catalogState == .emptyCatalog)
        #expect(empty.validationState == nil)
        #expect(!empty.showsDraftActions)
        #expect(
            noSelection.catalogState == .noSelection(options: [
                .init(id: available[0].id, name: "Main"),
            ])
        )
        #expect(noSelection.validationState == nil)
        #expect(!noSelection.showsDraftActions)
    }

    @Test("Selected clean and dirty configurations expose only applicable actions")
    func selectedToolbarCapabilitiesFollowDraftState() {
        let main = profile(name: "Main")
        let clean = toolbarPresentation(
            profiles: [main],
            selectedProfileID: main.id,
            hasChanges: false,
            preview: validPreview
        )
        let dirty = toolbarPresentation(
            profiles: [main],
            selectedProfileID: main.id,
            hasChanges: true,
            preview: validPreview
        )

        #expect(clean.validationState == .validated)
        #expect(!clean.showsDraftActions)
        #expect(dirty.validationState == .validated)
        #expect(dirty.showsDraftActions)
        guard case let .selected(selected, options) = dirty.catalogState else {
            Issue.record("Expected a selected configuration")
            return
        }
        #expect(selected.name == "Main")
        #expect(options.map(\.name) == ["Main"])
    }

    @Test("Validation toolbar reports validating and invalid drafts independently")
    func validationToolbarStates() {
        let main = profile(name: "Main")
        let validating = toolbarPresentation(
            profiles: [main],
            selectedProfileID: main.id,
            hasChanges: true,
            isLoading: true,
            preview: nil
        )
        let invalid = toolbarPresentation(
            profiles: [main],
            selectedProfileID: main.id,
            hasChanges: true,
            preview: invalidPreview
        )

        #expect(validating.validationState == .validating)
        #expect(validating.showsDraftActions)
        #expect(invalid.validationState == .issues(1))
        #expect(invalid.showsDraftActions)
    }

    @Test("Minimum width uses overflow without changing long profile names")
    func minimumWidthAndLongLocalizedNames() {
        let longName = "Main Configuration — 主要日常运行配置文件（双倍长度）"
        let main = profile(name: longName)
        let compact = toolbarPresentation(
            profiles: [main],
            selectedProfileID: main.id,
            hasChanges: true,
            preview: validPreview,
            contentWidth: 719
        )
        let regular = toolbarPresentation(
            profiles: [main],
            selectedProfileID: main.id,
            hasChanges: true,
            preview: validPreview,
            contentWidth: 959
        )

        #expect(compact.usesCompactOverflow)
        #expect(!regular.usesCompactOverflow)
        guard case let .selected(selected, _) = compact.catalogState else {
            Issue.record("Expected a selected configuration")
            return
        }
        #expect(selected.name == longName)
    }

    @Test("No profile clears stale selection and gates transactions")
    func noProfileClearsSelectionAndGatesTransactions() {
        let status = ConfigurationWorkbenchPresentationPolicy.status(
            hasProfile: false,
            hasChanges: true,
            isLoading: false,
            isSaving: false,
            preview: validPreview,
            errorMessage: nil
        )

        #expect(status.kind == .noProfile)
        #expect(!status.allowsApply)
        #expect(!status.allowsValidate)
        #expect(!status.allowsRevert)
        #expect(
            ConfigurationWorkbenchPresentationPolicy.reconciledSelection(
                .operation(path: "/mode"),
                hasProfile: false,
                preview: validPreview
            ) == nil
        )
    }

    @Test("Apply is enabled only for a validated current draft")
    func applyGateTracksValidatedDraft() {
        let clean = ConfigurationWorkbenchPresentationPolicy.status(
            hasProfile: true,
            hasChanges: false,
            isLoading: false,
            isSaving: false,
            preview: validPreview,
            errorMessage: nil
        )
        let ready = ConfigurationWorkbenchPresentationPolicy.status(
            hasProfile: true,
            hasChanges: true,
            isLoading: false,
            isSaving: false,
            preview: validPreview,
            errorMessage: nil
        )
        let staleCompile = ConfigurationWorkbenchPresentationPolicy.status(
            hasProfile: true,
            hasChanges: true,
            isLoading: false,
            isSaving: false,
            preview: nil,
            errorMessage: nil
        )
        let invalid = ConfigurationWorkbenchPresentationPolicy.status(
            hasProfile: true,
            hasChanges: true,
            isLoading: false,
            isSaving: false,
            preview: invalidPreview,
            errorMessage: nil
        )

        #expect(clean.kind == .clean && !clean.allowsApply)
        #expect(ready.kind == .readyToApply && ready.allowsApply)
        #expect(staleCompile.kind == .compiling && !staleCompile.allowsApply)
        #expect(invalid.kind == .invalid && !invalid.allowsApply)
    }

    @Test("Selection follows the current preview instead of stale path identity")
    func selectionReconciliationUsesCurrentPreview() {
        #expect(
            ConfigurationWorkbenchPresentationPolicy.reconciledSelection(
                .operation(path: "/mode"),
                hasProfile: true,
                preview: validPreview
            ) == .operation(path: "/mode")
        )
        #expect(
            ConfigurationWorkbenchPresentationPolicy.reconciledSelection(
                .operation(path: "/removed/from/new/generation"),
                hasProfile: true,
                preview: validPreview
            ) == .layer(.profileOverrides)
        )
        #expect(
            ConfigurationWorkbenchPresentationPolicy.reconciledSelection(
                .diagnostic(index: 99),
                hasProfile: true,
                preview: invalidPreview
            ) == .layer(.profileOverrides)
        )
    }

    @Test("Opaque profile and path values remain verbatim")
    func opaqueValuesRemainVerbatim() {
        let path = "/profiles/Daily Driver/Office/%E5%AE%B6"
        let preview = ConfigurationPreview(
            rawYAML: "mode: global",
            finalYAML: "mode: rule",
            semanticDiff: [
                .init(path: path, operation: .change, source: .velaOverride, before: .string("Office"), after: .string("Main")),
            ],
            validation: .init()
        )

        #expect(ConfigurationWorkbenchPresentationPolicy.matchingDiff(in: preview, search: "Daily Driver").first?.path == path)
        #expect(ConfigurationWorkbenchPresentationPolicy.matchingDiff(in: preview, search: "%E5%AE%B6").first?.path == path)
    }

    @Test("Rule projection preserves 50,000-entry runtime order", .timeLimit(.minutes(1)))
    func fiftyThousandRuleProjection() {
        let rules = (0 ..< 50_000).map { "  - DOMAIN-SUFFIX,host\($0).example,DIRECT" }
        let yaml = (["rules:"] + rules).joined(separator: "\n")
        let projected = ConfigurationWorkbenchPresentationPolicy.rules(from: yaml, segment: .effective)

        #expect(projected.count == 50_000)
        #expect(projected.first?.index == 0)
        #expect(projected.last?.index == 49_999)
        #expect(projected.last?.value.contains("host49999.example") == true)
    }

    @Test("Twenty MiB preview remains searchable without changing source bytes", .timeLimit(.minutes(1)))
    func twentyMiBPreviewResourceContract() {
        let block = "# deterministic payload\nmode: rule\n"
        let repeats = (20 * 1_024 * 1_024) / block.utf8.count + 1
        let raw = String(repeating: block, count: repeats)
        let preview = ConfigurationPreview(
            rawYAML: raw,
            finalYAML: raw,
            semanticDiff: [
                .init(path: "/mode", operation: .change, source: .velaOverride, before: .string("global"), after: .string("rule")),
            ],
            validation: .init()
        )

        #expect(preview.rawYAML.utf8.count >= 20 * 1_024 * 1_024)
        #expect(ConfigurationWorkbenchPresentationPolicy.matchingDiff(in: preview, search: "/mode").count == 1)
        #expect(preview.rawYAML == preview.finalYAML)
    }

    @Test("Repeated search and inspector reconciliation remain deterministic")
    func repeatedPresentationOperations() {
        for iteration in 0 ..< 500 {
            let query = iteration.isMultiple(of: 2) ? "mode" : "missing"
            let expectedCount = iteration.isMultiple(of: 2) ? 1 : 0
            #expect(ConfigurationWorkbenchPresentationPolicy.matchingDiff(in: validPreview, search: query).count == expectedCount)
        }
        for _ in 0 ..< 50 {
            #expect(
                ConfigurationWorkbenchPresentationPolicy.reconciledSelection(
                    .operation(path: "/mode"),
                    hasProfile: true,
                    preview: validPreview
                ) == .operation(path: "/mode")
            )
        }
    }

    @Test("Workbench defers YAML analysis and reuses the completed snapshot")
    func deferredYAMLAnalysisIsReusable() async {
        let main = profile(name: "Main")
        let yaml = """
        mode: rule
        proxies:
          - name: Edge
            type: direct
        proxy-groups:
          - name: Automatic
            type: select
        rule-providers:
          local:
            type: file
            path: ./rules.yaml
        rules:
          - MATCH,DIRECT
        """
        let preview = ConfigurationPreview(
            rawYAML: yaml,
            finalYAML: yaml,
            semanticDiff: [],
            validation: .init()
        )
        let status = ConfigurationWorkbenchStatus(
            kind: .clean,
            changeCount: 0,
            issueCount: 0
        )

        let immediate = ConfigurationWorkbenchSnapshot.resolve(
            profiles: [main],
            selectedProfileID: main.id,
            preview: preview,
            status: status,
            isLoading: false,
            errorMessage: nil,
            hasChanges: false,
            canApply: false
        )

        #expect(immediate.currentDocument?.yaml == yaml)
        #expect(immediate.structureTree.isEmpty)
        #expect(immediate.overview.mode == "—")

        let cache = ConfigurationWorkbenchYAMLAnalysisCache(capacity: 2)
        let analysis = await cache.analysis(for: yaml)
        #expect(cache.cachedAnalysis(for: yaml) == analysis)

        let enriched = ConfigurationWorkbenchSnapshot.resolve(
            profiles: [main],
            selectedProfileID: main.id,
            preview: preview,
            status: status,
            isLoading: false,
            errorMessage: nil,
            hasChanges: false,
            canApply: false,
            yamlAnalysis: analysis
        )

        #expect(enriched.overview.mode == "rule")
        #expect(enriched.overview.proxies == 1)
        #expect(enriched.overview.proxyGroups == 1)
        #expect(enriched.overview.ruleProviders == 1)
        #expect(enriched.overview.rules == 1)
        #expect(enriched.structureTree.contains { $0.path == "/proxies/0/name" })
    }

    @Test("Concurrent YAML analysis requests share one in-flight computation")
    func concurrentYAMLAnalysisIsCoalesced() async {
        let yaml = """
        mode: rule
        rules:
          - MATCH,DIRECT
        """
        let counter = YAMLAnalysisInvocationCounter()
        let cache = ConfigurationWorkbenchYAMLAnalysisCache(capacity: 2) { source in
            await counter.analyze(source)
        }

        async let first = cache.analysis(for: yaml)
        async let second = cache.analysis(for: yaml)
        async let third = cache.analysis(for: yaml)
        let (firstAnalysis, secondAnalysis, thirdAnalysis) = await (first, second, third)
        let analyses = [firstAnalysis, secondAnalysis, thirdAnalysis]
        let invocationCount = await counter.invocationCount()

        #expect(analyses.allSatisfy { $0 == analyses.first })
        #expect(invocationCount == 1)
        #expect(cache.cachedAnalysis(for: yaml) == analyses.first)
    }

    @Test("Remote subscription summary preserves quota and schedule metadata")
    func remoteSubscriptionMetadataIsProjected() throws {
        let update = Date(timeIntervalSince1970: 1_800_000_000)
        let expiry = update.addingTimeInterval(86_400)
        var remote = RemoteProfileMetadata(redactedURL: "https://example.com/profile")
        remote.lastSuccessfulUpdateAt = update
        remote.nextScheduledUpdateAt = update.addingTimeInterval(3_600)
        remote.usage = SubscriptionUsage(
            upload: 3,
            download: 7,
            total: 100,
            expireUnixSeconds: Int64(expiry.timeIntervalSince1970)
        )
        let profile = Profile(
            id: UUID(),
            name: "Remote",
            originalFileName: "remote.yaml",
            createdAt: update.addingTimeInterval(-100),
            updatedAt: update.addingTimeInterval(-50),
            sourceKind: .remoteSubscription,
            revisions: [],
            remote: remote
        )
        let status = ConfigurationWorkbenchStatus(kind: .clean, changeCount: 0, issueCount: 0)

        let snapshot = ConfigurationWorkbenchSnapshot.resolve(
            profiles: [profile],
            selectedProfileID: profile.id,
            preview: nil,
            status: status,
            isLoading: false,
            errorMessage: nil,
            hasChanges: false,
            canApply: false
        )
        let summary = try #require(snapshot.files.first?.subscription)

        #expect(summary.uploadBytes == 3)
        #expect(summary.downloadBytes == 7)
        #expect(summary.usedBytes == 10)
        #expect(summary.totalBytes == 100)
        #expect(summary.usedFraction == 0.1)
        #expect(summary.expiresAt == expiry)
        #expect(summary.lastSuccessfulUpdateAt == update)
    }

    @Test("Subscription quota projection clamps overflow and percentages")
    func subscriptionQuotaProjectionIsBounded() {
        let overflow = ConfigurationWorkbenchSnapshot.SubscriptionSummary(
            uploadBytes: Int64.max,
            downloadBytes: 1,
            totalBytes: 100
        )
        let overQuota = ConfigurationWorkbenchSnapshot.SubscriptionSummary(
            downloadBytes: 120,
            totalBytes: 100
        )

        #expect(overflow.usedBytes == Int64.max)
        #expect(overflow.usedFraction == 1)
        #expect(overQuota.usedFraction == 1)
    }

    private var validPreview: ConfigurationPreview {
        ConfigurationPreview(
            rawYAML: """
            mode: global
            rules:
              - DOMAIN-SUFFIX,example.com,DIRECT
              - MATCH,Select
            """,
            finalYAML: """
            mode: rule
            rules:
              - DOMAIN-SUFFIX,example.com,DIRECT
              - MATCH,Select
            """,
            semanticDiff: [
                .init(path: "/mode", operation: .change, source: .velaOverride, before: .string("global"), after: .string("rule")),
            ],
            validation: .init()
        )
    }

    private var invalidPreview: ConfigurationPreview {
        ConfigurationPreview(
            rawYAML: "mode: global",
            finalYAML: "mode: global",
            semanticDiff: [],
            validation: .init(issues: [
                .init(
                    severity: .error,
                    code: .invalidEnhancedMode,
                    path: "dns.enhanced-mode",
                    message: "Invalid enhanced mode."
                ),
            ])
        )
    }

    private func toolbarPresentation(
        profiles: [Profile],
        selectedProfileID: UUID?,
        hasChanges: Bool,
        isLoading: Bool = false,
        preview: ConfigurationPreview?,
        contentWidth: CGFloat = 959
    ) -> ConfigurationWorkbenchToolbarPresentation {
        ConfigurationWorkbenchToolbarPresentation.resolve(
            profiles: profiles,
            selectedProfileID: selectedProfileID,
            hasChanges: hasChanges,
            isLoading: isLoading,
            preview: preview,
            errorMessage: nil,
            contentWidth: contentWidth
        )
    }

    private func profile(name: String) -> Profile {
        Profile(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!,
            name: name,
            originalFileName: "main.yaml",
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0)
        )
    }
}

private actor YAMLAnalysisInvocationCounter {
    private var count = 0

    func analyze(
        _ yaml: String
    ) async -> ConfigurationWorkbenchSnapshot.YAMLAnalysis {
        count += 1
        try? await Task.sleep(for: .milliseconds(40))
        return ConfigurationWorkbenchSnapshot.analyze(yaml: yaml)
    }

    func invocationCount() -> Int {
        count
    }
}
