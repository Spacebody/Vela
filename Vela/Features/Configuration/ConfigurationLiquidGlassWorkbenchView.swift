import AppKit
import SwiftUI

nonisolated struct ConfigurationWorkbenchSnapshot: Equatable, Sendable {
    struct FileItem: Identifiable, Equatable, Sendable {
        let id: UUID
        let name: String
        let fileName: String
        let modifiedDescription: String
        let subscription: SubscriptionSummary?
        let isActive: Bool
    }

    struct SubscriptionSummary: Equatable, Sendable {
        let uploadBytes: Int64?
        let downloadBytes: Int64?
        let totalBytes: Int64?
        let expiresAt: Date?
        let lastCheckedAt: Date?
        let lastSuccessfulUpdateAt: Date?
        let nextScheduledUpdateAt: Date?
        let lastFailureMessage: String?

        init(metadata: RemoteProfileMetadata) {
            uploadBytes = metadata.usage?.upload
            downloadBytes = metadata.usage?.download
            totalBytes = metadata.usage?.total
            expiresAt = metadata.usage?.expireUnixSeconds.map {
                Date(timeIntervalSince1970: TimeInterval($0))
            }
            lastCheckedAt = metadata.lastCheckedAt
            lastSuccessfulUpdateAt = metadata.lastSuccessfulUpdateAt
            nextScheduledUpdateAt = metadata.nextScheduledUpdateAt
            lastFailureMessage = metadata.lastFailure?.message
        }

        init(
            uploadBytes: Int64? = nil,
            downloadBytes: Int64? = nil,
            totalBytes: Int64? = nil,
            expiresAt: Date? = nil,
            lastCheckedAt: Date? = nil,
            lastSuccessfulUpdateAt: Date? = nil,
            nextScheduledUpdateAt: Date? = nil,
            lastFailureMessage: String? = nil
        ) {
            self.uploadBytes = uploadBytes
            self.downloadBytes = downloadBytes
            self.totalBytes = totalBytes
            self.expiresAt = expiresAt
            self.lastCheckedAt = lastCheckedAt
            self.lastSuccessfulUpdateAt = lastSuccessfulUpdateAt
            self.nextScheduledUpdateAt = nextScheduledUpdateAt
            self.lastFailureMessage = lastFailureMessage
        }

        var usedBytes: Int64? {
            guard uploadBytes != nil || downloadBytes != nil else { return nil }
            let (sum, overflow) = (uploadBytes ?? 0).addingReportingOverflow(downloadBytes ?? 0)
            return overflow ? Int64.max : sum
        }

        var usedFraction: Double? {
            guard let usedBytes, let totalBytes, totalBytes > 0 else { return nil }
            return min(max(Double(usedBytes) / Double(totalBytes), 0), 1)
        }
    }

    struct Document: Equatable, Sendable {
        let fileName: String
        let yaml: String
        let language: String
        let line: Int
        let column: Int
    }

    enum ValidationKind: Equatable, Sendable {
        case valid
        case validating
        case warning(Int)
        case invalid(Int)
        case unavailable
    }

    struct Validation: Equatable, Sendable {
        let kind: ValidationKind
        let detail: String?
    }

    struct StructureItem: Identifiable, Equatable, Sendable {
        let id: String
        let path: String
        let label: String
        let parentID: String?
        let depth: Int
        let value: String?
        let isCollection: Bool
        let childCount: Int
    }

    struct HistoryItem: Identifiable, Equatable, Sendable {
        let id: String
        let event: String
        let fileName: String
        let time: String
        let author: String
    }

    struct Overview: Equatable, Sendable {
        let mode: String
        let proxies: Int
        let proxyGroups: Int
        let ruleProviders: Int
        let rules: Int
        let lastUpdated: String
    }

    struct YAMLAnalysis: Equatable, Sendable {
        let sourceYAML: String
        let structureTree: [StructureItem]
        let mode: String
        let proxies: Int
        let proxyGroups: Int
        let ruleProviders: Int
        let rules: Int
    }

    let activeProfileID: UUID?
    let activeProfileName: String?
    let files: [FileItem]
    let currentDocument: Document?
    let validation: Validation
    let structureTree: [StructureItem]
    let history: [HistoryItem]
    let overview: Overview
    let status: ConfigurationWorkbenchStatus
    let isLoading: Bool
    let errorMessage: String?
    let hasChanges: Bool
    let canApply: Bool
    let mutationAllowed: Bool

    static func resolve(
        profiles: [Profile],
        selectedProfileID: UUID?,
        preview: ConfigurationPreview?,
        status: ConfigurationWorkbenchStatus,
        isLoading: Bool,
        errorMessage: String?,
        hasChanges: Bool,
        canApply: Bool,
        yamlAnalysis: YAMLAnalysis? = nil
    ) -> Self {
        let selectedProfile = profiles.first { $0.id == selectedProfileID }
        let fileItems = profiles.map { profile in
            FileItem(
                id: profile.id,
                name: profile.name,
                fileName: profile.originalFileName.isEmpty
                    ? profile.configurationFileName
                    : profile.originalFileName,
                modifiedDescription: (profile.remote?.lastSuccessfulUpdateAt ?? profile.updatedAt).formatted(
                    date: .abbreviated,
                    time: .shortened
                ),
                subscription: profile.remote.map(SubscriptionSummary.init(metadata:)),
                isActive: profile.id == selectedProfileID
            )
        }
        let yaml = preview?.finalYAML ?? preview?.rawYAML
        return make(
            activeProfileID: selectedProfileID,
            activeProfileName: selectedProfile?.name,
            files: fileItems,
            fileName: selectedProfile.map {
                $0.originalFileName.isEmpty ? $0.configurationFileName : $0.originalFileName
            },
            yaml: yaml,
            preview: preview,
            history: revisionHistory(from: selectedProfile?.revisions ?? []),
            lastUpdated: selectedProfile?.updatedAt.formatted(
                date: .abbreviated,
                time: .shortened
            ) ?? "—",
            status: status,
            isLoading: isLoading,
            errorMessage: errorMessage,
            hasChanges: hasChanges,
            canApply: canApply,
            mutationAllowed: !isLoading,
            yamlAnalysis: yamlAnalysis
        )
    }

    static func fixture(
        activeProfileName: String?,
        profileOptions: [ConfigurationWorkbenchProfileOption],
        preview: ConfigurationPreview?,
        status: ConfigurationWorkbenchStatus,
        isLoading: Bool,
        errorMessage: String?,
        mutationAllowed: Bool
    ) -> Self {
        let activeID = profileOptions.first { $0.name == activeProfileName }?.id
        let fileItems = profileOptions.map { option in
            FileItem(
                id: option.id,
                name: option.name,
                fileName: yamlFileName(for: option.name),
                modifiedDescription: option.id == activeID
                    ? "Modified 2 min ago"
                    : "Modified 1 hour ago",
                subscription: nil,
                isActive: option.id == activeID
            )
        }
        let yaml = preview?.finalYAML ?? preview?.rawYAML
        return make(
            activeProfileID: activeID,
            activeProfileName: activeProfileName,
            files: fileItems,
            fileName: activeProfileName.map(yamlFileName(for:)),
            yaml: yaml,
            preview: preview,
            history: draftChangeItems(
                from: preview,
                fileName: activeProfileName.map(yamlFileName(for:)) ?? "config.yaml"
            ),
            lastUpdated: preview == nil ? "—" : "2 min ago",
            status: status,
            isLoading: isLoading,
            errorMessage: errorMessage,
            hasChanges: status.changeCount > 0,
            canApply: status.allowsApply && mutationAllowed,
            mutationAllowed: mutationAllowed,
            yamlAnalysis: yaml.map(analyze(yaml:))
        )
    }

    static func analyze(yaml: String) -> YAMLAnalysis {
        let yamlDocument = try? YAMLDocument(yaml: yaml)
        return YAMLAnalysis(
            sourceYAML: yaml,
            structureTree: structureItems(from: yamlDocument),
            mode: scalarValue(for: "mode", in: yamlDocument) ?? "—",
            proxies: collectionCount(for: "proxies", in: yamlDocument),
            proxyGroups: collectionCount(for: "proxy-groups", in: yamlDocument),
            ruleProviders: collectionCount(for: "rule-providers", in: yamlDocument),
            rules: collectionCount(for: "rules", in: yamlDocument)
        )
    }

    private static func make(
        activeProfileID: UUID?,
        activeProfileName: String?,
        files: [FileItem],
        fileName: String?,
        yaml: String?,
        preview: ConfigurationPreview?,
        history: [HistoryItem],
        lastUpdated: String,
        status: ConfigurationWorkbenchStatus,
        isLoading: Bool,
        errorMessage: String?,
        hasChanges: Bool,
        canApply: Bool,
        mutationAllowed: Bool,
        yamlAnalysis: YAMLAnalysis?
    ) -> Self {
        let validation: Validation
        if isLoading || status.kind == .compiling || status.kind == .loading {
            validation = Validation(
                kind: .validating,
                detail: nil
            )
        } else if let errorMessage {
            validation = Validation(
                kind: .invalid(max(status.issueCount, 1)),
                detail: errorMessage
            )
        } else if let preview, !preview.validation.errors.isEmpty {
            let count = preview.validation.errors.count
            validation = Validation(
                kind: .invalid(count),
                detail: preview.validation.errors.first?.message
            )
        } else if let preview, !preview.validation.warnings.isEmpty {
            let count = preview.validation.warnings.count
            validation = Validation(
                kind: .warning(count),
                detail: preview.validation.warnings.first?.message
            )
        } else if preview != nil {
            validation = Validation(
                kind: .valid,
                detail: nil
            )
        } else {
            validation = Validation(
                kind: .unavailable,
                detail: nil
            )
        }

        let document: Document?
        if let fileName, let yaml {
            document = Document(
                fileName: fileName,
                yaml: yaml,
                language: "YAML",
                line: 1,
                column: 1
            )
        } else {
            document = nil
        }
        let matchingAnalysis = yamlAnalysis.flatMap { analysis in
            analysis.sourceYAML == yaml ? analysis : nil
        }
        return Self(
            activeProfileID: activeProfileID,
            activeProfileName: activeProfileName,
            files: files,
            currentDocument: document,
            validation: validation,
            structureTree: matchingAnalysis?.structureTree ?? [],
            history: history,
            overview: Overview(
                mode: matchingAnalysis?.mode ?? "—",
                proxies: matchingAnalysis?.proxies ?? 0,
                proxyGroups: matchingAnalysis?.proxyGroups ?? 0,
                ruleProviders: matchingAnalysis?.ruleProviders ?? 0,
                rules: matchingAnalysis?.rules ?? 0,
                lastUpdated: lastUpdated
            ),
            status: status,
            isLoading: isLoading,
            errorMessage: errorMessage,
            hasChanges: hasChanges,
            canApply: canApply,
            mutationAllowed: mutationAllowed
        )
    }

    private static func yamlFileName(for name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.lowercased().hasSuffix(".yaml"),
              !trimmed.lowercased().hasSuffix(".yml")
        else { return trimmed }
        let normalized = trimmed
            .replacingOccurrences(of: " ", with: "-")
            .lowercased()
        return normalized.isEmpty ? "config.yaml" : "\(normalized).yaml"
    }

    private static func scalarValue(for key: String, in document: YAMLDocument?) -> String? {
        guard let value = document?[key] else { return nil }
        switch value {
        case let .string(value):
            return value
        case let .integer(value):
            return String(value)
        case let .floatingPoint(value):
            return String(value)
        case let .bool(value):
            return String(value)
        case .null:
            return "null"
        case .sequence, .mapping:
            return nil
        }
    }

    private static func collectionCount(for key: String, in document: YAMLDocument?) -> Int {
        guard let value = document?[key] else { return 0 }
        switch value {
        case let .sequence(values):
            return values.count
        case let .mapping(values):
            return values.count
        default:
            return 0
        }
    }

    private static func structureItems(from document: YAMLDocument?) -> [StructureItem] {
        guard let document else { return [] }

        let maximumItemCount = 2_000
        var items: [StructureItem] = []

        func escapedPathComponent(_ component: String) -> String {
            component
                .replacingOccurrences(of: "~", with: "~0")
                .replacingOccurrences(of: "/", with: "~1")
        }

        func scalarDescription(_ value: YAMLValue) -> String? {
            switch value {
            case .null:
                "null"
            case let .bool(value):
                String(value)
            case let .integer(value):
                String(value)
            case let .floatingPoint(value):
                String(value)
            case let .string(value):
                value
            case .sequence, .mapping:
                nil
            }
        }

        func append(
            _ value: YAMLValue,
            id: String,
            label: String,
            parentID: String?,
            depth: Int
        ) {
            guard items.count < maximumItemCount else { return }

            let childCount: Int
            switch value {
            case let .mapping(mapping):
                childCount = mapping.count
            case let .sequence(values):
                childCount = values.count
            default:
                childCount = 0
            }

            items.append(
                StructureItem(
                    id: id,
                    path: id,
                    label: label,
                    parentID: parentID,
                    depth: depth,
                    value: scalarDescription(value),
                    isCollection: childCount > 0,
                    childCount: childCount
                )
            )

            guard items.count < maximumItemCount else { return }
            switch value {
            case let .mapping(mapping):
                for (key, child) in mapping {
                    guard items.count < maximumItemCount else { break }
                    let childID = id == "/"
                        ? "/\(escapedPathComponent(key))"
                        : "\(id)/\(escapedPathComponent(key))"
                    append(
                        child,
                        id: childID,
                        label: key,
                        parentID: id,
                        depth: depth + 1
                    )
                }
            case let .sequence(values):
                for (index, child) in values.enumerated() {
                    guard items.count < maximumItemCount else { break }
                    append(
                        child,
                        id: "\(id)/\(index)",
                        label: "[\(index)]",
                        parentID: id,
                        depth: depth + 1
                    )
                }
            default:
                break
            }
        }

        append(
            .mapping(document.root),
            id: "/",
            label: "root",
            parentID: nil,
            depth: 0
        )
        return items
    }

    private static func revisionHistory(
        from revisions: [ProfileRevision]
    ) -> [HistoryItem] {
        revisions
            .sorted { $0.createdAt > $1.createdAt }
            .map { revision in
                HistoryItem(
                    id: revision.id.uuidString,
                    event: "Stored revision",
                    fileName: revision.sourceFileName,
                    time: revision.createdAt.formatted(date: .abbreviated, time: .shortened),
                    author: "Vela"
                )
            }
    }

    private static func draftChangeItems(
        from preview: ConfigurationPreview?,
        fileName: String
    ) -> [HistoryItem] {
        let entries = preview?.semanticDiff ?? []
        guard !entries.isEmpty else { return [] }
        return entries.enumerated().map { index, entry in
            let operation = String(describing: entry.operation)
                .replacingOccurrences(of: "_", with: " ")
                .capitalized
            return HistoryItem(
                id: "\(entry.path)-\(index)",
                event: "\(operation) \(entry.path)",
                fileName: fileName,
                time: "Fixture",
                author: "Fixture"
            )
        }
    }
}

