import Foundation
import Security
import SystemConfiguration

nonisolated struct SystemProxyBackendService: Equatable, Sendable {
    let id: String
    let name: String
    let isEnabled: Bool
    let configuration: Data
}

nonisolated struct SystemProxyBackendMutation: Equatable, Sendable {
    let serviceID: String
    let serviceName: String
    let expectedConfiguration: Data
    let configuration: Data
}

nonisolated protocol SystemProxyBackend: Actor {
    func currentServices() async throws -> [SystemProxyBackendService]
    func services(withIDs ids: [String]) async throws -> [SystemProxyBackendService]
    func apply(_ mutations: [SystemProxyBackendMutation]) async throws
}

nonisolated private final class SystemProxyAuthorizationSession: @unchecked Sendable {
    var reference: AuthorizationRef?

    deinit {
        if let reference {
            AuthorizationFree(reference, [])
        }
    }
}

actor LiveSystemProxyBackend: SystemProxyBackend {
    private let sessionName: String
    private let authorizationSession = SystemProxyAuthorizationSession()

    init(sessionName: String = "Vela System Proxy") {
        self.sessionName = sessionName
    }

    func currentServices() async throws -> [SystemProxyBackendService] {
        let preferences = try makeReadPreferences()
        guard let networkSet = SCNetworkSetCopyCurrent(preferences) else {
            throw SystemProxyBackendError.currentNetworkSetUnavailable(reason: lastSCError())
        }
        guard let rawServices = SCNetworkSetCopyServices(networkSet) as? [SCNetworkService] else {
            throw SystemProxyBackendError.serviceEnumerationFailed(reason: lastSCError())
        }

        return try rawServices
            .filter { SCNetworkServiceGetEnabled($0) }
            .map(readService)
            .sorted(by: serviceOrder)
    }

    func services(withIDs ids: [String]) async throws -> [SystemProxyBackendService] {
        guard !ids.isEmpty else {
            return []
        }

        let preferences = try makeReadPreferences()
        var services: [SystemProxyBackendService] = []
        for id in ids {
            guard let service = SCNetworkServiceCopy(preferences, id as CFString) else {
                continue
            }
            services.append(try readService(service))
        }
        return services.sorted(by: serviceOrder)
    }

    func apply(_ mutations: [SystemProxyBackendMutation]) async throws {
        guard !mutations.isEmpty else {
            return
        }

        let authorization = try mutationAuthorization()

        guard let preferences = SCPreferencesCreateWithAuthorization(
            nil,
            sessionName as CFString,
            nil,
            authorization
        ) else {
            throw SystemProxyBackendError.preferencesCreationFailed(reason: lastSCError())
        }

        // Never block indefinitely behind another preferences writer. This is
        // especially important during app termination, where restoration must
        // fail promptly and leave its recovery lease intact for a retry.
        guard SCPreferencesLock(preferences, false) else {
            throw SystemProxyBackendError.preferencesLockFailed(reason: lastSCError())
        }
        defer { SCPreferencesUnlock(preferences) }

        for mutation in mutations {
            guard let service = SCNetworkServiceCopy(preferences, mutation.serviceID as CFString) else {
                throw SystemProxyBackendError.serviceNotFound(name: mutation.serviceName)
            }

            let currentConfiguration: Data
            do {
                currentConfiguration = try readService(service).configuration
            } catch {
                throw SystemProxyBackendError.invalidConfiguration(
                    name: mutation.serviceName,
                    reason: error.localizedDescription
                )
            }
            guard SystemProxyPropertyList.configurationsEqual(
                currentConfiguration,
                mutation.expectedConfiguration
            ) else {
                throw SystemProxyBackendError.configurationChanged(name: mutation.serviceName)
            }

            var proxyProtocol = SCNetworkServiceCopyProtocol(
                service,
                kSCNetworkProtocolTypeProxies
            )
            if proxyProtocol == nil {
                guard SCNetworkServiceAddProtocolType(service, kSCNetworkProtocolTypeProxies) else {
                    throw SystemProxyBackendError.proxyProtocolUnavailable(
                        name: mutation.serviceName,
                        reason: lastSCError()
                    )
                }
                proxyProtocol = SCNetworkServiceCopyProtocol(
                    service,
                    kSCNetworkProtocolTypeProxies
                )
            }
            guard let proxyProtocol else {
                throw SystemProxyBackendError.proxyProtocolUnavailable(
                    name: mutation.serviceName,
                    reason: lastSCError()
                )
            }

            let dictionary: [String: Any]
            do {
                dictionary = try SystemProxyPropertyList.decode(mutation.configuration)
            } catch {
                throw SystemProxyBackendError.invalidConfiguration(
                    name: mutation.serviceName,
                    reason: error.localizedDescription
                )
            }

            guard SCNetworkProtocolSetConfiguration(proxyProtocol, dictionary as CFDictionary) else {
                throw SystemProxyBackendError.configurationSetFailed(
                    name: mutation.serviceName,
                    reason: lastSCError()
                )
            }
        }

        let serviceNames = mutations.map(\.serviceName).sorted()
        guard SCPreferencesCommitChanges(preferences) else {
            throw SystemProxyBackendError.commitFailed(
                serviceNames: serviceNames,
                reason: lastSCError()
            )
        }
        guard SCPreferencesApplyChanges(preferences) else {
            throw SystemProxyBackendError.applyFailed(
                serviceNames: serviceNames,
                reason: lastSCError()
            )
        }
    }

    /// Keeps one Authorization Services session for the lifetime of the app.
    /// The first protected mutation can still require administrator approval,
    /// but restoring or toggling the same system proxy no longer creates a new
    /// authorization session and prompts again immediately.
    private func mutationAuthorization() throws -> AuthorizationRef {
        if let reference = authorizationSession.reference {
            return reference
        }

        var createdAuthorization: AuthorizationRef?
        let status = AuthorizationCreate(
            nil,
            nil,
            [],
            &createdAuthorization
        )
        guard status == errAuthorizationSuccess, let createdAuthorization else {
            throw SystemProxyBackendError.authorizationFailed(status: status)
        }

        let rightsStatus = "system.preferences.network".withCString { rightName in
            var networkPreferencesItem = AuthorizationItem(
                name: rightName,
                valueLength: 0,
                value: nil,
                flags: 0
            )
            return withUnsafeMutablePointer(to: &networkPreferencesItem) { itemPointer in
                var rights = AuthorizationRights(count: 1, items: itemPointer)
                return AuthorizationCopyRights(
                    createdAuthorization,
                    &rights,
                    nil,
                    [.interactionAllowed, .extendRights, .preAuthorize],
                    nil
                )
            }
        }
        guard rightsStatus == errAuthorizationSuccess else {
            AuthorizationFree(createdAuthorization, [])
            throw SystemProxyBackendError.authorizationFailed(status: rightsStatus)
        }
        authorizationSession.reference = createdAuthorization
        return createdAuthorization
    }

    private func makeReadPreferences() throws -> SCPreferences {
        guard let preferences = SCPreferencesCreate(nil, sessionName as CFString, nil) else {
            throw SystemProxyBackendError.preferencesCreationFailed(reason: lastSCError())
        }
        SCPreferencesSynchronize(preferences)
        return preferences
    }

    private func readService(_ service: SCNetworkService) throws -> SystemProxyBackendService {
        guard let identifier = SCNetworkServiceGetServiceID(service) as String? else {
            throw SystemProxyBackendError.serviceIdentityUnavailable(reason: lastSCError())
        }
        let name = (SCNetworkServiceGetName(service) as String?) ?? identifier

        let dictionary: [String: Any]
        if
            let proxyProtocol = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies),
            let configuration = SCNetworkProtocolGetConfiguration(proxyProtocol)
        {
            dictionary = configuration as NSDictionary as? [String: Any] ?? [:]
        } else {
            dictionary = [:]
        }

        do {
            return SystemProxyBackendService(
                id: identifier,
                name: name,
                isEnabled: SCNetworkServiceGetEnabled(service),
                configuration: try SystemProxyPropertyList.encode(dictionary)
            )
        } catch {
            throw SystemProxyBackendError.invalidConfiguration(
                name: name,
                reason: error.localizedDescription
            )
        }
    }

    private func serviceOrder(
        _ lhs: SystemProxyBackendService,
        _ rhs: SystemProxyBackendService
    ) -> Bool {
        if lhs.name != rhs.name {
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        return lhs.id < rhs.id
    }

    private func lastSCError() -> String {
        let code = SCError()
        let description = SCErrorString(code)
        return String(cString: description)
    }
}

