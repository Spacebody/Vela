import SwiftUI
import UniformTypeIdentifiers

struct OnboardingFlowView: View {
  @Bindable private var coordinator: OnboardingCoordinator
  private let onFinished: @MainActor () -> Void
  private let onSkipped: @MainActor () -> Void

  @State private var isImporterPresented = false
  @State private var actionTask: Task<Void, Never>?
  @FocusState private var isPrimaryButtonFocused: Bool
  @AccessibilityFocusState private var isHeadingFocused: Bool

  init(
    coordinator: OnboardingCoordinator,
    onFinished: @escaping @MainActor () -> Void = {},
    onSkipped: @escaping @MainActor () -> Void = {}
  ) {
    self.coordinator = coordinator
    self.onFinished = onFinished
    self.onSkipped = onSkipped
  }

  var body: some View {
    ZStack {
      VelaPageCanvas()

      VStack(spacing: VelaSpacing.medium) {
        header

        HStack(alignment: .top, spacing: VelaSpacing.medium) {
          stepRail
          stepBody
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)

        footer
      }
      .padding(VelaSpacing.large)
    }
    .frame(minWidth: 760, idealWidth: 900, minHeight: 540, idealHeight: 640)
    .fileImporter(
      isPresented: $isImporterPresented,
      allowedContentTypes: Self.configurationContentTypes,
      allowsMultipleSelection: false,
      onCompletion: handleImportResult
    )
    .onAppear {
      isPrimaryButtonFocused = true
      isHeadingFocused = true
    }
    .onChange(of: coordinator.currentStepID) {
      coordinator.clearConfigurationActionState()
      isPrimaryButtonFocused = true
      isHeadingFocused = true
    }
    .onDisappear {
      actionTask?.cancel()
      actionTask = nil
    }
  }

  private var header: some View {
    HStack(spacing: VelaSpacing.medium) {
      ZStack {
        RoundedRectangle(cornerRadius: VelaRadius.small, style: .continuous)
          .fill(Color.accentColor.opacity(0.14))
        Image(systemName: "sailboat.fill")
          .font(.system(size: 18, weight: .semibold))
          .foregroundStyle(.tint)
          .accessibilityHidden(true)
      }
      .frame(width: 40, height: 40)

      VStack(alignment: .leading, spacing: 2) {
        Text(
          coordinator.flowMode == .tour
            ? VelaL10n.string(
              "onboarding.header.tour",
              defaultValue: "Vela Tour"
            )
            : VelaL10n.string(
              "onboarding.header.setup",
              defaultValue: "Set Up Vela"
            )
        )
        .font(VelaTypography.sectionTitle)
        Text(onboardingProgressText)
          .font(VelaTypography.caption)
          .foregroundStyle(.secondary)
          .accessibilityLabel(onboardingProgressText)
      }
      Spacer()
      if coordinator.isBusy {
        ProgressView()
          .controlSize(.small)
          .accessibilityLabel(
            VelaL10n.string(
              "onboarding.status.working",
              defaultValue: "Working"
            )
          )
      }
    }
    .padding(.horizontal, VelaSpacing.standard)
    .padding(.vertical, VelaSpacing.medium)
    .background(
      .ultraThinMaterial,
      in: RoundedRectangle(cornerRadius: VelaRadius.onboarding, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: VelaRadius.onboarding, style: .continuous)
        .stroke(VelaAppearance.separator.opacity(0.6), lineWidth: 1)
    }
  }

  private var onboardingProgressText: String {
    VelaL10n.string(
      "onboarding.progress.format",
      defaultValue: "Step %@ of %@",
      arguments: coordinator.currentStepID.ordinal.formatted(.number),
      OnboardingStepID.allCases.count.formatted(.number)
    )
  }

