import Foundation
import VelaIPC

nonisolated struct RuntimeControllerBinding: Equatable, Sendable {
    let instanceID: UUID
    let backend: EngineBackendKind
    let endpoint: URL
    let generation: UInt64
}

actor RuntimeControllerRouter: MihomoAPIProviding, MihomoTelemetryStreaming,
    MihomoConnectionsStreaming
{
    private struct ActiveBinding: Sendable {
        let snapshot: RuntimeControllerBinding
        let client: MihomoAPIClient
        let telemetry: MihomoTelemetryService
        let connections: MihomoConnectionsStream
    }

    private let telemetryTransport: any TelemetryWebSocketTransporting
    private let connectionsTransport: any TelemetryWebSocketTransporting
    private var active: ActiveBinding?
    private var generation: UInt64 = 0

    init(
        initialInstanceID: UUID? = nil,
        initialBackend: EngineBackendKind = .userProcess,
        endpoint: URL? = nil,
        secret: SecretValue? = nil,
        telemetryTransport: any TelemetryWebSocketTransporting = URLSessionWebSocketTransport(),
        connectionsTransport: any TelemetryWebSocketTransporting = URLSessionWebSocketTransport()
    ) {
        self.telemetryTransport = telemetryTransport
        self.connectionsTransport = connectionsTransport
        guard let endpoint, let secret, Self.isLoopback(endpoint) else { return }
        generation = 1
        let snapshot = RuntimeControllerBinding(
            instanceID: initialInstanceID ?? UUID(),
            backend: initialBackend,
            endpoint: endpoint,
            generation: generation
        )
        active = Self.makeBinding(
            snapshot: snapshot,
            endpoint: endpoint,
            secret: secret,
            telemetryTransport: telemetryTransport,
            connectionsTransport: connectionsTransport
        )
    }

    @discardableResult
    func bind(
        instanceID: UUID,
        backend: EngineBackendKind,
        endpoint: URL,
        secret: SecretValue
    ) throws -> RuntimeControllerBinding {
        guard Self.isLoopback(endpoint) else {
            throw RuntimeControllerRouterError.nonLoopbackController(endpoint.absoluteString)
        }
        generation &+= 1
        let snapshot = RuntimeControllerBinding(
            instanceID: instanceID,
            backend: backend,
            endpoint: endpoint,
            generation: generation
        )
        active = Self.makeBinding(
            snapshot: snapshot,
            endpoint: endpoint,
            secret: secret,
            telemetryTransport: telemetryTransport,
            connectionsTransport: connectionsTransport
        )
        return snapshot
    }

    func unbind(instanceID: UUID) {
        guard active?.snapshot.instanceID == instanceID else { return }
        generation &+= 1
        active = nil
    }

    func binding() -> RuntimeControllerBinding? {
        active?.snapshot
    }

    nonisolated func logs(level: LogLevel?) -> AsyncThrowingStream<LogEntry, Error> {
        routedTelemetryStream(
            bufferingPolicy: .bufferingNewest(LogBuffer.maximumCapacity)
        ) { $0.logs(level: level) }
    }

    nonisolated func traffic() -> AsyncThrowingStream<TrafficSample, Error> {
        routedTelemetryStream(bufferingPolicy: .bufferingNewest(1)) { $0.traffic() }
    }

    nonisolated func snapshots(
        generation configurationGeneration: ConfigurationGeneration
    ) -> AsyncThrowingStream<ConnectionsStreamEvent, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let worker = Task {
                do {
                    let route = try await self.connectionsRoute()
                    for try await event in route.stream.snapshots(
                        generation: configurationGeneration
                    ) {
                        try Task.checkCancellation()
                        guard await self.isCurrent(route.generation) else {
                            throw RuntimeControllerRouterError.bindingChanged
                        }
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in worker.cancel() }
        }
    }

    func stop() async {
        await active?.connections.stop()
    }

    func version() async throws -> MihomoVersion { try await client().version() }
    func configs() async throws -> MihomoConfigs { try await client().configs() }
    func patchConfigs(_ patch: MihomoConfigPatch) async throws {
        try await client().patchConfigs(patch)
    }
    func reloadConfiguration(at configurationURL: URL, force: Bool) async throws {
        try await client().reloadConfiguration(at: configurationURL, force: force)
    }
    func proxies() async throws -> MihomoProxiesResponse { try await client().proxies() }
    func proxy(named name: String) async throws -> MihomoProxy {
        try await client().proxy(named: name)
    }
    func proxyProviders() async throws -> MihomoProxyProvidersResponse {
        try await client().proxyProviders()
    }
    func proxyProvider(named name: String) async throws -> MihomoProxyProvider {
        try await client().proxyProvider(named: name)
    }
    func updateProxyProvider(named name: String) async throws {
        try await client().updateProxyProvider(named: name)
    }
    func healthCheckProxyProvider(named name: String) async throws {
        try await client().healthCheckProxyProvider(named: name)
    }
    func proxyProviderProxy(provider: String, name: String) async throws -> MihomoProxy {
        try await client().proxyProviderProxy(provider: provider, name: name)
    }
    func proxyProviderProxyDelay(
        provider: String,
        name: String,
        url: String,
        timeoutMilliseconds: Int,
        expectedStatus: String?
    ) async throws -> MihomoProxyDelayResponse {
        try await client().proxyProviderProxyDelay(
            provider: provider,
            name: name,
            url: url,
            timeoutMilliseconds: timeoutMilliseconds,
            expectedStatus: expectedStatus
        )
    }
    func ruleProviders() async throws -> MihomoRuleProvidersResponse {
        try await client().ruleProviders()
    }
    func updateRuleProvider(named name: String) async throws {
        try await client().updateRuleProvider(named: name)
    }
    func connections() async throws -> ConnectionsSnapshot { try await client().connections() }
    func closeConnection(id: String) async throws { try await client().closeConnection(id: id) }
    func closeAllConnections() async throws { try await client().closeAllConnections() }
    func rules() async throws -> MihomoRulesResponse { try await client().rules() }
    func setRulesDisabled(_ disabledByIndex: [Int: Bool]) async throws {
        try await client().setRulesDisabled(disabledByIndex)
    }
    func updateGeoDatabases() async throws { try await client().updateGeoDatabases() }
    func selectProxy(group: String, proxy: String) async throws {
        try await client().selectProxy(group: group, proxy: proxy)
    }
    func proxyDelay(
        name: String,
        url: String,
        timeoutMilliseconds: Int,
        expectedStatus: String?
    ) async throws -> MihomoProxyDelayResponse {
        try await client().proxyDelay(
            name: name,
            url: url,
            timeoutMilliseconds: timeoutMilliseconds,
            expectedStatus: expectedStatus
        )
    }

    private func client() throws -> MihomoAPIClient {
        guard let active else {
            throw MihomoAPIError.transport(
                code: .notConnectedToInternet,
                message: "No active Mihomo Controller runtime is bound."
            )
        }
        return active.client
    }

    private func telemetryRoute() throws -> (
        generation: UInt64,
        service: MihomoTelemetryService
    ) {
        guard let active else { throw RuntimeControllerRouterError.notBound }
        return (active.snapshot.generation, active.telemetry)
    }

    private func connectionsRoute() throws -> (
        generation: UInt64,
        stream: MihomoConnectionsStream
    ) {
        guard let active else { throw RuntimeControllerRouterError.notBound }
        return (active.snapshot.generation, active.connections)
    }

    private func isCurrent(_ expectedGeneration: UInt64) -> Bool {
        active?.snapshot.generation == expectedGeneration
    }

    private nonisolated func routedTelemetryStream<Element: Sendable>(
        bufferingPolicy: AsyncThrowingStream<Element, Error>.Continuation.BufferingPolicy,
        _ makeSource: @escaping @Sendable (
            MihomoTelemetryService
        ) -> AsyncThrowingStream<Element, Error>
    ) -> AsyncThrowingStream<Element, Error> {
        AsyncThrowingStream(bufferingPolicy: bufferingPolicy) { continuation in
            let worker = Task {
                do {
                    let route = try await self.telemetryRoute()
                    for try await value in makeSource(route.service) {
                        try Task.checkCancellation()
                        guard await self.isCurrent(route.generation) else {
                            throw RuntimeControllerRouterError.bindingChanged
                        }
                        continuation.yield(value)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in worker.cancel() }
        }
    }

    private nonisolated static func makeBinding(
        snapshot: RuntimeControllerBinding,
        endpoint: URL,
        secret: SecretValue,
        telemetryTransport: any TelemetryWebSocketTransporting,
        connectionsTransport: any TelemetryWebSocketTransporting
    ) -> ActiveBinding {
        secret.withValue { value in
            ActiveBinding(
                snapshot: snapshot,
                client: MihomoAPIClient(baseURL: endpoint, secret: value),
                telemetry: MihomoTelemetryService(
                    controllerURL: endpoint,
                    secret: value,
                    transport: telemetryTransport
                ),
                connections: MihomoConnectionsStream(
                    controllerURL: endpoint,
                    secret: value,
                    transport: connectionsTransport
                )
            )
        }
    }

    private nonisolated static func isLoopback(_ url: URL) -> Bool {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
            url.user == nil, url.password == nil,
            let host = url.host?.lowercased()
        else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }
}

nonisolated enum RuntimeControllerRouterError: Error, Equatable, Sendable {
    case nonLoopbackController(String)
    case notBound
    case bindingChanged
}