nonisolated enum SystemProxyBackendError: Error, Equatable, Sendable {
    case authorizationFailed(status: OSStatus)
    case preferencesCreationFailed(reason: String)
    case preferencesLockFailed(reason: String)
    case currentNetworkSetUnavailable(reason: String)
    case serviceEnumerationFailed(reason: String)
    case serviceIdentityUnavailable(reason: String)
    case serviceNotFound(name: String)
    case proxyProtocolUnavailable(name: String, reason: String)
    case invalidConfiguration(name: String, reason: String)
    case configurationChanged(name: String)
    case configurationSetFailed(name: String, reason: String)
    case commitFailed(serviceNames: [String], reason: String)
    case applyFailed(serviceNames: [String], reason: String)
}

extension SystemProxyBackendError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .authorizationFailed(status):
            "System proxy authorization failed with status \(status)."
        case let .preferencesCreationFailed(reason):
            "Could not open SystemConfiguration preferences: \(reason)"
        case let .preferencesLockFailed(reason):
            "Could not lock SystemConfiguration preferences: \(reason)"
        case let .currentNetworkSetUnavailable(reason):
            "Could not read the current network location: \(reason)"
        case let .serviceEnumerationFailed(reason):
            "Could not enumerate network services: \(reason)"
        case let .serviceIdentityUnavailable(reason):
            "A network service has no stable identifier: \(reason)"
        case let .serviceNotFound(name):
            "Network service \(name) no longer exists."
        case let .proxyProtocolUnavailable(name, reason):
            "Could not access proxy settings for \(name): \(reason)"
        case let .invalidConfiguration(name, reason):
            "Proxy settings for \(name) are invalid: \(reason)"
        case let .configurationChanged(name):
            "Proxy settings for \(name) changed before Vela could apply them. Nothing was committed."
        case let .configurationSetFailed(name, reason):
            "Could not stage proxy settings for \(name): \(reason)"
        case let .commitFailed(serviceNames, reason):
            "Could not save proxy settings for \(serviceNames.joined(separator: ", ")): \(reason)"
        case let .applyFailed(serviceNames, reason):
            "Could not apply proxy settings for \(serviceNames.joined(separator: ", ")): \(reason)"
        }
    }
}

extension SystemProxyBackendError {
    var definitelyRejectedBeforeCommit: Bool {
        switch self {
        case .authorizationFailed,
             .preferencesCreationFailed,
             .preferencesLockFailed,
             .serviceNotFound,
             .proxyProtocolUnavailable,
             .invalidConfiguration,
             .configurationChanged,
             .configurationSetFailed:
            return true
        case .currentNetworkSetUnavailable,
             .serviceEnumerationFailed,
             .serviceIdentityUnavailable,
             .commitFailed,
             .applyFailed:
            return false
        }
    }
}
