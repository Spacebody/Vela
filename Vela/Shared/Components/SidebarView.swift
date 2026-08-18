import AppKit
import SwiftUI

struct SidebarView: View {
    static let width = VelaMetrics.applicationSidebarWidth

    @Binding var selection: AppSection?
    let isServiceRunning: Bool
    let coreVersion: String
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.colorScheme) private var colorScheme

    private let primarySections: [AppSection] = [
        .overview,
        .proxies,
        .connections,
        .rules,
        .configuration,
        .unlockTests,
        .logs,
        .settings,
    ]

    var body: some View {
        GeometryReader { proxy in
            let isCompact = proxy.size.height < 760

            VStack(spacing: 0) {
                brandHeader

                VStack(spacing: isCompact ? 6 : 8) {
                    ForEach(primarySections) { section in
                        navigationButton(for: section, isCompact: isCompact)
                    }

                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // The navigation set is deliberately a fixed stack. AppKit's
                // source-list backing store can retain a clip-view offset while
                // changing destinations, even when SwiftUI scrolling is disabled.
                // A non-scrolling stack keeps the sidebar's own content extent
                // deterministic while feature pages change selection and focus.
                .padding(.horizontal, 15)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("sidebar.navigation")

                Spacer(minLength: isCompact ? 4 : VelaSpacing.section)
                serviceFooter(isCompact: isCompact)
            }
            // Fill the fixed app-shell column so service state remains pinned to
            // the bottom without inheriting destination scroll positions.
            .frame(width: Self.width)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(sidebarBackground)
            .background(.thinMaterial)
        }
        .frame(width: Self.width)
        .fixedSize(horizontal: true, vertical: false)
        .layoutPriority(1)
    }

    private var brandHeader: some View {
        HStack(alignment: .top, spacing: 12) {
            Image("VelaSailLogo")
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 58, height: 58)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: VelaSpacing.xSmall) {
                Text(VelaL10n.string("legacy.vela", defaultValue: "Vela"))
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(Color.primary)

                Text(
                    VelaL10n.string(
                        "sidebar.brand.subtitle",
                        defaultValue: "A native Mihomo\nnetwork proxy client"
                    )
                )
                .font(.system(size: 12.5, weight: .regular))
                .foregroundStyle(Color.secondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 10)

            Spacer(minLength: 0)
        }
        .padding(.leading, 32)
        .padding(.trailing, 12)
        .padding(
            .top,
            VelaWindowSizePolicy.measuredUnifiedChromeSize.height + 24
        )
        .padding(.bottom, 24)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("sidebar.brand")
    }

    private func serviceFooter(isCompact: Bool) -> some View {
        VStack(alignment: .center, spacing: VelaSpacing.small) {
            HStack(spacing: VelaSpacing.small) {
                Circle()
                    .fill(isServiceRunning ? serviceRunningColor : Color.secondary)
                    .frame(width: 10, height: 10)
                    .shadow(
                        color: isServiceRunning
                            ? serviceRunningColor.opacity(0.58)
                            : .clear,
                        radius: 7
                    )
                    .accessibilityHidden(true)

                Text(
                    isServiceRunning
                        ? VelaL10n.string(
                            "sidebar.service.running",
                            defaultValue: "Connected"
                        )
                        : VelaL10n.string(
                            "sidebar.service.stopped",
                            defaultValue: "Disconnected"
                        )
                )
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.primary.opacity(0.86))
            }

            Text(
                VelaL10n.string(
                    "sidebar.core.versionFormat",
                    defaultValue: "mihomo • %@",
                    arguments: coreVersion
                )
            )
                .font(VelaTypography.caption)
                .foregroundStyle(Color.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, isCompact ? 8 : 12)
        .frame(maxWidth: .infinity, alignment: .center)
        .background(Color.white.opacity(selection == .overview ? 0.38 : 0.52))
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.white.opacity(0.72))
                .frame(height: 1)
        }
        .frame(
            maxWidth: .infinity,
            minHeight: isCompact ? 60 : 76,
            maxHeight: isCompact ? 64 : 84,
            alignment: .center
        )
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("sidebar.service")
    }

    private func navigationButton(for section: AppSection, isCompact: Bool) -> some View {
        let isSelected = selection == section

        return Button {
            selection = section
        } label: {
            navigationLabel(
                title: sidebarTitle(for: section),
                systemImage: sidebarSystemImage(for: section),
                isSelected: isSelected,
                isCompact: isCompact
            )
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(selectedBackground)
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(
                                    selectedBorder,
                                    lineWidth: 1
                                )
                        }
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sidebar.\(section.rawValue)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func navigationLabel(
        title: String,
        systemImage: String,
        isSelected: Bool,
        isCompact: Bool
    ) -> some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(isSelected ? selectedIconForeground : Color.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)

            Text(title)
                .font(.system(size: 16, weight: .regular))
                .fontWeight(isSelected ? .medium : .regular)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .foregroundStyle(isSelected ? selectedForeground : Color.primary.opacity(0.82))
        .padding(.horizontal, VelaSpacing.section)
        .frame(
            maxWidth: .infinity,
            minHeight: isCompact ? 52 : 58,
            alignment: .leading
        )
        .contentShape(.rect)
    }

    private func sidebarTitle(for section: AppSection) -> String {
        if section == .configuration {
            return VelaL10n.string(
                "sidebar.configurationWorkbench",
                defaultValue: "Configuration Workbench"
            )
        }
        return section.title
    }

    private func sidebarSystemImage(for section: AppSection) -> String {
        switch section {
        case .proxies:
            "globe"
        case .connections:
            "point.3.connected.trianglepath.dotted"
        case .configuration:
            "puzzlepiece.extension"
        default:
            section.systemImage
        }
    }

    private var selectedBackground: Color {
        Color(red: 220 / 255, green: 248 / 255, blue: 250 / 255)
            .opacity(controlActiveState == .inactive ? 0.78 : 0.94)
    }

    private var selectedForeground: Color {
        Color.primary.opacity(controlActiveState == .inactive ? 0.88 : 0.96)
    }

    private var selectedIconForeground: Color {
        Color(red: 0 / 255, green: 125 / 255, blue: 145 / 255)
            .opacity(controlActiveState == .inactive ? 0.90 : 1)
    }

    private var selectedBorder: Color {
        Color(red: 83 / 255, green: 220 / 255, blue: 224 / 255)
            .opacity(controlActiveState == .inactive ? 0.16 : 0.24)
    }

    private var sidebarBackground: some View {
        let colors: [Color]
        if colorScheme == .dark {
            colors = [
                Color(red: 22 / 255, green: 31 / 255, blue: 37 / 255).opacity(0.98),
                Color(red: 17 / 255, green: 25 / 255, blue: 31 / 255).opacity(0.96),
            ]
        } else {
            colors = [
                Color(red: 245 / 255, green: 251 / 255, blue: 252 / 255).opacity(0.98),
                Color(red: 238 / 255, green: 248 / 255, blue: 249 / 255).opacity(0.96),
            ]
        }

        return LinearGradient(
            colors: colors,
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var serviceRunningColor: Color {
        Color(red: 70 / 255, green: 215 / 255, blue: 169 / 255)
    }
}
