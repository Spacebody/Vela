import Foundation
import VelaIPC
import VelaPrivilegedCore

/// Per-connection exported object. It owns only transport mechanics; all
/// privileged mutable state remains serialized by `PrivilegedHelperCoordinator`.
final class VelaHelperXPCService: NSObject, VelaHelperProtocol, @unchecked Sendable {
    private let coordinator: PrivilegedHelperCoordinator
    private let connection: AuthenticatedHelperConnection

    init(
        coordinator: PrivilegedHelperCoordinator,
        connection: AuthenticatedHelperConnection
    ) {
        self.coordinator = coordinator
        self.connection = connection
    }

    func handshake(
        _ request: Data,
        withReply reply: @escaping @Sendable (Data?, NSError?) -> Void
    ) {
        perform(request, reply: reply) { [coordinator, connection] request in
            try await coordinator.handshake(request, connection: connection)
        }
    }

    func status(
        _ request: Data,
        withReply reply: @escaping @Sendable (Data?, NSError?) -> Void
    ) {
        perform(request, reply: reply) { [coordinator, connection] request in
            try await coordinator.status(request, connectionID: connection.connectionID)
        }
    }

    func prepareStart(
        _ request: Data,
        withReply reply: @escaping @Sendable (Data?, NSError?) -> Void
    ) {
        perform(request, reply: reply) { [coordinator, connection] request in
            try await coordinator.prepareStart(
                request,
                connectionID: connection.connectionID
            )
        }
    }

    func stageConfiguration(
        _ transaction: Data,
        configuration: Data,
        withReply reply: @escaping @Sendable (Data?, NSError?) -> Void
    ) {
        perform(transaction, reply: reply) {
            [coordinator, connection] (request: StageConfigurationRequest) in
            guard configuration.count <= VelaIPCConstants.maximumConfigurationBytes else {
                throw VelaHelperFailure(
                    code: .payloadTooLarge,
                    requestID: request.requestID,
                    safeMessage: "The privileged configuration exceeds its size limit."
                )
            }
            return try await coordinator.stageConfiguration(
                request,
                configuration: configuration,
                connectionID: connection.connectionID
            )
        }
    }

    func stageResource(
        _ metadata: Data,
        file: FileHandle,
        withReply reply: @escaping @Sendable (Data?, NSError?) -> Void
    ) {
        perform(metadata, reply: reply) {
            [coordinator, connection] (request: StageResourceRequest) in
            defer { try? file.close() }
            return try await coordinator.stageResource(
                request,
                file: file,
                connectionID: connection.connectionID
            )
        }
    }

    func commitStart(
        _ request: Data,
        withReply reply: @escaping @Sendable (Data?, NSError?) -> Void
    ) {
        perform(request, reply: reply) { [coordinator, connection] request in
            try await coordinator.commitStart(request, connectionID: connection.connectionID)
        }
    }

    func abortStart(
        _ request: Data,
        withReply reply: @escaping @Sendable (Data?, NSError?) -> Void
    ) {
        perform(request, reply: reply) { [coordinator, connection] request in
            try await coordinator.abortStart(request, connectionID: connection.connectionID)
        }
    }

    func stop(
        _ request: Data,
        withReply reply: @escaping @Sendable (Data?, NSError?) -> Void
    ) {
        perform(request, reply: reply) { [coordinator, connection] request in
            try await coordinator.stop(request, connectionID: connection.connectionID)
        }
    }

    func renewLease(
        _ request: Data,
        withReply reply: @escaping @Sendable (Data?, NSError?) -> Void
    ) {
        perform(request, reply: reply) { [coordinator, connection] request in
            try await coordinator.renewLease(request, connectionID: connection.connectionID)
        }
    }

    func readLogBatch(
        _ request: Data,
        withReply reply: @escaping @Sendable (Data?, NSError?) -> Void
    ) {
        perform(
            request,
            maximumResponseBytes: VelaIPCConstants.maximumLogBatchBytes,
            reply: reply
        ) { [coordinator, connection] request in
            try await coordinator.readLogs(request, connectionID: connection.connectionID)
        }
    }