  private var stepRail: some View {
    VStack(alignment: .leading, spacing: 4) {
      ForEach(OnboardingStepID.allCases) { stepID in
        HStack(spacing: 10) {
          Image(systemName: railImage(for: stepID))
            .foregroundStyle(railColor(for: stepID))
            .frame(width: 18)
            .accessibilityHidden(true)
          Text(stepID.shortTitle)
            .font(
              .callout.weight(
                stepID == coordinator.currentStepID ? .semibold : .regular
              )
            )
            .foregroundStyle(
              stepID == coordinator.currentStepID ? .primary : .secondary
            )
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
          Spacer(minLength: 0)
        }
        .padding(.horizontal, VelaSpacing.medium)
        .padding(.vertical, VelaSpacing.small)
        .frame(minHeight: 38)
        .background(
          stepID == coordinator.currentStepID
            ? Color.accentColor.opacity(0.12)
            : Color.clear,
          in: RoundedRectangle(cornerRadius: VelaRadius.small, style: .continuous)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(railAccessibilityLabel(for: stepID))
      }
      Spacer()
    }
    .padding(VelaSpacing.medium)
    .frame(minWidth: 188, idealWidth: 212, maxWidth: 220, maxHeight: .infinity)
    .velaPanelSurface(radius: VelaRadius.onboarding)
  }

  private var stepBody: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: VelaSpacing.section) {
        Label(
          coordinator.currentStepID.title,
          systemImage: coordinator.currentStepID.icon
        )
        .font(VelaTypography.pageTitle)
        .accessibilityAddTraits(.isHeader)
        .accessibilityFocused($isHeadingFocused)

        Text(coordinator.currentStepID.subtitle)
          .font(VelaTypography.body)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        stepContent

        if let message = coordinator.lastErrorMessage {
          Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.orange)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityLabel(
              VelaL10n.string(
                "onboarding.error.format",
                defaultValue: "Error: %@",
                arguments: message
              )
            )
        }
      }
      .padding(VelaSpacing.large)
      .frame(maxWidth: 720, alignment: .leading)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .scrollIndicators(.automatic)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .velaPanelSurface(radius: VelaRadius.onboarding, emphasized: true)
  }

  @ViewBuilder
  private var stepContent: some View {
    switch coordinator.currentStepID {
    case .welcome:
      WelcomeOnboardingStep()
    case .privacy:
      PrivacyOnboardingStep()
    case .addConfiguration:
      AddConfigurationOnboardingStep(
        actionState: coordinator.configurationActionState,
        isBusy: coordinator.isBusy,
        onImport: { isImporterPresented = true }
      )
    case .validation:
      ValidationOnboardingStep(
        actionState: coordinator.configurationActionState,
        isBusy: coordinator.isBusy,
        onValidate: {
          runAction {
            try await coordinator.validateConfiguration()
          }
        }
      )
    case .networkModeEducation:
      NetworkModeEducationOnboardingStep()
    case .optionalTools:
      OptionalToolsOnboardingStep()
    case .finish:
      FinishOnboardingStep()
    }
  }

  private var footer: some View {
    VStack(alignment: .trailing, spacing: VelaSpacing.xSmall) {
      HStack(spacing: 10) {
        Button(
          VelaL10n.string(
            "onboarding.action.back",
            defaultValue: "Back"
          )
        ) {
          runAction { try await coordinator.goBack() }
        }
        .keyboardShortcut(.leftArrow, modifiers: [.command])
        .buttonStyle(.bordered)
        .disabled(!coordinator.canGoBack || coordinator.isBusy)

        Button(
          VelaL10n.string(
            "onboarding.action.skip",
            defaultValue: "Skip Setup"
          )
        ) {
          runAction {
            try await coordinator.skip()
            onSkipped()
          }
        }
        .keyboardShortcut("s", modifiers: [.command])
        .buttonStyle(.bordered)
        .disabled(coordinator.isBusy)
        .accessibilityHint(
          VelaL10n.string(
            "onboarding.action.skip.hint",
            defaultValue: "Saves this step so setup can be resumed later"
          )
        )

        Spacer()

        Button(primaryButtonTitle) {
          runAction {
            let result = try await coordinator.advance()
            if result == .finished { onFinished() }
          }
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
        .focused($isPrimaryButtonFocused)
        .disabled(coordinator.isBusy)
        .accessibilityHint(primaryButtonHint)
      }

      Text(
        VelaL10n.string(
          "onboarding.network.automatic.none",
          defaultValue: "No network mode is enabled automatically."
        )
      )
      .font(VelaTypography.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
    }
    .padding(.horizontal, VelaSpacing.standard)
    .padding(.vertical, VelaSpacing.medium)
    .background(
      .ultraThinMaterial,
      in: RoundedRectangle(cornerRadius: VelaRadius.onboarding, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: VelaRadius.onboarding, style: .continuous)
        .stroke(VelaAppearance.separator.opacity(0.6), lineWidth: 1)
    }
  }

  private var primaryButtonTitle: String {
    coordinator.currentStepID == .finish
      ? VelaL10n.string(
        "onboarding.action.finish",
        defaultValue: "Finish"
      )
      : VelaL10n.string(
        "onboarding.action.continue",
        defaultValue: "Continue"
      )
  }

  private var primaryButtonHint: String {
    coordinator.currentStepID == .finish
      ? VelaL10n.string(
        "onboarding.action.finish.hint",
        defaultValue: "Completes setup without changing the active network mode"
      )
      : VelaL10n.string(
        "onboarding.action.continue.hint",
        defaultValue: "Moves to the next setup step"
      )
  }

  private func railImage(for stepID: OnboardingStepID) -> String {
    if coordinator.progress.completedStepIDs.contains(stepID) {
      return "checkmark.circle.fill"
    }
    return stepID == coordinator.currentStepID ? "circle.inset.filled" : "circle"
  }

  private func railColor(for stepID: OnboardingStepID) -> Color {
    if coordinator.progress.completedStepIDs.contains(stepID)
      || stepID == coordinator.currentStepID
    {
      return .accentColor
    }
    return .secondary
  }

  private func railAccessibilityLabel(for stepID: OnboardingStepID) -> String {
    let state: String
    if coordinator.progress.completedStepIDs.contains(stepID) {
      state = VelaL10n.string(
        "onboarding.step.state.completed",
        defaultValue: "Completed"
      )
    } else if stepID == coordinator.currentStepID {
      state = VelaL10n.string(
        "onboarding.step.state.current",
        defaultValue: "Current"
      )
    } else {
      state = VelaL10n.string(
        "onboarding.step.state.notCompleted",
        defaultValue: "Not completed"
      )
    }
    return VelaL10n.string(
      "onboarding.step.accessibility.format",
      defaultValue: "Step %@, %@, %@",
      arguments: stepID.ordinal.formatted(.number),
      stepID.shortTitle,
      state
    )
  }

  private func handleImportResult(_ result: Result<[URL], any Error>) {
    guard case .success(let urls) = result, let url = urls.first else { return }
    let accessed = url.startAccessingSecurityScopedResource()
    runAction {
      defer {
        if accessed { url.stopAccessingSecurityScopedResource() }
      }
      try await coordinator.importConfiguration(from: url)
    }
  }

  private func runAction(
    _ operation: @escaping @MainActor @Sendable () async throws -> Void
  ) {
    actionTask?.cancel()
    actionTask = Task { @MainActor in
      do {
        try await operation()
      } catch is CancellationError {
        return
      } catch {
        return
      }
    }
  }

  private static var configurationContentTypes: [UTType] {
    ["yaml", "yml", "json"].compactMap { UTType(filenameExtension: $0) }
      + [.plainText]
  }
}

private struct WelcomeOnboardingStep: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      OnboardingInfoCard(
        icon: "checkmark.shield.fill",
        title: VelaL10n.string(
          "onboarding.welcome.control.title",
          defaultValue: "You stay in control"
        ),
        detail: VelaL10n.string(
          "onboarding.welcome.control.detail",
          defaultValue:
            "Vela will not start a proxy, TUN interface, or background permission during setup."
        )
      )
      OnboardingInfoCard(
        icon: "arrow.triangle.2.circlepath",
        title: VelaL10n.string(
          "onboarding.welcome.resume.title",
          defaultValue: "Safe to pause"
        ),
        detail: VelaL10n.string(
          "onboarding.welcome.resume.detail",
          defaultValue: "Progress is saved locally. You can skip now and resume from the last step."
        )
      )
    }
  }
}

