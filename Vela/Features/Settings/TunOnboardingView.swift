import AppKit
import SwiftUI
import VelaIPC

struct TunOnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
#if DEBUG
    @Environment(\.visualUITestConfiguration) private var visualTestConfiguration
#endif

    let engineStore: EngineStore
    @State private var requestedStage: TunVisualStage = .install
    @State private var operation: TunOnboardingOperation = .idle

    @ViewBuilder
    var body: some View {
#if DEBUG
        if let configuration = visualTestConfiguration,
            VisualFixturePresentationCatalog.supports(
                configuration,
                captureBoundary: .sheet
            )
        {
            VisualFixtureTunFlowHost(configuration: configuration)
        } else {
            liveBody
        }
#else
        liveBody
#endif
    }

    private var liveBody: some View {
      ZStack {
        VelaPageCanvas()

        VStack(alignment: .leading, spacing: 0) {
          flowHeader
            .background(.ultraThinMaterial)

          ScrollView {
            stageContent
              .id(visualStage)
              .transition(.opacity)
              .padding(VelaSpacing.large)
              .frame(maxWidth: .infinity, alignment: .topLeading)
              .velaPanelSurface()
              .padding(VelaSpacing.standard)
          }
          .scrollIndicators(.automatic)

          footer
            .background(.ultraThinMaterial)
        }
      }
    .frame(
      minWidth: 720,
      idealWidth: 780,
      maxWidth: 900,
      minHeight: minimumSheetHeight,
      idealHeight: idealSheetHeight,
      maxHeight: maximumSheetHeight
    )
        .animation(
            reduceMotion ? nil : .easeOut(duration: VelaMotion.standardSeconds),
            value: visualStage
        )
#if DEBUG
        .overlay(alignment: .topLeading) {
            VisualSurfaceMarker(
                identifier: "tun.onboarding",
                label: "TUN onboarding"
            )
        }
#endif
    }

    @ViewBuilder
    private var flowHeader: some View {
        switch presentation.shell {
        case .setup:
            VStack(alignment: .leading, spacing: VelaSpacing.medium) {
                Text(
                    VelaL10n.string(
                        "tun.flow.setup.title",
                        defaultValue: "Set Up TUN"
                    )
                )
                .font(VelaTypography.pageTitle)
                .accessibilityAddTraits(.isHeader)

                TunSetupProgress(steps: presentation.setupSteps)
            }
            .padding(.horizontal, VelaSpacing.large)
            .padding(.vertical, VelaSpacing.medium)

        case .transition:
            VStack(alignment: .leading, spacing: VelaSpacing.medium) {
                HStack(alignment: .firstTextBaseline) {
                    Text(
                        VelaL10n.string(
                            "tun.flow.transition.title",
                            defaultValue: "Switching to TUN"
                        )
                    )
                    .font(VelaTypography.pageTitle)
                    .accessibilityAddTraits(.isHeader)
                    Spacer()
                    VelaStatusPill(
                        status: engineStore.transitionState.phase == .rollingBack
                            ? .warning : .pending,
                        label: VelaRuntimeStatusPresentation.transitionTitle(
                            engineStore.transitionState
                        )
                    )
                }
                transitionContext
            }
            .padding(.horizontal, VelaSpacing.large)
            .padding(.vertical, VelaSpacing.medium)

        case .recovery:
            HStack(alignment: .firstTextBaseline) {
                Text(
                    VelaL10n.string(
                        "tun.flow.recovery.title",
                        defaultValue: "TUN Recovery"
                    )
                )
                .font(VelaTypography.pageTitle)
                .accessibilityAddTraits(.isHeader)
                Spacer()
                VelaStatusPill(status: .error, label: recoveryTitle)
            }
            .padding(.horizontal, VelaSpacing.large)
            .padding(.vertical, VelaSpacing.medium)
        }
    }

    private var transitionContext: some View {
        Grid(alignment: .leading, horizontalSpacing: VelaSpacing.large) {
            GridRow {
                Text(VelaL10n.string("tun.flow.current", defaultValue: "Current"))
                    .foregroundStyle(.secondary)
                Text(
                    presentation.sourceBackend.map(
                        VelaRuntimeStatusPresentation.backendTitle
                    )
                        ?? VelaRuntimeStatusPresentation.backendTitle(
                            engineStore.activeBackendKind
                        )
                )
                Text(VelaL10n.string("tun.flow.requested", defaultValue: "Requested"))
                    .foregroundStyle(.secondary)
                Text(
                    presentation.targetBackend.map(
                        VelaRuntimeStatusPresentation.backendTitle
                    )
                        ?? VelaRuntimeStatusPresentation.backendTitle(.privilegedDaemon)
                )
            }
            if let transitionID = presentation.transitionID {
                GridRow {
                    Text(
                        VelaL10n.string(
                            "tun.flow.transaction",
                            defaultValue: "Transaction"
                        )
                    )
                    .foregroundStyle(.secondary)
                    Text(transitionID.uuidString)
                        .fontDesign(.monospaced)
                        .textSelection(.enabled)
                    Color.clear
                    Color.clear
                }
            }
        }
        .font(VelaTypography.caption)
        .accessibilityIdentifier("tun.transition.context")
    }

    @ViewBuilder
    private var stageContent: some View {
        switch visualStage {
        case .install:
            installStage
        case .approval:
            approvalStage
        case .starting:
            startingStage
        case .running:
            runningStage
        case .recovery:
            recoveryStage
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: VelaSpacing.small) {
      Button(dismissActionTitle, role: presentation.dismiss == .notNow ? .cancel : nil) {
                dismiss()
            }
            .buttonStyle(.bordered)
            .keyboardShortcut(.cancelAction)
      .accessibilityIdentifier("tun.dismissAction")

            Spacer()

      ForEach(presentation.secondaryActions, id: \.action.rawValue) { action in
        Button(actionTitle(action.action)) {
          perform(action.action)
                }
        .buttonStyle(.bordered)
        .disabled(!action.isEnabled)
        .help(disabledReasonText(action.disabledReason) ?? "")
        .accessibilityIdentifier("tun.secondaryAction.\(action.action.rawValue)")
            }

      if let action = presentation.primaryAction {
        Button(actionTitle(action.action)) {
          perform(action.action)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        .disabled(!action.isEnabled)
        .help(disabledReasonText(action.disabledReason) ?? "")
        .accessibilityIdentifier("tun.primaryAction.\(action.action.rawValue)")
            } else if visualStage == .starting {
                HStack(spacing: VelaSpacing.small) {
                    ProgressView()
                        .controlSize(.small)
                    Text(
                        VelaRuntimeStatusPresentation.transitionTitle(
                            engineStore.transitionState
                        )
                    )
                        .font(VelaTypography.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    .padding(.horizontal, VelaSpacing.large)
    .padding(.vertical, VelaSpacing.medium)
        .controlSize(.regular)
    .accessibilityIdentifier("tun.flow.footer")
    }

    private var installStage: some View {
        VStack(alignment: .leading, spacing: VelaSpacing.medium) {
            stageHeading(
                VelaL10n.string(
                    "tun.onboarding.install.title",
                    defaultValue: "Install the Privileged Component"
                ),
                systemImage: "shield.lefthalf.filled",
                detail: VelaL10n.string(
                    "tun.onboarding.install.detail",
                    defaultValue:
                        "macOS requires a narrowly scoped privileged component to create the TUN interface and apply routes. Vela itself keeps running as your user."
                )
            )

            LabeledContent(VelaL10n.string("legacy.currentStatus", defaultValue: "Current Status")) {
                VelaStatusPill(
                    status: helperStatus,
                    label: helperStatusTitle
                )
            }

            VStack(alignment: .leading, spacing: VelaSpacing.small) {
                feature(
                    VelaL10n.string(
                        "tun.onboarding.install.feature.validated",
                        defaultValue:
                            "Launches only Vela's bundled Mihomo with a validated TUN configuration."
                    )
                )
                feature(
                    VelaL10n.string(
                        "tun.onboarding.install.feature.transaction",
                        defaultValue:
                            "Keeps TUN and System Proxy transitions inside the existing ownership transaction."
                    )
                )
                feature(
                    VelaL10n.string(
                        "tun.onboarding.install.feature.removable",
                        defaultValue:
                            "Can be stopped and uninstalled from Advanced settings at any time."
                    )
                )
            }

            DisclosureGroup(VelaL10n.string("legacy.learnMore", defaultValue: "Learn More")) {
                Text(
                    VelaL10n.string(
                        "tun.onboarding.install.securityDetail",
            defaultValue:
              "The privileged component validates the caller, executable, configuration, paths, and owner lease before starting a privileged runtime. Vela never asks you to paste a terminal command or type an administrator password into the app."
                    )
                )
                    .font(VelaTypography.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, VelaSpacing.small)
            }
        }
        .accessibilityIdentifier("tun.stage.install")
    }

    private var approvalStage: some View {
        VStack(alignment: .leading, spacing: VelaSpacing.medium) {
            stageHeading(
                VelaL10n.string(
                    "tun.onboarding.approval.title",
                    defaultValue: "Authorize and Verify"
                ),
                systemImage: "person.badge.key.fill",
                detail: VelaL10n.string(
                    "tun.onboarding.approval.detail",
                    defaultValue:
                        "Approve Vela in Login Items & Extensions when macOS requires it, then let Vela verify the privileged component handshake."
                )
            )

            LabeledContent(VelaL10n.string("legacy.registration", defaultValue: "Registration")) {
                VelaStatusPill(
                    status: engineStore.privilegedComponentIsReady ? .success : .permission,
                    label: helperStateTitle
                )
            }

            if let handshake = engineStore.privilegedComponentManager?.lastHandshake {
                LabeledContent(
                    VelaL10n.string(
                        "tun.onboarding.component.version",
                        defaultValue: "Privileged Component Version"
                    ),
                    value: "\(handshake.helperVersion) (\(handshake.helperBuild))"
                )
                LabeledContent(
                    VelaL10n.string("legacy.protocol", defaultValue: "Protocol"),
                    value: "\(handshake.helperProtocolMinimum)–\(handshake.helperProtocolMaximum)"
                )
            }

            if let detail = presentedHelperDetail {
                Text(detail)
                    .font(VelaTypography.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if engineStore.selectedProfileID == nil {
                VelaStateBanner(
                    kind: .warning,
                    title: VelaL10n.string(
                        "tun.onboarding.approval.profileRequired.title",
                        defaultValue: "Profile Required"
                    ),
                    detail: VelaL10n.string(
                        "tun.onboarding.approval.profileRequired.detail",
                        defaultValue: "Select and validate a profile before enabling TUN."
                    )
                )
            } else {
                LabeledContent(
                    VelaL10n.string("legacy.selectedProfile", defaultValue: "Selected Profile"),
                    value: engineStore.selectedProfile?.name
                        ?? VelaL10n.string(
                            "runtime.status.unavailable",
                            defaultValue: "Unavailable"
                        )
                )
            }

      DisclosureGroup(
        VelaL10n.string(
          "tun.flow.preflight.title",
          defaultValue: "TUN Preflight"
        )
      ) {
        Grid(alignment: .leading, horizontalSpacing: VelaSpacing.large) {
          runningRow(
            VelaL10n.string("tun.flow.preflight.stack", defaultValue: "Stack"),
            engineStore.tunSettings.stack.rawValue
          )
          runningRow(
            VelaL10n.string(
              "tun.flow.preflight.interface",
              defaultValue: "Outbound Interface"
            ),
            runningInterface
          )
          runningRow(
            VelaL10n.string(
              "tun.flow.preflight.routes",
              defaultValue: "Automatic Routes"
            ),
            booleanStatus(engineStore.tunSettings.autoRoute)
          )
          runningRow(
            VelaL10n.string(
              "tun.flow.preflight.dns",
              defaultValue: "DNS Hijack"
            ),
            booleanStatus(engineStore.tunSettings.dnsHijack)
          )
          runningRow(
            VelaL10n.string(
              "tun.flow.preflight.validation",
              defaultValue: "Configuration Validation"
            ),
            validationStatusTitle
          )
          runningRow(
            VelaL10n.string(
              "tun.flow.preflight.core",
              defaultValue: "Mihomo Core"
            ),
            engineStore.resolvedExecutable?.version
              ?? VelaL10n.string(
                "runtime.status.unavailable",
                defaultValue: "Unavailable"
              )
          )
        }
        .padding(.top, VelaSpacing.small)
      }

      Text(
        VelaL10n.string(
          "legacy.noTerminalCommandsAreRequiredEnablingTunRemainsASeparateExplicitActionAfterApprovalSucceeds",
          defaultValue:
            "No terminal commands are required. Enabling TUN remains a separate explicit action after approval succeeds."
        )
      )
                .font(VelaTypography.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("tun.stage.approval")
#if DEBUG
        .overlay(alignment: .topLeading) {
            VisualReadyMarker(fixtureID: "tunFlow.permissionRequired")
        }
#endif
    }

    private var startingStage: some View {
        VStack(alignment: .leading, spacing: VelaSpacing.medium) {
      Text(
                VelaL10n.string(
                    "tun.onboarding.starting.detail",
                    defaultValue:
                        "Vela reports the actual transition phase. It does not invent a completion percentage."
                )
            )
      .font(VelaTypography.body)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)

            if engineStore.transitionState.phase == .rollingBack {
                VelaStateBanner(
                    kind: .recovery,
                    title: VelaL10n.string(
                        "tun.onboarding.starting.rollback.title",
                        defaultValue: "Rolling Back"
                    ),
                    detail: VelaL10n.string(
                        "tun.onboarding.starting.rollback.detail",
                        defaultValue:
                            "The target transition did not complete. Vela is attempting one bounded restore of the previous backend."
                    )
                )
            }

            VStack(spacing: VelaSpacing.small) {
                ForEach(TunStartingMilestone.allCases) { milestone in
                    TunStartingMilestoneRow(
                        milestone: milestone,
                        state: milestoneState(milestone)
                    )
                }
            }
        }
        .accessibilityIdentifier("tun.stage.starting")
    }

    private var runningStage: some View {
        VStack(alignment: .leading, spacing: VelaSpacing.medium) {
            stageHeading(
                VelaL10n.string(
                    "tun.onboarding.running.title",
                    defaultValue: "TUN Is Running"
                ),
                systemImage: "checkmark.circle.fill",
                detail: VelaL10n.string(
                    "tun.onboarding.running.detail",
                    defaultValue:
                        "The privileged runtime, TUN interface, route, and DNS checks are reported from the live engine state."
                )
            )

            HStack(spacing: VelaSpacing.small) {
                VelaStatusPill(
                    status: .success,
                    label: VelaL10n.string(
                        "tun.onboarding.running.connected",
                        defaultValue: "Connected"
                    )
                )
                if let health = engineStore.privilegedHealth {
                    VelaStatusPill(
                        status: health.ownerLeaseValid ? .success : .warning,
                        label: health.ownerLeaseValid
                            ? VelaL10n.string(
                                "tun.onboarding.running.leaseValid",
                                defaultValue: "Lease Valid"
                            )
                            : VelaL10n.string(
                                "tun.onboarding.running.leaseNeedsAttention",
                                defaultValue: "Lease Needs Attention"
                            )
                    )
                }
            }

            Grid(alignment: .leading, horizontalSpacing: VelaSpacing.large) {
                runningRow(
                    VelaL10n.string("tun.onboarding.running.interface", defaultValue: "Interface"),
                    runningInterface
                )
                runningRow(
                    VelaL10n.string("tun.onboarding.running.backend", defaultValue: "Backend"),
                    VelaRuntimeStatusPresentation.backendTitle(engineStore.activeBackendKind)
                )
                runningRow(
                    VelaL10n.string("tun.onboarding.running.mode", defaultValue: "Mode"),
                    engineStore.runtimeMode?.displayName
                        ?? VelaL10n.string(
                            "runtime.status.unavailable",
                            defaultValue: "Unavailable"
                        )
                )
                runningRow(
                    VelaL10n.string("tun.onboarding.running.profile", defaultValue: "Profile"),
                    engineStore.selectedProfile?.name
                        ?? VelaL10n.string(
                            "runtime.status.unavailable",
                            defaultValue: "Unavailable"
                        )
                )
                runningRow(
                    VelaL10n.string(
                        "tun.onboarding.running.helper",
                        defaultValue: "Privileged Component"
                    ),
                    helperStateTitle
                )
        if let health = engineStore.privilegedHealth {
          runningRow(
            VelaL10n.string(
              "tun.flow.running.controller",
              defaultValue: "Controller"
            ),
            booleanStatus(health.controllerReachable)
          )
          runningRow(
            VelaL10n.string(
              "tun.flow.running.routes",
              defaultValue: "Routes"
            ),
            booleanStatus(health.routeApplied)
          )
          runningRow(
            VelaL10n.string(
              "tun.flow.running.dns",
              defaultValue: "DNS"
            ),
            booleanStatus(health.dnsReady)
          )
        }
        runningRow(
          VelaL10n.string(
            "tun.flow.running.systemProxy",
            defaultValue: "System Proxy"
          ),
          VelaRuntimeStatusPresentation.systemProxyTitle(
            engineStore.systemProxyStatus
          )
        )
                if let renewal = engineStore.lastLeaseRenewalAt {
                    runningRow(
                        VelaL10n.string(
                            "tun.onboarding.running.leaseRenewed",
                            defaultValue: "Lease Renewed"
                        ),
                        renewal.formatted(date: .omitted, time: .standard)
                    )
                }
                if let sample = engineStore.trafficSample {
                    runningRow(
                        VelaL10n.string(
                            "tun.onboarding.running.traffic",
                            defaultValue: "Traffic"
                        ),
                        "↓ \(rateString(sample.downloadBytesPerSecond))  ↑ \(rateString(sample.uploadBytesPerSecond))"
                    )
                }
            }

            HStack(spacing: VelaSpacing.small) {
                Button(VelaL10n.string("legacy.stopTun", defaultValue: "Stop TUN"), role: .destructive) {
                    Task { await stopTun() }
                }
                .disabled(isWorking)

                Menu(VelaL10n.string("legacy.pauseTun", defaultValue: "Pause TUN")) {
          Button(VelaL10n.string("legacy.value5Minutes", defaultValue: "5 Minutes")) {
            Task { await pauseTun(for: .seconds(300)) }
          }
          Button(VelaL10n.string("legacy.value15Minutes", defaultValue: "15 Minutes")) {
            Task { await pauseTun(for: .seconds(900)) }
          }
          Button(VelaL10n.string("legacy.value30Minutes", defaultValue: "30 Minutes")) {
            Task { await pauseTun(for: .seconds(1_800)) }
          }
                }
                .disabled(isWorking)
            }
        }
        .accessibilityIdentifier("tun.stage.running")
    }

    private var recoveryStage: some View {
        VStack(alignment: .leading, spacing: VelaSpacing.medium) {
            VelaStateBanner(
                kind: .error,
                title: recoveryTitle,
                detail: recoveryDetail
            )

            if let failure = transitionFailure {
        LabeledContent(
          VelaL10n.string("legacy.failedPhase", defaultValue: "Failed Phase"),
          value: phaseTitle(failure.failedPhase))
                LabeledContent(
                    VelaL10n.string("legacy.transition", defaultValue: "Transition"),
                    value:
                        "\(VelaRuntimeStatusPresentation.backendTitle(failure.source)) → \(VelaRuntimeStatusPresentation.backendTitle(failure.target))"
                )
                rollbackView(failure.rollback)
            }

            LabeledContent(
                VelaL10n.string("legacy.systemProxy", defaultValue: "System Proxy"),
                value: VelaRuntimeStatusPresentation.systemProxyTitle(
                    engineStore.systemProxyStatus
                )
            )
            LabeledContent(
                VelaL10n.string(
                    "tun.onboarding.component.label",
                    defaultValue: "Privileged Component"
                ),
                value: helperStateTitle
            )

            if engineStore.lastError?.suggestedAction != nil {
                Text(
                    VelaL10n.string(
                        "tun.onboarding.recovery.suggestedAction",
                        defaultValue: "Review Diagnostics and resolve the reported issue before retrying TUN."
                    )
                )
                    .font(VelaTypography.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

        }
        .accessibilityIdentifier("tun.stage.recovery")
    }

    private var visualStage: TunVisualStage {
#if DEBUG
        // Visual fixtures supply presentation state only. The isolated runtime
        // never installs or contacts a real helper, but permission-required
        // evidence must still render the authorization stage rather than the
        // preceding installation stage.
        if visualTestConfiguration?.page == .tunFlow,
            visualTestConfiguration?.state == .permissionRequired
        {
            return .approval
        }
#endif
        if engineStore.isTunActive { return .running }
        if transitionFailure != nil || helperNeedsRecovery { return .recovery }
        if engineStore.isEngineTransitioning,
            operation != .disabling
        {
            return .starting
        }
        if requestedStage == .starting { return .starting }
        if requestedStage == .approval
            || engineStore.privilegedComponentIsReady
            || engineStore.privilegedComponentManager?.registrationStatus == .requiresApproval
        {
            return .approval
        }
        return .install
    }

    private var minimumSheetHeight: CGFloat {
        visualStage == .recovery ? 360 : 500
    }

    private var idealSheetHeight: CGFloat {
        switch visualStage {
        case .recovery:
            410
        case .running:
            620
        case .install, .approval, .starting:
            560
        }
    }

    private var maximumSheetHeight: CGFloat {
        visualStage == .recovery ? 480 : 720
    }

    private var isWorking: Bool { operation != .idle }

  private var presentation: TunFlowPresentation {
    TunFlowPresentationResolver.resolve(
      stage: visualStage,
      componentAvailable: engineStore.privilegedComponentManager != nil,
      componentReady: engineStore.privilegedComponentIsReady,
      componentNeedsApproval:
        engineStore.privilegedComponentManager?.registrationStatus == .requiresApproval,
      hasProfile: engineStore.selectedProfileID != nil,
      canEnableTun: engineStore.canEnableTun,
      isWorking: isWorking,
      transitionSnapshot: engineStore.transitionSnapshot,
      transitionFailure: transitionFailure,
      hasDiagnosticDetails: redactedDiagnosticText != nil
    )
  }

    private var transitionFailure: EngineTransitionFailure? {
    if case .failed(let failure) = engineStore.transitionState {
            return failure
        }
        return nil
    }

    private var helperNeedsRecovery: Bool {
        guard let state = engineStore.privilegedComponentManager?.state else { return false }
        return switch state {
        case .incompatible, .damaged, .failed:
            true
        case .notInstalled, .registering, .needsApproval, .connecting, .ready, .uninstalling:
            false
        }
    }

    private var helperStatus: VelaSemanticStatus {
#if DEBUG
        if isVisualPermissionRequiredFixture { return .permission }
#endif
        if engineStore.privilegedComponentIsReady { return .success }
        if helperNeedsRecovery { return .error }
        if engineStore.privilegedComponentManager?.registrationStatus == .requiresApproval {
            return .permission
        }
        return .neutral
    }

    private var helperStatusTitle: String {
        presentedHelperTitle
    }

    private var helperStateTitle: String {
        presentedHelperTitle
    }

    private var presentedHelperTitle: String {
#if DEBUG
        if isVisualPermissionRequiredFixture {
            return VelaL10n.string(
                "runtime.helper.needsApproval",
                defaultValue: "Needs Approval"
            )
        }
#endif
        return VelaRuntimeStatusPresentation.helperTitle(
            engineStore.privilegedComponentManager?.state
        )
    }

    private var presentedHelperDetail: String? {
#if DEBUG
        if isVisualPermissionRequiredFixture {
            return VelaL10n.string(
                "runtime.helper.needsApproval.detail",
                defaultValue:
                    "Approve Vela in System Settings > General > Login Items & Extensions."
            )
        }
#endif
        return VelaRuntimeStatusPresentation.helperDetail(
            engineStore.privilegedComponentManager?.state
        )
    }

#if DEBUG
    private var isVisualPermissionRequiredFixture: Bool {
        visualTestConfiguration?.page == .tunFlow
            && visualTestConfiguration?.state == .permissionRequired
    }
#endif

    private var runningInterface: String {
        if let interface = engineStore.privilegedHealth?.tunInterface, !interface.isEmpty {
            return interface
        }
        if let interface = engineStore.tunSettings.outboundInterface, !interface.isEmpty {
            return interface
        }
        return engineStore.tunSettings.autoDetectInterface
            ? VelaL10n.string(
                "tun.onboarding.running.interface.autoDetected",
                defaultValue: "Auto-detected"
            )
            : VelaL10n.string(
                "runtime.status.unavailable",
                defaultValue: "Unavailable"
            )
    }

  private var validationStatusTitle: String {
    guard let result = engineStore.validationResult else {
      return VelaL10n.string(
        "tun.flow.preflight.validationOnStart",
        defaultValue: "Validated when TUN starts"
      )
    }
    return result.isValid
      ? VelaL10n.string("tun.flow.status.valid", defaultValue: "Valid")
      : VelaL10n.string(
        "tun.flow.status.needsAttention",
        defaultValue: "Needs Attention"
      )
  }

    private var recoveryTitle: String {
        if let failure = transitionFailure {
            if case .failed = failure.rollback {
                return VelaL10n.string(
                    "tun.onboarding.recovery.transitionAndRollbackFailed",
                    defaultValue: "Transition and Rollback Failed"
                )
            }
            return VelaL10n.string(
                "tun.onboarding.recovery.transitionFailed",
                defaultValue: "Transition Failed"
            )
        }
        return VelaL10n.string(
            "tun.onboarding.recovery.helperAttention",
            defaultValue: "Privileged Component Requires Attention"
        )
    }

    private var recoveryDetail: String {
        if let failure = transitionFailure {
            if case .failed = failure.rollback {
                return VelaL10n.string(
                    "tun.onboarding.recovery.transitionAndRollbackFailed.detail",
          defaultValue:
            "The TUN transition and its rollback could not be verified. Open Diagnostics before trying another network change."
                )
            }
            return VelaL10n.string(
                "tun.onboarding.recovery.transitionFailed.detail",
        defaultValue:
          "The TUN transition failed and the previous backend was restored. Review Diagnostics before retrying."
            )
        }
        if let detail = VelaRuntimeStatusPresentation.helperDetail(
            engineStore.privilegedComponentManager?.state
        ) {
            return DiagnosticTextSanitizer.redact(detail)
        }
        if engineStore.lastError != nil {
            return VelaL10n.string(
                "tun.onboarding.recovery.runtimeError.detail",
        defaultValue:
          "Vela could not complete the TUN operation. Open Diagnostics for redacted details."
            )
        }
        return VelaL10n.string(
            "tun.onboarding.recovery.unverified.detail",
            defaultValue: "Vela could not verify the privileged component or TUN runtime."
        )
    }

    private var redactedDiagnosticText: String? {
        var lines: [String] = []
        if let failure = transitionFailure {
            lines.append("Transition: \(failure.source.rawValue) -> \(failure.target.rawValue)")
            lines.append("Failed phase: \(failure.failedPhase.rawValue)")
            lines.append("Reason: \(DiagnosticTextSanitizer.redact(failure.reason))")
      if case .failed(let reason) = failure.rollback {
                lines.append("Rollback failed: \(DiagnosticTextSanitizer.redact(reason))")
            }
        }
        if let error = engineStore.lastError {
            lines.append("Correlation: \(error.correlationID.uuidString)")
            lines.append(error.message)
            if let details = error.redactedTechnicalDetails {
                lines.append(details)
            }
        }
        lines.append(
            "System Proxy: \(VelaRuntimeStatusPresentation.systemProxyTitle(engineStore.systemProxyStatus))"
        )
        let componentLabel = VelaL10n.string(
            "tun.onboarding.component.label",
            defaultValue: "Privileged Component"
        )
        lines.append("\(componentLabel): \(helperStateTitle)")
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    @ViewBuilder
    private func rollbackView(_ rollback: EngineRollbackOutcome) -> some View {
        switch rollback {
        case .notRequired:
            LabeledContent(VelaL10n.string("legacy.previousMode", defaultValue: "Previous Mode")) {
                VelaStatusPill(
                    status: .neutral,
                    label: VelaL10n.string(
                        "tun.onboarding.recovery.rollback.notRequired",
                        defaultValue: "Rollback Not Required"
                    )
                )
            }
        case .succeeded:
            LabeledContent(VelaL10n.string("legacy.previousMode", defaultValue: "Previous Mode")) {
                VelaStatusPill(
                    status: .success,
                    label: VelaL10n.string(
                        "tun.onboarding.recovery.rollback.restored",
                        defaultValue: "Restored"
                    )
                )
            }
        case .failed:
            VelaStateBanner(
                kind: .error,
                title: VelaL10n.string(
                    "tun.onboarding.recovery.rollback.failed",
                    defaultValue: "Rollback Also Failed"
                ),
                detail: VelaL10n.string(
                    "tun.onboarding.recovery.rollback.failed.detail",
          defaultValue:
            "Vela could not verify that the previous network backend was restored. Open Diagnostics before retrying."
                )
            )
        }
    }

    @ViewBuilder
    private func stageHeading(
        _ title: String,
        systemImage: String,
        detail: String
    ) -> some View {
        HStack(alignment: .top, spacing: VelaSpacing.medium) {
            Image(systemName: systemImage)
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: VelaSpacing.xLarge)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: VelaSpacing.xSmall) {
                Text(title)
                    .font(VelaTypography.pageTitle)
                    .accessibilityAddTraits(.isHeader)
                Text(detail)
                    .font(VelaTypography.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func feature(_ text: String) -> some View {
        Label(text, systemImage: "checkmark.circle")
            .font(VelaTypography.body)
            .foregroundStyle(.secondary)
    }

    private func runningRow(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title)
                .font(VelaTypography.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(VelaTypography.body)
                .textSelection(.enabled)
        }
    }

    private func milestoneState(
        _ milestone: TunStartingMilestone
    ) -> TunStartingMilestoneState {
        guard let phase = engineStore.transitionState.phase else {
            return milestone == .prepareAndValidate ? .active : .pending
        }
        guard phase != .rollingBack else { return .pending }
    let activeIndex: Int =
      switch phase {
        case .preparingTarget: TunStartingMilestone.prepareAndValidate.rawValue
        case .disablingSystemProxy: TunStartingMilestone.disableSystemProxy.rawValue
        case .stoppingSource: TunStartingMilestone.stopCurrentBackend.rawValue
        case .startingTarget: TunStartingMilestone.startPrivilegedBackend.rawValue
        case .verifyingTarget, .committing: TunStartingMilestone.verifyNetwork.rawValue
        case .rollingBack: TunStartingMilestone.prepareAndValidate.rawValue
        }
        if milestone.rawValue < activeIndex { return .complete }
        if milestone.rawValue == activeIndex { return .active }
        return .pending
    }

    private func installHelper() async {
        operation = .installing
        if !engineStore.privilegedComponentIsReady {
            await engineStore.installPrivilegedComponent(userConfirmed: true)
        }
        await engineStore.refreshPrivilegedComponent()
        operation = .idle
        if engineStore.privilegedComponentIsReady
            || engineStore.privilegedComponentManager?.registrationStatus == .requiresApproval
        {
            requestedStage = .approval
        }
    }

    private func refreshHelper() async {
        operation = .checkingApproval
        await engineStore.refreshPrivilegedComponent()
        operation = .idle
        requestedStage = engineStore.privilegedComponentIsReady ? .approval : requestedStage
    }

    private func enableTun() async {
        requestedStage = .starting
        operation = .enabling
        await engineStore.refreshPrivilegedComponent()
        if engineStore.privilegedComponentIsReady {
            await engineStore.setTunEnabled(true)
        }
        operation = .idle
        if engineStore.isTunActive {
            requestedStage = .running
        } else if transitionFailure == nil, !helperNeedsRecovery {
            requestedStage = .approval
        }
    }

    private func stopTun() async {
        operation = .disabling
        requestedStage = .approval
        await engineStore.setTunEnabled(false)
        operation = .idle
    }

    private func pauseTun(for duration: Duration) async {
        operation = .disabling
        await engineStore.pauseTun(for: duration)
        operation = .idle
        if engineStore.tunPauseUntil != nil {
            dismiss()
        }
    }

    private func openDiagnostics() {
        dismiss()
        Task { @MainActor in
            await Task.yield()
            SettingsMainNavigationRequest.navigateInCurrentWindow(.diagnostics)
        }
    }

    private func copyRedactedDetails() {
        guard let redactedDiagnosticText else { return }
        let pasteboard = NSPasteboard.general
        _ = pasteboard.clearContents()
        _ = pasteboard.setString(redactedDiagnosticText, forType: .string)
    }

    private func rateString(_ bytesPerSecond: Int64) -> String {
        ByteCountFormatter.string(
            fromByteCount: max(0, bytesPerSecond),
            countStyle: .file
        ) + "/s"
    }

    private func phaseTitle(_ phase: EngineTransitionPhase) -> String {
        VelaRuntimeStatusPresentation.transitionPhaseTitle(phase)
    }

  private func booleanStatus(_ value: Bool) -> String {
    value
      ? VelaL10n.string("legacy.enabled", defaultValue: "Enabled")
      : VelaL10n.string("tun.flow.status.disabled", defaultValue: "Disabled")
  }

  private var dismissActionTitle: String {
    switch presentation.dismiss {
    case .notNow:
      VelaL10n.string("legacy.notNow", defaultValue: "Not Now")
    case .hideWhileContinuing:
      VelaL10n.string("tun.flow.action.hide", defaultValue: "Hide")
    case .close:
      VelaL10n.string("tun.flow.action.close", defaultValue: "Close")
    }
  }

  private func actionTitle(_ action: TunFlowAction) -> String {
        switch action {
        case .installPrivilegedComponent:
            VelaL10n.string(
                "tun.onboarding.action.installPrivilegedComponent",
                defaultValue: "Install Privileged Component"
            )
    case .openLoginItems:
      VelaL10n.string(
        "legacy.openLoginItemsSettings",
        defaultValue: "Open Login Items Settings"
      )
        case .checkAgain:
            VelaL10n.string("legacy.checkAgain", defaultValue: "Check Again")
        case .enableTun:
            VelaL10n.string("legacy.enableTun", defaultValue: "Enable TUN")
    case .tryAgain:
            VelaL10n.string("legacy.tryAgain", defaultValue: "Try Again")
    case .openRecovery:
      VelaL10n.string("tun.flow.action.openRecovery", defaultValue: "Open Recovery")
    case .runDiagnostics:
      VelaL10n.string("legacy.runDiagnostics", defaultValue: "Run Diagnostics")
    case .copyRedactedDetails:
            VelaL10n.string(
        "legacy.copyRedactedDetails",
        defaultValue: "Copy Redacted Details"
            )
    case .back:
      VelaL10n.string("legacy.back", defaultValue: "Back")
    case .done:
      VelaL10n.string("legacy.done", defaultValue: "Done")
        }
    }

  private func disabledReasonText(_ reason: TunFlowDisabledReason?) -> String? {
    switch reason {
    case .none:
      nil
    case .operationInProgress:
      VelaL10n.string(
        "tun.flow.disabled.operationInProgress",
        defaultValue: "Wait for the current operation to finish."
      )
    case .privilegedComponentUnavailable:
      VelaL10n.string(
        "tun.flow.disabled.componentUnavailable",
        defaultValue: "The privileged component is unavailable."
      )
    case .profileRequired:
      VelaL10n.string(
        "tun.flow.disabled.profileRequired",
        defaultValue: "Select a configuration before enabling TUN."
      )
    case .prerequisitesNotReady:
      VelaL10n.string(
        "tun.flow.disabled.prerequisites",
        defaultValue: "Complete the required checks before enabling TUN."
      )
        }
    }

  private func perform(_ action: TunFlowAction) {
        switch action {
        case .installPrivilegedComponent:
      Task { await installHelper() }
    case .openLoginItems:
      engineStore.privilegedComponentManager?.openSystemSettings()
    case .checkAgain:
      Task { await refreshHelper() }
    case .enableTun, .tryAgain:
      Task { await enableTun() }
    case .openRecovery, .runDiagnostics:
      openDiagnostics()
    case .copyRedactedDetails:
      copyRedactedDetails()
    case .back:
      requestedStage = .install
    case .done:
      dismiss()
        }
    }
}

private enum TunOnboardingOperation: Equatable {
    case idle
    case installing
    case checkingApproval
    case enabling
    case disabling
}

nonisolated enum TunVisualStage: Int, CaseIterable, Identifiable, Sendable {
    case install
    case approval
    case starting
    case running
    case recovery

    var id: Self { self }

    var title: String {
        switch self {
        case .install:
            VelaL10n.string(
                "tun.onboarding.stage.install",
                defaultValue: "Install Privileged Component"
            )
        case .approval:
            VelaL10n.string("tun.onboarding.stage.approval", defaultValue: "Approval")
        case .starting:
            VelaL10n.string("tun.onboarding.stage.starting", defaultValue: "Starting TUN")
        case .running:
            VelaL10n.string("tun.onboarding.stage.running", defaultValue: "TUN Running")
        case .recovery:
            VelaL10n.string("tun.onboarding.stage.recovery", defaultValue: "Recovery")
        }
    }

    var symbol: String {
        switch self {
        case .install: "shield"
        case .approval: "lock.open"
        case .starting: "clock.arrow.circlepath"
        case .running: "checkmark.circle"
        case .recovery: "exclamationmark.triangle"
        }
    }
}

private enum TunStartingMilestone: Int, CaseIterable, Identifiable {
    case prepareAndValidate
    case disableSystemProxy
    case stopCurrentBackend
    case startPrivilegedBackend
    case verifyNetwork

    var id: Self { self }

    var title: String {
        switch self {
        case .prepareAndValidate:
            VelaL10n.string(
                "tun.onboarding.milestone.prepareAndValidate",
                defaultValue: "Prepare configuration and validate Mihomo"
            )
        case .disableSystemProxy:
            VelaL10n.string(
                "tun.onboarding.milestone.disableSystemProxy",
                defaultValue: "Disable System Proxy"
            )
        case .stopCurrentBackend:
            VelaL10n.string(
                "tun.onboarding.milestone.stopCurrentBackend",
                defaultValue: "Stop the current backend"
            )
        case .startPrivilegedBackend:
            VelaL10n.string(
                "tun.onboarding.milestone.startPrivilegedBackend",
                defaultValue: "Start the privileged backend"
            )
        case .verifyNetwork:
            VelaL10n.string(
                "tun.onboarding.milestone.verifyNetwork",
                defaultValue: "Verify TUN interface, route, and DNS"
            )
        }
    }
}

private enum TunStartingMilestoneState: Equatable {
    case pending
    case active
    case complete
}

private struct TunStartingMilestoneRow: View {
    let milestone: TunStartingMilestone
    let state: TunStartingMilestoneState

    var body: some View {
        HStack(spacing: VelaSpacing.medium) {
            Group {
                switch state {
                case .pending:
                    Image(systemName: "circle")
                        .foregroundStyle(.secondary)
                case .active:
                    ProgressView()
                        .controlSize(.small)
                case .complete:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
            .frame(width: VelaSpacing.section)

            Text(milestone.title)
                .font(VelaTypography.body)
                .foregroundStyle(state == .pending ? .secondary : .primary)

            Spacer()
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        switch state {
        case .pending:
            VelaL10n.string(
                "tun.onboarding.milestone.accessibility.pending",
                defaultValue: "Pending"
            )
        case .active:
            VelaL10n.string(
                "tun.onboarding.milestone.accessibility.inProgress",
                defaultValue: "In progress"
            )
        case .complete:
            VelaL10n.string(
                "tun.onboarding.milestone.accessibility.complete",
                defaultValue: "Complete"
            )
        }
    }
}

private struct TunSetupProgress: View {
  let steps: [TunSetupStepPresentation]

    var body: some View {
    HStack(alignment: .center, spacing: VelaSpacing.small) {
      ForEach(Array(steps.enumerated()), id: \.element.step) { index, item in
        HStack(spacing: VelaSpacing.small) {
          Image(systemName: symbol(for: item))
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(color(for: item))
            .frame(width: 26, height: 26)
            .background(color(for: item).opacity(0.10), in: Circle())

          Text(title(for: item.step))
                        .font(VelaTypography.caption)
            .foregroundStyle(item.state == .current ? .primary : .secondary)
            .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityValue(accessibilityValue(for: item.state))

        if index < steps.count - 1 {
                    Rectangle()
            .fill(connectorColor(after: item))
                        .frame(height: 1)
                }
            }
        }
    .frame(minHeight: 32, idealHeight: 40, maxHeight: 48)
    .accessibilityIdentifier("tun.setup.progress")
    }

  private func title(for step: TunSetupStep) -> String {
    switch step {
    case .install:
      VelaL10n.string("tun.flow.step.install", defaultValue: "Install")
    case .approve:
      VelaL10n.string("tun.flow.step.approve", defaultValue: "Approve")
    case .start:
      VelaL10n.string("tun.flow.step.start", defaultValue: "Start")
    case .verify:
      VelaL10n.string("tun.flow.step.verify", defaultValue: "Verify")
    }
  }

  private func symbol(for item: TunSetupStepPresentation) -> String {
    switch item.state {
    case .pending:
      "circle"
    case .current:
      "circle.inset.filled"
    case .complete:
      "checkmark.circle.fill"
    case .failed:
      "exclamationmark.circle.fill"
    }
        }

  private func color(for item: TunSetupStepPresentation) -> Color {
    switch item.state {
    case .pending:
      .secondary
    case .current:
      .accentColor
    case .complete:
      .green
    case .failed:
      .red
    }
  }

  private func connectorColor(after item: TunSetupStepPresentation) -> Color {
    item.state == .complete ? .green.opacity(0.55) : VelaAppearance.separator
    }

  private func accessibilityValue(for state: TunSetupStepState) -> String {
    switch state {
    case .pending:
      VelaL10n.string(
        "tun.onboarding.milestone.accessibility.pending",
        defaultValue: "Pending"
      )
    case .current:
      VelaL10n.string(
        "tun.onboarding.milestone.accessibility.inProgress",
        defaultValue: "In progress"
      )
    case .complete:
      VelaL10n.string(
        "tun.onboarding.milestone.accessibility.complete",
        defaultValue: "Complete"
      )
    case .failed:
      VelaL10n.string("legacy.failed", defaultValue: "Failed")
        }
    }
}
