import Foundation

nonisolated private struct FixedCoreExecutableResolver: MihomoExecutableResolving {
    let executable: ResolvedMihomoExecutable

    func resolve() async throws -> ResolvedMihomoExecutable {
        executable
    }
}

/// Decodes the Controller responses Vela depends on instead of accepting an
/// arbitrary HTTP 2xx body. A Core with a schema-incompatible Controller is a
/// critical compatibility failure even when the process itself stays alive.
nonisolated struct CoreControllerAPIContractProbe: Sendable {
    let api: any MihomoAPIProviding

    func run() async throws {
        async let version = api.version()
        async let configs = api.configs()
        async let proxies = api.proxies()
        async let rules = api.rules()
        let decoded = try await (version, configs, proxies, rules)
        guard !decoded.0.version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw InstalledCorePreflightError.smokeFailed
        }
        _ = decoded.1
        _ = decoded.2
        _ = decoded.3
    }
}

/// Runs a candidate in an isolated temporary home against a dedicated
/// loopback Controller endpoint. It checks only process/API compatibility;
/// internet or proxy-node reachability is deliberately outside the signal so
/// an ordinary network outage cannot quarantine a Core.
nonisolated struct LiveCoreSmokeTester: CoreSmokeTesting, Sendable {
    private let startupTimeout: Duration
    private let pollInterval: Duration

    init(
        startupTimeout: Duration = .seconds(8),
        pollInterval: Duration = .milliseconds(200)
    ) {
        self.startupTimeout = max(.seconds(1), startupTimeout)
        self.pollInterval = max(.milliseconds(50), pollInterval)
    }

    func run(_ request: CoreSmokeTestRequest) async throws -> CoreSmokeTestResult {
        let manager = await MihomoProcessManager(
            resolver: FixedCoreExecutableResolver(executable: request.executable),
            validator: ConfigurationValidator()
        )
        var started = false
        do {
            let snapshot = try await manager.start(
                configurationURL: request.configurationURL,
                dataDirectoryURL: request.temporaryHomeURL,
                validationTimeout: .seconds(10)
            )
            started = snapshot.isRunning
            guard started else { throw InstalledCorePreflightError.smokeFailed }

            let controllerResponded = try await waitForController(
                endpoint: request.controllerEndpoint,
                secret: request.controllerSecret,
                manager: manager
            )
            let stop = try await manager.stop(timeout: .seconds(3))
            let stillRunning = await manager.isRunning()
            let stoppedCleanly = stop != nil && !stillRunning
            return CoreSmokeTestResult(
                controllerAPIProfile: request.controllerAPIProfile,
                started: true,
                controllerResponded: controllerResponded,
                stoppedCleanly: stoppedCleanly
            )
        } catch {
            let stillRunning = await manager.isRunning()
            if started || stillRunning {
                _ = try? await manager.stop(timeout: .seconds(3))
            }
            if error is CancellationError { throw CancellationError() }
            throw error
        }
    }

    private func waitForController(
        endpoint: URL,
        secret: String,
        manager: MihomoProcessManager
    ) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: startupTimeout)
        while clock.now < deadline {
            try Task.checkCancellation()
            guard await manager.isRunning() else {
                throw InstalledCorePreflightError.smokeFailed
            }
            if await probeRequiredEndpoints(baseURL: endpoint, secret: secret) {
                return true
            }
            try await Task.sleep(for: pollInterval)
        }
        throw InstalledCorePreflightError.smokeFailed
    }

    private func probeRequiredEndpoints(baseURL: URL, secret: String) async -> Bool {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 1
        configuration.timeoutIntervalForResource = 1
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let api = MihomoAPIClient(
            baseURL: baseURL,
            secret: secret,
            session: session,
            retryPolicy: MihomoRetryPolicy(maximumRetryCount: 0),
            requestTimeout: 1
        )
        do {
            try await CoreControllerAPIContractProbe(api: api).run()
            return true
        } catch {
            return false
        }
    }
}
