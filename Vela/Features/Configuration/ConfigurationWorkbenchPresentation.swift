import Foundation
import SwiftUI

nonisolated enum ConfigurationPresentation {
    static func diffOperation(_ operation: ConfigurationDiffOperation) -> String {
        switch operation {
        case .add:
            VelaL10n.string(
                "configuration.inspector.diff.operation.add",
                defaultValue: "ADD"
            )
        case .change:
            VelaL10n.string(
                "configuration.inspector.diff.operation.change",
                defaultValue: "CHANGE"
            )
        case .remove:
            VelaL10n.string(
                "configuration.inspector.diff.operation.remove",
                defaultValue: "REMOVE"
            )
        }
    }

    static func valueSource(_ source: ConfigurationValueSource) -> String {
        switch source {
        case .upstream:
            VelaL10n.string(
                "configuration.inspector.diff.source.upstream",
                defaultValue: "Upstream"
            )
        case .velaOverride:
            VelaL10n.string(
                "configuration.inspector.diff.source.override",
                defaultValue: "Vela Override"
            )
        case .velaForced:
            VelaL10n.string(
                "configuration.inspector.diff.source.forced",
                defaultValue: "Vela Required"
            )
        }
    }
}

nonisolated enum ConfigurationWorkbenchMode: String, CaseIterable, Identifiable, Sendable {
    case editor
    case rules
    case diff
    case effective

    var id: Self { self }

    var title: String {
        switch self {
        case .editor:
            VelaL10n.string("configuration.mode.editor", defaultValue: "Editor")
        case .rules:
            VelaL10n.string("configuration.mode.rules", defaultValue: "Rules")
        case .diff:
            VelaL10n.string("configuration.mode.diff", defaultValue: "Diff")
        case .effective:
            VelaL10n.string("configuration.mode.effective", defaultValue: "Effective")
        }
    }
}

nonisolated enum ConfigurationWorkbenchLayer: String, CaseIterable, Identifiable, Sendable {
    case upstream
    case profileOverrides
    case runtimeSafety
    case effective

    var id: Self { self }

    var title: String {
        switch self {
        case .upstream:
            VelaL10n.string("configuration.layer.upstream", defaultValue: "Upstream Profile")
        case .profileOverrides:
            VelaL10n.string("configuration.layer.overrides", defaultValue: "Profile Overrides")
        case .runtimeSafety:
            VelaL10n.string("configuration.layer.runtimeSafety", defaultValue: "Runtime Safety")
        case .effective:
            VelaL10n.string("configuration.layer.effective", defaultValue: "Effective Configuration")
        }
    }

    var symbol: String {
        switch self {
        case .upstream: "doc.text"
        case .profileOverrides: "slider.horizontal.3"
        case .runtimeSafety: "lock.shield"
        case .effective: "checkmark.seal"
        }
    }

    var isEditable: Bool { self == .profileOverrides }
}

nonisolated enum ConfigurationWorkbenchStatusKind: String, Sendable {
    case noProfile
    case loading
    case clean
    case draft
    case compiling
    case invalid
    case readyToApply
    case applying
    case stale
    case recoveryRequired
}

