import Foundation
import VelaIPC

nonisolated enum SettingsStatusPresentation {
  static func coreDisplayName(_ coreID: CoreID) -> String {
    VelaL10n.string(
      "overview.core.activeFormat",
      defaultValue: "Mihomo %@",
      arguments: coreID.upstreamVersion
    )
  }

  static func coreSource(_ source: CoreDescriptorSource) -> String {
    switch source {
    case .factory:
      VelaL10n.string("settings.core.source.factory", defaultValue: "Built-in")
    case .user:
      VelaL10n.string("settings.core.source.downloaded", defaultValue: "Downloaded")
    }
  }

  static func privilegedComponentTitle(_ state: PrivilegedComponentState?) -> String {
    if case .damaged = state {
      return VelaL10n.string(
        "settings.privilegedComponent.repairRequired",
        defaultValue: "Repair Required"
      )
    }
    return VelaRuntimeStatusPresentation.helperTitle(state)
  }

  static func privilegedComponentDetail(_ state: PrivilegedComponentState?) -> String? {
    if case .damaged(let message) = state {
      if message == PrivilegedBundleFailurePresentation.untrustedCodeSignature {
        return VelaL10n.string(
          "settings.privilegedComponent.signingIdentityInvalid.detail",
          defaultValue: message
        )
      }
      return VelaL10n.string(
        "settings.privilegedComponent.repairRequired.detail",
        defaultValue:
          "Vela could not verify the installed privileged component against this app build. Turn off TUN, then reinstall the component; development builds may also require installing a consistently signed app in Applications."
      )
    }
    return VelaRuntimeStatusPresentation.helperDetail(state)
  }

  static func installedCoreStatus(_ status: InstalledCoreStatus) -> String {
    switch status {
    case .ready:
      VelaL10n.string("settings.core.status.ready", defaultValue: "Ready")
    case .knownGood:
      VelaL10n.string("settings.core.status.knownGood", defaultValue: "Known Good")
    case .quarantined:
      VelaL10n.string(
        "settings.core.status.quarantined",
        defaultValue: "Quarantined"
      )
    case .blocked:
      VelaL10n.string("settings.core.status.blocked", defaultValue: "Blocked")
    case .withdrawn:
      VelaL10n.string("settings.core.status.withdrawn", defaultValue: "Withdrawn")
    }
  }

  static func parity(_ value: Bool?) -> String {
    switch value {
    case true:
      VelaL10n.string(
        "settings.core.parity.userPrivileged",
        defaultValue: "User / Privileged"
      )
    case false:
      VelaL10n.string("settings.core.parity.userOnly", defaultValue: "User only")
    case nil:
      VelaL10n.string(
        "settings.core.parity.helperUnavailable",
        defaultValue: "Privileged component unavailable"
      )
    }
  }

  static func coreCatalogState(_ state: CoreCatalogClientState) -> String {
    switch state {
    case .unconfigured:
      VelaL10n.string(
        "settings.core.catalog.notConfigured",
        defaultValue: "Not configured"
      )
    case .idle:
      VelaL10n.string("settings.core.catalog.ready", defaultValue: "Ready")
    case .checking:
      VelaL10n.string("settings.core.catalog.checking", defaultValue: "Checking")
    case .verified(let sequence, _, _):
      VelaL10n.string(
        "settings.core.catalog.verifiedSequenceIntegerFormat",
        defaultValue: "Verified · sequence %llu",
        arguments: sequence
      )
    case .stale(let sequence, _, _):
      VelaL10n.string(
        "settings.core.catalog.expiredSequenceIntegerFormat",
        defaultValue: "Expired · sequence %llu",
        arguments: sequence
      )
    case .staleUncached:
      VelaL10n.string(
        "settings.core.catalog.expiredNotAccepted",
        defaultValue: "Expired · not accepted"
      )
    case .clockSkew:
      VelaL10n.string(
        "settings.core.catalog.checkSystemClock",
        defaultValue: "Check system clock"
      )
    case .failed:
      VelaL10n.string(
        "settings.core.catalog.verificationFailed",
        defaultValue: "Verification failed"
      )
    }
  }

  static func tunStack(_ stack: TunStack) -> String {
    switch stack {
    case .mixed:
      VelaL10n.string("settings.tun.stack.mixed", defaultValue: "Mixed")
    case .system:
      VelaL10n.string("settings.tun.stack.system", defaultValue: "System")
    case .gvisor:
      VelaL10n.string("settings.tun.stack.gvisor", defaultValue: "gVisor")
    }
  }

  static func verificationResult(_ passed: Bool) -> String {
    passed
      ? VelaL10n.string(
        "settings.core.verification.passed",
        defaultValue: "Passed"
      )
      : VelaL10n.string(
        "settings.core.verification.failed",
        defaultValue: "Failed"
      )
  }
}
