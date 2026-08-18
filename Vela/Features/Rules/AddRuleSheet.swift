import SwiftUI

struct AddRuleSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale

    let availablePolicies: [String]
    let save: @MainActor (String) async throws -> Void

    @State private var ruleType = "DOMAIN-SUFFIX"
    @State private var payload = ""
    @State private var policy = "DIRECT"
    @State private var noResolve = false
    @State private var isSaving = false
    @State private var errorMessage: String?

    private let commonRuleTypes = [
        "DOMAIN",
        "DOMAIN-SUFFIX",
        "DOMAIN-KEYWORD",
        "GEOSITE",
        "GEOIP",
        "IP-CIDR",
        "IP-CIDR6",
        "SRC-IP-CIDR",
        "DST-PORT",
        "SRC-PORT",
        "PROCESS-NAME",
        "PROCESS-PATH",
        "RULE-SET",
        "NETWORK",
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 42, height: 42)
                    .background(
                        Color.accentColor.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )

                VStack(alignment: .leading, spacing: 3) {
                    Text(strings.title)
                        .font(VelaTypography.pageTitle)
                    Text(strings.subtitle)
                        .font(VelaTypography.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(20)

            Divider()

            Form {
                Picker(strings.type, selection: $ruleType) {
                    ForEach(commonRuleTypes, id: \.self) { type in
                        Text(type).tag(type)
                    }
                }

                TextField(strings.matchValue, text: $payload)
                    .textFieldStyle(.roundedBorder)

                Picker(strings.target, selection: $policy) {
                    ForEach(policyChoices, id: \.self) { value in
                        Text(value).tag(value)
                    }
                }
                TextField(strings.customTarget, text: $policy)
                    .textFieldStyle(.roundedBorder)

                if supportsNoResolve {
                    Toggle(strings.noResolve, isOn: $noResolve)
                }
            }
            .formStyle(.grouped)
            .padding(.horizontal, 8)

            VStack(alignment: .leading, spacing: 6) {
                Text(strings.preview)
                    .font(VelaTypography.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(rulePreview)
                    .font(VelaTypography.code)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(
                        Color(nsColor: .textBackgroundColor).opacity(0.72),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(VelaTypography.caption.weight(.medium))
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
            }

            Divider()

            HStack {
                Text(strings.persistenceHint)
                    .font(VelaTypography.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if isSaving {
                    ProgressView()
                        .controlSize(.small)
                }
                Button(strings.cancel, role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button(strings.add) {
                    addRule()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
            .padding(20)
        }
        .frame(width: 540, height: 520)
        .background(VelaPageCanvas())
        .accessibilityIdentifier("rules.add.sheet")
    }

    private var strings: AddRuleStrings {
        AddRuleStrings(locale: locale)
    }

    private var policyChoices: [String] {
        var choices = ["DIRECT", "REJECT"]
        choices.append(contentsOf: availablePolicies)
        var seen = Set<String>()
        return choices.filter { seen.insert($0).inserted }
    }

    private var supportsNoResolve: Bool {
        ["IP-CIDR", "IP-CIDR6", "SRC-IP-CIDR"].contains(ruleType)
    }

    private var normalizedPayload: String {
        payload.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var normalizedPolicy: String {
        policy.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var rulePreview: String {
        var fields = [ruleType, normalizedPayload, normalizedPolicy]
        if supportsNoResolve, noResolve {
            fields.append("no-resolve")
        }
        return fields.joined(separator: ",")
    }

    private var canSave: Bool {
        !isSaving && !normalizedPayload.isEmpty && !normalizedPolicy.isEmpty
    }

    @MainActor
    private func addRule() {
        guard canSave else { return }
        isSaving = true
        errorMessage = nil
        let rule = rulePreview
        Task {
            defer { isSaving = false }
            do {
                try await save(rule)
                dismiss()
            } catch {
                errorMessage = strings.saveFailed
            }
        }
    }
}

private struct AddRuleStrings {
    private let isChinese: Bool

    init(locale: Locale) {
        isChinese = locale.language.languageCode?.identifier == "zh"
    }

    private func copy(_ english: String, _ chinese: String) -> String {
        isChinese ? chinese : english
    }

    var title: String { copy("Add Rule", "添加规则") }
    var subtitle: String {
        copy(
            "Create a persistent rule for the current configuration.",
            "为当前配置创建一条长期保留的规则。"
        )
    }
    var type: String { copy("Rule Type", "规则类型") }
    var matchValue: String { copy("Match Value", "匹配内容") }
    var target: String { copy("Target", "目标策略") }
    var customTarget: String { copy("Target or Proxy Group", "目标或代理组") }
    var noResolve: String { copy("Do not resolve hostnames", "不解析主机名") }
    var preview: String { copy("Rule Preview", "规则预览") }
    var persistenceHint: String {
        copy(
            "Saved as an override so subscription updates do not remove it.",
            "规则会保存为覆盖项，订阅更新不会将其移除。"
        )
    }
    var cancel: String { copy("Cancel", "取消") }
    var add: String { copy("Add", "添加") }
    var saveFailed: String {
        copy(
            "The rule could not be validated and applied.",
            "规则未能通过验证并应用，请检查内容后重试。"
        )
    }
}
