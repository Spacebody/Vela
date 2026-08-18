import Foundation
import Network
import OSLog

nonisolated struct ConnectivityProbeResult: Equatable, Sendable {
    let networkReachable: Bool
    let internetReachable: Bool
    let mixedPortListening: Bool
    let details: [String]
}

nonisolated protocol ConnectivityProbing: Sendable {
    func probe(
        networkPath: NetworkPathSnapshot,
        host: String,
        mixedPort: UInt16
    ) async -> ConnectivityProbeResult
}

nonisolated struct ConnectivityCheckResult: Equatable, Sendable {
    let succeeded: Bool
    let detail: String

    static func success(_ detail: String) -> ConnectivityCheckResult {
        ConnectivityCheckResult(succeeded: true, detail: detail)
    }

    static func failure(_ detail: String) -> ConnectivityCheckResult {
        ConnectivityCheckResult(succeeded: false, detail: detail)
    }
}

nonisolated protocol InternetConnectivityChecking: Sendable {
    func check() async -> ConnectivityCheckResult
}

nonisolated protocol TCPPortChecking: Sendable {
    func check(host: String, port: UInt16) async -> ConnectivityCheckResult
}

nonisolated struct ConnectivityProbe: ConnectivityProbing, Sendable {
    private nonisolated static let logger = Logger(
        subsystem: "dev.yilin.Vela",
        category: "ConnectivityProbe"
    )

    private let internetChecker: any InternetConnectivityChecking
    private let portChecker: any TCPPortChecking

    init() {
        internetChecker = URLSessionInternetConnectivityChecker()
        portChecker = TCPPortProbe()
    }

    init(
        internetChecker: any InternetConnectivityChecking,
        portChecker: any TCPPortChecking
    ) {
        self.internetChecker = internetChecker
        self.portChecker = portChecker
    }

    func probe(
        networkPath: NetworkPathSnapshot,
        host: String,
        mixedPort: UInt16
    ) async -> ConnectivityProbeResult {
        async let portCheck = portChecker.check(host: host, port: mixedPort)
        let internet: ConnectivityCheckResult
        if networkPath.networkReachable {
            internet = await internetChecker.check()
        } else {
            internet = .failure(
                "Internet probe was skipped because the network path is not satisfied."
            )
        }
        let port = await portCheck

        let result = ConnectivityProbeResult(
            networkReachable: networkPath.networkReachable,
            internetReachable: internet.succeeded,
            mixedPortListening: port.succeeded,
            details: [networkPath.diagnosticDetail, internet.detail, port.detail]
        )
        Self.logger.info(
            "Probe network=\(result.networkReachable, privacy: .public) internet=\(result.internetReachable, privacy: .public) mixedPort=\(result.mixedPortListening, privacy: .public)"
        )
        return result
    }
}

nonisolated struct URLSessionInternetConnectivityChecker: InternetConnectivityChecking, Sendable {
    private static let defaultURL = URL(string: "https://cp.cloudflare.com/generate_204")
        ?? URL(fileURLWithPath: "/invalid-vela-connectivity-probe-url")

    private let request: URLRequest
    private let session: URLSession
    private let expectedStatusCode: Int

    init(timeout: TimeInterval = 2) {
        self.init(
            url: Self.defaultURL,
            expectedStatusCode: 204,
            timeout: timeout
        )
    }

    init(
        url: URL,
        expectedStatusCode: Int = 204,
        timeout: TimeInterval = 2
    ) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = timeout

        self.request = request
        session = URLSession(configuration: configuration)
        self.expectedStatusCode = expectedStatusCode
    }

    init(
        request: URLRequest,
        session: URLSession,
        expectedStatusCode: Int = 204
    ) {
        self.request = request
        self.session = session
        self.expectedStatusCode = expectedStatusCode
    }

    func check() async -> ConnectivityCheckResult {
        do {
            let (_, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return .failure("Internet probe returned a non-HTTP response.")
            }
            guard httpResponse.statusCode == expectedStatusCode else {
                return .failure(
                    "Internet probe returned HTTP \(httpResponse.statusCode); expected \(expectedStatusCode)."
                )
            }
            return .success(
                "Internet probe returned HTTP \(httpResponse.statusCode)."
            )
        } catch is CancellationError {
            return .failure("Internet probe was cancelled.")
        } catch {
            return .failure("Internet probe failed: \(error.localizedDescription)")
        }
    }
}

nonisolated struct TCPPortProbe: TCPPortChecking, Sendable {
    private static let queue = DispatchQueue(
        label: "dev.yilin.Vela.TCPPortProbe",
        qos: .utility
    )

    private let timeout: Duration

    init(timeout: Duration = .seconds(2)) {
        self.timeout = timeout
    }

    func check(host: String, port: UInt16) async -> ConnectivityCheckResult {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty, port > 0,
            let endpointPort = NWEndpoint.Port(rawValue: port)
        else {
            return .failure("Mixed port probe received an invalid host or port.")
        }

        let connection = NWConnection(
            host: NWEndpoint.Host(trimmedHost),
            port: endpointPort,
            using: .tcp
        )
        let (states, continuation) = AsyncStream.makeStream(
            of: NWConnection.State.self,
            bufferingPolicy: .bufferingNewest(8)
        )
        connection.stateUpdateHandler = { state in
            continuation.yield(state)
        }
        connection.start(queue: Self.queue)

        let result = await withTaskCancellationHandler {
            await withTaskGroup(of: ConnectivityCheckResult.self) { group in
                group.addTask {
                    for await state in states {
                        guard !Task.isCancelled else { break }
                        if let result = Self.result(
                            for: state,
                            host: trimmedHost,
                            port: port
                        ) {
                            return result
                        }
                    }
                    return .failure("Mixed port probe was cancelled.")
                }
                group.addTask {
                    do {
                        try await Task.sleep(for: timeout)
                        return .failure(
                            "Mixed port probe timed out after \(timeout.formattedDescription)."
                        )
                    } catch {
                        return .failure("Mixed port probe was cancelled.")
                    }
                }

                let first = await group.next()
                    ?? .failure("Mixed port probe ended without a result.")
                group.cancelAll()
                continuation.finish()
                while await group.next() != nil {}
                return first
            }
        } onCancel: {
            connection.cancel()
            continuation.finish()
        }

        connection.stateUpdateHandler = nil
        connection.cancel()
        continuation.finish()
        return result
    }

    private static func result(
        for state: NWConnection.State,
        host: String,
        port: UInt16
    ) -> ConnectivityCheckResult? {
        switch state {
        case .setup, .preparing:
            nil
        case .ready:
            .success("Mixed port \(host):\(port) accepted a TCP connection.")
        case let .waiting(error):
            .failure("Mixed port \(host):\(port) is unavailable: \(error.localizedDescription)")
        case let .failed(error):
            .failure("Mixed port \(host):\(port) failed: \(error.localizedDescription)")
        case .cancelled:
            .failure("Mixed port probe was cancelled.")
        @unknown default:
            .failure("Mixed port probe entered an unknown state.")
        }
    }
}

nonisolated private extension NetworkPathSnapshot {
    var diagnosticDetail: String {
        switch status {
        case .unknown:
            "Network path has not reported an initial state."
        case .satisfied:
            "Network path is satisfied."
        case .unsatisfied:
            "Network path is unsatisfied."
        case .requiresConnection:
            "Network path requires a connection."
        }
    }
}

nonisolated private extension Duration {
    var formattedDescription: String {
        let components = self.components
        let seconds = Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
        return String(format: "%.1f seconds", seconds)
    }
}
