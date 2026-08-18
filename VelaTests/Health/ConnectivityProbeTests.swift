import Foundation
import Synchronization
import Testing
@testable import Vela

@Suite("Connectivity probe")
struct ConnectivityProbeTests {
    @Test("A satisfied path combines Internet and mixed-port checks")
    func combinesChecks() async {
        let checks = ConnectivityChecksFake(
            internet: .success("Internet is reachable."),
            port: .failure("Mixed port is closed.")
        )
        let probe = ConnectivityProbe(
            internetChecker: checks,
            portChecker: checks
        )
        let path = NetworkPathSnapshot(
            status: .satisfied,
            isExpensive: true,
            isConstrained: true
        )

        let result = await probe.probe(
            networkPath: path,
            host: "127.0.0.1",
            mixedPort: 7_890
        )

        #expect(result.networkReachable)
        #expect(result.internetReachable)
        #expect(!result.mixedPortListening)
        #expect(result.details == [
            "Network path is satisfied.",
            "Internet is reachable.",
            "Mixed port is closed."
        ])
        #expect(await checks.internetCallCount == 1)
        #expect(await checks.portRequests == [
            ConnectivityPortRequest(host: "127.0.0.1", port: 7_890)
        ])
    }

    @Test("An unsatisfied path skips the external request but still checks localhost")
    func offlinePathSkipsInternetOnly() async {
        let checks = ConnectivityChecksFake(
            internet: .success("This result must not be used."),
            port: .success("Mixed port is listening.")
        )
        let probe = ConnectivityProbe(
            internetChecker: checks,
            portChecker: checks
        )

        let result = await probe.probe(
            networkPath: NetworkPathSnapshot(status: .unsatisfied),
            host: "127.0.0.1",
            mixedPort: 7_890
        )

        #expect(!result.networkReachable)
        #expect(!result.internetReachable)
        #expect(result.mixedPortListening)
        #expect(result.details[1].contains("was skipped"))
        #expect(await checks.internetCallCount == 0)
        #expect(await checks.portRequests.count == 1)
    }

    @Test("The HTTP checker requires the configured status code")
    func expectedHTTPStatusIsStrict() async throws {
        defer { ConnectivityProbeMockURLProtocol.reset() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ConnectivityProbeMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let request = URLRequest(
            url: try #require(URL(string: "https://connectivity.example.test/generate_204"))
        )
        let checker = URLSessionInternetConnectivityChecker(
            request: request,
            session: session,
            expectedStatusCode: 204
        )

        ConnectivityProbeMockURLProtocol.setStatusCode(204)
        let passing = await checker.check()
        #expect(passing.succeeded)

        ConnectivityProbeMockURLProtocol.setStatusCode(200)
        let failing = await checker.check()
        #expect(!failing.succeeded)
        #expect(failing.detail.contains("expected 204"))
    }

    @Test("Invalid mixed-port input fails without opening a connection")
    func invalidPortFailsLocally() async {
        let result = await TCPPortProbe().check(host: "127.0.0.1", port: 0)

        #expect(!result.succeeded)
        #expect(result.detail.contains("invalid host or port"))
    }
}

nonisolated private struct ConnectivityPortRequest: Equatable, Sendable {
    let host: String
    let port: UInt16
}

private actor ConnectivityChecksFake: InternetConnectivityChecking, TCPPortChecking {
    private let internet: ConnectivityCheckResult
    private let port: ConnectivityCheckResult
    private(set) var internetCallCount = 0
    private(set) var portRequests: [ConnectivityPortRequest] = []

    init(internet: ConnectivityCheckResult, port: ConnectivityCheckResult) {
        self.internet = internet
        self.port = port
    }

    func check() -> ConnectivityCheckResult {
        internetCallCount += 1
        return internet
    }

    func check(host: String, port: UInt16) -> ConnectivityCheckResult {
        portRequests.append(ConnectivityPortRequest(host: host, port: port))
        return self.port
    }
}

nonisolated private final class ConnectivityProbeMockURLProtocol: URLProtocol, @unchecked Sendable {
    private static let statusCode = Mutex(204)

    static func setStatusCode(_ value: Int) {
        statusCode.withLock { $0 = value }
    }

    static func reset() {
        setStatusCode(204)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url,
            let response = HTTPURLResponse(
                url: url,
                statusCode: Self.statusCode.withLock { $0 },
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