nonisolated struct ConfigurationWorkbenchStatus: Equatable, Sendable {
    let kind: ConfigurationWorkbenchStatusKind
    let changeCount: Int
    let issueCount: Int

    var label: String {
        switch kind {
        case .noProfile:
            VelaL10n.string("configuration.status.noProfile", defaultValue: "No Profile")
        case .loading:
            VelaL10n.string("configuration.status.loading", defaultValue: "Loading…")
        case .clean:
            VelaL10n.string("configuration.status.clean", defaultValue: "Clean")
        case .draft:
            VelaL10n.string(
                "configuration.status.draft.count",
                defaultValue: "Draft · %lld changes",
                arguments: changeCount
            )
        case .compiling:
            VelaL10n.string("configuration.status.compiling", defaultValue: "Compiling")
        case .invalid:
            VelaL10n.string(
                "configuration.status.invalid.count",
                defaultValue: "Invalid · %lld issues",
                arguments: issueCount
            )
        case .readyToApply:
            VelaL10n.string("configuration.status.readyToApply", defaultValue: "Ready to Apply")
        case .applying:
            VelaL10n.string("configuration.status.applying", defaultValue: "Applying")
        case .stale:
            VelaL10n.string("configuration.status.stale", defaultValue: "Stale")
        case .recoveryRequired:
            VelaL10n.string("configuration.status.recoveryRequired", defaultValue: "Recovery Required")
        }
    }

    var semanticStatus: VelaSemanticStatus {
        switch kind {
        case .clean, .readyToApply: .success
        case .draft, .compiling, .loading, .noProfile: .info
        case .invalid, .stale: .warning
        case .applying: .info
        case .recoveryRequired: .error
        }
    }

    var allowsApply: Bool { kind == .readyToApply }
    var allowsValidate: Bool {
        switch kind {
        case .draft, .invalid, .readyToApply: true
        default: false
        }
    }
    var allowsRevert: Bool {
        switch kind {
        case .draft, .compiling, .invalid, .readyToApply: true
        default: false
        }
    }
}

nonisolated enum ConfigurationWorkbenchSelection: Hashable, Sendable {
    case layer(ConfigurationWorkbenchLayer)
    case operation(path: String)
    case rule(index: Int, effective: Bool)
    case diagnostic(index: Int)
    case transaction
    case recovery
}

nonisolated struct ConfigurationRuleRow: Identifiable, Equatable, Sendable {
    enum Segment: String, Sendable {
        case upstream
        case effective
    }

    let index: Int
    let value: String
    let segment: Segment

    var id: String { "\(segment.rawValue):\(index)" }
}

nonisolated enum ConfigurationWorkbenchPresentationPolicy {
    static func status(
        hasProfile: Bool,
        hasChanges: Bool,
        isLoading: Bool,
        isSaving: Bool,
        preview: ConfigurationPreview?,
        errorMessage: String?
    ) -> ConfigurationWorkbenchStatus {
        guard hasProfile else {
            return ConfigurationWorkbenchStatus(kind: .noProfile, changeCount: 0, issueCount: 0)
        }
        if isSaving {
            return ConfigurationWorkbenchStatus(
                kind: .applying,
                changeCount: preview?.semanticDiff.count ?? 0,
                issueCount: preview?.validation.issues.count ?? 0
            )
        }
        if isLoading {
            return ConfigurationWorkbenchStatus(kind: .loading, changeCount: 0, issueCount: 0)
        }
        let issues = preview?.validation.issues ?? []
        let errorCount = issues.filter { $0.severity == .error }.count
        if errorMessage != nil || errorCount > 0 {
            return ConfigurationWorkbenchStatus(
                kind: .invalid,
                changeCount: preview?.semanticDiff.count ?? 0,
                issueCount: max(errorCount, errorMessage == nil ? 0 : 1)
            )
        }
        guard hasChanges else {
            return ConfigurationWorkbenchStatus(kind: .clean, changeCount: 0, issueCount: 0)
        }
        guard let preview else {
            return ConfigurationWorkbenchStatus(kind: .compiling, changeCount: 0, issueCount: 0)
        }
        return ConfigurationWorkbenchStatus(
            kind: preview.validation.isValid ? .readyToApply : .invalid,
            changeCount: preview.semanticDiff.count,
            issueCount: preview.validation.issues.count
        )
    }

    static func reconciledSelection(
        _ selection: ConfigurationWorkbenchSelection?,
        hasProfile: Bool,
        preview: ConfigurationPreview?
    ) -> ConfigurationWorkbenchSelection? {
        guard hasProfile else { return nil }
        guard let selection else { return .layer(.profileOverrides) }
        switch selection {
        case let .operation(path):
            return preview?.semanticDiff.contains(where: { $0.path == path }) == true
                ? selection : .layer(.profileOverrides)
        case let .diagnostic(index):
            return preview?.validation.issues.indices.contains(index) == true
                ? selection : .layer(.profileOverrides)
        case let .rule(index, effective):
            let yaml = effective ? preview?.finalYAML : preview?.rawYAML
            return rules(from: yaml, segment: effective ? .effective : .upstream)
                .indices.contains(index) ? selection : .layer(.profileOverrides)
        case .layer, .transaction, .recovery:
            return selection
        }
    }

    static func rules(
        from yaml: String?,
        segment: ConfigurationRuleRow.Segment
    ) -> [ConfigurationRuleRow] {
        guard let yaml,
              let document = try? YAMLDocument(yaml: yaml),
              case let .sequence(values)? = try? document.value(at: ["rules"])
        else { return [] }
        return values.enumerated().map { index, value in
            ConfigurationRuleRow(
                index: index,
                value: value.stableDescription,
                segment: segment
            )
        }
    }

    static func matchingDiff(
        in preview: ConfigurationPreview?,
        search: String
    ) -> [ConfigurationSemanticDiffEntry] {
        guard let preview else { return [] }
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return preview.semanticDiff }
        return preview.semanticDiff.filter {
            $0.path.localizedCaseInsensitiveContains(query)
                || ($0.beforeDescription?.localizedCaseInsensitiveContains(query) == true)
                || ($0.afterDescription?.localizedCaseInsensitiveContains(query) == true)
        }
    }
}