nonisolated final class ConfigurationWorkbenchYAMLAnalysisCache: @unchecked Sendable {
    private enum Lookup {
        case cached(ConfigurationWorkbenchSnapshot.YAMLAnalysis)
        case inFlight(Task<ConfigurationWorkbenchSnapshot.YAMLAnalysis, Never>)
    }

    static let shared = ConfigurationWorkbenchYAMLAnalysisCache(capacity: 2)

    private let capacity: Int
    private let analyzer: @Sendable (String) async -> ConfigurationWorkbenchSnapshot.YAMLAnalysis
    private let lock = NSLock()
    private var entries: [ConfigurationWorkbenchSnapshot.YAMLAnalysis] = []
    private var inFlight: [String: Task<ConfigurationWorkbenchSnapshot.YAMLAnalysis, Never>] = [:]

    init(capacity: Int) {
        self.capacity = max(capacity, 1)
        analyzer = { yaml in
            await Task.detached(priority: .userInitiated) {
                ConfigurationWorkbenchSnapshot.analyze(yaml: yaml)
            }.value
        }
    }

    init(
        capacity: Int,
        analyzer: @escaping @Sendable (String) async -> ConfigurationWorkbenchSnapshot.YAMLAnalysis
    ) {
        self.capacity = max(capacity, 1)
        self.analyzer = analyzer
    }

    func cachedAnalysis(for yaml: String?) -> ConfigurationWorkbenchSnapshot.YAMLAnalysis? {
        guard let yaml else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return cachedAnalysisLocked(for: yaml)
    }

    func analysis(for yaml: String) async -> ConfigurationWorkbenchSnapshot.YAMLAnalysis {
        let lookup = lock.withLock {
            if let cached = cachedAnalysisLocked(for: yaml) {
                return Lookup.cached(cached)
            }
            if let existing = inFlight[yaml] {
                return Lookup.inFlight(existing)
            }
            let analyzer = analyzer
            let task = Task(priority: .userInitiated) {
                await analyzer(yaml)
            }
            inFlight[yaml] = task
            return Lookup.inFlight(task)
        }

        switch lookup {
        case let .cached(analysis):
            return analysis
        case let .inFlight(task):
            let analysis = await task.value
            lock.withLock {
                inFlight.removeValue(forKey: yaml)
                storeLocked(analysis)
            }
            return analysis
        }
    }

    private func cachedAnalysisLocked(
        for yaml: String
    ) -> ConfigurationWorkbenchSnapshot.YAMLAnalysis? {
        guard let index = entries.firstIndex(where: { $0.sourceYAML == yaml }) else {
            return nil
        }
        let analysis = entries.remove(at: index)
        entries.insert(analysis, at: 0)
        return analysis
    }

    private func storeLocked(_ analysis: ConfigurationWorkbenchSnapshot.YAMLAnalysis) {
        if let existingIndex = entries.firstIndex(where: {
            $0.sourceYAML == analysis.sourceYAML
        }) {
            entries.remove(at: existingIndex)
        }
        entries.insert(analysis, at: 0)
        if entries.count > capacity {
            entries.removeLast(entries.count - capacity)
        }
    }
}

enum ConfigurationWorkbenchAction {
    case selectProfile(UUID)
    case editProfile(UUID)
    case refreshProfiles
    case updateProfile(UUID)
    case deleteProfile(UUID)
    case validate
    case apply
    case revert
    case addRemoteSubscription
    case importConfiguration
    case exportConfiguration
    case openConfigurationFolder
    case viewChangeHistory
    case toggleInspector
}

struct ConfigurationLiquidGlassWorkbenchView: View {
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    let snapshot: ConfigurationWorkbenchSnapshot
    let overrides: Binding<ProfileStructuredOverrides>?
    @Binding var mode: ConfigurationWorkbenchMode
    let prefersInspector: Bool
    let identifierNamespace: String
    let action: @MainActor (ConfigurationWorkbenchAction) -> Void

