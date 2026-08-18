import SwiftUI

nonisolated struct VelaResultItem: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    var detail: String?
    let status: VelaSemanticStatus

    var needsAttention: Bool {
        status == .error || status == .warning
    }
}

struct VelaResultSummary: View {
    let title: String
    let items: [VelaResultItem]
    var retryTitle = "Retry Failed"
    var retryFailed: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: VelaSpacing.medium) {
            VelaSectionHeader(title, subtitle: summary) {
                if attentionCount > 0, let retryFailed {
                    Button(VelaL10n.legacy(retryTitle), action: retryFailed)
                        .accessibilityHint(
                            VelaL10n.string(
                                "resultSummary.retryFailed.hint",
                                defaultValue: "Retries only the operations that need attention."
                            )
                        )
                }
            }

            ForEach(items) { item in
                HStack(alignment: .firstTextBaseline, spacing: VelaSpacing.small) {
                    Image(systemName: item.status.systemImage)
                        .foregroundStyle(item.status.tint)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: VelaSpacing.micro) {
                        Text(item.title)
                            .font(VelaTypography.body)
                        if let detail = item.detail, !detail.isEmpty {
                            Text(detail)
                                .font(VelaTypography.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer(minLength: VelaSpacing.small)
                    Text(item.status.accessibilityValue)
                        .font(VelaTypography.caption)
                        .foregroundStyle(item.status.tint)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(VelaSpacing.standard)
        .velaPanelSurface()
    }

    private var summary: String {
        if attentionCount == 0 {
            return VelaL10n.string(
                "resultSummary.completed.format",
                defaultValue: "%lld operations completed",
                arguments: Int64(items.count)
            )
        }
        return VelaL10n.string(
            "resultSummary.attention.format",
            defaultValue: "%lld of %lld operations need attention",
            arguments: Int64(attentionCount),
            Int64(items.count)
        )
    }

    private var attentionCount: Int {
        items.count { $0.needsAttention }
    }
}
