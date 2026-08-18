import AppKit
import SwiftUI

nonisolated enum VelaSpacing {
  static let micro: CGFloat = 2
  static let xSmall: CGFloat = 4
  static let small: CGFloat = 8
  static let medium: CGFloat = 12
  static let standard: CGFloat = 16
  static let section: CGFloat = 20
  static let large: CGFloat = 24
  static let xLarge: CGFloat = 32
}

nonisolated enum VelaRadius {
  static let small: CGFloat = 8
  static let panel: CGFloat = 12
  static let onboarding: CGFloat = 16
}

nonisolated enum VelaMetrics {
  static let minimumWindow = CGSize(width: 1_040, height: 680)
  static let defaultWindow = CGSize(width: 1_280, height: 820)
  static let largeReferenceWindow = CGSize(width: 1_600, height: 1_000)

  static let applicationSidebarWidth: CGFloat = 240
  static let sidebarMinimumWidth: CGFloat = 208
  static let sidebarIdealWidth: CGFloat = 232
  static let sidebarMaximumWidth: CGFloat = 260

  static let inspectorMinimumWidth: CGFloat = 280
  static let inspectorIdealWidth: CGFloat = 320
  static let inspectorMaximumWidth: CGFloat = 380

  static let sidebarRowHeight: CGFloat = 36
  static let sidebarIconSize: CGFloat = 16
  static let sidebarIconWidth: CGFloat = 20
  static let tableRowHeight: CGFloat = 36
  static let compactControlHeight: CGFloat = 30
  static let regularControlHeight: CGFloat = 32
  static let primaryControlHeight: CGFloat = 36
  static let compactMetricCardMinimumHeight: CGFloat = 82
  static let regularMetricCardMinimumHeight: CGFloat = 96
  static let emptyStateMinimumHeight: CGFloat = 180
  static let emptyStateSymbolSize: CGFloat = 28
}

nonisolated enum VelaTableContentState: Equatable, Sendable {
  case loading
  case loaded
  case empty
  case filteredEmpty
  case offline
  case failure

  var usesAlternatingRows: Bool {
    self == .loaded
  }
}

nonisolated enum VelaTypeSize {
  /// Smallest supported text size for dense tables, badges, and diagrams.
  /// macOS interface text must remain legible at 10 pt or larger.
  static let dense: CGFloat = 10
  static let mainPageTitle: CGFloat = 28
  static let pageTitle: CGFloat = 22
  static let sectionTitle: CGFloat = 15
  static let body: CGFloat = 14
  static let table: CGFloat = 13
  static let caption: CGFloat = 12
  static let metric: CGFloat = 20
  static let code: CGFloat = 13
}

enum VelaTypography {
  /// Primary title used at the top of full-size application workspaces.
  static var mainPageTitle: Font {
    .system(size: VelaTypeSize.mainPageTitle, weight: .semibold, design: .rounded)
  }

  /// Supporting copy directly beneath a primary workspace title.
  static var pageSubtitle: Font {
    .system(size: VelaTypeSize.body, weight: .regular)
  }

  static var pageTitle: Font {
    .system(size: VelaTypeSize.pageTitle, weight: .semibold)
  }

  static var sectionTitle: Font {
    .system(size: VelaTypeSize.sectionTitle, weight: .semibold)
  }

  static var body: Font {
    .system(size: VelaTypeSize.body, weight: .regular)
  }

  static var table: Font {
    .system(size: VelaTypeSize.table, weight: .regular)
  }

  static var caption: Font {
    .system(size: VelaTypeSize.caption, weight: .regular)
  }

  static var metric: Font {
    .system(size: VelaTypeSize.metric, weight: .semibold)
  }

  static var code: Font {
    .system(size: VelaTypeSize.code, weight: .regular, design: .monospaced)
  }
}

nonisolated enum VelaMotion {
  static let fastSeconds = 0.12
  static let standardSeconds = 0.18
  static let slowSeconds = 0.24

  static func resolvedDuration(_ duration: Double, reduceMotion: Bool) -> Double {
    reduceMotion ? 0 : duration
  }

  @MainActor
  static func animation(
    _ duration: Double = standardSeconds,
    reduceMotion: Bool
  ) -> Animation? {
    guard !reduceMotion else { return nil }
    return .easeOut(duration: duration)
  }
}

enum VelaAppearance {
  static var windowBackground: Color {
    Color(nsColor: .windowBackgroundColor)
  }

  static var contentBackground: Color {
    Color(nsColor: .textBackgroundColor)
  }

  static var separator: Color {
    Color(nsColor: .separatorColor)
  }

  static var controlBackground: Color {
    Color(nsColor: .controlBackgroundColor)
  }

