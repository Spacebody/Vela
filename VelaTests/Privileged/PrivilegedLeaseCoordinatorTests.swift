import Foundation
import Testing
import VelaIPC
@testable import Vela

@Suite("Privileged lease coordinator")
struct PrivilegedLeaseCoordinatorTests {
    @Test("A stalled event consumer retains only the newest bounded suffix")
    func stalledConsumerReceivesNewestBoundedSuffix() async {
        let coordinator = PrivilegedLeaseCoordinator(
            client: PrivilegedLeaseClientFake(),
            renewalInterval: .seconds(60)
        )
        let stream = await coordinator.events()
        var expected: [PrivilegedLeaseEvent] = []

        for _ in 0..<6 {
            let sessionID = UUID()
            let started = PrivilegedLeaseEvent.started(sessionID: sessionID, instanceID: nil)
            expected.append(started)
            expected.append(.stopped)
            await coordinator.start(sessionID: sessionID, instanceID: nil)
            await coordinator.stop()
        }

        var iterator = stream.makeAsyncIterator()
        var received: [PrivilegedLeaseEvent] = []
        for _ in 0..<8 {
            if let event = await iterator.next() {
                received.append(event)
            }
        }

        #expect(received == Array(expected.suffix(8)))
    }
}

private actor PrivilegedLeaseClientFake: PrivilegedHelperClientProtocol {
    private enum Failure: Error { case unexpectedCall }

    func handshake(
        clientVersion: String,
        clientBuild: String,
        requestedSessionID: UUID?
    ) async throws -> HelperHandshakeResponse {
        throw Failure.unexpectedCall
    }

    func status() async throws -> HelperStatusResponse { throw Failure.unexpectedCall }

    func prepareStart(_ request: PrepareStartRequest) async throws -> PrepareStartResponse {
        throw Failure.unexpectedCall
    }

    func stageConfiguration(_ request: StageConfigurationRequest, data: Data) async throws {
        throw Failure.unexpectedCall
    }

    func stageResource(_ request: StageResourceRequest, file: FileHandle) async throws {
        throw Failure.unexpectedCall
    }

    func commitStart(_ request: CommitStartRequest) async throws -> PrivilegedEngineRuntime {
        throw Failure.unexpectedCall
    }

    func abortStart(_ request: AbortStartRequest) async throws { throw Failure.unexpectedCall }
    func stop(_ request: StopHelperRequest) async throws { throw Failure.unexpectedCall }
    func renewLease(_ request: RenewLeaseRequest) async throws {}

    func readLogBatch(_ request: ReadLogBatchRequest) async throws -> ReadLogBatchResponse {
        throw Failure.unexpectedCall
    }

    func cleanup(_ request: CleanupHelperRequest) async throws { throw Failure.unexpectedCall }
    func invalidate() async {}
}
