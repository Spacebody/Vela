import SwiftUI

struct VelaInspectorSection<Content: View>: View {
    let title: String
    var subtitle: String?
    var help: String?
    var showsDivider: Bool
    private let content: Content

    init(
        title: String,
        subtitle: String? = nil,
        help: String? = nil,
        showsDivider: Bool = true,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.help = help
        self.showsDivider = showsDivider
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: VelaSpacing.medium) {
            HStack(alignment: .firstTextBaseline, spacing: VelaSpacing.xSmall) {
                VStack(alignment: .leading, spacing: VelaSpacing.micro) {
                    Text(VelaL10n.legacy(title))
                        .font(VelaTypography.sectionTitle)
                        .accessibilityAddTraits(.isHeader)

                    if let subtitle, !subtitle.isEmpty {
                        Text(VelaL10n.legacy(subtitle))
                            .font(VelaTypography.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if let help, !help.isEmpty {
                    Image(systemName: "questionmark.circle")
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                        .help(VelaL10n.legacy(help))
                        .accessibilityLabel(
                            VelaL10n.string(
                                "accessibility.helpFor",
                                defaultValue: "Help for %@",
                                arguments: VelaL10n.legacy(title)
                            )
                        )
                        .accessibilityHint(VelaL10n.legacy(help))
                }

                Spacer(minLength: VelaSpacing.small)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, VelaSpacing.standard)
        .overlay(alignment: .bottom) {
            if showsDivider {
                Divider()
            }
        }
    }
}