nonisolated struct ConfigurationWorkbenchProfileOption: Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
}

nonisolated enum ConfigurationWorkbenchCatalogState: Equatable, Sendable {
    case emptyCatalog
    case noSelection(options: [ConfigurationWorkbenchProfileOption])
    case selected(
        current: ConfigurationWorkbenchProfileOption,
        options: [ConfigurationWorkbenchProfileOption]
    )
}

nonisolated enum ConfigurationWorkbenchValidationState: Equatable, Sendable {
    case unvalidated
    case validating
    case validated
    case issues(Int)

    var label: String {
        switch self {
        case .unvalidated:
            VelaL10n.string(
                "configuration.validation.unvalidated",
                defaultValue: "Not Validated"
            )
        case .validating:
            VelaL10n.string(
                "configuration.validation.validating",
                defaultValue: "Validating…"
            )
        case .validated:
            VelaL10n.string(
                "configuration.validation.validated",
                defaultValue: "Validated"
            )
        case let .issues(count):
            VelaL10n.string(
                "configuration.validation.issues.count",
                defaultValue: "%lld Issues",
                arguments: count
            )
        }
    }

    var systemImage: String {
        switch self {
        case .unvalidated: "circle.dashed"
        case .validating: "arrow.trianglehead.2.clockwise.rotate.90"
        case .validated: "checkmark.seal"
        case .issues: "exclamationmark.triangle"
        }
    }

    var semanticStatus: VelaSemanticStatus {
        switch self {
        case .unvalidated, .validating: .info
        case .validated: .success
        case .issues: .warning
        }
    }
}

nonisolated struct ConfigurationWorkbenchToolbarPresentation: Equatable, Sendable {
    let catalogState: ConfigurationWorkbenchCatalogState
    let validationState: ConfigurationWorkbenchValidationState?
    let showsDraftActions: Bool
    let usesCompactOverflow: Bool

    static func resolve(
        profiles: [Profile],
        selectedProfileID: UUID?,
        hasChanges: Bool,
        isLoading: Bool,
        preview: ConfigurationPreview?,
        errorMessage: String?,
        contentWidth: CGFloat
    ) -> Self {
        let options = profiles.map {
            ConfigurationWorkbenchProfileOption(id: $0.id, name: $0.name)
        }
        guard !options.isEmpty else {
            return Self(
                catalogState: .emptyCatalog,
                validationState: nil,
                showsDraftActions: false,
                usesCompactOverflow: false
            )
        }
        guard let selected = options.first(where: { $0.id == selectedProfileID }) else {
            return Self(
                catalogState: .noSelection(options: options),
                validationState: nil,
                showsDraftActions: false,
                usesCompactOverflow: false
            )
        }

        let validationState: ConfigurationWorkbenchValidationState
        if isLoading || (hasChanges && preview == nil && errorMessage == nil) {
            validationState = .validating
        } else if let preview, !preview.validation.issues.isEmpty {
            validationState = .issues(preview.validation.issues.count)
        } else if errorMessage != nil {
            validationState = .issues(1)
        } else if preview != nil {
            validationState = .validated
        } else {
            validationState = .unvalidated
        }

        return Self(
            catalogState: .selected(current: selected, options: options),
            validationState: validationState,
            showsDraftActions: hasChanges,
            usesCompactOverflow: contentWidth
                < ConfigurationWorkbenchLayoutMetrics.toolbarOverflowThreshold
        )
    }
}

