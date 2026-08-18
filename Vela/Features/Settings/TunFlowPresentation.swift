import Foundation
import VelaIPC

nonisolated enum TunFlowShellKind: Equatable, Sendable {
  case setup
  case transition
  case recovery
}

nonisolated enum TunSetupStep: Int, CaseIterable, Identifiable, Sendable {
  case install
  case approve
  case start
  case verify

  var id: Self { self }
}

nonisolated enum TunSetupStepState: Equatable, Sendable {
  case pending
  case current
  case complete
  case failed
}

nonisolated struct TunSetupStepPresentation: Equatable, Sendable {
  let step: TunSetupStep
  let state: TunSetupStepState
}

nonisolated enum TunFlowAction: String, Equatable, Sendable {
  case installPrivilegedComponent
  case openLoginItems
  case checkAgain
  case enableTun
  case tryAgain
  case openRecovery
  case runDiagnostics
  case copyRedactedDetails
  case back
  case done
}

nonisolated enum TunFlowDisabledReason: Equatable, Sendable {
  case operationInProgress
  case privilegedComponentUnavailable
  case profileRequired
  case prerequisitesNotReady
}

nonisolated struct TunFlowActionPresentation: Equatable, Sendable {
  let action: TunFlowAction
  let isEnabled: Bool
  let disabledReason: TunFlowDisabledReason?

  init(
    _ action: TunFlowAction,
    isEnabled: Bool = true,
    disabledReason: TunFlowDisabledReason? = nil
  ) {
    self.action = action
    self.isEnabled = isEnabled
    self.disabledReason = disabledReason
  }
}

nonisolated enum TunFlowDismissPresentation: Equatable, Sendable {
  /// Setup has not started a network transaction, so deferring is safe.
  case notNow
  /// The transaction continues in EngineStore after the sheet is hidden.
  case hideWhileContinuing
  /// A terminal success or recovery surface can be closed.
  case close
}

nonisolated struct TunFlowPresentation: Equatable, Sendable {
  let shell: TunFlowShellKind
  let setupSteps: [TunSetupStepPresentation]
  let primaryAction: TunFlowActionPresentation?
  let secondaryActions: [TunFlowActionPresentation]
  let dismiss: TunFlowDismissPresentation
  let transitionID: UUID?
  let sourceBackend: EngineBackendKind?
  let targetBackend: EngineBackendKind?
}

nonisolated enum TunFlowPresentationResolver {
  static func resolve(
    stage: TunVisualStage,
    componentAvailable: Bool,
    componentReady: Bool,
    componentNeedsApproval: Bool,
    hasProfile: Bool,
    canEnableTun: Bool,
    isWorking: Bool,
    transitionSnapshot: EngineTransitionSnapshot,
    transitionFailure: EngineTransitionFailure?,
    hasDiagnosticDetails: Bool
  ) -> TunFlowPresentation {
    let primary: TunFlowActionPresentation?
    var secondary: [TunFlowActionPresentation] = []
    let dismiss: TunFlowDismissPresentation

    switch stage {
    case .install:
      primary = action(
        .installPrivilegedComponent,
        enabled: componentAvailable && !isWorking,
        unavailableReason: componentAvailable
          ? .operationInProgress
          : .privilegedComponentUnavailable
      )
      dismiss = .notNow

    case .approval:
      if componentReady {
        let disabledReason: TunFlowDisabledReason =
          hasProfile
          ? .prerequisitesNotReady
          : .profileRequired
        primary = action(
          .enableTun,
          enabled: canEnableTun && !isWorking,
          unavailableReason: isWorking ? .operationInProgress : disabledReason
        )
        secondary = [.init(.back, isEnabled: !isWorking)]
      } else if componentNeedsApproval {
        primary = action(
          .openLoginItems,
          enabled: componentAvailable && !isWorking,
          unavailableReason: componentAvailable
            ? .operationInProgress
            : .privilegedComponentUnavailable
        )
        secondary = [
          action(
            .checkAgain,
            enabled: componentAvailable && !isWorking,
            unavailableReason: componentAvailable
              ? .operationInProgress
              : .privilegedComponentUnavailable
          )
        ]
      } else {
        primary = action(
          .checkAgain,
          enabled: componentAvailable && !isWorking,
          unavailableReason: componentAvailable
            ? .operationInProgress
            : .privilegedComponentUnavailable
        )
        secondary = [.init(.back, isEnabled: !isWorking)]
      }
      dismiss = .notNow

    case .starting:
      primary = nil
      dismiss = .hideWhileContinuing

    case .running:
      primary = .init(.done)
      dismiss = .close

    case .recovery:
      if isSafeToRetry(
        failure: transitionFailure,
        componentReady: componentReady,
        hasProfile: hasProfile
      ) {
        primary = action(
          .tryAgain,
          enabled: !isWorking,
          unavailableReason: .operationInProgress
        )
        secondary = [.init(.runDiagnostics)]
      } else {
        primary = .init(.openRecovery)
        secondary = []
      }
      if hasDiagnosticDetails {
        secondary.append(.init(.copyRedactedDetails))
      }
      dismiss = .close
    }

    return TunFlowPresentation(
      shell: shell(for: stage),
      setupSteps: setupSteps(
        for: stage,
        componentReady: componentReady,
        componentNeedsApproval: componentNeedsApproval,
        transitionState: transitionSnapshot.state
      ),
      primaryAction: primary,
      secondaryActions: secondary,
      dismiss: dismiss,
      transitionID: transitionFailure?.transitionID ?? transitionSnapshot.transitionID,
      sourceBackend: transitionFailure?.source ?? transitionSnapshot.source,
      targetBackend: transitionFailure?.target ?? transitionSnapshot.target
    )
  }

  private static func shell(for stage: TunVisualStage) -> TunFlowShellKind {
    switch stage {
    case .install, .approval, .running:
      .setup
    case .starting:
      .transition
    case .recovery:
      .recovery
    }
  }

  private static func setupSteps(
    for stage: TunVisualStage,
    componentReady: Bool,
    componentNeedsApproval: Bool,
    transitionState: EngineTransitionState
  ) -> [TunSetupStepPresentation] {
    TunSetupStep.allCases.map { step in
      let state: TunSetupStepState =
        switch stage {
        case .install:
          step == .install ? .current : .pending
        case .approval:
          switch step {
          case .install:
            .complete
          case .approve:
            componentReady ? .complete : (componentNeedsApproval ? .current : .pending)
          case .start:
            componentReady ? .current : .pending
          case .verify:
            .pending
          }
        case .starting:
          switch step {
          case .install, .approve:
            .complete
          case .start:
            transitionState.phase == .verifyingTarget
              || transitionState.phase == .committing ? .complete : .current
          case .verify:
            transitionState.phase == .verifyingTarget
              || transitionState.phase == .committing ? .current : .pending
          }
        case .running:
          .complete
        case .recovery:
          switch step {
          case .install, .approve:
            .complete
          case .start, .verify:
            .failed
          }
        }
      return TunSetupStepPresentation(step: step, state: state)
    }
  }

  private static func action(
    _ action: TunFlowAction,
    enabled: Bool,
    unavailableReason: TunFlowDisabledReason
  ) -> TunFlowActionPresentation {
    TunFlowActionPresentation(
      action,
      isEnabled: enabled,
      disabledReason: enabled ? nil : unavailableReason
    )
  }

  private static func isSafeToRetry(
    failure: EngineTransitionFailure?,
    componentReady: Bool,
    hasProfile: Bool
  ) -> Bool {
    guard componentReady, hasProfile, let failure else { return false }
    if case .failed = failure.rollback { return false }
    return true
  }
}