private struct PrivacyOnboardingStep: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      OnboardingInfoCard(
        icon: "internaldrive.fill",
        title: VelaL10n.string(
          "onboarding.privacy.local.title",
          defaultValue: "Local progress only"
        ),
        detail: VelaL10n.string(
          "onboarding.privacy.local.detail",
          defaultValue:
            "Setup progress contains step identifiers and timestamps. It never stores configuration secrets or subscription input."
        )
      )
      OnboardingInfoCard(
        icon: "hand.raised.fill",
        title: VelaL10n.string(
          "onboarding.privacy.permission.title",
          defaultValue: "Permission prompts have context"
        ),
        detail: VelaL10n.string(
          "onboarding.privacy.permission.detail",
          defaultValue:
            "Vela explains why access is needed before macOS is asked. Choosing Not Now remains supported."
        )
      )
    }
  }
}

private struct AddConfigurationOnboardingStep: View {
  let actionState: OnboardingConfigurationActionState
  let isBusy: Bool
  let onImport: @MainActor () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(
        VelaL10n.string(
          "legacy.importingIsOptionalYouCanContinueAndAddAProfileLaterFromSettings",
          defaultValue:
            "Importing is optional. You can continue and add a profile later from Settings.")
      )
      .fixedSize(horizontal: false, vertical: true)

