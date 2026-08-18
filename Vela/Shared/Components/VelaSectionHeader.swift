import SwiftUI

struct VelaSectionHeader<Accessory: View>: View {
    let title: String
    var subtitle: String?
    var help: String?
    private let accessory: Accessory

    init(
        _ title: String,
        subtitle: String? = nil,
        help: String? = nil,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.title = title
        self.subtitle = subtitle
        self.help = help
        self.accessory = accessory()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: VelaSpacing.medium) {
            VStack(alignment: .leading, spacing: VelaSpacing.micro) {
                HStack(spacing: VelaSpacing.xSmall) {
                    Text(VelaL10n.legacy(title))
                        .font(VelaTypography.sectionTitle)
                        .accessibilityAddTraits(.isHeader)

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
                }

                if let subtitle, !subtitle.isEmpty {
                    Text(VelaL10n.legacy(subtitle))
                        .font(VelaTypography.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: VelaSpacing.small)
            accessory
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension VelaSectionHeader where Accessory == EmptyView {
    init(_ title: String, subtitle: String? = nil, help: String? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.help = help
        accessory = EmptyView()
    }
}
