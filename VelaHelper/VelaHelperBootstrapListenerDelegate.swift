import Foundation
import VelaIPC
import VelaPrivilegedCore

/// Authenticates each client before installing any exported object or activating
/// the connection. The requirement is derived from the Helper's own valid Team
/// ID and the exact, compiled-in Vela application identifier.
final class VelaHelperBootstrapListenerDelegate: NSObject, NSXPCListenerDelegate,
    @unchecked Sendable
{
    private let signingIdentity: VelaHelperSigningIdentity
    private let coordinator: PrivilegedHelperCoordinator
    private let lock = NSLock()
    private var retainedConnections: [UUID: NSXPCConnection] = [:]

    init(
        signingIdentity: VelaHelperSigningIdentity,
        coordinator: PrivilegedHelperCoordinator
    ) {
        self.signingIdentity = signingIdentity
        self.coordinator = coordinator
    }

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        let connection = AuthenticatedHelperConnection(
            effectiveUserID: newConnection.effectiveUserIdentifier
        )
        let service = VelaHelperXPCService(
            coordinator: coordinator,
            connection: connection
        )

        // The string was parsed successfully with SecRequirement before the
        // listener was created. Foundation enforces it on every XPC message.
        newConnection.setCodeSigningRequirement(
            signingIdentity.mainApplicationRequirement
        )
        newConnection.exportedInterface = VelaHelperXPCInterface.make()
        newConnection.exportedObject = service
        newConnection.interruptionHandler = { [weak self] in
            self?.markDisconnected(connection.connectionID)
        }
        newConnection.invalidationHandler = { [weak self] in
            self?.removeConnection(connection.connectionID)
        }

        lock.withLock {
            retainedConnections[connection.connectionID] = newConnection
        }
        newConnection.activate()
        return true
    }

    private func markDisconnected(_ connectionID: UUID) {
        Task { await coordinator.connectionInvalidated(connectionID: connectionID) }
    }

    private func removeConnection(_ connectionID: UUID) {
        lock.withLock {
            _ = retainedConnections.removeValue(forKey: connectionID)
        }
        markDisconnected(connectionID)
    }
}
