import SwiftUI

struct VelaLoadingState: View {
    let title: String
    var detail: String?
    var compact = false

    var body: some View {
        HStack(spacing: VelaSpacing.medium) {
            ProgressView()
                .controlSize(compact ? .small : .regular)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: VelaSpacing.micro) {
                Text(VelaL10n.legacy(title))
                    .font(compact ? VelaTypography.body : VelaTypography.sectionTitle)

                if let detail, !detail.isEmpty {
                    Text(VelaL10n.legacy(detail))
                        .font(VelaTypography.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(compact ? VelaSpacing.small : VelaSpacing.standard)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(VelaL10n.legacy(title))
        .accessibilityValue(
            detail.map { VelaL10n.legacy($0) }
                ?? VelaL10n.string("status.inProgress", defaultValue: "In progress")
        )
    }
}