nonisolated enum ConfigurationWorkbenchLayoutMetrics {
    static let navigatorMinimumWidth: CGFloat = 190
    static let navigatorIdealWidth: CGFloat = 220
    static let navigatorMaximumWidth: CGFloat = 280
    static let workAreaMinimumWidth: CGFloat = 340
    static let workAreaIdealWidth: CGFloat = 650
    static let inspectorMinimumWidth: CGFloat = 280
    static let inspectorIdealWidth: CGFloat = 320
    static let inspectorMaximumWidth: CGFloat = 380
    static let overrideControlMinimumWidth: CGFloat = 128
    static let overrideControlIdealWidth: CGFloat = 156
    static let overrideControlMaximumWidth: CGFloat = 184
    static let dividerAllowance: CGFloat = 1
    static let toolbarOverflowThreshold: CGFloat = 900

    static var primaryMinimumWidth: CGFloat {
        navigatorMinimumWidth + dividerAllowance + workAreaMinimumWidth
    }

    static var threePaneMinimumWidth: CGFloat {
        primaryMinimumWidth + dividerAllowance + inspectorMinimumWidth
    }

    static func inspectorFits(contentWidth: CGFloat) -> Bool {
        contentWidth >= threePaneMinimumWidth
    }
}

struct ConfigurationWorkbenchModeBar: View {
    @Binding var mode: ConfigurationWorkbenchMode
    let status: ConfigurationWorkbenchStatus
    @Binding var searchText: String
    @Binding var isSearchPresented: Bool

    var body: some View {
        VStack(spacing: VelaSpacing.xSmall) {
            HStack(spacing: VelaSpacing.medium) {
                Picker(
                    VelaL10n.string("configuration.mode.title", defaultValue: "Work Area"),
                    selection: $mode
                ) {
                    ForEach(ConfigurationWorkbenchMode.allCases) { value in
                        Text(value.title).tag(value)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: 430)
                .accessibilityIdentifier("configuration.mode")

                Spacer(minLength: VelaSpacing.small)

                Text(status.label)
                    .font(VelaTypography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if isSearchPresented {
                HStack(spacing: VelaSpacing.small) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField(
                        VelaL10n.string(
                            "configuration.searchPath.placeholder",
                            defaultValue: "Path, rule, or value"
                        ),
                        text: $searchText
                    )
                    .textFieldStyle(.plain)
                    .accessibilityIdentifier("configuration.search")
                    Button {
                        searchText = ""
                        isSearchPresented = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(
                        VelaL10n.string(
                            "configuration.search.close",
                            defaultValue: "Close Search"
                        )
                    )
                }
                .padding(.horizontal, VelaSpacing.small)
                .frame(height: 30)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 7))
            }
        }
        .padding(.horizontal, VelaSpacing.standard)
        .padding(.vertical, VelaSpacing.small)
        .accessibilityIdentifier("configuration.workArea.header")
    }
}

struct ConfigurationRuntimeSafetyWorkspace: View {
    let preview: ConfigurationPreview?

