import Foundation

/// View-layer evidence for one setting operation. The committed `currentValue`
/// is intentionally separate from the requested value so a control never
/// presents an unconfirmed system change as truth.
nonisolated struct SettingOperationSnapshot<Value: Sendable & Equatable>: Sendable, Equatable {
  enum Phase: String, Sendable, Equatable {
    case applying
    case permissionRequired
    case failed
  }

  enum Permission: String, Sendable, Equatable {
    case loginItemApproval
    case privilegedComponentApproval
  }

  let settingID: String
  let currentValue: Value
  let requestedValue: Value?
  let operation: String?
  let phase: Phase?
  let permission: Permission?
  let errorCode: String?

  var isPending: Bool {
    phase == .applying
  }

  var hasUncommittedRequest: Bool {
    requestedValue != nil && requestedValue != currentValue
  }
}

nonisolated enum SettingsCapabilityAudit {
  /// The production Scene feature owns Automatic Scenes. Public CLI, App
  /// Intents, and a user automation socket remain gated by the RC contract.
  static let automationOwner = "Scenes"
  static let exposesAutomaticScenes = true
  static let exposesPublicCLI = false
  static let exposesAppIntents = false
  static let exposesAutomationSocket = false
}