      Button(
        VelaL10n.string("legacy.chooseConfigurationDialog", defaultValue: "Choose Configuration…"),
        action: onImport
      )
      .buttonStyle(.borderedProminent)
      .disabled(isBusy)
      .accessibilityHint(
        VelaL10n.string(
          "legacy.opensAFileChooserForAYamlOrJsonConfiguration",
          defaultValue: "Opens a file chooser for a YAML or JSON configuration"))

      actionStatus
    }
  }

  @ViewBuilder
  private var actionStatus: some View {
    switch actionState {
    case .running(.importConfiguration):
      Label(
        VelaL10n.string(
          "legacy.importingWithVelaSConfigurationTransactionDialog",
          defaultValue: "Importing with Vela's configuration transaction…"),
        systemImage: "hourglass")
    case .succeeded(.importConfiguration):
      Label(
        VelaL10n.string("legacy.configurationImported", defaultValue: "Configuration imported."),
        systemImage: "checkmark.circle.fill"
      )
      .foregroundStyle(.green)
    case .failed(.importConfiguration):
      Label(
        VelaL10n.string(
          "legacy.configurationWasNotImportedYourExistingSetupIsUnchanged",
          defaultValue: "Configuration was not imported. Your existing setup is unchanged."),
        systemImage: "xmark.circle.fill"
      )
      .foregroundStyle(.orange)
    default:
      EmptyView()
    }
  }
}

private struct ValidationOnboardingStep: View {
  let actionState: OnboardingConfigurationActionState
  let isBusy: Bool
  let onValidate: @MainActor () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(
        VelaL10n.string(
          "legacy.validationChecksTheSelectedProfileThroughVelaSExistingEngineTransactionItDoesNotEnableANetworkMode",
          defaultValue:
            "Validation checks the selected profile through Vela's existing engine transaction. It does not enable a network mode."
        )
      )
      .fixedSize(horizontal: false, vertical: true)
      Button(
        VelaL10n.string(
          "legacy.validateSelectedConfiguration", defaultValue: "Validate Selected Configuration"),
        action: onValidate
      )
      .buttonStyle(.borderedProminent)
      .disabled(isBusy)
      validationStatus
    }
  }

  @ViewBuilder
  private var validationStatus: some View {
    switch actionState {
    case .running(.validateConfiguration):
      Label(
        VelaL10n.string("legacy.validatingDialog", defaultValue: "Validating…"),
        systemImage: "hourglass")
    case .succeeded(.validateConfiguration):
      Label(
        VelaL10n.string("legacy.configurationIsValid", defaultValue: "Configuration is valid."),
        systemImage: "checkmark.circle.fill"
      )
      .foregroundStyle(.green)
    case .failed(.validateConfiguration):
      Label(
        VelaL10n.string(
          "legacy.validationDidNotPassYouCanFixTheProfileLater",
          defaultValue: "Validation did not pass. You can fix the profile later."),
        systemImage: "xmark.circle.fill"
      )
      .foregroundStyle(.orange)
    default:
      EmptyView()
    }
  }
}