    func cleanup(
        _ request: Data,
        withReply reply: @escaping @Sendable (Data?, NSError?) -> Void
    ) {
        perform(request, reply: reply) { [coordinator, connection] request in
            try await coordinator.cleanup(request, connectionID: connection.connectionID)
        }
    }

    func prepareCoreInstall(
        _ request: Data,
        withReply reply: @escaping @Sendable (Data?, NSError?) -> Void
    ) {
        perform(
            request,
            maximumRequestBytes: VelaIPCConstants.maximumCoreInstallPayloadBytes,
            reply: reply
        ) { [coordinator, connection] request in
            try await coordinator.prepareCoreInstall(
                request,
                connectionID: connection.connectionID
            )
        }
    }

    func stageCoreFile(
        _ metadata: Data,
        file: FileHandle,
        withReply reply: @escaping @Sendable (Data?, NSError?) -> Void
    ) {
        perform(metadata, reply: reply) {
            [coordinator, connection] (request: StageCoreFileRequest) in
            defer { try? file.close() }
            return try await coordinator.stageCoreFile(
                request,
                file: file,
                connectionID: connection.connectionID
            )
        }
    }

    func commitCoreInstall(
        _ request: Data,
        withReply reply: @escaping @Sendable (Data?, NSError?) -> Void
    ) {
        perform(request, reply: reply) { [coordinator, connection] request in
            try await coordinator.commitCoreInstall(
                request,
                connectionID: connection.connectionID
            )
        }
    }

    func abortCoreInstall(
        _ request: Data,
        withReply reply: @escaping @Sendable (Data?, NSError?) -> Void
    ) {
        perform(request, reply: reply) { [coordinator, connection] request in
            try await coordinator.abortCoreInstall(
                request,
                connectionID: connection.connectionID
            )
        }
    }

    func listInstalledCores(
        _ request: Data,
        withReply reply: @escaping @Sendable (Data?, NSError?) -> Void
    ) {
        perform(request, reply: reply) { [coordinator, connection] request in
            try await coordinator.listInstalledCores(
                request,
                connectionID: connection.connectionID
            )
        }
    }

    func refreshCoreCatalog(
        _ request: Data,
        withReply reply: @escaping @Sendable (Data?, NSError?) -> Void
    ) {
        perform(
            request,
            maximumRequestBytes: VelaIPCConstants.maximumCoreInstallPayloadBytes,
            reply: reply
        ) { [coordinator, connection] request in
            try await coordinator.refreshCoreCatalog(
                request,
                connectionID: connection.connectionID
            )
        }
    }

    func removeCore(
        _ request: Data,
        withReply reply: @escaping @Sendable (Data?, NSError?) -> Void
    ) {
        perform(request, reply: reply) { [coordinator, connection] request in
            try await coordinator.removeCore(request, connectionID: connection.connectionID)
        }
    }

    func validateCore(
        _ request: Data,
        withReply reply: @escaping @Sendable (Data?, NSError?) -> Void
    ) {
        perform(request, reply: reply) { [coordinator, connection] request in
            try await coordinator.validateCore(request, connectionID: connection.connectionID)
        }
    }

    private func perform<Request: HelperPayload, Response: HelperPayload>(
        _ requestData: Data,
        maximumRequestBytes: Int = VelaIPCConstants.maximumPayloadBytes,
        maximumResponseBytes: Int = VelaIPCConstants.maximumPayloadBytes,
        reply: @escaping @Sendable (Data?, NSError?) -> Void,
        operation: @escaping @Sendable (Request) async throws -> Response
    ) {
        Task {
            var requestID: UUID?
            do {
                let request = try HelperPayloadCodec.decode(
                    Request.self,
                    from: requestData,
                    maximumBytes: maximumRequestBytes
                )
                requestID = request.requestID
                let response = try await operation(request)
                let encoded = try HelperPayloadCodec.encode(
                    response,
                    maximumBytes: maximumResponseBytes
                )
                reply(encoded, nil)
            } catch {
                let failure = VelaHelperFailure.from(error, requestID: requestID)
                reply(nil, failure.nsError)
            }
        }
    }
}