  static var secondarySurface: Color {
    Color(nsColor: .underPageBackgroundColor)
  }

  static var selectedSurface: Color {
    Color.accentColor.opacity(0.12)
  }
}

/// The application-wide detail canvas, measured from the approved Overview
/// artwork. Every primary destination uses this same canvas so switching tabs
/// never changes the window's base color temperature.
struct VelaPageCanvas: View {
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    LinearGradient(
      colors: canvasColors,
      startPoint: .topLeading,
      endPoint: .bottomTrailing
    )
    .overlay(alignment: .topLeading) {
      Circle()
        .fill(
          Color(red: 34 / 255, green: 143 / 255, blue: 1)
            .opacity(colorScheme == .dark ? 0.075 : 0.022)
        )
        .frame(width: 480, height: 480)
        .blur(radius: 90)
        .offset(x: -170, y: -230)
    }
    .overlay(alignment: .bottomTrailing) {
      Circle()
        .fill(
          Color(red: 142 / 255, green: 76 / 255, blue: 1)
            .opacity(colorScheme == .dark ? 0.045 : 0.014)
        )
        .frame(width: 520, height: 520)
        .blur(radius: 110)
        .offset(x: 180, y: 250)
    }
    .ignoresSafeArea()
  }

  private var canvasColors: [Color] {
    if colorScheme == .dark {
      return [
        Color(red: 18 / 255, green: 24 / 255, blue: 31 / 255),
        Color(red: 24 / 255, green: 31 / 255, blue: 40 / 255),
      ]
    }
    return [
      Color(red: 239 / 255, green: 246 / 255, blue: 253 / 255),
      Color(red: 228 / 255, green: 236 / 255, blue: 244 / 255),
    ]
  }
}

/// The shared glass tone for every primary workspace. The values are measured
/// from the approved Overview surface so changing destinations never changes
/// the perceived color temperature of the window.
struct VelaWorkspaceGlassSurfaceModifier: ViewModifier {
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.velaAccessibilityOverrides) private var accessibilityOverrides

  let radius: CGFloat
  let emphasized: Bool

  // Keep dense workspaces optically neutral. A very transparent blue/green
  // material lets the canvas gradient bleed through differently at each
  // vertical position, so identical panels can appear mint or cyan. The
  // neutral backing preserves Liquid Glass depth without changing hue as a
  // user scrolls between destinations.
  private let glassTint = Color.white
  private let fill = Color(red: 247 / 255, green: 249 / 255, blue: 252 / 255)
  private let stroke = Color.white.opacity(0.82)
  private let shadow = Color(red: 51 / 255, green: 84 / 255, blue: 116 / 255)

  private var usesIncreasedContrast: Bool {
    accessibilityOverrides.increasedContrast ?? (contrast == .increased)
  }

  @ViewBuilder
  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)

    if #available(macOS 26.0, *), !reduceTransparency, !usesIncreasedContrast {
      content
        .background(
          fill.opacity(emphasized ? 0.62 : 0.56),
          in: shape
        )
        .glassEffect(
          .regular.tint(glassTint.opacity(emphasized ? 0.22 : 0.17)),
          in: .rect(cornerRadius: radius)
        )
        .overlay {
          shape.stroke(Color.white.opacity(0.66), lineWidth: 1)
        }
        .clipShape(shape)
        .shadow(
          color: shadow.opacity(emphasized ? 0.055 : 0.035),
          radius: emphasized ? 20 : 15,
          y: emphasized ? 9 : 6
        )
    } else {
      content
        .background(
          fill.opacity(
            reduceTransparency || usesIncreasedContrast
              ? 0.96
              : (emphasized ? 0.94 : 0.91)
          ),
          in: shape
        )
        .background {
          if !reduceTransparency {
            shape.fill(.thinMaterial)
          }
        }
        .overlay {
          shape.stroke(
            stroke.opacity(usesIncreasedContrast ? 1 : 0.86),
            lineWidth: 1
          )
        }
        .clipShape(shape)
        .shadow(
          color: shadow.opacity(emphasized ? 0.07 : 0.045),
          radius: emphasized ? 22 : 16,
          y: emphasized ? 10 : 7
        )
    }
  }
}

private struct VelaPanelSurfaceModifier: ViewModifier {
  let radius: CGFloat
  let emphasized: Bool

  func body(content: Content) -> some View {
    content.modifier(
      VelaWorkspaceGlassSurfaceModifier(
        radius: radius,
        emphasized: emphasized
      )
    )
  }
}

private struct VelaEmptyStateActionModifier: ViewModifier {
  let minimumWidth: CGFloat

