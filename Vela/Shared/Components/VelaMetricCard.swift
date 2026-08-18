import SwiftUI

nonisolated enum VelaMetricCardDensity: String, CaseIterable, Equatable, Hashable, Sendable {
    case compact
    case regular

    var minimumHeight: CGFloat {
        switch self {
        case .compact:
            VelaMetrics.compactMetricCardMinimumHeight
        case .regular:
            VelaMetrics.regularMetricCardMinimumHeight
        }
    }
}

struct VelaMetricCard<Action: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.velaAccessibilityOverrides) private var accessibilityOverrides

    let title: String
    let value: String
    var secondaryText: String?
    var status: VelaSemanticStatus?
    var statusLabel: String?
    var density: VelaMetricCardDensity
    var accessibilityText: String?

    private let hasAction: Bool
    private let action: Action

    init(
        title: String,
        value: String,
        secondaryText: String? = nil,
        status: VelaSemanticStatus? = nil,
        statusLabel: String? = nil,
        density: VelaMetricCardDensity = .regular,
        accessibilityText: String? = nil,
        @ViewBuilder action: () -> Action
    ) {
        self.title = title
        self.value = value
        self.secondaryText = secondaryText
        self.status = status
        self.statusLabel = statusLabel
        self.density = density
        self.accessibilityText = accessibilityText
        hasAction = true
        self.action = action()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: VelaSpacing.small) {
            HStack(alignment: .firstTextBaseline, spacing: VelaSpacing.small) {
                Text(VelaL10n.legacy(title))
                    .font(VelaTypography.sectionTitle)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer(minLength: VelaSpacing.small)

                if let status {
                    VelaStatusPill(
                        status: status,
                        label: statusLabel ?? status.accessibilityValue
                    )
                }

                action
            }

            Text(value)
                .font(VelaTypography.metric)
                .monospacedDigit()
                .lineLimit(1)
                .truncationMode(.middle)

            if let secondaryText, !secondaryText.isEmpty {
                Text(VelaL10n.legacy(secondaryText))
                    .font(VelaTypography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(density == .compact ? 1 : 2)
            }
        }
        .padding(VelaSpacing.medium)
        .frame(
            maxWidth: .infinity,
            minHeight: density.minimumHeight,
            alignment: .topLeading
        )
        .background(VelaAppearance.controlBackground, in: RoundedRectangle(
            cornerRadius: VelaRadius.panel,
            style: .continuous
        ))
        .overlay {
            RoundedRectangle(cornerRadius: VelaRadius.panel, style: .continuous)
                .stroke(
                    VelaAppearance.separator.opacity(
                        usesIncreasedContrast ? 0.95 : 0.65
                    ),
                    lineWidth: 1
                )
        }
        .accessibilityElement(children: hasAction ? .contain : .ignore)
        .accessibilityLabel(accessibilityText ?? accessibilitySummary)
        .animation(
            VelaMotion.animation(reduceMotion: usesReducedMotion),
            value: value
        )
    }

    private var accessibilitySummary: String {
        [title, value, secondaryText, status?.accessibilityValue]
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

extension VelaMetricCard where Action == EmptyView {
    init(
        title: String,
        value: String,
        secondaryText: String? = nil,
        status: VelaSemanticStatus? = nil,
        statusLabel: String? = nil,
        density: VelaMetricCardDensity = .regular,
        accessibilityText: String? = nil
    ) {
        self.title = title
        self.value = value
        self.secondaryText = secondaryText
        self.status = status
        self.statusLabel = statusLabel
        self.density = density
        self.accessibilityText = accessibilityText
        hasAction = false
        action = EmptyView()
    }
}
