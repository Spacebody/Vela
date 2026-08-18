import SwiftUI

struct InlineFeatureError: View {
    let title: String
    let message: String
    var retryTitle = "Try Again"
    var retry: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(VelaL10n.legacy(title))
                    .font(.callout.weight(.semibold))
                Text(VelaL10n.legacy(message))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 12)
            if let retry {
                Button(VelaL10n.legacy(retryTitle), action: retry)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.orange.opacity(0.08))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            VelaL10n.string(
                "accessibility.sentences.format",
                defaultValue: "%@. %@",
                arguments: VelaL10n.legacy(title),
                VelaL10n.legacy(message)
            )
        )
    }
}
