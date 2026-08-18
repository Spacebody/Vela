import Foundation

nonisolated enum CoreAutomaticCatalogPolicy {
    static let checkInterval: TimeInterval = 24 * 60 * 60
    static let schedulerTolerance: TimeInterval = 60 * 60

    static func isCheckDue(lastAttempt: Date?, now: Date) -> Bool {
        guard let lastAttempt else { return true }
        let elapsed = now.timeIntervalSince(lastAttempt)
        // A wall-clock correction must not suppress checks indefinitely.
        guard elapsed >= 0 else { return true }
        return elapsed >= checkInterval
    }

    static func allowsAutomaticCheck(on path: NetworkPathSnapshot) -> Bool {
        path.networkReachable
    }

    static func allowsAutomaticDownload(on path: NetworkPathSnapshot) -> Bool {
        path.networkReachable && !path.isExpensive && !path.isConstrained
    }
}
