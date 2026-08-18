import SwiftUI

/// Overview-only design tokens measured from the approved Liquid Glass artwork.
///
/// These values intentionally do not leak into the application-wide theme. The
/// Overview is being rebuilt page-by-page and must remain visually deterministic
/// while the rest of the app continues to use the existing system styling.
enum OverviewDesignTokens {
    enum ColorToken {
        static let sidebarTop = Color(red: 222 / 255, green: 227 / 255, blue: 233 / 255)
        static let sidebarBottom = Color(red: 211 / 255, green: 218 / 255, blue: 225 / 255)

        static let accent = Color(red: 34 / 255, green: 143 / 255, blue: 1)
        static let accentViolet = Color(red: 142 / 255, green: 76 / 255, blue: 1)
        static let connected = Color(red: 18 / 255, green: 177 / 255, blue: 103 / 255)
        static let warning = Color(red: 221 / 255, green: 145 / 255, blue: 37 / 255)
        static let error = Color(red: 218 / 255, green: 63 / 255, blue: 67 / 255)

        static let textPrimary = Color(red: 20 / 255, green: 28 / 255, blue: 36 / 255)
        static let textSecondary = Color(red: 91 / 255, green: 105 / 255, blue: 121 / 255)
        static let textTertiary = Color(red: 124 / 255, green: 139 / 255, blue: 155 / 255)
        static let glassStroke = Color.white.opacity(0.82)
        static let divider = Color(red: 118 / 255, green: 145 / 255, blue: 171 / 255).opacity(0.24)
        static let map = Color(red: 139 / 255, green: 165 / 255, blue: 186 / 255)
    }

    enum Radius {
        static let core: CGFloat = 30
        static let route: CGFloat = 26
        static let metrics: CGFloat = 24
        static let endpoint: CGFloat = 24
        static let banner: CGFloat = 16
        static let chip: CGFloat = 12
    }

    enum Motion {
        static let state = 0.24
        static let hover = 0.14
        static let routeSweep = 2.7
        static let routeGlow = 1.8
    }

    static func statusColor(for state: OverviewConnectionState) -> Color {
        switch state {
        case .connected:
            ColorToken.connected
        case .connecting:
            ColorToken.accent
        case .disconnected, .noConfiguration:
            ColorToken.textTertiary
        case .error:
            ColorToken.error
        case .degraded:
            ColorToken.warning
        }
    }
}
