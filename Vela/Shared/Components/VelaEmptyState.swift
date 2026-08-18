import SwiftUI

struct VelaEmptyState<Action: View>: View {
    let title: String
    let description: String
    let systemImage: String
    var accessibilityText: String?
    private let action: Action

    init(
        title: String,
        description: String,
        systemImage: String,
        accessibilityText: String? = nil,
        @ViewBuilder action: () -> Action
    ) {
        self.title = title
        self.description = description
        self.systemImage = systemImage
        self.accessibilityText = accessibilityText
        self.action = action()
    }

    var body: some View {
        VStack(spacing: VelaSpacing.medium) {
            Image(systemName: systemImage)
                .font(.system(size: VelaMetrics.emptyStateSymbolSize, weight: .regular))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            VStack(spacing: VelaSpacing.xSmall) {
                Text(VelaL10n.legacy(title))
                    .font(VelaTypography.sectionTitle)
                    .accessibilityAddTraits(.isHeader)

                Text(VelaL10n.legacy(description))
                    .font(VelaTypography.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 560)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilitySummary)

            action
                .controlSize(.regular)
        }
        .padding(VelaSpacing.large)
        .frame(
            maxWidth: .infinity,
            minHeight: VelaMetrics.emptyStateMinimumHeight,
            alignment: .center
        )
        .accessibilityElement(children: .contain)
    }

    private var accessibilitySummary: String {
        if let accessibilityText {
            return VelaL10n.legacy(accessibilityText)
        }
        return VelaL10n.string(
            "accessibility.sentences.format",
            defaultValue: "%@. %@",
            arguments: VelaL10n.legacy(title),
            VelaL10n.legacy(description)
        )
    }
}

extension VelaEmptyState where Action == EmptyView {
    init(
        title: String,
        description: String,
        systemImage: String,
        accessibilityText: String? = nil
    ) {
        self.title = title
        self.description = description
        self.systemImage = systemImage
        self.accessibilityText = accessibilityText
        action = EmptyView()
    }
}