    @State private var previewTab: PreviewTab = .structure
    @State private var searchText = ""
    @State private var isSearchPresented = false
    @State private var largeYAMLSearchState: ConfigurationLargeYAMLSearchState = .idle
    @State private var expandedStructureItemIDs: Set<String> = ["/"]
    @State private var pendingConfigurationDeletion: ConfigurationWorkbenchSnapshot.FileItem?
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        GeometryReader { proxy in
            let metrics = ConfigurationLiquidLayoutMetrics.resolve(
                width: proxy.size.width,
                height: proxy.size.height,
                prefersInspector: prefersInspector
            )

            VStack(spacing: metrics.sectionSpacing) {
                pageHeader(metrics: metrics)
                workspaceTabs(metrics: metrics)
                workspace(metrics: metrics)
            }
            .padding(.horizontal, metrics.pagePadding)
            .padding(.top, metrics.topPadding)
            .padding(.bottom, metrics.bottomPadding)
            .frame(
                width: proxy.size.width,
                height: proxy.size.height,
                alignment: .topLeading
            )
            .background(VelaPageCanvas())
        }
        .textSelection(.enabled)
        .onChange(of: snapshot.currentDocument?.fileName) { _, _ in
            expandedStructureItemIDs = ["/"]
        }
        .onReceive(NotificationCenter.default.publisher(for: .velaFocusSearch)) { _ in
            isSearchPresented = true
            Task { @MainActor in
                await Task.yield()
                isSearchFocused = true
            }
        }
        .confirmationDialog(
            strings.deleteConfigurationQuestion,
            isPresented: Binding(
                get: { pendingConfigurationDeletion != nil },
                set: { isPresented in
                    if !isPresented {
                        pendingConfigurationDeletion = nil
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            if let pendingConfigurationDeletion {
                Button(
                    strings.deleteConfiguration(pendingConfigurationDeletion.fileName),
                    role: .destructive
                ) {
                    action(.deleteProfile(pendingConfigurationDeletion.id))
                    self.pendingConfigurationDeletion = nil
                }
                Button(strings.cancel, role: .cancel) {
                    self.pendingConfigurationDeletion = nil
                }
            }
        } message: {
            if let pendingConfigurationDeletion {
                Text(configurationDeletionDetail(pendingConfigurationDeletion))
            }
        }
    }

    private var strings: ConfigurationLiquidStrings {
        ConfigurationLiquidStrings(locale: locale)
    }

    private func pageHeader(metrics: ConfigurationLiquidLayoutMetrics) -> some View {
        HStack(alignment: .center, spacing: metrics.controlSpacing) {
            VStack(alignment: .leading, spacing: 4) {
                Text(strings.pageTitle)
                    .font(VelaTypography.mainPageTitle)
                    .foregroundStyle(ConfigurationLiquidTokens.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                Text(strings.pageSubtitle)
                    .font(VelaTypography.pageSubtitle)
                    .foregroundStyle(ConfigurationLiquidTokens.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }

            Spacer(minLength: 12)

            if snapshot.activeProfileID != nil {
                profileMenu(metrics: metrics)
                validationButton(compact: metrics.usesCompactActions)
                if shouldShowApply {
                    applyActionButton(compact: metrics.usesCompactActions)
                }
                moreActionsMenu
            }
        }
        .frame(height: metrics.headerHeight)
    }

    private func validationButton(compact: Bool) -> some View {
        Button {
            action(.validate)
        } label: {
            Group {
                if compact {
                    Image(systemName: "checkmark.circle")
                } else {
                    Label(strings.validate, systemImage: "checkmark.circle")
                }
            }
            .frame(minWidth: compact ? 22 : 76)
        }
        .buttonStyle(ConfigurationSecondaryGlassButtonStyle())
        .disabled(snapshot.isLoading)
        .accessibilityLabel(
            identifierNamespace == "configuration.fixture"
                ? fixtureValidationLabel
                : strings.validate
        )
        .accessibilityIdentifier(validationIdentifier)
    }

    private func applyActionButton(compact: Bool) -> some View {
        Button {
            action(.apply)
        } label: {
            Group {
                if compact {
                    Image(
                        systemName: snapshot.isLoading
                            ? "arrow.trianglehead.2.clockwise.rotate.90"
                            : "play.fill"
                    )
                } else {
                    Label(
                        snapshot.isLoading ? strings.applying : strings.applyChanges,
                        systemImage: snapshot.isLoading
                            ? "arrow.trianglehead.2.clockwise.rotate.90"
                            : "play.fill"
                    )
                }
            }
            .frame(minWidth: compact ? 24 : 116)
        }
        .buttonStyle(ConfigurationPrimaryGlassButtonStyle())
        .disabled(!snapshot.canApply || !snapshot.mutationAllowed)
        .accessibilityLabel(snapshot.isLoading ? strings.applying : strings.applyChanges)
        .accessibilityIdentifier(applyIdentifier)
    }

    private var moreActionsMenu: some View {
        Menu {
            Button(strings.revertDraft, systemImage: "arrow.uturn.backward") {
                action(.revert)
            }
            .disabled(!snapshot.hasChanges)
            Button(addRemoteSubscriptionTitle, systemImage: "link.badge.plus") {
                action(.addRemoteSubscription)
            }
            Button(importLocalYAMLTitle, systemImage: "square.and.arrow.down") {
                action(.importConfiguration)
            }
            Button(strings.exportConfiguration, systemImage: "square.and.arrow.up") {
                action(.exportConfiguration)
            }
            Divider()
            Button(strings.toggleInspector, systemImage: "sidebar.right") {
                action(.toggleInspector)
            }
        } label: {
            Image(systemName: "ellipsis")
                .frame(width: 22, height: 22)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .buttonStyle(ConfigurationSecondaryGlassButtonStyle())
        .accessibilityLabel(strings.moreActions)
    }

    private func profileMenu(metrics: ConfigurationLiquidLayoutMetrics) -> some View {
        Menu {
            ForEach(snapshot.files) { file in
                Button {
                    action(.selectProfile(file.id))
                } label: {
                    if file.isActive {
                        Label(file.name, systemImage: "checkmark")
                    } else {
                        Text(file.name)
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Text(snapshot.activeProfileName ?? strings.chooseProfile)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ConfigurationLiquidTokens.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(ConfigurationLiquidTokens.textSecondary)
            }
            .frame(width: metrics.profileWidth, alignment: .leading)
            .padding(.horizontal, 12)
            .frame(height: metrics.actionHeight)
            .background(
                Color.white.opacity(0.44),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.white.opacity(0.72), lineWidth: 1)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: true, vertical: true)
        .accessibilityLabel(
            "\(strings.activeProfile): \(snapshot.activeProfileName ?? strings.chooseProfile)"
        )
        .accessibilityIdentifier(profileMenuIdentifier)
    }

    private func workspaceTabs(metrics: ConfigurationLiquidLayoutMetrics) -> some View {
        HStack(spacing: 8) {
            tabButton(
                strings.yamlEditor,
                systemImage: "chevron.left.forwardslash.chevron.right",
                targetMode: .editor
            )
            tabButton(
                strings.snippetLibrary,
                systemImage: "curlybraces.square",
                targetMode: .rules
            )
            tabButton(
                strings.schemaReference,
                systemImage: "doc.text.magnifyingglass",
                targetMode: .effective
            )
            Spacer()
        }
        .frame(height: metrics.tabHeight)
    }

    private func tabButton(
        _ title: String,
        systemImage: String,
        targetMode: ConfigurationWorkbenchMode
    ) -> some View {
        Button {
            mode = targetMode
        } label: {
            Label(title, systemImage: systemImage)
                .font(.system(size: 13, weight: mode == targetMode ? .semibold : .medium))
                .foregroundStyle(
                    mode == targetMode
                        ? ConfigurationLiquidTokens.accentText
                        : ConfigurationLiquidTokens.textSecondary
                )
                .padding(.horizontal, 14)
                .frame(height: 34)
                .background {
                    if mode == targetMode {
                        Capsule(style: .continuous)
                            .fill(ConfigurationLiquidTokens.accent.opacity(0.095))
                    }
                }
        }
        .buttonStyle(.plain)
        .contentShape(Capsule())
        .accessibilityLabel(title)
    }

    @ViewBuilder
    private func workspace(metrics: ConfigurationLiquidLayoutMetrics) -> some View {
        let content = HStack(alignment: .top, spacing: metrics.columnSpacing) {
            configurationsPanel(metrics: metrics)
                .frame(width: metrics.navigatorWidth)

            VStack(spacing: metrics.sectionSpacing) {
                editorPanel(metrics: metrics)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                historyPanel(metrics: metrics)
                    .frame(height: metrics.historyHeight)
            }

            if metrics.showsInspector {
                inspectorColumn(metrics: metrics)
                    .frame(width: metrics.inspectorWidth)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

        // Each panel owns its own glass surface. Grouping the entire dynamic
        // workspace causes macOS to recompose every sibling surface when the
        // preview tab changes, which visibly shifts the page's color temperature.
        content
    }

    private func configurationsPanel(metrics: ConfigurationLiquidLayoutMetrics) -> some View {
        VStack(spacing: 0) {
            panelHeader(strings.configurations) {
                Menu {
                    Button(addRemoteSubscriptionTitle, systemImage: "link.badge.plus") {
                        action(.addRemoteSubscription)
                    }
                    Button(importLocalYAMLTitle, systemImage: "square.and.arrow.down") {
                        action(.importConfiguration)
                    }
                    Button(strings.refreshConfigurations, systemImage: "arrow.clockwise") {
                        action(.refreshProfiles)
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 24, height: 24)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .accessibilityLabel(strings.configurationActions)
            }

            Divider().opacity(0.45)

            if snapshot.files.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "doc.badge.plus")
                        .font(.system(size: 26, weight: .regular))
                        .foregroundStyle(ConfigurationLiquidTokens.textTertiary)
                    Text(strings.noConfigurations)
                        .font(.system(size: 13, weight: .semibold))
                    Menu {
                        Button(addRemoteSubscriptionTitle, systemImage: "link.badge.plus") {
                            action(.addRemoteSubscription)
                        }
                        Button(importLocalYAMLTitle, systemImage: "square.and.arrow.down") {
                            action(.importConfiguration)
                        }
                    } label: {
                        Label(strings.addConfiguration, systemImage: "plus")
                    }
                    .menuStyle(.button)
                    .buttonStyle(.borderedProminent)
                    .tint(ConfigurationLiquidTokens.accent)
                    .accessibilityIdentifier(emptyPrimaryIdentifier)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier(emptyIdentifier)
                .accessibilityLabel(strings.noConfigurations)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(snapshot.files) { file in
                            configurationRow(file)
                        }
                    }
                    .padding(8)
                }
                .scrollBounceBehavior(.basedOnSize)
                .accessibilityIdentifier(layersIdentifier)

                Divider().opacity(0.45)

                Button {
                    action(.openConfigurationFolder)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "folder")
                        Text(strings.openConfigFolder)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(ConfigurationLiquidTokens.textTertiary)
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ConfigurationLiquidTokens.textPrimary)
                    .padding(.horizontal, 12)
                    .frame(height: 42)
                }
                .buttonStyle(.plain)
            }
        }
        .configurationGlassSurface(radius: metrics.panelRadius)
    }

    private func configurationRow(_ file: ConfigurationWorkbenchSnapshot.FileItem) -> some View {
        HStack(spacing: 0) {
            Button {
                action(.selectProfile(file.id))
            } label: {
                configurationRowLabel(file)
            }
            .buttonStyle(.plain)

            configurationActionsMenu(file)
                .padding(.trailing, 7)
        }
        .frame(height: file.subscription == nil ? 58 : 72)
        .background(
            file.isActive
                ? ConfigurationLiquidTokens.accent.opacity(0.075)
                : Color.clear,
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contextMenu {
            configurationLifecycleActions(file)
        }
    }

    private func configurationRowLabel(
        _ file: ConfigurationWorkbenchSnapshot.FileItem
    ) -> some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(
                        file.isActive
                            ? ConfigurationLiquidTokens.accent.opacity(0.11)
                            : ConfigurationLiquidTokens.blue.opacity(0.08)
                    )
                Image(systemName: "doc.text")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(
                        file.isActive
                            ? ConfigurationLiquidTokens.accent
                            : ConfigurationLiquidTokens.blue
                    )
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(file.fileName)
                        .font(VelaTypography.table.weight(.semibold))
                        .foregroundStyle(ConfigurationLiquidTokens.textPrimary)
                        .lineLimit(1)
                    if file.isActive {
                        Text(strings.active)
                            .font(VelaTypography.caption.weight(.semibold))
                            .foregroundStyle(ConfigurationLiquidTokens.success)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                ConfigurationLiquidTokens.success.opacity(0.11),
                                in: Capsule()
                            )
                    }
                }
                Text(file.modifiedDescription)
                    .font(VelaTypography.caption.weight(.medium))
                    .foregroundStyle(ConfigurationLiquidTokens.textSecondary)
                    .lineLimit(1)
                if let summary = file.subscription,
                   let detail = subscriptionCompactDescription(summary)
                {
                    Text(detail)
                        .font(VelaTypography.caption.weight(.medium))
                        .foregroundStyle(ConfigurationLiquidTokens.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(.rect)
    }

    private func configurationActionsMenu(
        _ file: ConfigurationWorkbenchSnapshot.FileItem
    ) -> some View {
        Menu {
            configurationLifecycleActions(file)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(ConfigurationLiquidTokens.textSecondary)
                .frame(width: 28, height: 28)
                .contentShape(.rect)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .accessibilityLabel(
            "\(strings.configurationActions), \(file.fileName)"
        )
        .accessibilityIdentifier("configuration.file.\(file.id.uuidString).actions")
    }

    private func configurationDeletionDetail(
        _ file: ConfigurationWorkbenchSnapshot.FileItem
    ) -> String {
        let removalDetail = VelaL10n.string(
            "legacy.theProfileRevisionsOverridesAndStoredSubscriptionCredentialsWillBeRemoved",
            defaultValue: "The profile, revisions, overrides, and stored subscription credentials will be removed."
        )
        guard file.isActive else { return removalDetail }
        let activeDetail = VelaL10n.string(
            "profiles.delete.activeWarning",
            defaultValue: "Deleting the active profile clears the runtime selection. Choose another profile before starting Mihomo again."
        )
        return "\(activeDetail)\n\n\(removalDetail)"
    }

    @ViewBuilder
    private func configurationLifecycleActions(
        _ file: ConfigurationWorkbenchSnapshot.FileItem
    ) -> some View {
        Button(strings.selectConfiguration, systemImage: "checkmark.circle") {
            action(.selectProfile(file.id))
        }
        Button(strings.editConfiguration, systemImage: "pencil") {
            action(.editProfile(file.id))
        }
        Button(strings.updateConfiguration, systemImage: "arrow.clockwise") {
            action(.updateProfile(file.id))
        }
        Divider()
        Button(role: .destructive) {
            pendingConfigurationDeletion = file
        } label: {
            Label(strings.delete, systemImage: "trash")
        }
    }

    @ViewBuilder
    private func editorPanel(metrics: ConfigurationLiquidLayoutMetrics) -> some View {
        VStack(spacing: 0) {
            editorHeader
            Divider().opacity(0.45)

            if snapshot.isLoading {
                ZStack {
                    VelaLoadingState(
                        title: strings.compiling,
                        detail: strings.compilingDetail
                    )
                    .fixedSize()
                }
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: .center
                )
            } else if snapshot.activeProfileID == nil {
                VelaEmptyState(
                    title: snapshot.files.isEmpty ? strings.noConfigurations : strings.noSelection,
                    description: strings.chooseConfigurationDetail,
                    systemImage: "doc.badge.plus"
                ) {
                    if snapshot.files.isEmpty {
                        Menu {
                            Button(addRemoteSubscriptionTitle, systemImage: "link.badge.plus") {
                                action(.addRemoteSubscription)
                            }
                            Button(importLocalYAMLTitle, systemImage: "square.and.arrow.down") {
                                action(.importConfiguration)
                            }
                        } label: {
                            Label(strings.addConfiguration, systemImage: "plus")
                        }
                        .menuStyle(.button)
                        .buttonStyle(.borderedProminent)
                        .tint(ConfigurationLiquidTokens.accent)
                        .accessibilityIdentifier(emptyPrimaryIdentifier)
                    } else {
                        Menu(strings.chooseProfile) {
                            ForEach(snapshot.files) { file in
                                Button(file.name) {
                                    action(.selectProfile(file.id))
                                }
                            }
                        }
                        .menuStyle(.button)
                        .buttonStyle(.borderedProminent)
                        .tint(ConfigurationLiquidTokens.accent)
                        .accessibilityIdentifier(chooseIdentifier)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier(emptyIdentifier)
                .accessibilityLabel(snapshot.files.isEmpty ? strings.noConfigurations : strings.noSelection)
            } else {
                editorContent(metrics: metrics)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .configurationGlassSurface(radius: metrics.panelRadius, emphasized: true)
        .accessibilityIdentifier(editorIdentifier)
    }

    private var editorHeader: some View {
        HStack(spacing: 10) {
            Text(snapshot.currentDocument?.fileName ?? strings.noDocument)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(ConfigurationLiquidTokens.textPrimary)
                .lineLimit(1)

            Spacer(minLength: 8)

            if isSearchPresented {
                TextField(strings.search, text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($isSearchFocused)
                    .frame(width: 150)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(
                        Color.white.opacity(0.52),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                    )
                    .accessibilityIdentifier("\(identifierNamespace).search")
            }

            Button {
                action(.validate)
            } label: {
                Label(strings.refreshPreview, systemImage: "arrow.clockwise")
            }
            .buttonStyle(.plain)

            Button {
                isSearchPresented.toggle()
                if !isSearchPresented {
                    searchText = ""
                }
            } label: {
                Label(strings.search, systemImage: "magnifyingglass")
            }
            .buttonStyle(.plain)

            Menu {
                Button(strings.exportConfiguration, systemImage: "square.and.arrow.up") {
                    action(.exportConfiguration)
                }
                Button(strings.viewHistory, systemImage: "clock.arrow.circlepath") {
                    action(.viewChangeHistory)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .font(VelaTypography.caption.weight(.semibold))
        .foregroundStyle(ConfigurationLiquidTokens.textSecondary)
        .padding(.horizontal, 14)
        .frame(height: 46)
    }

    @ViewBuilder
    private func editorContent(metrics: ConfigurationLiquidLayoutMetrics) -> some View {
        switch mode {
        case .editor:
            VStack(spacing: 0) {
                if let document = snapshot.currentDocument {
                    yamlPreview(document)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                } else {
                    VelaEmptyState(
                        title: strings.previewUnavailable,
                        description: strings.validateToPreview,
                        systemImage: "doc.text.magnifyingglass"
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                editorStatusBar
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .rules:
            if let overrides {
                ConfigurationStructuredOverridesEditor(draft: overrides)
            } else {
                sampleOverrides
            }
        case .diff:
            changeDetailWorkspace
        case .effective:
            structureWorkspace
        }
    }

    @ViewBuilder
    private func yamlPreview(
        _ document: ConfigurationWorkbenchSnapshot.Document
    ) -> some View {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        if document.yaml.utf8.count >= ConfigurationYAMLPreviewPolicy.appKitThresholdBytes {
            ZStack {
                ConfigurationLargeYAMLPreview(
                    yaml: document.yaml,
                    query: query,
                    accessibilityLabel: strings.yamlEditor,
                    searchState: $largeYAMLSearchState
                )
                if largeYAMLSearchState == .noMatch {
                    VStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 24))
                        Text(strings.noSearchResults)
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(ConfigurationLiquidTokens.textSecondary)
                    .padding(18)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                    .allowsHitTesting(false)
                    .accessibilityElement(children: .combine)
                }
            }
            .background(Color.white.opacity(0.24))
        } else {
            let allLines = document.yaml.split(
                separator: "\n",
                omittingEmptySubsequences: false
            ).map(String.init)
            let visibleLines = allLines.enumerated().compactMap {
                (index, line) -> (number: Int, text: String)? in
                guard query.isEmpty || line.localizedCaseInsensitiveContains(query) else {
                    return nil
                }
                return (number: index + 1, text: line)
            }

            GeometryReader { proxy in
                if visibleLines.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 24))
                        Text(strings.noSearchResults)
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(ConfigurationLiquidTokens.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView([.horizontal, .vertical]) {
                        HStack(alignment: .top, spacing: 0) {
                            LazyVStack(alignment: .trailing, spacing: 0) {
                                ForEach(Array(visibleLines.indices), id: \.self) { index in
                                    Text(String(visibleLines[index].number))
                                        .frame(height: 20)
                                }
                            }
                            .font(.system(size: VelaTypeSize.caption, weight: .regular, design: .monospaced))
                            .foregroundStyle(ConfigurationLiquidTokens.textTertiary.opacity(0.70))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 10)
                            .frame(width: 42, alignment: .trailing)
                            .background(Color.white.opacity(0.22))

                            Rectangle()
                                .fill(ConfigurationLiquidTokens.textTertiary.opacity(0.14))
                                .frame(width: 1)

                            Text(
                                highlightedYAML(
                                    visibleLines.map { $0.text }.joined(separator: "\n")
                                )
                            )
                            .font(VelaTypography.code)
                            .lineSpacing(5)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                        }
                        .frame(
                            minWidth: proxy.size.width,
                            minHeight: proxy.size.height,
                            alignment: .topLeading
                        )
                    }
                    .scrollBounceBehavior(.basedOnSize)
                }
            }
            .background(Color.white.opacity(0.24))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(strings.yamlEditor)
            .accessibilityValue(document.yaml)
        }
    }

    private func highlightedYAML(_ yaml: String) -> AttributedString {
        let sourceLines = yaml.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).map(String.init)
        var result = AttributedString()

        for (index, sourceLine) in sourceLines.enumerated() {
            var line = AttributedString(sourceLine)
            line.foregroundColor = ConfigurationLiquidTokens.textPrimary

            if let separator = sourceLine.firstIndex(of: ":") {
                let leading = sourceLine.firstIndex { character in
                    !character.isWhitespace && character != "-"
                }
                if let leading,
                   let keyRange = Range(leading ... separator, in: line)
                {
                    line[keyRange].foregroundColor = ConfigurationLiquidTokens.blue
                }

                let valueStart = sourceLine.index(after: separator)
                let value = sourceLine[valueStart...]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty,
                   let valueRange = Range(valueStart ..< sourceLine.endIndex, in: line)
                {
                    let semanticValue = value.lowercased()
                    let isSemanticScalar = Int(value) != nil
                        || Double(value) != nil
                        || ["true", "false", "null", "\"\""].contains(semanticValue)
                    line[valueRange].foregroundColor = isSemanticScalar
                        ? ConfigurationLiquidTokens.success
                        : ConfigurationLiquidTokens.textPrimary
                }
            }

            result.append(line)
            if index < sourceLines.index(before: sourceLines.endIndex) {
                result.append(AttributedString("\n"))
            }
        }
        return result
    }

    private var editorStatusBar: some View {
        HStack(spacing: 16) {
            Text(snapshot.currentDocument?.language ?? "YAML")
            Spacer()
            Text("Ln \(snapshot.currentDocument?.line ?? 1), Col \(snapshot.currentDocument?.column ?? 1)")
            Text("Spaces: 2")
            Label(schemaStatusLabel, systemImage: schemaStatusImage)
                .foregroundStyle(schemaStatusColor)
            Label(issueStatusLabel, systemImage: issueStatusImage)
                .foregroundStyle(issueStatusColor)
        }
        .font(VelaTypography.caption.weight(.medium))
        .foregroundStyle(ConfigurationLiquidTokens.textSecondary)
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(Color.white.opacity(0.30))
    }

    @ViewBuilder
    private var sampleOverrides: some View {
        if let overrides {
            ConfigurationStructuredOverridesEditor(draft: overrides)
                .disabled(!snapshot.mutationAllowed)
        } else {
            Form {
                Section(strings.runtime) {
                    LabeledContent(strings.mode, value: snapshot.overview.mode)
                    LabeledContent(strings.mixedPort, value: "7890")
                }
                Section("DNS") {
                    LabeledContent(
                        strings.enableDNS,
                        value: VelaL10n.string("legacy.enabled", defaultValue: "Enabled")
                    )
                    LabeledContent(strings.enhancedMode, value: "fake-ip")
                    LabeledContent(
                        strings.respectRules,
                        value: VelaL10n.string("legacy.enabled", defaultValue: "Enabled")
                    )
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
    }

    private var changeDetailWorkspace: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(snapshot.history) { item in
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .foregroundStyle(ConfigurationLiquidTokens.accent)
                        Text(item.event)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                        Spacer()
                        Text(item.time)
                            .foregroundStyle(ConfigurationLiquidTokens.textSecondary)
                    }
                    .padding(10)
                    .background(
                        Color.white.opacity(0.32),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                }
            }
            .padding(14)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private var structureWorkspace: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(visibleStructureItems) { item in
                    structureRow(item, fontSize: 12, rowHeight: 30)
                }
            }
            .padding(.vertical, 10)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private func historyPanel(metrics: ConfigurationLiquidLayoutMetrics) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(strings.changeHistory)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ConfigurationLiquidTokens.textPrimary)
                Spacer()
                Button {
                    action(.viewChangeHistory)
                    mode = .diff
                } label: {
                    Label(strings.viewFullHistory, systemImage: "arrow.up.right")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.plain)
                .font(VelaTypography.caption.weight(.semibold))
            }
            .padding(.horizontal, 14)
            .frame(height: 42)

            Divider().opacity(0.42)

            if snapshot.history.isEmpty {
                Text(strings.noRecentChanges)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(ConfigurationLiquidTokens.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    historyHeader
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(snapshot.history.prefix(metrics.historyRowLimit)) { item in
                                historyRow(item)
                            }
                        }
                    }
                    .scrollBounceBehavior(.basedOnSize)
                }
            }
        }
        .configurationGlassSurface(radius: metrics.panelRadius)
    }

    private var historyHeader: some View {
        HStack(spacing: 10) {
            Text(strings.event)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(strings.file)
                .frame(width: 120, alignment: .leading)
            Text(strings.time)
                .frame(width: 74, alignment: .leading)
            Text(strings.by)
                .frame(width: 52, alignment: .leading)
        }
        .font(VelaTypography.caption.weight(.semibold))
        .foregroundStyle(ConfigurationLiquidTokens.textSecondary)
        .padding(.horizontal, 14)
        .frame(height: 28)
    }

    private func historyRow(_ item: ConfigurationWorkbenchSnapshot.HistoryItem) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(ConfigurationLiquidTokens.textSecondary)
                Text(item.event)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(item.fileName)
                .lineLimit(1)
                .frame(width: 120, alignment: .leading)
            Text(item.time)
                .frame(width: 74, alignment: .leading)
            Text(item.author)
                .frame(width: 52, alignment: .leading)
        }
        .font(VelaTypography.caption.weight(.medium))
        .foregroundStyle(ConfigurationLiquidTokens.textPrimary)
        .padding(.horizontal, 14)
        .frame(height: 28)
        .background(Color.white.opacity(0.18))
    }

    private func inspectorColumn(metrics: ConfigurationLiquidLayoutMetrics) -> some View {
        GeometryReader { proxy in
            ScrollView {
                inspectorCards(metrics: metrics)
                    .frame(
                        minHeight: proxy.size.height,
                        alignment: .top
                    )
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
            .padding(.trailing, 8)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .clipped()
        .accessibilityIdentifier("configuration.inspector")
    }

    private func inspectorCards(metrics: ConfigurationLiquidLayoutMetrics) -> some View {
        VStack(spacing: metrics.sectionSpacing) {
            overviewCard(metrics: metrics)
            if let subscription = selectedSubscription {
                subscriptionCard(subscription, metrics: metrics)
            }
            validationCard(metrics: metrics)
            previewCard(metrics: metrics)
                .layoutPriority(1)
            quickActionsCard(metrics: metrics)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func overviewCard(metrics: ConfigurationLiquidLayoutMetrics) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            cardTitle(strings.configurationOverview)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
                GridRow {
                    overviewMetric(strings.mode, snapshot.overview.mode, "arrow.triangle.branch")
                    overviewMetric(strings.proxies, String(snapshot.overview.proxies), "point.3.connected.trianglepath.dotted")
                }
                GridRow {
                    overviewMetric(strings.proxyGroups, String(snapshot.overview.proxyGroups), "hexagon")
                    overviewMetric(strings.ruleProviders, String(snapshot.overview.ruleProviders), "shippingbox")
                }
                GridRow {
                    overviewMetric(strings.rules, formattedCount(snapshot.overview.rules), "rectangle.3.group")
                    overviewMetric(strings.lastUpdated, snapshot.overview.lastUpdated, "arrow.clockwise")
                }
            }
        }
        .padding(14)
        .configurationGlassSurface(radius: metrics.cardRadius)
    }

    private func overviewMetric(_ title: String, _ value: String, _ symbol: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(ConfigurationLiquidTokens.textPrimary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(VelaTypography.caption.weight(.medium))
                    .foregroundStyle(ConfigurationLiquidTokens.textSecondary)
                    .lineLimit(1)
                Text(value)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(
                        title == strings.mode
                            ? ConfigurationLiquidTokens.success
                            : ConfigurationLiquidTokens.textPrimary
                    )
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func subscriptionCard(
        _ summary: ConfigurationWorkbenchSnapshot.SubscriptionSummary,
        metrics: ConfigurationLiquidLayoutMetrics
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            cardTitle(strings.subscriptionOverview)

            if let fraction = summary.usedFraction {
                ProgressView(value: fraction)
                    .tint(ConfigurationLiquidTokens.accent)
                    .accessibilityLabel(strings.subscriptionUsage)
                    .accessibilityValue(subscriptionUsageDescription(summary))
            }

            subscriptionValueRow(
                strings.subscriptionUsage,
                subscriptionUsageDescription(summary)
            )
            subscriptionValueRow(
                strings.uploaded,
                formattedBytes(summary.uploadBytes)
            )
            subscriptionValueRow(
                strings.downloaded,
                formattedBytes(summary.downloadBytes)
            )
            subscriptionValueRow(
                strings.lastChecked,
                formattedDate(summary.lastCheckedAt)
            )
            subscriptionValueRow(
                strings.lastSuccessfulUpdate,
                formattedDate(summary.lastSuccessfulUpdateAt)
            )
            subscriptionValueRow(
                strings.nextScheduledUpdate,
                formattedDate(summary.nextScheduledUpdateAt)
            )
            subscriptionValueRow(
                strings.expiresAt,
                formattedExpiration(summary.expiresAt)
            )

            if let failure = summary.lastFailureMessage, !failure.isEmpty {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(VelaTypography.caption.weight(.medium))
                    .foregroundStyle(ConfigurationLiquidTokens.warning)
                    .lineLimit(3)
                    .accessibilityLabel("\(strings.lastUpdateFailure): \(failure)")
            }
        }
        .padding(14)
        .configurationGlassSurface(radius: metrics.cardRadius)
    }

    private func subscriptionValueRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .foregroundStyle(ConfigurationLiquidTokens.textSecondary)
            Spacer(minLength: 8)
            Text(value)
                .foregroundStyle(ConfigurationLiquidTokens.textPrimary)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
        .font(VelaTypography.caption.weight(.medium))
    }

    private var selectedSubscription: ConfigurationWorkbenchSnapshot.SubscriptionSummary? {
        snapshot.files.first(where: { $0.id == snapshot.activeProfileID })?.subscription
    }

    private func subscriptionCompactDescription(
        _ summary: ConfigurationWorkbenchSnapshot.SubscriptionSummary
    ) -> String? {
        var components: [String] = []
        if summary.usedBytes != nil || summary.totalBytes != nil {
            components.append(subscriptionUsageDescription(summary))
        }
        if let expiresAt = summary.expiresAt {
            components.append("\(strings.expiresAt) \(formattedExpiration(expiresAt))")
        }
        return components.isEmpty ? nil : components.joined(separator: " · ")
    }

    private func subscriptionUsageDescription(
        _ summary: ConfigurationWorkbenchSnapshot.SubscriptionSummary
    ) -> String {
        let used = formattedBytes(summary.usedBytes)
        guard let total = summary.totalBytes else { return used }
        return "\(used) / \(formattedBytes(total))"
    }

    private func formattedBytes(_ value: Int64?) -> String {
        guard let value else { return strings.notProvided }
        return ByteCountFormatter.string(fromByteCount: max(value, 0), countStyle: .file)
    }

    private func formattedDate(_ value: Date?) -> String {
        value?.formatted(date: .abbreviated, time: .shortened) ?? strings.notProvided
    }

    private func formattedExpiration(_ value: Date?) -> String {
        guard let value else { return strings.notProvided }
        if value <= Date() {
            return "\(value.formatted(date: .abbreviated, time: .omitted)) · \(strings.expired)"
        }
        return value.formatted(date: .abbreviated, time: .omitted)
    }

    private func validationCard(metrics: ConfigurationLiquidLayoutMetrics) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            cardTitle(strings.schemaValidation)
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: schemaStatusImage)
                    .foregroundStyle(schemaStatusColor)
                VStack(alignment: .leading, spacing: 4) {
                    Text(localizedValidationTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(ConfigurationLiquidTokens.textPrimary)
                    Text(localizedValidationDetail)
                        .font(VelaTypography.caption.weight(.medium))
                        .foregroundStyle(ConfigurationLiquidTokens.textSecondary)
                        .lineLimit(2)
                }
            }
            Button {
                action(.validate)
            } label: {
                Label(strings.validateNow, systemImage: "checkmark.shield")
                    .font(VelaTypography.caption.weight(.semibold))
                    .foregroundStyle(Color.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 34)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .background(
                ConfigurationLiquidTokens.accent,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .disabled(snapshot.activeProfileID == nil || snapshot.isLoading)
            .opacity(snapshot.activeProfileID == nil || snapshot.isLoading ? 0.46 : 1)
            .accessibilityIdentifier("configuration.validation.validateNow")
        }
        .padding(14)
        .configurationGlassSurface(radius: metrics.cardRadius)
    }

    private func previewCard(metrics: ConfigurationLiquidLayoutMetrics) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            cardTitle(strings.configurationPreview)
            Picker("", selection: $previewTab) {
                Text(strings.rawYAML).tag(PreviewTab.raw)
                Text(strings.structure).tag(PreviewTab.structure)
            }
            .labelsHidden()
            .pickerStyle(.segmented)

            Group {
                if previewTab == .raw {
                    ScrollView {
                        Text(snapshot.currentDocument?.yaml ?? "—")
                            .font(VelaTypography.code)
                            .foregroundStyle(ConfigurationLiquidTokens.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 5) {
                            ForEach(visibleStructureItems) { item in
                                structureRow(item, fontSize: VelaTypeSize.caption, rowHeight: 22)
                            }
                            if snapshot.structureTree.isEmpty {
                                Text(strings.previewUnavailable)
                                    .font(VelaTypography.caption.weight(.medium))
                                    .foregroundStyle(ConfigurationLiquidTokens.textSecondary)
                            }
                        }
                    }
                }
            }
            .frame(
                minHeight: metrics.previewContentHeight,
                maxHeight: .infinity,
                alignment: .topLeading
            )
            .scrollBounceBehavior(.basedOnSize)
            .clipped()
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(14)
        .configurationGlassSurface(radius: metrics.cardRadius)
    }

    private var visibleStructureItems: [ConfigurationWorkbenchSnapshot.StructureItem] {
        let itemsByID = Dictionary(
            uniqueKeysWithValues: snapshot.structureTree.map { ($0.id, $0) }
        )
        return snapshot.structureTree.filter { item in
            var parentID = item.parentID
            while let currentParentID = parentID {
                guard expandedStructureItemIDs.contains(currentParentID) else {
                    return false
                }
                parentID = itemsByID[currentParentID]?.parentID
            }
            return true
        }
    }

    @ViewBuilder
    private func structureRow(
        _ item: ConfigurationWorkbenchSnapshot.StructureItem,
        fontSize: CGFloat,
        rowHeight: CGFloat
    ) -> some View {
        let content = HStack(spacing: 6) {
            Image(
                systemName: item.isCollection
                    ? (expandedStructureItemIDs.contains(item.id)
                        ? "chevron.down"
                        : "chevron.right")
                    : "point.3.connected.trianglepath.dotted"
            )
            .font(.system(size: max(7, fontSize - 3), weight: .semibold))
            .foregroundStyle(ConfigurationLiquidTokens.textSecondary)
            .frame(width: 12)

            Text(item.label)
                .font(.system(size: fontSize, weight: .medium, design: .monospaced))
                .foregroundStyle(ConfigurationLiquidTokens.textPrimary)
                .lineLimit(1)

            if item.isCollection {
                Text("(\(item.childCount))")
                    .font(.system(size: max(VelaTypeSize.caption, fontSize - 2), weight: .medium))
                    .foregroundStyle(ConfigurationLiquidTokens.textTertiary)
            }

            Spacer(minLength: 8)

            if let value = item.value {
                Text(value)
                    .font(.system(size: fontSize, weight: .semibold, design: .monospaced))
                    .foregroundStyle(ConfigurationLiquidTokens.success)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.leading, 8 + CGFloat(item.depth) * 14)
        .padding(.trailing, 8)
        .frame(height: rowHeight)
        .contentShape(.rect)
        .help(item.path)

        if item.isCollection {
            Button {
                if expandedStructureItemIDs.contains(item.id) {
                    expandedStructureItemIDs.remove(item.id)
                } else {
                    expandedStructureItemIDs.insert(item.id)
                }
            } label: {
                content
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("configuration.structure.\(item.id)")
            .accessibilityLabel(item.label)
            .accessibilityValue(
                expandedStructureItemIDs.contains(item.id)
                    ? strings.expanded
                    : strings.collapsed
            )
        } else {
            content
                .accessibilityIdentifier("configuration.structure.\(item.id)")
        }
    }

    private func quickActionsCard(metrics: ConfigurationLiquidLayoutMetrics) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            cardTitle(strings.quickActions)
            quickAction(addRemoteSubscriptionTitle, "link.badge.plus") {
                action(.addRemoteSubscription)
            }
            quickAction(importLocalYAMLTitle, "square.and.arrow.down") {
                action(.importConfiguration)
            }
            quickAction(strings.exportConfiguration, "square.and.arrow.up") {
                action(.exportConfiguration)
            }
            quickAction(strings.resetToDefault, "arrow.counterclockwise") {
                overrides?.wrappedValue = ProfileStructuredOverrides()
            }
            .disabled(
                overrides.map {
                    $0.wrappedValue == ProfileStructuredOverrides()
                } ?? true
            )
            quickAction(strings.viewHistory, "clock.arrow.circlepath") {
                action(.viewChangeHistory)
                mode = .diff
            }
        }
        .padding(14)
        .configurationGlassSurface(radius: metrics.cardRadius)
    }

    private var addRemoteSubscriptionTitle: String {
        VelaL10n.string(
            "legacy.addRemoteSubscriptionDialog",
            defaultValue: "Add Remote Subscription…"
        )
    }

    private var importLocalYAMLTitle: String {
        VelaL10n.string(
            "legacy.importLocalYamlDialog",
            defaultValue: "Import Local YAML…"
        )
    }

    private func quickAction(
        _ title: String,
        _ systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .frame(width: 16)
                Text(title)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(ConfigurationLiquidTokens.textTertiary)
            }
            .font(VelaTypography.caption.weight(.semibold))
            .foregroundStyle(ConfigurationLiquidTokens.textPrimary)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(
                Color.white.opacity(0.32),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
        }
        .buttonStyle(.plain)
    }

