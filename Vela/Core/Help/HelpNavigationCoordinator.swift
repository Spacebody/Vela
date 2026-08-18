import Foundation
import Observation

/// Carries context-sensitive Help requests across independent SwiftUI windows.
/// Requests contain only stable bundled topic identifiers and never trigger I/O.
@MainActor
@Observable
final class HelpNavigationCoordinator {
    private(set) var requestedTopicID: HelpTopicID?
    private(set) var requestRevision: UInt64 = 0

    @discardableResult
    func request(topic rawValue: String?) -> Bool {
        if let rawValue {
            guard let topicID = HelpTopicID(rawValue: rawValue) else { return false }
            requestedTopicID = topicID
        } else {
            requestedTopicID = nil
        }
        requestRevision &+= 1
        return true
    }
}
