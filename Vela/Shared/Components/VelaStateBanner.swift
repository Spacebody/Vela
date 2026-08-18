import SwiftUI

nonisolated enum VelaStateBannerKind: String, CaseIterable, Equatable, Hashable, Sendable {
    case info
    case warning
    case error
    case recovery
    case stale
    case permission

    var semanticStatus: VelaSemanticStatus {
        switch self {
        case .info:
            .info
        case .warning:
            .warning
        case .error:
            .error
        case .recovery:
            .info
        case .stale:
            .stale
        case .permission:
            .permission
        }
    }
}

struct VelaStateBanner<Actions: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.velaAccessibilityOverrides) private var accessibilityOverrides
    @State private var dismissedIdentity: BannerIdentity?

    let kind: VelaStateBannerKind
    let title: String
    let detail: String
    private let dismissalID: String?
    private let onDismiss: (() -> Void)?
    private let actions: Actions

    init(
        kind: VelaStateBannerKind,
        title: String,
        detail: String,
        dismissalID: String? = nil,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder actions: () -> Actions
    ) {
        self.kind = kind
        self.title = title
        self.detail = detail
        self.dismissalID = dismissalID
        self.onDismiss = onDismiss
        self.actions = actions()
    }

    var body: some View {
        let identity = BannerIdentity(
            dismissalID: dismissalID,
            kind: kind,
            title: title,
            detail: detail
        )

        Group {
            if dismissedIdentity != identity {
                bannerContent(identity: identity)
            }
        }
        .onChange(of: identity) { _, newIdentity in
            if dismissedIdentity != nil, dismissedIdentity != newIdentity {
                dismissedIdentity = nil
            }
        }
        .animation(
            VelaMotion.animation(VelaMotion.fastSeconds, reduceMotion: usesReducedMotion),
            value: dismissedIdentity
        )
    }

    private func bannerContent(identity: BannerIdentity) -> some View {
        let status = kind.semanticStatus

        return HStack(alignment: .top, spacing: VelaSpacing.medium) {
            Image(systemName: status.systemImage)
                .font(.system(size: VelaTypeSize.body, weight: .semibold))
                .foregroundStyle(status.tint)
                .frame(width: VelaSpacing.standard)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: VelaSpacing.micro) {
                Text(VelaL10n.legacy(title))
                    .font(VelaTypography.sectionTitle)

                Text(VelaL10n.legacy(detail))
                    .font(VelaTypography.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(VelaL10n.legacy(title))
            .accessibilityValue(
                VelaL10n.string(
                    "accessibility.sentences.format",
                    defaultValue: "%@. %@",
                    arguments: status.accessibilityValue,
                    VelaL10n.legacy(detail)
                )
            )

            Spacer(minLength: VelaSpacing.medium)

            HStack(spacing: VelaSpacing.small) {
                actions

                if kind == .error {
                    Button {
                        if let onDismiss {
                            onDismiss()
                        } else {
                            dismissedIdentity = identity
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: VelaTypeSize.caption, weight: .semibold))
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(dismissTitle)
                    .accessibilityLabel(dismissTitle)
                    .accessibilityIdentifier("vela.stateBanner.dismiss")
                }
            }
            .controlSize(.regular)
        }
        .padding(.horizontal, VelaSpacing.medium)
        .padding(.vertical, VelaSpacing.small)
        .background(status.tint.opacity(0.08), in: RoundedRectangle(
            cornerRadius: VelaRadius.small,
            style: .continuous
        ))
        .overlay {
            RoundedRectangle(cornerRadius: VelaRadius.small, style: .continuous)
                .stroke(
                    status.tint.opacity(usesIncreasedContrast ? 0.60 : 0.24),
                    lineWidth: 1
                )
        }
        .accessibilityElement(children: .contain)
        .animation(
            VelaMotion.animation(VelaMotion.fastSeconds, reduceMotion: usesReducedMotion),
            value: kind
        )
    }

    private var dismissTitle: String {
        VelaL10n.string("common.dismiss", defaultValue: "Dismiss")
    }

    private var usesReducedMotion: Bool {
        accessibilityOverrides.reduceMotion ?? reduceMotion
    }

    private var usesIncreasedContrast: Bool {
        accessibilityOverrides.increasedContrast ?? (colorSchemeContrast == .increased)
    }

    private struct BannerIdentity: Equatable {
        let dismissalID: String?
        let kind: VelaStateBannerKind
        let title: String
        let detail: String
    }
}

extension VelaStateBanner where Actions == EmptyView {
    init(
        kind: VelaStateBannerKind,
        title: String,
        detail: String,
        dismissalID: String? = nil,
        onDismiss: (() -> Void)? = nil
    ) {
        self.kind = kind
        self.title = title
        self.detail = detail
        self.dismissalID = dismissalID
        self.onDismiss = onDismiss
        actions = EmptyView()
    }
}