    private func panelHeader<Accessory: View>(
        _ title: String,
        @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(ConfigurationLiquidTokens.textPrimary)
            Spacer()
            accessory()
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
    }

    private func cardTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(ConfigurationLiquidTokens.textPrimary)
    }

    private var localizedValidationTitle: String {
        switch snapshot.validation.kind {
        case .valid: strings.noIssuesFound
        case .validating: strings.validating
        case let .warning(count): strings.issueCount(count)
        case let .invalid(count): strings.issueCount(count)
        case .unavailable: strings.notValidated
        }
    }

    private var shouldShowApply: Bool {
        guard identifierNamespace == "configuration.fixture" else { return true }
        return snapshot.hasChanges && snapshot.status.kind != .recoveryRequired
    }

    private var fixtureValidationLabel: String {
        switch snapshot.validation.kind {
        case .valid:
            strings.validated
        case .validating:
            strings.validating
        case let .warning(count), let .invalid(count):
            strings.issueCount(count)
        case .unavailable:
            strings.notValidated
        }
    }

    private var localizedValidationDetail: String {
        switch snapshot.validation.kind {
        case .valid: strings.configurationValid
        case .validating: strings.validatingDetail
        case .warning: snapshot.validation.detail ?? strings.reviewWarningBeforeApplying
        case .invalid: snapshot.validation.detail ?? strings.resolveIssuesBeforeApplying
        case .unavailable: strings.validateToPreview
        }
    }

    private var schemaStatusLabel: String {
        switch snapshot.validation.kind {
        case .valid: strings.schemaValid
        case .validating: strings.validating
        case .warning: strings.schemaWarning
        case .invalid: strings.schemaInvalid
        case .unavailable: strings.notValidated
        }
    }

    private var schemaStatusImage: String {
        switch snapshot.validation.kind {
        case .valid: "checkmark.circle"
        case .validating: "arrow.trianglehead.2.clockwise.rotate.90"
        case .warning: "exclamationmark.triangle"
        case .invalid: "xmark.circle"
        case .unavailable: "questionmark.circle"
        }
    }

    private var schemaStatusColor: Color {
        switch snapshot.validation.kind {
        case .valid: ConfigurationLiquidTokens.success
        case .validating: ConfigurationLiquidTokens.blue
        case .warning: ConfigurationLiquidTokens.warning
        case .invalid: ConfigurationLiquidTokens.error
        case .unavailable: ConfigurationLiquidTokens.textSecondary
        }
    }

    private var issueStatusLabel: String {
        switch snapshot.validation.kind {
        case let .warning(count), let .invalid(count):
            strings.issueCount(count)
        default:
            strings.noErrors
        }
    }

    private var issueStatusImage: String {
        switch snapshot.validation.kind {
        case .warning, .invalid: "exclamationmark.triangle"
        default: "checkmark.circle"
        }
    }

    private var issueStatusColor: Color {
        switch snapshot.validation.kind {
        case .warning: ConfigurationLiquidTokens.warning
        case .invalid: ConfigurationLiquidTokens.error
        default: ConfigurationLiquidTokens.success
        }
    }

    private func formattedCount(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic))
    }

    private var profileMenuIdentifier: String {
        identifierNamespace == "configuration.fixture"
            ? "configuration.fixture.profileMenu"
            : "configuration.profile.menu"
    }

    private var validationIdentifier: String {
        identifierNamespace == "configuration.fixture"
            ? "configuration.fixture.validation"
            : "configuration.validate"
    }

    private var applyIdentifier: String {
        identifierNamespace == "configuration.fixture"
            ? "configuration.fixture.apply"
            : "configuration.apply"
    }

    private var editorIdentifier: String {
        identifierNamespace == "configuration.fixture"
            ? "configuration.fixture.editor"
            : "configuration.editor"
    }

    private var layersIdentifier: String {
        identifierNamespace == "configuration.fixture"
            ? "configuration.fixture.layers"
            : "configuration.files"
    }

    private var emptyIdentifier: String {
        identifierNamespace == "configuration.fixture"
            ? "configuration.fixture.empty"
            : "configuration.empty"
    }

    private var emptyPrimaryIdentifier: String {
        identifierNamespace == "configuration.fixture"
            ? "configuration.fixture.add"
            : "configuration.empty.add"
    }

    private var chooseIdentifier: String {
        identifierNamespace == "configuration.fixture"
            ? "configuration.fixture.choose"
            : "configuration.empty.choose"
    }
}