    private var forced: [ConfigurationSemanticDiffEntry] {
        preview?.semanticDiff.filter { $0.source == .velaForced } ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VelaSectionHeader(
                ConfigurationWorkbenchLayer.runtimeSafety.title,
                subtitle: VelaL10n.string(
                    "configuration.runtimeSafety.subtitle",
                    defaultValue: "Protected values enforced by Vela at runtime"
                )
            )
            .padding(VelaSpacing.standard)
            Divider()

            List {
                if forced.isEmpty {
                    LabeledContent(
                        VelaL10n.string("configuration.status.readOnly", defaultValue: "Read only"),
                        value: VelaL10n.string("configuration.status.protected", defaultValue: "Protected")
                    )
                } else {
                    ForEach(forced, id: \.path) { entry in
                        VStack(alignment: .leading, spacing: VelaSpacing.micro) {
                            Text(verbatim: entry.path)
                                .font(VelaTypography.code)
                            Text(VelaL10n.string(
                                "configuration.runtimeSafety.protectedReason",
                                defaultValue: "Vela-owned protected runtime value"
                            ))
                                .font(VelaTypography.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
        .accessibilityIdentifier("configuration.runtimeSafety")
    }
}

struct ConfigurationRulesWorkspace: View {
    let preview: ConfigurationPreview?
    let searchText: String
    @Binding var selection: ConfigurationWorkbenchSelection?

    private var upstream: [ConfigurationRuleRow] {
        filtered(ConfigurationWorkbenchPresentationPolicy.rules(from: preview?.rawYAML, segment: .upstream))
    }
    private var effective: [ConfigurationRuleRow] {
        filtered(ConfigurationWorkbenchPresentationPolicy.rules(from: preview?.finalYAML, segment: .effective))
    }

    var body: some View {
        List {
            Section(VelaL10n.string("configuration.rules.prepend", defaultValue: "Prepend · Vela-owned")) {
                Text(VelaL10n.string(
                    "configuration.rules.noOwnedPrepend",
                    defaultValue: "No owned prepend rules"
                ))
                    .foregroundStyle(.secondary)
            }
            Section(VelaL10n.string("configuration.rules.upstream", defaultValue: "Upstream · Read only")) {
                ruleRows(upstream, effective: false)
            }
            Section(VelaL10n.string("configuration.rules.effective", defaultValue: "Effective Runtime Order")) {
                ruleRows(effective, effective: true)
            }
            Section(VelaL10n.string("configuration.rules.append", defaultValue: "Append · Vela-owned")) {
                Text(VelaL10n.string(
                    "configuration.rules.noOwnedAppend",
                    defaultValue: "No owned append rules"
                ))
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.inset)
        .accessibilityIdentifier("configuration.rules")
    }

    @ViewBuilder
    private func ruleRows(_ rows: [ConfigurationRuleRow], effective: Bool) -> some View {
        if rows.isEmpty {
            Text(VelaL10n.string("configuration.rules.empty", defaultValue: "No rules in this segment"))
                .foregroundStyle(.secondary)
        } else {
            ForEach(rows) { row in
                Button {
                    selection = .rule(index: row.index, effective: effective)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: VelaSpacing.small) {
                        Text(verbatim: String(row.index + 1))
                            .font(VelaTypography.code)
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                        Text(verbatim: row.value)
                            .font(VelaTypography.code)
                            .lineLimit(1)
                            .textSelection(.enabled)
                        Spacer(minLength: VelaSpacing.small)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(
                    selection == .rule(index: row.index, effective: effective)
                        ? Color.accentColor.opacity(0.18) : Color.clear
                )
                .accessibilityIdentifier("configuration.rule.\(effective ? "effective" : "upstream").\(row.index)")
            }
        }
    }

    private func filtered(_ rows: [ConfigurationRuleRow]) -> [ConfigurationRuleRow] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return rows }
        return rows.filter { $0.value.localizedCaseInsensitiveContains(query) }
    }
}

struct ConfigurationDiffWorkspace: View {
    let preview: ConfigurationPreview?
    let searchText: String
    @Binding var selection: ConfigurationWorkbenchSelection?

    private var entries: [ConfigurationSemanticDiffEntry] {
        ConfigurationWorkbenchPresentationPolicy.matchingDiff(in: preview, search: searchText)
    }

    var body: some View {
        List(entries, id: \.path) { entry in
            Button {
                selection = .operation(path: entry.path)
            } label: {
                VStack(alignment: .leading, spacing: VelaSpacing.xSmall) {
                    HStack(spacing: VelaSpacing.small) {
                        VelaStatusPill(
                            status: entry.operation == .remove ? .warning : .info,
                            label: operationLabel(entry.operation)
                        )
                        Text(verbatim: entry.path)
                            .font(VelaTypography.code)
                            .lineLimit(1)
                        Spacer(minLength: VelaSpacing.small)
                        Text(sourceLabel(entry.source))
                            .font(VelaTypography.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(verbatim: "\(entry.beforeDescription ?? "∅") → \(entry.afterDescription ?? "∅")")
                        .font(VelaTypography.code)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowBackground(
                selection == .operation(path: entry.path)
                    ? Color.accentColor.opacity(0.18) : Color.clear
            )
            .accessibilityIdentifier("configuration.diff.\(entry.path)")
        }
        .overlay {
            if entries.isEmpty {
                VelaEmptyState(
                    title: VelaL10n.string("configuration.diff.empty.title", defaultValue: "No Draft Differences"),
                    description: VelaL10n.string(
                        "configuration.diff.empty.description",
                        defaultValue: "The draft matches the committed profile overrides."
                    ),
                    systemImage: "equal.circle"
                )
            }
        }
        .listStyle(.inset)
        .accessibilityIdentifier("configuration.diff")
    }
}

struct ConfigurationWorkbenchInspectorPanel: View {
    let preview: ConfigurationPreview?
    let errorMessage: String?
    let hasProfile: Bool
    let status: ConfigurationWorkbenchStatus
    @Binding var selection: ConfigurationWorkbenchSelection?

    var body: some View {
        VStack(spacing: 0) {
            VelaSectionHeader(inspectorTitle, subtitle: inspectorSubtitle)
                .padding(VelaSpacing.standard)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    inspectorContent
                }
                .padding(.horizontal, VelaSpacing.standard)
            }
        }
        .background(VelaAppearance.controlBackground.opacity(0.30))
        .accessibilityIdentifier("configuration.inspector")
    }

    @ViewBuilder
    private var inspectorContent: some View {
        if !hasProfile {
            emptyInspector(
                title: VelaL10n.string("configuration.inspector.noSelection", defaultValue: "No Selection"),
                detail: VelaL10n.string(
                    "configuration.inspector.noProfile.description",
                    defaultValue: "Select a profile to inspect sources and effective values."
                )
            )
        } else if status.kind == .loading {
            VelaLoadingState(
                title: VelaL10n.string("configuration.status.loading", defaultValue: "Loading…"),
                detail: VelaL10n.string(
                    "configuration.inspector.loading.description",
                    defaultValue: "Selection will be available with the new snapshot."
                )
            )
        } else if let errorMessage, preview == nil {
            VelaInspectorSection(
                title: VelaL10n.string("configuration.inspector.failure", defaultValue: "Configuration Unavailable"),
                showsDivider: false
            ) {
                Text(DiagnosticTextSanitizer.redact(errorMessage))
                    .font(VelaTypography.body)
                    .foregroundStyle(.secondary)
            }
        } else if status.kind == .applying {
            transactionInspector
        } else if let selection {
            selectionInspector(selection)
        } else {
            emptyInspector(
                title: VelaL10n.string("configuration.inspector.noSelection", defaultValue: "No Selection"),
                detail: VelaL10n.string(
                    "configuration.inspector.chooseContext",
                    defaultValue: "Select a layer, change, rule, or diagnostic."
                )
            )
        }
    }

    @ViewBuilder
    private func selectionInspector(_ selection: ConfigurationWorkbenchSelection) -> some View {
        switch selection {
        case let .layer(layer):
            VelaInspectorSection(title: VelaL10n.string("configuration.inspector.layer", defaultValue: "Layer")) {
                valueRow(VelaL10n.string("configuration.inspector.name", defaultValue: "Name"), layer.title)
                valueRow(
                    VelaL10n.string("configuration.inspector.capability", defaultValue: "Capability"),
                    layer.isEditable
                        ? VelaL10n.string("configuration.status.editable", defaultValue: "Editable draft")
                        : VelaL10n.string("configuration.status.readOnly", defaultValue: "Read only")
                )
                valueRow(VelaL10n.string("configuration.inspector.state", defaultValue: "State"), status.label)
            }
        case let .operation(path):
            operationInspector(path: path)
        case let .rule(index, effective):
            ruleInspector(index: index, effective: effective)
        case let .diagnostic(index):
            diagnosticInspector(index: index)
        case .transaction:
            transactionInspector
        case .recovery:
            VelaInspectorSection(title: VelaL10n.string("configuration.inspector.recovery", defaultValue: "Recovery Evidence")) {
                valueRow(VelaL10n.string("configuration.inspector.state", defaultValue: "State"), status.label)
            }
        }
    }

    private func operationInspector(path: String) -> some View {
        let entry = preview?.semanticDiff.first { $0.path == path }
        return VStack(alignment: .leading, spacing: 0) {
            VelaInspectorSection(title: VelaL10n.string("configuration.inspector.changeDetails", defaultValue: "Change Details")) {
                valueRow(VelaL10n.string("configuration.inspector.path", defaultValue: "Path"), path, verbatim: true)
                valueRow(
                    VelaL10n.string("configuration.inspector.operation", defaultValue: "Operation"),
                    entry.map { operationLabel($0.operation) } ?? "—"
                )
                valueRow(
                    VelaL10n.string("configuration.inspector.source", defaultValue: "Source"),
                    entry.map { sourceLabel($0.source) } ?? "—"
                )
            }
            VelaInspectorSection(title: VelaL10n.string("configuration.inspector.values", defaultValue: "Source & Effective Value")) {
                valueRow(
                    VelaL10n.string("configuration.inspector.committedValue", defaultValue: "Committed"),
                    entry?.beforeDescription ?? "∅",
                    verbatim: true
                )
                valueRow(
                    VelaL10n.string("configuration.inspector.draftValue", defaultValue: "Draft / Effective"),
                    entry?.afterDescription ?? "∅",
                    verbatim: true
                )
                valueRow(
                    VelaL10n.string("configuration.inspector.confidence", defaultValue: "Confidence"),
                    VelaL10n.string("configuration.inspector.currentPreview", defaultValue: "Current preview")
                )
            }
        }
    }

    private func ruleInspector(index: Int, effective: Bool) -> some View {
        let segment: ConfigurationRuleRow.Segment = effective ? .effective : .upstream
        let yaml = effective ? preview?.finalYAML : preview?.rawYAML
        let row = ConfigurationWorkbenchPresentationPolicy.rules(from: yaml, segment: segment)
            .first { $0.index == index }
        return VStack(alignment: .leading, spacing: 0) {
            VelaInspectorSection(title: VelaL10n.string("configuration.inspector.ruleSource", defaultValue: "Rule Source")) {
                valueRow(VelaL10n.string("configuration.inspector.runtimeIndex", defaultValue: "Runtime index"), String(index))
                valueRow(
                    VelaL10n.string("configuration.inspector.source", defaultValue: "Source"),
                    effective
                        ? VelaL10n.string("configuration.rules.effective", defaultValue: "Effective Runtime Order")
                        : VelaL10n.string("configuration.rules.upstream", defaultValue: "Upstream · Read only")
                )
                valueRow(VelaL10n.string("configuration.inspector.rule", defaultValue: "Rule"), row?.value ?? "—", verbatim: true)
            }
        }
    }

    private func diagnosticInspector(index: Int) -> some View {
        let issue = preview?.validation.issues.indices.contains(index) == true
            ? preview?.validation.issues[index] : nil
        return VStack(alignment: .leading, spacing: 0) {
            VelaInspectorSection(title: VelaL10n.string("configuration.inspector.diagnostic", defaultValue: "Diagnostic")) {
                valueRow(VelaL10n.string("configuration.inspector.path", defaultValue: "Path"), issue?.path ?? "—", verbatim: true)
                valueRow(VelaL10n.string("configuration.inspector.message", defaultValue: "Message"), issue?.message ?? "—")
            }
        }
    }

    private var transactionInspector: some View {
        VelaInspectorSection(title: VelaL10n.string("configuration.inspector.applyProgress", defaultValue: "Apply Progress")) {
            valueRow(VelaL10n.string("configuration.inspector.phase", defaultValue: "Phase"), status.label)
            valueRow(
                VelaL10n.string("configuration.inspector.committedState", defaultValue: "Committed state"),
                VelaL10n.string("configuration.inspector.unchangedUntilVerified", defaultValue: "Unchanged until verified")
            )
            valueRow(
                VelaL10n.string("configuration.inspector.draftState", defaultValue: "Draft"),
                VelaL10n.string("configuration.inspector.preserved", defaultValue: "Preserved")
            )
        }
    }

    private func emptyInspector(title: String, detail: String) -> some View {
        VelaInspectorSection(title: title, showsDivider: false) {
            Text(detail)
                .font(VelaTypography.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func valueRow(_ label: String, _ value: String, verbatim: Bool = false) -> some View {
        LabeledContent {
            Group {
                if verbatim { Text(verbatim: value) } else { Text(value) }
            }
            .font(verbatim ? VelaTypography.code : VelaTypography.body)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .multilineTextAlignment(.trailing)
        } label: {
            Text(label)
                .font(VelaTypography.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var inspectorTitle: String {
        if status.kind == .applying {
            return VelaL10n.string("configuration.inspector.applyProgress", defaultValue: "Apply Progress")
        }
        switch selection {
        case .operation:
            return VelaL10n.string("configuration.inspector.changeDetails", defaultValue: "Change Details")
        case .rule:
            return VelaL10n.string("configuration.inspector.ruleSource", defaultValue: "Rule Source")
        case .diagnostic:
            return VelaL10n.string("configuration.inspector.diagnostic", defaultValue: "Diagnostic")
        case .recovery:
            return VelaL10n.string("configuration.inspector.recovery", defaultValue: "Recovery Evidence")
        case .transaction:
            return VelaL10n.string("configuration.inspector.applyProgress", defaultValue: "Apply Progress")
        case .layer:
            return VelaL10n.string("configuration.inspector.sourceEffective", defaultValue: "Source & Effective Value")
        case nil:
            return VelaL10n.string("configuration.inspector.noSelection", defaultValue: "No Selection")
        }
    }

    private var inspectorSubtitle: String {
        VelaL10n.string(
            "configuration.inspector.subtitle",
            defaultValue: "Validation, provenance, and redacted output"
        )
    }
}

private func operationLabel(_ operation: ConfigurationDiffOperation) -> String {
    switch operation {
    case .add: VelaL10n.string("configuration.inspector.diff.operation.add", defaultValue: "ADD")
    case .change: VelaL10n.string("configuration.inspector.diff.operation.change", defaultValue: "CHANGE")
    case .remove: VelaL10n.string("configuration.inspector.diff.operation.remove", defaultValue: "REMOVE")
    }
}

private func sourceLabel(_ source: ConfigurationValueSource) -> String {
    switch source {
    case .upstream: VelaL10n.string("configuration.inspector.diff.source.upstream", defaultValue: "Upstream")
    case .velaOverride: VelaL10n.string("configuration.inspector.diff.source.override", defaultValue: "Profile Overrides")
    case .velaForced: VelaL10n.string("configuration.inspector.diff.source.forced", defaultValue: "Runtime Safety")
    }
}
