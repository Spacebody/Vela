import Foundation

nonisolated enum SystemProxyOperationState: Equatable, Sendable {
    case refreshing
    case enabling
    case restoring
}