private struct NetworkModeEducationOnboardingStep: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      OnboardingInfoCard(
        icon: "macwindow",
        title: VelaL10n.string(
          "legacy.systemProxy",
          defaultValue: "System Proxy"
        ),
        detail: VelaL10n.string(
          "onboarding.network.systemProxy.detail",
          defaultValue:
            "Routes apps that honor macOS proxy settings. Enabling it later is an explicit action."
        )
      )
      OnboardingInfoCard(
        icon: "network.badge.shield.half.filled",
        title: VelaL10n.string(
          "legacy.tunMode",
          defaultValue: "TUN Mode"
        ),
        detail: VelaL10n.string(
          "onboarding.network.tun.detail",
          defaultValue:
            "Covers more traffic and requires privileged setup. Vela asks only after you choose TUN and reconfirm."
        )
      )
      Label(
        VelaL10n.string(
          "legacy.continuingThisTourDoesNotStartEitherMode",
          defaultValue: "Continuing this tour does not start either mode."),
        systemImage: "info.circle.fill"
      )
      .font(.callout.weight(.medium))
    }
  }
}

private struct OptionalToolsOnboardingStep: View {
  private let models: [PermissionEducationModel] = [
    .tun(),
    .locationSSID(),
    .launchAtLogin(),
  ]

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      ForEach(models) { model in
        HStack(alignment: .top, spacing: 12) {
          Image(systemName: icon(for: model.topic))
            .foregroundStyle(.tint)
            .frame(width: 22)
            .accessibilityHidden(true)
          VStack(alignment: .leading, spacing: 3) {
            Text(model.title)
              .font(.headline)
            Text(model.whenUsed)
              .font(.callout)
              .foregroundStyle(.secondary)
          }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
          VelaAppearance.controlBackground.opacity(0.58),
          in: RoundedRectangle(cornerRadius: VelaRadius.small, style: .continuous)
        )
        .overlay {
          RoundedRectangle(cornerRadius: VelaRadius.small, style: .continuous)
            .stroke(VelaAppearance.separator.opacity(0.45), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
          VelaL10n.string(
            "permission.education.card.accessibility.format",
            defaultValue: "%@. Not requested during onboarding. %@",
            arguments: model.title,
            model.whenUsed
          )
        )
      }
    }
  }

  private func icon(for topic: PermissionEducationTopic) -> String {
    switch topic {
    case .tun: "network.badge.shield.half.filled"
    case .locationSSID: "wifi"
    case .launchAtLogin: "power"
    }
  }
}

private struct FinishOnboardingStep: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Label(
        VelaL10n.string("legacy.setupIsReadyToFinish", defaultValue: "Setup is ready to finish"),
        systemImage: "checkmark.seal.fill"
      )
      .font(.title2.weight(.semibold))
      .foregroundStyle(.green)
      Text(
        VelaL10n.string(
          "legacy.finishingSavesOnboardingProgressOnlyNoProxyTunInterfaceLocationAccessOrLoginItemIsEnabled",
          defaultValue:
            "Finishing saves onboarding progress only. No proxy, TUN interface, location access, or login item is enabled."
        )
      )
      .fixedSize(horizontal: false, vertical: true)
      Text(
        VelaL10n.string(
          "legacy.whenYouAreReadyChooseANetworkModeFromVelaSNormalControlsAndConfirmItThere",
          defaultValue:
            "When you are ready, choose a network mode from Vela's normal controls and confirm it there."
        )
      )
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
    }
  }
}

