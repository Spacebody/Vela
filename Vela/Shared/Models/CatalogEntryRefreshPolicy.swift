import Foundation

nonisolated enum CatalogEntryRefreshPolicy {
    static func shouldRefresh(
        hasReceivedSnapshot: Bool,
        hasError: Bool
    ) -> Bool {
        !hasReceivedSnapshot && !hasError
    }
}