  func body(content: Content) -> some View {
    content
      .font(VelaTypography.body.weight(.medium))
      .controlSize(.regular)
      .frame(
        minWidth: minimumWidth,
        minHeight: VelaMetrics.primaryControlHeight
      )
  }
}

private struct VelaPageRootModifier: ViewModifier {
  func body(content: Content) -> some View {
    content.frame(
      maxWidth: .infinity,
      maxHeight: .infinity,
      alignment: .topLeading
    )
    .textSelection(.enabled)
    .velaContainsNestedScrolling()
  }
}

/// A compact, native recovery action group shared by page-level empty states.
/// The primary action keeps the system prominent treatment while the secondary
/// action stays visually subordinate with the native borderless treatment.
struct PageRecoveryActions: View {
  struct SecondaryAction {
    let title: String
    let systemImage: String?
    let accessibilityIdentifier: String
    let accessibilityHint: String
    let action: () -> Void
  }

  let primaryTitle: String
  let pendingTitle: String
  let primarySystemImage: String
  let isPending: Bool
  let isPrimaryEnabled: Bool
  let primaryMinimumWidth: CGFloat
  let primaryAccessibilityIdentifier: String
  let primaryAccessibilityHint: String
  var primaryAccessibilityValue: String?
  let primaryAction: () -> Void
  var secondaryAction: SecondaryAction?

  var body: some View {
    HStack(spacing: VelaSpacing.medium) {
      primaryButton

      if let secondaryAction {
        Button(action: secondaryAction.action) {
          HStack(spacing: VelaSpacing.xSmall) {
            Text(secondaryAction.title)
            if let systemImage = secondaryAction.systemImage {
              Image(systemName: systemImage)
                .accessibilityHidden(true)
            }
          }
          .frame(minHeight: 30, maxHeight: 32)
          .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .controlSize(.regular)
        .accessibilityHint(secondaryAction.accessibilityHint)
        .accessibilityIdentifier(secondaryAction.accessibilityIdentifier)
      }
    }
    .padding(.top, 6)
  }

  @ViewBuilder
  private var primaryButton: some View {
    if let primaryAccessibilityValue {
      primaryButtonBase
        .accessibilityValue(Text(verbatim: primaryAccessibilityValue))
    } else {
      primaryButtonBase
    }
  }

  private var primaryButtonBase: some View {
    Button(action: primaryAction) {
      HStack(spacing: VelaSpacing.small) {
        if isPending {
          ProgressView()
            .controlSize(.small)
            .accessibilityHidden(true)
        } else {
          Image(systemName: primarySystemImage)
            .accessibilityHidden(true)
        }
        Text(isPending ? pendingTitle : primaryTitle)
          .lineLimit(1)
      }
      .frame(
        minWidth: primaryMinimumWidth,
        minHeight: 22,
        maxHeight: 22
      )
    }
    .buttonStyle(.borderedProminent)
    .controlSize(.regular)
    .keyboardShortcut(.defaultAction)
    .disabled(isPending || !isPrimaryEnabled)
    .help(primaryAccessibilityHint)
    .accessibilityLabel(isPending ? pendingTitle : primaryTitle)
    .accessibilityHint(primaryAccessibilityHint)
    .accessibilityIdentifier(primaryAccessibilityIdentifier)
  }
}

extension View {
  func velaPageRoot() -> some View {
    modifier(VelaPageRootModifier())
  }

  func velaPanelSurface(
    radius: CGFloat = VelaRadius.panel,
    emphasized: Bool = false
  ) -> some View {
    modifier(VelaPanelSurfaceModifier(radius: radius, emphasized: emphasized))
  }

  func velaWorkspaceGlassSurface(
    radius: CGFloat,
    emphasized: Bool = false
  ) -> some View {
    modifier(
      VelaWorkspaceGlassSurfaceModifier(
        radius: radius,
        emphasized: emphasized
      )
    )
  }

  func velaEmptyStateAction(minimumWidth: CGFloat = 112) -> some View {
    modifier(VelaEmptyStateActionModifier(minimumWidth: minimumWidth))
  }
}

nonisolated struct VelaAccessibilityOverrides: Equatable, Sendable {
  var reduceMotion: Bool?
  var increasedContrast: Bool?

  static let system = VelaAccessibilityOverrides(
    reduceMotion: nil,
    increasedContrast: nil
  )
}

private struct VelaAccessibilityOverridesKey: EnvironmentKey {
  static let defaultValue = VelaAccessibilityOverrides.system
}

extension EnvironmentValues {
  var velaAccessibilityOverrides: VelaAccessibilityOverrides {
    get { self[VelaAccessibilityOverridesKey.self] }
    set { self[VelaAccessibilityOverridesKey.self] = newValue }
  }
}