private struct OnboardingInfoCard: View {
  let icon: String
  let title: String
  let detail: String

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: icon)
        .foregroundStyle(.tint)
        .frame(width: 24)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 4) {
        Text(VelaL10n.legacy(title))
          .font(.headline)
        Text(VelaL10n.legacy(detail))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      VelaAppearance.controlBackground.opacity(0.58),
      in: RoundedRectangle(cornerRadius: VelaRadius.panel, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: VelaRadius.panel, style: .continuous)
        .stroke(VelaAppearance.separator.opacity(0.45), lineWidth: 1)
    }
    .accessibilityElement(children: .combine)
  }
}

@MainActor
extension OnboardingStepID {
  fileprivate var shortTitle: String {
    switch self {
    case .welcome:
      VelaL10n.string("onboarding.step.welcome.short", defaultValue: "Welcome")
    case .privacy:
      VelaL10n.string("onboarding.step.privacy.short", defaultValue: "Privacy")
    case .addConfiguration:
      VelaL10n.string("onboarding.step.configuration.short", defaultValue: "Configuration")
    case .validation:
      VelaL10n.string("onboarding.step.validation.short", defaultValue: "Validation")
    case .networkModeEducation:
      VelaL10n.string("onboarding.step.network.short", defaultValue: "Network Modes")
    case .optionalTools:
      VelaL10n.string("onboarding.step.optional.short", defaultValue: "Optional Tools")
    case .finish:
      VelaL10n.string("onboarding.step.finish.short", defaultValue: "Finish")
    }
  }

  fileprivate var title: String {
    switch self {
    case .welcome:
      VelaL10n.string("onboarding.welcome.title", defaultValue: "Welcome to Vela")
    case .privacy:
      VelaL10n.string("onboarding.step.privacy.title", defaultValue: "Privacy by Default")
    case .addConfiguration:
      VelaL10n.string("onboarding.step.configuration.title", defaultValue: "Add a Configuration")
    case .validation:
      VelaL10n.string("onboarding.step.validation.title", defaultValue: "Validate Safely")
    case .networkModeEducation:
      VelaL10n.string("onboarding.step.network.title", defaultValue: "Choose a Network Mode Later")
    case .optionalTools:
      VelaL10n.string("onboarding.step.optional.title", defaultValue: "Optional Tools Stay Optional")
    case .finish:
      VelaL10n.string("onboarding.step.finish.title", defaultValue: "You're Ready")
    }
  }

  fileprivate var subtitle: String {
    switch self {
    case .welcome:
      VelaL10n.string(
        "onboarding.step.welcome.subtitle",
        defaultValue: "A short, reversible setup that leaves your network unchanged until you act."
      )
    case .privacy:
      VelaL10n.string(
        "onboarding.step.privacy.subtitle",
        defaultValue: "Vela asks only when a feature needs access, and explains the request first."
      )
    case .addConfiguration:
      VelaL10n.string(
        "onboarding.step.configuration.subtitle",
        defaultValue: "Use the existing Vela import transaction, or add a profile later."
      )
    case .validation:
      VelaL10n.string(
        "onboarding.step.validation.subtitle",
        defaultValue: "Check a selected profile without starting the engine or changing routing."
      )
    case .networkModeEducation:
      VelaL10n.string(
        "onboarding.step.network.subtitle",
        defaultValue: "System Proxy and TUN solve different problems; neither is enabled here."
      )
    case .optionalTools:
      VelaL10n.string(
        "onboarding.step.optional.subtitle",
        defaultValue: "TUN, Wi-Fi name access, and Launch at Login are requested only at the moment of use."
      )
    case .finish:
      VelaL10n.string(
        "onboarding.step.finish.subtitle",
        defaultValue: "Setup ends with the same network state you started with."
      )
    }
  }

  fileprivate var icon: String {
    switch self {
    case .welcome: "sparkles"
    case .privacy: "hand.raised.fill"
    case .addConfiguration: "doc.badge.plus"
    case .validation: "checkmark.shield.fill"
    case .networkModeEducation: "arrow.triangle.branch"
    case .optionalTools: "switch.2"
    case .finish: "flag.checkered"
    }
  }
}