private enum ConfigurationYAMLPreviewPolicy {
    // Subscription profiles routinely contain hundreds or thousands of lines.
    // NSTextView keeps those documents out of SwiftUI's view/layout graph.
    static let appKitThresholdBytes = 16 * 1_024
}

private enum ConfigurationLargeYAMLSearchState: Equatable {
    case idle
    case searching
    case matched
    case noMatch
}

private struct ConfigurationLargeYAMLPreview: NSViewRepresentable {
    let yaml: String
    let query: String
    let accessibilityLabel: String
    @Binding var searchState: ConfigurationLargeYAMLSearchState

    func makeCoordinator() -> Coordinator {
        Coordinator(searchState: $searchState)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.verticalScrollElasticity = .none
        scrollView.horizontalScrollElasticity = .none

        let textView = NSTextView(frame: .zero)
        textView.isRichText = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.usesFindPanel = true
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textColor = .labelColor
        textView.backgroundColor = .clear
        textView.textContainerInset = NSSize(width: 14, height: 10)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.layoutManager?.allowsNonContiguousLayout = true
        Self.applyYAML(yaml, to: textView)
        textView.setAccessibilityLabel(accessibilityLabel)
        scrollView.documentView = textView

        context.coordinator.textView = textView
        context.coordinator.updateSearch(query, in: textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        textView.setAccessibilityLabel(accessibilityLabel)
        if textView.string != yaml {
            context.coordinator.documentDidChange()
            Self.applyYAML(yaml, to: textView)
        }
        context.coordinator.updateSearch(query, in: textView)
    }

    private static func applyYAML(_ yaml: String, to textView: NSTextView) {
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let rendered = NSMutableAttributedString(
            string: yaml,
            attributes: [
                .font: font,
                .foregroundColor: NSColor.labelColor,
            ]
        )
        let source = yaml as NSString
        var location = 0

        while location < source.length {
            let lineRange = source.lineRange(for: NSRange(location: location, length: 0))
            let line = source.substring(with: lineRange) as NSString
            let contentLength = (line as String)
                .trimmingCharacters(in: .newlines)
                .utf16.count
            guard contentLength > 0 else {
                location = NSMaxRange(lineRange)
                continue
            }

            let colon = line.range(of: ":")
            let leading = line.rangeOfCharacter(from: .whitespacesAndNewlines.inverted)
            if colon.location != NSNotFound,
               leading.location != NSNotFound,
               colon.location >= leading.location,
               !line.substring(from: leading.location).hasPrefix("#")
            {
                rendered.addAttribute(
                    .foregroundColor,
                    value: NSColor.systemBlue,
                    range: NSRange(
                        location: lineRange.location + leading.location,
                        length: colon.location - leading.location + 1
                    )
                )

                let valueLocation = colon.location + colon.length
                if valueLocation < contentLength {
                    let rawValue = line.substring(from: valueLocation)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let semanticValue = rawValue.lowercased()
                    if Int(rawValue) != nil
                        || Double(rawValue) != nil
                        || ["true", "false", "null", "\"\""].contains(semanticValue)
                    {
                        rendered.addAttribute(
                            .foregroundColor,
                            value: NSColor.systemGreen,
                            range: NSRange(
                                location: lineRange.location + valueLocation,
                                length: contentLength - valueLocation
                            )
                        )
                    }
                }
            }

            location = NSMaxRange(lineRange)
        }

        textView.textStorage?.setAttributedString(rendered)
    }

    @MainActor
    final class Coordinator {
        weak var textView: NSTextView?
        private var searchState: Binding<ConfigurationLargeYAMLSearchState>
        private var searchTask: Task<Void, Never>?
        private var requestID = 0
        private var lastQuery: String?

        init(searchState: Binding<ConfigurationLargeYAMLSearchState>) {
            self.searchState = searchState
        }

        func documentDidChange() {
            searchTask?.cancel()
            requestID += 1
            lastQuery = nil
        }

        func updateSearch(_ rawQuery: String, in textView: NSTextView) {
            let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            guard query != lastQuery else { return }
            lastQuery = query
            requestID += 1
            let currentRequestID = requestID
            searchTask?.cancel()

            guard !query.isEmpty else {
                textView.setSelectedRange(NSRange(location: 0, length: 0))
                publish(.idle, requestID: currentRequestID)
                return
            }

            let source = textView.string
            publish(.searching, requestID: currentRequestID)
            searchTask = Task { [weak self, weak textView] in
                try? await Task.sleep(for: .milliseconds(140))
                guard !Task.isCancelled else { return }
                let match = await Task.detached(priority: .userInitiated) {
                    (source as NSString).range(
                        of: query,
                        options: [.caseInsensitive]
                    )
                }.value
                guard
                    !Task.isCancelled,
                    let self,
                    self.requestID == currentRequestID,
                    let textView
                else {
                    return
                }
                guard match.location != NSNotFound else {
                    textView.setSelectedRange(NSRange(location: 0, length: 0))
                    self.searchState.wrappedValue = .noMatch
                    return
                }
                textView.setSelectedRange(match)
                textView.scrollRangeToVisible(match)
                self.searchState.wrappedValue = .matched
            }
        }

        private func publish(
            _ state: ConfigurationLargeYAMLSearchState,
            requestID: Int
        ) {
            Task { @MainActor [weak self] in
                await Task.yield()
                guard let self, self.requestID == requestID else { return }
                self.searchState.wrappedValue = state
            }
        }
    }
}

private enum PreviewTab: String, CaseIterable, Identifiable {
    case raw
    case structure

