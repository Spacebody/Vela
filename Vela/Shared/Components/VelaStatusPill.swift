import SwiftUI

struct VelaStatusPill: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.velaAccessibilityOverrides) private var accessibilityOverrides

    let status: VelaSemanticStatus
    let label: String
    var detail: String?
    var accessibilityText: String?

    var body: some View {
        HStack(spacing: VelaSpacing.xSmall) {
            Image(systemName: status.systemImage)
                .imageScale(.small)
                .accessibilityHidden(true)

            Text(VelaL10n.legacy(label))
                .font(VelaTypography.caption.weight(.semibold))
                .lineLimit(1)

            if let detail, !detail.isEmpty {
                Text(verbatim: "·")
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                Text(VelaL10n.legacy(detail))
                    .font(VelaTypography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .foregroundStyle(status.tint)
        .padding(.horizontal, VelaSpacing.small)
        .padding(.vertical, VelaSpacing.xSmall)
        .background(status.tint.opacity(0.10), in: Capsule())
        .overlay {
            Capsule()
                .stroke(
                    status.tint.opacity(usesIncreasedContrast ? 0.55 : 0.24),
                    lineWidth: 1
                )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            accessibilityText.map { VelaL10n.legacy($0) }
                ?? VelaL10n.legacy(label)
        )
        .accessibilityValue(accessibilityValue)
        .animation(
            VelaMotion.animation(VelaMotion.fastSeconds, reduceMotion: usesReducedMotion),
            value: status
        )
    }

    private var accessibilityValue: String {
        [status.accessibilityValue, detail.map { VelaL10n.legacy($0) }]
            .compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: ", ")
    }

    private var usesReducedMotion: Bool {
        accessibilityOverrides.reduceMotion ?? reduceMotion
    }

    private var usesIncreasedContrast: Bool {
        accessibilityOverrides.increasedContrast ?? (colorSchemeContrast == .increased)
    }
}
