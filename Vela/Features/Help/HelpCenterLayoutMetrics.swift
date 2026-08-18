import CoreGraphics

nonisolated struct HelpCenterLayoutMetrics: Equatable, Sendable {
  let navigationWidth: CGFloat
  let supportToolsWidth: CGFloat
  let showsSupportToolsColumn: Bool
  let contentPadding: CGFloat

  init(availableWidth: CGFloat) {
    let boundedWidth = max(0, availableWidth)
    navigationWidth = min(300, max(250, boundedWidth * 0.25))
    showsSupportToolsColumn = boundedWidth >= 1_180
    supportToolsWidth = showsSupportToolsColumn ? min(280, max(230, boundedWidth * 0.21)) : 0
    contentPadding = boundedWidth < 1_000 ? 16 : 20
  }
}
