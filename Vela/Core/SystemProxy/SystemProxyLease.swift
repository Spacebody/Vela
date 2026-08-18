import Foundation

nonisolated struct SystemProxyRecoveryLease: Codable, Equatable, Sendable {
    static let currentVersion = 1

    let version: Int
    let createdAt: Date
    let target: SystemProxyTarget
    let services: [SystemProxyRecoveryService]

    init(
        version: Int = currentVersion,
        createdAt: Date,
        target: SystemProxyTarget,
        services: [SystemProxyRecoveryService]
    ) {
        self.version = version
        self.createdAt = createdAt
        self.target = target
        self.services = services.sorted { lhs, rhs in
            if lhs.name != rhs.name {
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            return lhs.id < rhs.id
        }
    }
}

nonisolated struct SystemProxyRecoveryService: Codable, Equatable, Sendable {
    let id: String
    let name: String
    let originalConfiguration: Data
    let managedConfiguration: Data
}

nonisolated protocol SystemProxyRecoveryStoring: Actor {
    func load() async throws -> SystemProxyRecoveryLease?
    func save(_ lease: SystemProxyRecoveryLease) async throws
    func clear() async throws
}