    var id: Self { self }
}

private enum ConfigurationLiquidTokens {
    static let textPrimary = Color.primary
    static let textSecondary = Color.secondary
    static let textTertiary = Color(nsColor: .tertiaryLabelColor)
    static let accent = Color(red: 0 / 255, green: 177 / 255, blue: 147 / 255)
    static let accentText = Color(red: 0 / 255, green: 124 / 255, blue: 103 / 255)
    static let success = Color(red: 38 / 255, green: 190 / 255, blue: 111 / 255)
    static let warning = Color(red: 237 / 255, green: 153 / 255, blue: 35 / 255)
    static let error = Color(red: 226 / 255, green: 69 / 255, blue: 77 / 255)
    static let blue = Color(red: 38 / 255, green: 139 / 255, blue: 1)
}

private struct ConfigurationGlassSurfaceModifier: ViewModifier {
    let radius: CGFloat
    let emphasized: Bool

    func body(content: Content) -> some View {
        content.velaWorkspaceGlassSurface(
            radius: radius,
            emphasized: emphasized
        )
    }
}

private extension View {
    func configurationGlassSurface(
        radius: CGFloat,
        emphasized: Bool = false
    ) -> some View {
        modifier(ConfigurationGlassSurfaceModifier(radius: radius, emphasized: emphasized))
    }
}

private struct ConfigurationSecondaryGlassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(ConfigurationLiquidTokens.textPrimary)
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(
                Color.white.opacity(configuration.isPressed ? 0.58 : 0.44),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.white.opacity(0.72), lineWidth: 1)
            }
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

private struct ConfigurationPrimaryGlassButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(
                ConfigurationLiquidTokens.accent.opacity(
                    isEnabled ? (configuration.isPressed ? 0.78 : 0.94) : 0.30
                ),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.white.opacity(isEnabled ? 0.44 : 0.20), lineWidth: 1)
            }
            .shadow(
                color: ConfigurationLiquidTokens.accent.opacity(isEnabled ? 0.24 : 0),
                radius: 12,
                y: 5
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

private struct ConfigurationLiquidLayoutMetrics {
    let pagePadding: CGFloat
    let topPadding: CGFloat
    let bottomPadding: CGFloat
    let sectionSpacing: CGFloat
    let columnSpacing: CGFloat
    let controlSpacing: CGFloat
    let headerHeight: CGFloat
    let tabHeight: CGFloat
    let actionHeight: CGFloat
    let navigatorWidth: CGFloat
    let inspectorWidth: CGFloat
    let historyHeight: CGFloat
    let previewContentHeight: CGFloat
    let profileWidth: CGFloat
    let panelRadius: CGFloat
    let cardRadius: CGFloat
    let titleSize: CGFloat
    let subtitleSize: CGFloat
    let historyRowLimit: Int
    let showsInspector: Bool
    let usesCompactActions: Bool

    static func resolve(
        width: CGFloat,
        height: CGFloat,
        prefersInspector: Bool
    ) -> Self {
        let compactWidth = width < 920
        let heightProgress = min(max((height - 700) / 260, 0), 1)
        func interpolated(_ compact: CGFloat, _ spacious: CGFloat) -> CGFloat {
            compact + ((spacious - compact) * heightProgress)
        }
        let showsInspector = prefersInspector
            && ConfigurationWorkbenchLayoutPolicy.canPresentInspector(contentWidth: width)
        return Self(
            pagePadding: compactWidth ? 14 : 20,
            topPadding: interpolated(12, 18),
            bottomPadding: interpolated(12, 18),
            sectionSpacing: interpolated(10, 12),
            columnSpacing: compactWidth ? 10 : 12,
            controlSpacing: compactWidth ? 8 : 10,
            headerHeight: interpolated(58, 66),
            tabHeight: 38,
            actionHeight: 42,
            navigatorWidth: compactWidth ? 178 : 204,
            inspectorWidth: width >= 1160 ? 286 : 262,
            historyHeight: interpolated(126, 158),
            previewContentHeight: interpolated(64, 96),
            profileWidth: compactWidth ? 112 : 150,
            panelRadius: compactWidth ? 17 : 20,
            cardRadius: 17,
            titleSize: compactWidth ? 24 : 28,
            subtitleSize: compactWidth ? 12 : 13,
            historyRowLimit: height < 820 ? 2 : 4,
            showsInspector: showsInspector,
            usesCompactActions: compactWidth
        )
    }
}

private struct ConfigurationLiquidStrings {
    private let isChinese: Bool

    init(locale: Locale) {
        isChinese = locale.language.languageCode?.identifier == "zh"
    }

    private func copy(_ english: String, _ chinese: String) -> String {
        isChinese ? chinese : english
    }

    var pageTitle: String { copy("Configuration Workbench", "配置工作台") }
    var pageSubtitle: String { copy("Edit, validate and manage your Mihomo configuration", "编辑、验证和管理 Mihomo 配置") }
    var activeProfile: String { copy("Active Profile", "当前配置") }
    var chooseProfile: String { copy("Choose Profile", "选择配置") }
    var validate: String { copy("Validate", "验证") }
    var applying: String { copy("Applying…", "正在应用…") }
    var applyChanges: String { copy("Apply Changes", "应用更改") }
    var revertDraft: String { copy("Revert Draft", "还原草稿") }
    var toggleInspector: String { copy("Toggle Inspector", "切换检查器") }
    var moreActions: String { copy("More Actions", "更多操作") }
    var yamlEditor: String { copy("YAML Editor", "YAML 编辑器") }
    var snippetLibrary: String { copy("Override Editor", "覆盖编辑器") }
    var schemaReference: String { copy("Structure", "结构") }
    var configurations: String { copy("Configurations", "配置文件") }
    var configurationActions: String { copy("Configuration Actions", "配置文件操作") }
    var importConfiguration: String { copy("Import Configuration", "导入配置") }
    var exportConfiguration: String { copy("Export Configuration", "导出配置") }
    var refreshConfigurations: String { copy("Refresh Configurations", "刷新配置列表") }
    var selectConfiguration: String { copy("Select Configuration", "选择配置") }
    var editConfiguration: String { copy("Edit Configuration…", "编辑配置…") }
    var updateConfiguration: String { copy("Update / Reload", "更新或重新载入") }
    var delete: String { copy("Delete", "删除") }
    var cancel: String { copy("Cancel", "取消") }
    var deleteConfigurationQuestion: String {
        copy("Delete Configuration?", "删除配置文件？")
    }
    var active: String { copy("Active", "当前") }
    var openConfigFolder: String { copy("Open Config Folder", "打开配置目录") }
    var noConfigurations: String { copy("No Configuration Files", "没有配置文件") }
    var noSelection: String { copy("No Configuration Selected", "未选择配置文件") }
    var addConfiguration: String { copy("Add Configuration…", "添加配置…") }
    var chooseConfigurationDetail: String { copy("Choose a configuration file, then edit, inspect, and apply it.", "请选择配置文件，然后编辑、检查并应用。") }
    var noDocument: String { copy("No document", "无文档") }
    var refreshPreview: String { copy("Refresh Preview", "刷新预览") }
    var search: String { copy("Search", "搜索") }
    var noSearchResults: String { copy("No matching YAML lines", "没有匹配的 YAML 行") }
    var compiling: String { copy("Compiling configuration", "正在编译配置") }
    var compilingDetail: String { copy("Building a deterministic redacted preview", "正在生成确定性的脱敏预览") }
    var previewUnavailable: String { copy("Preview unavailable", "预览不可用") }
    var validateToPreview: String { copy("Validate this configuration to generate a preview.", "验证此配置以生成预览。") }
    var runtime: String { copy("Runtime", "运行时") }
    var mode: String { copy("Mode", "模式") }
    var mixedPort: String { copy("Mixed Port", "混合端口") }
    var enableDNS: String { copy("Enable DNS", "启用 DNS") }
    var enhancedMode: String { copy("Enhanced Mode", "增强模式") }
    var respectRules: String { copy("Respect Rules", "遵循规则") }
    var changeHistory: String { copy("Change History", "变更历史") }
    var viewFullHistory: String { copy("View Full History", "查看完整历史") }
    var noRecentChanges: String { copy("No recent configuration changes", "没有最近的配置变更") }
    var event: String { copy("Event", "事件") }
    var file: String { copy("File", "文件") }
    var time: String { copy("Time", "时间") }
    var by: String { copy("By", "操作人") }
    var configurationOverview: String { copy("Configuration Overview", "配置概览") }
    var proxies: String { copy("Proxies", "代理") }
    var proxyGroups: String { copy("Proxy Groups", "代理组") }
    var ruleProviders: String { copy("Rule Providers", "规则提供者") }
    var rules: String { copy("Rules", "规则") }
    var lastUpdated: String { copy("Last Updated", "最近更新") }
    var subscriptionOverview: String { copy("Subscription Overview", "订阅概览") }
    var subscriptionUsage: String { copy("Used / Total", "已用 / 总量") }
    var uploaded: String { copy("Uploaded", "上传") }
    var downloaded: String { copy("Downloaded", "下载") }
    var lastChecked: String { copy("Last Checked", "上次检查") }
    var lastSuccessfulUpdate: String { copy("Last Successful Update", "上次成功更新") }
    var nextScheduledUpdate: String { copy("Next Scheduled Update", "下次计划更新") }
    var expiresAt: String { copy("Expires", "到期") }
    var lastUpdateFailure: String { copy("Last Update Failure", "最近更新失败") }
    var notProvided: String { copy("Not provided", "未提供") }
    var expired: String { copy("Expired", "已过期") }
    var schemaValidation: String { copy("Schema Validation", "结构验证") }
    var noIssuesFound: String { copy("No issues found", "未发现问题") }
    var validated: String { copy("Validated", "已验证") }
    var configurationValid: String { copy("Your configuration is valid.", "配置有效。") }
    var validating: String { copy("Validating…", "正在验证…") }
    var validatingDetail: String { copy("Checking the current compiled snapshot.", "正在检查当前编译快照。") }
    var resolveIssuesBeforeApplying: String {
        copy("Resolve the reported issues before applying.", "应用前请先解决报告的问题。")
    }
    var reviewWarningBeforeApplying: String {
        copy("Review the warning before applying.", "应用前请先检查警告。")
    }
    var notValidated: String { copy("Not validated", "尚未验证") }
    var validateNow: String { copy("Validate Now", "立即验证") }
    var configurationPreview: String { copy("Configuration Preview", "配置预览") }
    var rawYAML: String { copy("Raw YAML", "原始 YAML") }
    var structure: String { copy("Structure", "结构") }
    var expanded: String { copy("Expanded", "已展开") }
    var collapsed: String { copy("Collapsed", "已收起") }
    var quickActions: String { copy("Quick Actions", "快捷操作") }
    var resetToDefault: String { copy("Reset to Default", "恢复默认") }
    var viewHistory: String { copy("View Change History", "查看变更历史") }
    var schemaValid: String { copy("Schema: Valid", "结构：有效") }
    var schemaWarning: String { copy("Schema: Warning", "结构：警告") }
    var schemaInvalid: String { copy("Schema: Invalid", "结构：无效") }
    var noErrors: String { copy("No errors", "无错误") }

    func deleteConfiguration(_ fileName: String) -> String {
        copy("Delete \(fileName)", "删除 \(fileName)")
    }

    func deleteConfigurationDetail(_ fileName: String) -> String {
        copy(
            "\(fileName) and its stored revisions will be removed. This action cannot be undone.",
            "\(fileName) 及其已保存的版本记录将被移除，此操作无法撤销。"
        )
    }

    func issueCount(_ count: Int) -> String {
        copy("\(count) issue\(count == 1 ? "" : "s")", "\(count) 个问题")
    }
}
