import Foundation
import Synchronization
import Testing
import VelaIPC
@testable import Vela

@Suite("Runtime controller router")
struct RuntimeControllerRouterTests {
    @Test("Telemetry follows the active runtime endpoint and secret")
    func telemetryRebinds() async throws {
        let transport = RuntimeRouterTransport()
        let firstInstance = UUID()
        let router = RuntimeControllerRouter(
            initialInstanceID: firstInstance,
            endpoint: URL(string: "http://127.0.0.1:19090")!,
            secret: SecretValue("first-secret"),
            telemetryTransport: transport,
            connectionsTransport: transport
        )

        let first = try await firstValue(from: router.traffic())
        #expect(first.downloadBytesPerSecond == 2)
        let firstRequest = try #require(transport.recordedRequests().first)
        #expect(firstRequest.url?.port == 19_090)
        #expect(firstRequest.value(forHTTPHeaderField: "Authorization") == "Bearer first-secret")

        let secondInstance = UUID()
        _ = try await router.bind(
            instanceID: secondInstance,
            backend: .privilegedDaemon,
            endpoint: try #require(URL(string: "http://127.0.0.1:29090")),
            secret: SecretValue("second-secret")
        )
        _ = try await firstValue(from: router.traffic())

        let requests = transport.recordedRequests()
        #expect(requests.count == 2)
        #expect(requests[1].url?.port == 29_090)
        #expect(requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer second-secret")
        #expect(await router.binding()?.instanceID == secondInstance)

        await router.unbind(instanceID: firstInstance)
        #expect(await router.binding()?.instanceID == secondInstance)
        await router.unbind(instanceID: secondInstance)
        #expect(await router.binding() == nil)
    }

    @Test("Traffic routing keeps only the newest buffered sample")
    func trafficRoutingKeepsNewestSample() async throws {
        let transport = RuntimeRouterBurstTransport(downloadValues: [1, 2, 3, 4])
        let router = RuntimeControllerRouter(
            initialInstanceID: UUID(),
            endpoint: URL(string: "http://127.0.0.1:19090")!,
            secret: SecretValue("secret"),
            telemetryTransport: transport,
            connectionsTransport: transport
        )

        let stream = router.traffic()
        while transport.deliveredCount < 4 {
            try await Task.sleep(for: .milliseconds(1))
        }

        let sample = try await firstValue(from: stream)
        #expect(sample.downloadBytesPerSecond == 4)
    }

    @Test("Non-loopback controller bindings are rejected")
    func rejectsNonLoopbackBinding() async throws {
        let router = RuntimeControllerRouter()
        await #expect(throws: RuntimeControllerRouterError.self) {
            _ = try await router.bind(
                instanceID: UUID(),
                backend: .privilegedDaemon,
                endpoint: try #require(URL(string: "http://192.0.2.10:9090")),
                secret: SecretValue("redacted")
            )
        }
        #expect(await router.binding() == nil)
    }

    private func firstValue<Element: Sendable>(
        from stream: AsyncThrowingStream<Element, Error>
    ) async throws -> Element {
        var iterator = stream.makeAsyncIterator()
        return try #require(try await iterator.next())
    }
}

private final class RuntimeRouterTransport: TelemetryWebSocketTransporting, Sendable {
    private let requests = Mutex<[URLRequest]>([])

    func connect(request: URLRequest) async throws -> any TelemetryWebSocketConnection {
        requests.withLock { $0.append(request) }
        return RuntimeRouterConnection()
    }

    func recordedRequests() -> [URLRequest] {
        requests.withLock { $0 }
    }
}

private actor RuntimeRouterConnection: TelemetryWebSocketConnection {
    private var delivered = false

    func receive() async throws -> TelemetryWebSocketMessage {
        guard !delivered else { throw CancellationError() }
        delivered = true
        return .data(Data("""
        {"up":1,"down":2,"upTotal":3,"downTotal":4}
        """.utf8))
    }

    func close() async {}
}

private final class RuntimeRouterBurstTransport: TelemetryWebSocketTransporting, Sendable {
    private let downloadValues: [UInt64]
    private let delivered = Mutex(0)

    init(downloadValues: [UInt64]) {
        self.downloadValues = downloadValues
    }

    var deliveredCount: Int {
        delivered.withLock { $0 }
    }

    func connect(request _: URLRequest) async throws -> any TelemetryWebSocketConnection {
        RuntimeRouterBurstConnection(downloadValues: downloadValues) { [weak self] in
            self?.recordDelivery()
        }
    }

    private func recordDelivery() {
        delivered.withLock { $0 += 1 }
    }
}

private actor RuntimeRouterBurstConnection: TelemetryWebSocketConnection {
    private var downloadValues: [UInt64]
    private let didDeliver: @Sendable () -> Void

    init(downloadValues: [UInt64], didDeliver: @escaping @Sendable () -> Void) {
        self.downloadValues = downloadValues
        self.didDeliver = didDeliver
    }

    func receive() async throws -> TelemetryWebSocketMessage {
        guard !downloadValues.isEmpty else { throw CancellationError() }
        let value = downloadValues.removeFirst()
        didDeliver()
        return .data(Data("""
        {"up":1,"down":\(value),"upTotal":3,"downTotal":4}
        """.utf8))
    }

    func close() async {}
}
