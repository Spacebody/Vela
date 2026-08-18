import Foundation

/// Routes a Settings category into the main application window.
@MainActor
struct SettingsNavigationRequest {
  static let categoryUserInfoKey = "category"
  private static var pendingCategory: SettingsCategory?

  let category: SettingsCategory

  func open() {
    Self.pendingCategory = category
    SettingsMainNavigationRequest.open(.settings)
    Task { @MainActor in
      await Task.yield()
      NotificationCenter.default.post(
        name: .velaOpenSettingsCategory,
        object: nil,
        userInfo: [Self.categoryUserInfoKey: category.rawValue]
      )
    }
  }

  static func consumePendingCategory() -> SettingsCategory? {
    defer { pendingCategory = nil }
    return pendingCategory
  }

  static func acknowledge(_ category: SettingsCategory) {
    guard pendingCategory == category else { return }
    pendingCategory = nil
  }

  static func category(from notification: Notification) -> SettingsCategory? {
    guard let rawValue = notification.userInfo?[categoryUserInfoKey] as? String else {
      return nil
    }
    return SettingsCategory(rawValue: rawValue)
  }
}

extension Notification.Name {
  static let velaOpenSettingsCategory = Notification.Name(
    "dev.yilin.Vela.openSettingsCategory"
  )
}
