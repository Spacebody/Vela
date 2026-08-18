import SwiftUI

struct PermissionEducationView: View {
  let model: PermissionEducationModel
  let onPrimaryAction: @MainActor () -> Void
  let onNotNow: @MainActor () -> Void
  let onHelp: @MainActor (String) -> Void

  @AccessibilityFocusState private var isHeadingFocused: Bool

  init(
    model: PermissionEducationModel,
    onPrimaryAction: @escaping @MainActor () -> Void = {},
    onNotNow: @escaping @MainActor () -> Void = {},
    onHelp: @escaping @MainActor (String) -> Void = { _ in }
  ) {
    self.model = model
    self.onPrimaryAction = onPrimaryAction
    self.onNotNow = onNotNow
    self.onHelp = onHelp
  }

  var body: some View {
    ZStack {
      VelaPageCanvas()

      VStack(alignment: .leading, spacing: VelaSpacing.standard) {
        HStack(alignment: .top, spacing: VelaSpacing.medium) {
          ZStack {
            RoundedRectangle(cornerRadius: VelaRadius.small, style: .continuous)
              .fill(Color.accentColor.opacity(0.14))
            Image(systemName: systemImage)
              .font(.system(size: 20, weight: .semibold))
              .foregroundStyle(.tint)
              .accessibilityHidden(true)
          }
          .frame(width: 42, height: 42)

          VStack(alignment: .leading, spacing: VelaSpacing.xSmall) {
            Text(model.title)
              .font(VelaTypography.pageTitle)
              .accessibilityAddTraits(.isHeader)
              .accessibilityFocused($isHeadingFocused)
            statusLabel
          }
        }

        VStack(alignment: .leading, spacing: VelaSpacing.medium) {
          educationRow(
            title: VelaL10n.string(
              "permission.education.why",
              defaultValue: "Why Vela asks"
            ),
            detail: model.why
          )
          educationRow(
            title: VelaL10n.string(
              "permission.education.data",
              defaultValue: "Data used"
            ),
            detail: model.dataUsed
          )
          educationRow(
            title: VelaL10n.string(
              "permission.education.when",
              defaultValue: "When it is used"
            ),
            detail: model.whenUsed
          )
          educationRow(
            title: VelaL10n.string(
              "permission.education.revoke",
              defaultValue: "How to revoke access"
            ),
            detail: model.revocationInstructions
          )
        }
        .padding(VelaSpacing.standard)
        .velaPanelSurface(radius: VelaRadius.panel)

        HStack(spacing: VelaSpacing.small) {
          Button(VelaL10n.legacy(primaryActionTitle), action: onPrimaryAction)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
          Button(
            VelaL10n.string(
              "permission.education.notNow",
              defaultValue: "Not Now"
            ),
            action: onNotNow
          )
          .buttonStyle(.bordered)
          .keyboardShortcut(.cancelAction)
          Button(
            VelaL10n.string(
              "permission.education.help",
              defaultValue: "Help"
            )
          ) {
            onHelp(model.helpTopicID)
          }
          .buttonStyle(.bordered)
        }
      }
      .padding(VelaSpacing.large)
      .velaPanelSurface(radius: VelaRadius.onboarding, emphasized: true)
      .padding(VelaSpacing.large)
    }
    .frame(minWidth: 480, idealWidth: 620, maxWidth: 680, alignment: .leading)
    .accessibilityElement(children: .contain)
    .onAppear {
      isHeadingFocused = true
    }
  }

  private var primaryActionTitle: String {
    switch model.status {
    case .denied, .requiresApproval:
      VelaL10n.string(
        "permission.action.openSettings",
        defaultValue: "Open System Settings"
      )
    default:
      model.primaryActionTitle
    }
  }

  private var systemImage: String {
    switch model.topic {
    case .tun: "network.badge.shield.half.filled"
    case .locationSSID: "wifi"
    case .launchAtLogin: "power"
    }
  }

  private var statusLabel: some View {
    Label(VelaL10n.legacy(statusTitle), systemImage: statusImage)
      .font(.callout.weight(.medium))
      .foregroundStyle(statusColor)
      .accessibilityLabel(
        VelaL10n.string(
          "permission.education.status.format",
          defaultValue: "Current status: %@",
          arguments: statusTitle
        )
      )
  }

  private var statusTitle: String {
    switch model.status {
    case .notRequested:
      VelaL10n.string(
        "permission.status.notRequested",
        defaultValue: "Not requested"
      )
    case .available:
      VelaL10n.string(
        "permission.status.available",
        defaultValue: "Available"
      )
    case .denied:
      VelaL10n.string(
        "permission.status.denied",
        defaultValue: "Blocked in System Settings"
      )
    case .requiresApproval:
      VelaL10n.string(
        "permission.status.requiresApproval",
        defaultValue: "Approval required"
      )
    case .enabled:
      VelaL10n.string(
        "permission.status.enabled",
        defaultValue: "Enabled"
      )
    case .unavailable:
      VelaL10n.string(
        "permission.status.unavailable",
        defaultValue: "Unavailable"
      )
    }
  }

  private var statusImage: String {
    switch model.status {
    case .enabled, .available: "checkmark.circle.fill"
    case .denied, .unavailable: "exclamationmark.triangle.fill"
    case .requiresApproval: "person.badge.key.fill"
    case .notRequested: "circle.dashed"
    }
  }

  private var statusColor: Color {
    switch model.status {
    case .enabled, .available: .green
    case .denied, .unavailable: .orange
    case .requiresApproval: .blue
    case .notRequested: .secondary
    }
  }

  private func educationRow(title: String, detail: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title)
        .font(.headline)
      Text(detail)
        .font(.body)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .accessibilityElement(children: .combine)
  }
}
