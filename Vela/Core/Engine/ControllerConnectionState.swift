import Foundation

nonisolated enum ControllerConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case unavailable(String)
}
