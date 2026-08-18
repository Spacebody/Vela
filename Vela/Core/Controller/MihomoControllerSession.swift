import Foundation
import OSLog

nonisolated struct MihomoControllerSnapshot: Equatable, Sendable {
    let version: MihomoVersion
    let configs: MihomoConfigs
}

nonisolated struct MihomoProxyDelayResult: Equatable, Sendable {
    let proxyID: ProxyCatalogID
    let proxyName: String
    let delayMilliseconds: UInt16?
    let errorDescription: String?

    init(
        proxyName: String,
        delayMilliseconds: UInt16?,
        errorDescription: String? = nil
    ) {
        self.init(
            proxyID: ProxyCatalogID(origin: .runtime, name: proxyName),
            delayMilliseconds: delayMilliseconds,
            errorDescription: errorDescription
        )
    }

    init(
        proxyID: ProxyCatalogID,
        delayMilliseconds: UInt16?,
        errorDescription: String? = nil
    ) {
        self.proxyID = proxyID
        proxyName = proxyID.name
        self.delayMilliseconds = delayMilliseconds
        self.errorDescription = errorDescription
    }
}

nonisolated enum MihomoControllerEvent: Equatable, Sendable {
    case connecting
    case ready(MihomoControllerSnapshot)
    case proxiesUpdated(MihomoProxiesResponse)
    case proxyCatalogUpdated(ProxyCatalog)
    case proxiesUnavailable(String)
    case logsUpdated([LogEntry])
    case trafficUpdated(TrafficSample)
    case unavailable(String)
    case disconnected
}

nonisolated enum MihomoControllerSessionError: Error, Equatable, Sendable {
    case notConnected
    case modeChangeInProgress
    case proxyOperationInProgress
    case providerProxyOperationUnavailable(provider: String)
    case proxySelectionVerificationFailed(group: String, expected: String, actual: String?)
    case modeVerificationFailed(expected: MihomoMode, actual: MihomoMode)
}

extension MihomoControllerSessionError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .notConnected:
            "The Mihomo controller is not connected."
        case .modeChangeInProgress:
            "Another Mihomo runtime mode change is already in progress."
        case .proxyOperationInProgress:
            "Another proxy operation is already in progress."
        case let .providerProxyOperationUnavailable(provider):
            "Proxy provider operations are unavailable for \(provider)."
        case let .proxySelectionVerificationFailed(group, expected, actual):
            "Mihomo did not confirm \(expected) for \(group). Current selection: \(actual ?? "unknown")."
        case let .modeVerificationFailed(expected, actual):
            "Mihomo reported mode \(actual.rawValue) after Vela requested \(expected.rawValue)."
        }
    }
}

nonisolated protocol MihomoControllerManaging: Sendable {
    func events() async -> AsyncStream<MihomoControllerEvent>
    func start() async
    func refresh() async
    func stop() async
    func changeMode(_ mode: MihomoMode) async throws
    func refreshProxies() async throws
    func selectProxy(group: String, proxy: String) async throws
    func testProxyDelay(
        name: String,
        url: String,
        timeoutMilliseconds: Int,
        expectedStatus: String?
    ) async throws -> MihomoProxyDelayResult
    func testProxyDelay(
        nodeID: ProxyCatalogID,
        url: String,
        timeoutMilliseconds: Int,
        expectedStatus: String?
    ) async throws -> MihomoProxyDelayResult
    func testProxyGroupDelay(
        names: [String],
        url: String,
        timeoutMilliseconds: Int,
        expectedStatus: String?,
        concurrencyLimit: Int
    ) async throws -> [MihomoProxyDelayResult]
    func testProxyGroupDelay(
        nodeIDs: [ProxyCatalogID],
        url: String,
        timeoutMilliseconds: Int,
        expectedStatus: String?,
        concurrencyLimit: Int
    ) async throws -> [MihomoProxyDelayResult]
    func appendProcessOutput(_ output: MihomoProcessOutput) async
    func appendProcessOutputs(_ outputs: [MihomoProcessOutput]) async
    func recordApplicationLog(level: LogLevel, message: String) async
    func clearLogs() async
}

extension MihomoControllerManaging {
    func appendProcessOutputs(_ outputs: [MihomoProcessOutput]) async {
        for output in outputs {
            await appendProcessOutput(output)
        }
    }

    func recordApplicationLog(level: LogLevel, message: String) async {}

    func testProxyDelay(
        nodeID: ProxyCatalogID,
        url: String,
        timeoutMilliseconds: Int,
        expectedStatus: String?
    ) async throws -> MihomoProxyDelayResult {
        switch nodeID.origin {
        case .runtime:
            return try await testProxyDelay(
                name: nodeID.name,
                url: url,
                timeoutMilliseconds: timeoutMilliseconds,
                expectedStatus: expectedStatus
            )
        case let .provider(providerName):
            throw MihomoControllerSessionError.providerProxyOperationUnavailable(
                provider: providerName
            )
        }
    }

    func testProxyGroupDelay(
        nodeIDs: [ProxyCatalogID],
        url: String,
        timeoutMilliseconds: Int,
        expectedStatus: String?,
        concurrencyLimit: Int
    ) async throws -> [MihomoProxyDelayResult] {
        for nodeID in nodeIDs {
            switch nodeID.origin {
            case .runtime:
                continue
            case let .provider(providerName):
                throw MihomoControllerSessionError.providerProxyOperationUnavailable(
                    provider: providerName
                )
            }
        }
        return try await testProxyGroupDelay(
            names: nodeIDs.map(\.name),
            url: url,
            timeoutMilliseconds: timeoutMilliseconds,
            expectedStatus: expectedStatus,
            concurrencyLimit: concurrencyLimit
        )
    }
}

actor MihomoControllerSession: MihomoControllerManaging {
    private nonisolated static let logger = Logger(
        subsystem: "dev.yilin.Vela",
        category: "ControllerSession"
    )

    private let apiClient: any MihomoAPIProviding
    private let telemetry: any MihomoTelemetryStreaming
    private let logBuffer: LogBuffer
    private let logUpdateInterval: Duration

    private var snapshot: MihomoControllerSnapshot?
    private var proxyResponse: MihomoProxiesResponse?
    private var proxyProvidersResponse: MihomoProxyProvidersResponse?
    private var proxyCatalog: ProxyCatalog?
    private var sessionTask: SessionTask?
    private var modeTask: ModeTask?
    private var proxyOperationTask: ProxyOperationTask?
    private var shutdownTask: ShutdownTask?
    private var logFlushTask: LogFlushTask?
    private var lifecycleGeneration: UInt64 = 0
    private var proxyCatalogGeneration: UInt64 = 0
    private var desiredRunning = false
    private var eventContinuations: [UUID: AsyncStream<MihomoControllerEvent>.Continuation] = [:]

    init(
        apiClient: any MihomoAPIProviding,
        telemetry: any MihomoTelemetryStreaming,
        logBuffer: LogBuffer = LogBuffer(),
        logUpdateInterval: Duration = .milliseconds(200)
    ) {
        self.apiClient = apiClient
        self.telemetry = telemetry
        self.logBuffer = logBuffer
        self.logUpdateInterval = logUpdateInterval
    }

    func events() -> AsyncStream<MihomoControllerEvent> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(64)) { continuation in
            eventContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeEventContinuation(id: id) }
            }
        }
    }

    func start() async {
        desiredRunning = true
        guard sessionTask == nil, shutdownTask == nil else { return }

        lifecycleGeneration &+= 1
        await beginSession(generation: lifecycleGeneration)
    }

    func refresh() async {
        desiredRunning = true
        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration
        await stopSession(emitDisconnected: false)

        guard desiredRunning, lifecycleGeneration == generation else { return }
        await beginSession(generation: generation)
    }

    func stop() async {
        desiredRunning = false
        lifecycleGeneration &+= 1
        await stopSession(emitDisconnected: true)
    }

    /// Exposes the actor-linearized lifecycle intent for coordination and
    /// deterministic race tests without leaking mutable session internals.
    func isRunningDesired() -> Bool {
        desiredRunning
    }

    func changeMode(_ mode: MihomoMode) async throws {
        guard desiredRunning, let currentSnapshot = snapshot else {
            throw MihomoControllerSessionError.notConnected
        }
        guard modeTask == nil else {
            throw MihomoControllerSessionError.modeChangeInProgress
        }

        let id = UUID()
        let generation = lifecycleGeneration
        let apiClient = self.apiClient
        let task = Task<MihomoConfigs, Error> {
            try await Self.requestModeChange(
                mode,
                using: apiClient
            )
        }
        modeTask = ModeTask(id: id, generation: generation, task: task)

        let configs: MihomoConfigs
        do {
            configs = try await task.value
        } catch {
            clearModeTask(id: id)
            throw error
        }

        guard desiredRunning,
            lifecycleGeneration == generation,
            modeTask?.id == id
        else {
            clearModeTask(id: id)
            throw CancellationError()
        }
        clearModeTask(id: id)

        let updatedSnapshot = MihomoControllerSnapshot(
            version: currentSnapshot.version,
            configs: configs
        )
        snapshot = updatedSnapshot
        emit(.ready(updatedSnapshot))
        await appendApplicationLog(
            level: .info,
            message: "Runtime mode changed to \(mode.rawValue)."
        )
    }

    func refreshProxies() async throws {
        try ensureProxyOperationCanStart()

        let id = UUID()
        let generation = lifecycleGeneration
        proxyCatalogGeneration &+= 1
        let apiClient = self.apiClient
        let task = Task<ProxyCatalogLoad, Error> {
            try await Self.requestProxyCatalog(using: apiClient)
        }
        proxyOperationTask = ProxyOperationTask(
            id: id,
            generation: generation,
            task: task
        )

        let load: ProxyCatalogLoad
        do {
            load = try await task.value
        } catch {
            clearProxyOperation(id: id)
            throw error
        }

        try ensureCurrentProxyOperation(id: id, generation: generation)
        clearProxyOperation(id: id)
        await acceptProxyCatalogLoad(load)
    }

    func selectProxy(group: String, proxy: String) async throws {
        try ensureProxyOperationCanStart()

        let id = UUID()
        let generation = lifecycleGeneration
        proxyCatalogGeneration &+= 1
        let apiClient = self.apiClient
        let task = Task<MihomoProxy, Error> {
            try await Self.requestProxySelection(
                group: group,
                proxy: proxy,
                using: apiClient
            )
        }
        proxyOperationTask = ProxyOperationTask(
            id: id,
            generation: generation,
            task: task
        )

        let selectedGroup: MihomoProxy
        do {
            selectedGroup = try await task.value
        } catch {
            clearProxyOperation(id: id)
            throw error
        }

        try ensureCurrentProxyOperation(id: id, generation: generation)
        clearProxyOperation(id: id)

        var proxies = proxyResponse?.proxies ?? [:]
        proxies[group] = selectedGroup
        let response = MihomoProxiesResponse(proxies: proxies)
        let updatedCatalog = ProxyCatalog(
            runtimeResponse: response,
            providerResponse: proxyProvidersResponse ?? .empty,
            fetchErrors: proxyCatalog?.fetchErrors ?? [],
            updatedAt: Date()
        )
        proxyResponse = response
        proxyCatalog = updatedCatalog
        emit(.proxyCatalogUpdated(updatedCatalog))
        await appendApplicationLog(
            level: .info,
            message: "Proxy group \(group) switched to \(proxy)."
        )
    }

    func testProxyDelay(
        name: String,
        url: String,
        timeoutMilliseconds: Int,
        expectedStatus: String?
    ) async throws -> MihomoProxyDelayResult {
        try await testProxyDelay(
            nodeID: ProxyCatalogID(origin: .runtime, name: name),
            url: url,
            timeoutMilliseconds: timeoutMilliseconds,
            expectedStatus: expectedStatus
        )
    }

    func testProxyDelay(
        nodeID: ProxyCatalogID,
        url: String,
        timeoutMilliseconds: Int,
        expectedStatus: String?
    ) async throws -> MihomoProxyDelayResult {
        try ensureProxyOperationCanStart()

        let id = UUID()
        let generation = lifecycleGeneration
        let apiClient = self.apiClient
        let task = Task<MihomoProxyDelayResult, Error> {
            let response = try await Self.requestProxyDelay(
                nodeID: nodeID,
                url: url,
                timeoutMilliseconds: timeoutMilliseconds,
                expectedStatus: expectedStatus,
                using: apiClient
            )
            return MihomoProxyDelayResult(
                proxyID: nodeID,
                delayMilliseconds: response.delay
            )
        }
        proxyOperationTask = ProxyOperationTask(
            id: id,
            generation: generation,
            task: task
        )

        let result: MihomoProxyDelayResult
        do {
            result = try await task.value
        } catch {
            clearProxyOperation(id: id)
            throw error
        }

        try ensureCurrentProxyOperation(id: id, generation: generation)
        clearProxyOperation(id: id)
        return result
    }

    func testProxyGroupDelay(
        names: [String],
        url: String,
        timeoutMilliseconds: Int,
        expectedStatus: String?,
        concurrencyLimit: Int
    ) async throws -> [MihomoProxyDelayResult] {
        try await testProxyGroupDelay(
            nodeIDs: names.map { ProxyCatalogID(origin: .runtime, name: $0) },
            url: url,
            timeoutMilliseconds: timeoutMilliseconds,
            expectedStatus: expectedStatus,
            concurrencyLimit: concurrencyLimit
        )
    }

    func testProxyGroupDelay(
        nodeIDs: [ProxyCatalogID],
        url: String,
        timeoutMilliseconds: Int,
        expectedStatus: String?,
        concurrencyLimit: Int
    ) async throws -> [MihomoProxyDelayResult] {
        try ensureProxyOperationCanStart()

        let id = UUID()
        let generation = lifecycleGeneration
        let apiClient = self.apiClient
        let task = Task<[MihomoProxyDelayResult], Error> {
            try await Self.requestProxyGroupDelays(
                nodeIDs: nodeIDs,
                url: url,
                timeoutMilliseconds: timeoutMilliseconds,
                expectedStatus: expectedStatus,
                concurrencyLimit: concurrencyLimit,
                using: apiClient
            )
        }
        proxyOperationTask = ProxyOperationTask(
            id: id,
            generation: generation,
            task: task
        )

        let results: [MihomoProxyDelayResult]
        do {
            results = try await task.value
        } catch {
            clearProxyOperation(id: id)
            throw error
        }

        try ensureCurrentProxyOperation(id: id, generation: generation)
        clearProxyOperation(id: id)
        return results
    }

    func appendProcessOutput(_ output: MihomoProcessOutput) async {
        await appendProcessOutputs([output])
    }

    func appendProcessOutputs(_ outputs: [MihomoProcessOutput]) async {
        let entries = outputs.flatMap { output -> [LogEntry] in
            let source: LogSource = switch output.channel {
            case .stdout: .mihomoStdout
            case .stderr: .mihomoStderr
            }
            return output.text
                .split(whereSeparator: \.isNewline)
                .map(String.init)
                .filter { !$0.isEmpty }
                .map { message in
                    LogEntry(
                        timestamp: output.timestamp,
                        level: LogLevel(
                            processMessage: message,
                            channel: output.channel
                        ),
                        source: source,
                        message: message
                    )
                }
        }
        guard !entries.isEmpty else { return }
        await logBuffer.append(
            contentsOf: entries
        )
        scheduleLogFlush()
    }

    func recordApplicationLog(level: LogLevel, message: String) async {
        await appendApplicationLog(level: level, message: message)
    }

    func clearLogs() async {
        logFlushTask?.task.cancel()
        logFlushTask = nil
        await logBuffer.clear()
        emit(.logsUpdated([]))
    }

    private func beginSession(generation: UInt64) async {
        guard desiredRunning,
            lifecycleGeneration == generation,
            sessionTask == nil,
            shutdownTask == nil
        else { return }

        let id = UUID()
        await logBuffer.beginSession(id)
        emit(.connecting)
        await appendApplicationLog(
            level: .info,
            message: "Connecting to the Mihomo controller."
        )

        let task = Task { [weak self] in
            guard let self else { return }
            await self.runSession(id: id, generation: generation)
        }
        sessionTask = SessionTask(id: id, generation: generation, task: task)
    }

    private func runSession(id: UUID, generation: UInt64) async {
        do {
            let version = try await apiClient.version()
            try ensureCurrentSession(id: id, generation: generation)
            let configs = try await apiClient.configs()
            try ensureCurrentSession(id: id, generation: generation)

            let snapshot = MihomoControllerSnapshot(version: version, configs: configs)
            self.snapshot = snapshot
            emit(.ready(snapshot))
            await appendApplicationLog(
                level: .info,
                message: "Connected to Mihomo \(version.version)."
            )

            proxyCatalogGeneration &+= 1
            let proxyGeneration = proxyCatalogGeneration
            do {
                let load = try await Self.requestProxyCatalog(using: apiClient)
                try ensureCurrentSession(id: id, generation: generation)
                if proxyCatalogGeneration == proxyGeneration {
                    await acceptProxyCatalogLoad(load)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try ensureCurrentSession(id: id, generation: generation)
                if proxyCatalogGeneration == proxyGeneration {
                    emit(.proxiesUnavailable(error.localizedDescription))
                    await appendApplicationLog(
                        level: .warning,
                        message: "Proxy catalog unavailable: \(error.localizedDescription)"
                    )
                }
            }

            await consumeTelemetry(id: id, generation: generation)
        } catch is CancellationError {
            // Stop and refresh invalidate this generation before cancelling it.
        } catch {
            await reportUnavailable(
                error.localizedDescription,
                id: id,
                generation: generation
            )
        }

        finishSession(id: id, generation: generation)
    }

    private func consumeTelemetry(id: UUID, generation: UInt64) async {
        let telemetry = self.telemetry
        let maximumReconnectCount = 3
        let reconnectDelay = Duration.milliseconds(250)
        let trafficSilenceTimeout = Duration.seconds(5)
        var reconnectCount = 0

        while !Task.isCancelled, isCurrentSession(id: id, generation: generation) {
            let activity = TelemetryActivityTracker()
            let outcome = await withTaskGroup(
                of: TelemetryStreamEnd.self,
                returning: TelemetryAttemptOutcome.self
            ) { group in
                group.addTask { [weak self] in
                    do {
                        for try await entry in telemetry.logs(level: .debug) {
                            try Task.checkCancellation()
                            await self?.acceptControllerLog(
                                entry,
                                id: id,
                                generation: generation
                            )
                        }
                        return .logs(nil)
                    } catch is CancellationError {
                        return .cancelled
                    } catch {
                        return .logs(error.localizedDescription)
                    }
                }

                group.addTask { [weak self] in
                    do {
                        for try await sample in telemetry.traffic() {
                            try Task.checkCancellation()
                            await activity.recordTraffic()
                            await self?.acceptTraffic(
                                sample,
                                id: id,
                                generation: generation
                            )
                        }
                        return .traffic(nil)
                    } catch is CancellationError {
                        return .cancelled
                    } catch {
                        return .traffic(error.localizedDescription)
                    }
                }

                group.addTask {
                    while !Task.isCancelled {
                        do {
                            try await Task.sleep(for: trafficSilenceTimeout)
                        } catch {
                            return .cancelled
                        }
                        if await activity.trafficIsStale(after: trafficSilenceTimeout) {
                            return .traffic(
                                "The controller traffic stream stopped producing updates."
                            )
                        }
                    }
                    return .cancelled
                }

                guard let firstEnd = await group.next() else {
                    return TelemetryAttemptOutcome(end: .cancelled, receivedTraffic: false)
                }
                group.cancelAll()
                return TelemetryAttemptOutcome(
                    end: firstEnd,
                    receivedTraffic: await activity.hasReceivedTraffic()
                )
            }

            guard !Task.isCancelled, isCurrentSession(id: id, generation: generation) else {
                return
            }
            if case .cancelled = outcome.end { return }

            if outcome.receivedTraffic {
                reconnectCount = 0
            }
            let message = switch outcome.end {
            case let .logs(details):
                details ?? "The controller log stream ended unexpectedly."
            case let .traffic(details):
                details ?? "The controller traffic stream ended unexpectedly."
            case .cancelled:
                "The controller telemetry stream was cancelled."
            }

            guard reconnectCount < maximumReconnectCount else {
                await reportUnavailable(message, id: id, generation: generation)
                return
            }

            reconnectCount += 1
            await appendApplicationLog(
                level: .warning,
                message: "Controller reconnect \(reconnectCount)/\(maximumReconnectCount): \(message)"
            )
            do {
                try await Task.sleep(for: reconnectDelay)
            } catch {
                return
            }
        }
    }

    private func acceptControllerLog(
        _ entry: LogEntry,
        id: UUID,
        generation: UInt64
    ) async {
        guard isCurrentSession(id: id, generation: generation) else { return }
        await logBuffer.append(entry)
        scheduleLogFlush()
    }

    private func acceptTraffic(
        _ sample: TrafficSample,
        id: UUID,
        generation: UInt64
    ) {
        guard isCurrentSession(id: id, generation: generation) else { return }
        emit(.trafficUpdated(sample))
    }

    private func appendApplicationLog(level: LogLevel, message: String) async {
        let message = SensitiveTextRedactor(context: .log).redact(message)
        switch level {
        case .debug:
            Self.logger.debug("\(message, privacy: .public)")
        case .info:
            Self.logger.info("\(message, privacy: .public)")
        case .warning:
            Self.logger.warning("\(message, privacy: .public)")
        case .error:
            Self.logger.error("\(message, privacy: .public)")
        case .silent, .unknown:
            Self.logger.log("\(message, privacy: .public)")
        }

        await logBuffer.append(
            LogEntry(level: level, source: .application, message: message)
        )
        scheduleLogFlush()
    }

    private func acceptProxyCatalogLoad(_ load: ProxyCatalogLoad) async {
        proxyResponse = load.runtimeResponse
        proxyProvidersResponse = load.providerResponse
        proxyCatalog = load.catalog
        emit(.proxyCatalogUpdated(load.catalog))

        for fetchError in load.catalog.fetchErrors {
            await appendApplicationLog(
                level: .warning,
                message: fetchError.localizedDescription
            )
        }
    }

    private func reportUnavailable(
        _ message: String,
        id: UUID,
        generation: UInt64
    ) async {
        guard isCurrentSession(id: id, generation: generation) else { return }
        snapshot = nil
        emit(.unavailable(message))
        await appendApplicationLog(
            level: .error,
            message: "Mihomo controller unavailable: \(message)"
        )
    }

    private func scheduleLogFlush() {
        guard logFlushTask == nil else { return }

        let id = UUID()
        let interval = logUpdateInterval
        let task = Task { [weak self] in
            do {
                try await Task.sleep(for: interval)
                await self?.flushLogs(id: id)
            } catch {
                // Cancellation intentionally suppresses a pending UI update.
            }
        }
        logFlushTask = LogFlushTask(id: id, task: task)
    }

    private func flushLogs(id: UUID) async {
        guard logFlushTask?.id == id else { return }
        logFlushTask = nil
        emit(.logsUpdated(await logBuffer.entries()))
    }

    private func stopSession(emitDisconnected: Bool) async {
        if let shutdownTask {
            await shutdownTask.task.value
            if emitDisconnected {
                emit(.disconnected)
            }
            return
        }

        let activeSession = sessionTask
        let activeMode = modeTask
        let activeProxyOperation = proxyOperationTask
        sessionTask = nil
        modeTask = nil
        proxyOperationTask = nil
        snapshot = nil
        proxyResponse = nil
        proxyProvidersResponse = nil
        proxyCatalog = nil
        proxyCatalogGeneration &+= 1

        let id = UUID()
        let task = Task {
            activeSession?.task.cancel()
            activeMode?.task.cancel()
            activeProxyOperation?.task.cancel()
            await activeSession?.task.value
            _ = try? await activeMode?.task.value
            await activeProxyOperation?.task.value
        }
        shutdownTask = ShutdownTask(id: id, task: task)
        await task.value
        if shutdownTask?.id == id {
            shutdownTask = nil
        }

        if let logFlushTask {
            logFlushTask.task.cancel()
            self.logFlushTask = nil
        }
        emit(.logsUpdated(await logBuffer.entries()))

        if emitDisconnected {
            emit(.disconnected)
        }
    }

    private func ensureCurrentSession(id: UUID, generation: UInt64) throws {
        guard isCurrentSession(id: id, generation: generation) else {
            throw CancellationError()
        }
    }

    private func isCurrentSession(id: UUID, generation: UInt64) -> Bool {
        desiredRunning
            && lifecycleGeneration == generation
            && sessionTask?.id == id
            && sessionTask?.generation == generation
    }

    private func finishSession(id: UUID, generation: UInt64) {
        guard sessionTask?.id == id, sessionTask?.generation == generation else { return }
        sessionTask = nil
    }

    private func clearModeTask(id: UUID) {
        guard modeTask?.id == id else { return }
        modeTask = nil
    }

    private func ensureProxyOperationCanStart() throws {
        guard desiredRunning, snapshot != nil else {
            throw MihomoControllerSessionError.notConnected
        }
        guard proxyOperationTask == nil else {
            throw MihomoControllerSessionError.proxyOperationInProgress
        }
    }

    private func ensureCurrentProxyOperation(
        id: UUID,
        generation: UInt64
    ) throws {
        guard desiredRunning,
            snapshot != nil,
            lifecycleGeneration == generation,
            proxyOperationTask?.id == id,
            proxyOperationTask?.generation == generation
        else {
            clearProxyOperation(id: id)
            throw CancellationError()
        }
    }

    private func clearProxyOperation(id: UUID) {
        guard proxyOperationTask?.id == id else { return }
        proxyOperationTask = nil
    }

    private func emit(_ event: MihomoControllerEvent) {
        for continuation in eventContinuations.values {
            continuation.yield(event)
        }
    }

    private func removeEventContinuation(id: UUID) {
        eventContinuations.removeValue(forKey: id)
    }

    private nonisolated static func requestProxyCatalog(
        using apiClient: any MihomoAPIProviding
    ) async throws -> ProxyCatalogLoad {
        async let runtimeTask = apiClient.proxies()
        async let providerTask = requestProxyProvidersDegrading(using: apiClient)

        let runtimeResponse = try await runtimeTask
        let providerOutcome = try await providerTask
        let providerResponse: MihomoProxyProvidersResponse
        let fetchErrors: [ProxyCatalogFetchError]
        switch providerOutcome {
        case let .success(response):
            providerResponse = response
            fetchErrors = []
        case let .failure(error):
            providerResponse = .empty
            fetchErrors = [error]
        }

        return ProxyCatalogLoad(
            runtimeResponse: runtimeResponse,
            providerResponse: providerResponse,
            catalog: ProxyCatalog(
                runtimeResponse: runtimeResponse,
                providerResponse: providerResponse,
                fetchErrors: fetchErrors,
                updatedAt: Date()
            )
        )
    }

    private nonisolated static func requestProxyProvidersDegrading(
        using apiClient: any MihomoAPIProviding
    ) async throws -> ProxyProviderFetchOutcome {
        do {
            return .success(try await apiClient.proxyProviders())
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            return .failure(
                ProxyCatalogFetchError(
                    source: .proxyProviders,
                    endpoint: "/providers/proxies",
                    message: error.localizedDescription
                )
            )
        }
    }

    private nonisolated static func requestModeChange(
        _ mode: MihomoMode,
        using apiClient: any MihomoAPIProviding
    ) async throws -> MihomoConfigs {
        do {
            try await apiClient.patchConfigs(MihomoConfigPatch(mode: mode))
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as MihomoAPIError {
            let isAmbiguousFailure = switch error {
            case .transport:
                true
            case let .httpStatus(code, _):
                (500..<600).contains(code)
            case .invalidResponse, .unauthorized, .decodingFailed, .encodingFailed:
                false
            }

            guard isAmbiguousFailure else { throw error }
            let readBack = try await apiClient.configs()
            guard readBack.mode == mode else { throw error }
            return readBack
        }

        try Task.checkCancellation()
        let configs = try await apiClient.configs()
        guard configs.mode == mode else {
            throw MihomoControllerSessionError.modeVerificationFailed(
                expected: mode,
                actual: configs.mode
            )
        }
        return configs
    }

    private nonisolated static func requestProxySelection(
        group: String,
        proxy: String,
        using apiClient: any MihomoAPIProviding
    ) async throws -> MihomoProxy {
        do {
            try await apiClient.selectProxy(group: group, proxy: proxy)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard isAmbiguousMutationFailure(error) else { throw error }

            let readBack = try await apiClient.proxy(named: group)
            guard confirmsSelection(readBack, expected: proxy) else {
                throw error
            }
            return readBack
        }

        try Task.checkCancellation()
        let readBack = try await apiClient.proxy(named: group)
        guard confirmsSelection(readBack, expected: proxy) else {
            throw MihomoControllerSessionError.proxySelectionVerificationFailed(
                group: group,
                expected: proxy,
                actual: selectionVerificationValue(readBack)
            )
        }
        return readBack
    }

    private nonisolated static func requestProxyDelay(
        nodeID: ProxyCatalogID,
        url: String,
        timeoutMilliseconds: Int,
        expectedStatus: String?,
        using apiClient: any MihomoAPIProviding
    ) async throws -> MihomoProxyDelayResponse {
        switch nodeID.origin {
        case .runtime:
            return try await apiClient.proxyDelay(
                name: nodeID.name,
                url: url,
                timeoutMilliseconds: timeoutMilliseconds,
                expectedStatus: expectedStatus
            )
        case let .provider(providerName):
            return try await apiClient.proxyProviderProxyDelay(
                provider: providerName,
                name: nodeID.name,
                url: url,
                timeoutMilliseconds: timeoutMilliseconds,
                expectedStatus: expectedStatus
            )
        }
    }

    private nonisolated static func requestProxyGroupDelays(
        nodeIDs: [ProxyCatalogID],
        url: String,
        timeoutMilliseconds: Int,
        expectedStatus: String?,
        concurrencyLimit: Int,
        using apiClient: any MihomoAPIProviding
    ) async throws -> [MihomoProxyDelayResult] {
        guard !nodeIDs.isEmpty else { return [] }

        let limit = min(max(1, concurrencyLimit), min(nodeIDs.count, 8))
        return try await withThrowingTaskGroup(
            of: IndexedProxyDelayResult.self,
            returning: [MihomoProxyDelayResult].self
        ) { group in
            var nextIndex = 0
            var results = Array<MihomoProxyDelayResult?>(
                repeating: nil,
                count: nodeIDs.count
            )

            func addNextTask() {
                guard nextIndex < nodeIDs.count else { return }
                let index = nextIndex
                let nodeID = nodeIDs[index]
                nextIndex += 1
                group.addTask {
                    do {
                        let response = try await requestProxyDelay(
                            nodeID: nodeID,
                            url: url,
                            timeoutMilliseconds: timeoutMilliseconds,
                            expectedStatus: expectedStatus,
                            using: apiClient
                        )
                        return IndexedProxyDelayResult(
                            index: index,
                            result: MihomoProxyDelayResult(
                                proxyID: nodeID,
                                delayMilliseconds: response.delay
                            )
                        )
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        return IndexedProxyDelayResult(
                            index: index,
                            result: MihomoProxyDelayResult(
                                proxyID: nodeID,
                                delayMilliseconds: nil,
                                errorDescription: error.localizedDescription
                            )
                        )
                    }
                }
            }

            for _ in 0..<limit {
                addNextTask()
            }

            while let indexedResult = try await group.next() {
                results[indexedResult.index] = indexedResult.result
                addNextTask()
            }

            try Task.checkCancellation()
            return results.compactMap { $0 }
        }
    }

    private nonisolated static func isAmbiguousMutationFailure(_ error: Error) -> Bool {
        guard let apiError = error as? MihomoAPIError else { return false }
        return switch apiError {
        case .transport, .invalidResponse:
            true
        case let .httpStatus(code, _):
            (500..<600).contains(code)
        case .unauthorized, .decodingFailed, .encodingFailed:
            false
        }
    }

    private nonisolated static func confirmsSelection(
        _ group: MihomoProxy,
        expected: String
    ) -> Bool {
        switch group.type {
        case "URLTest", "Fallback":
            return group.fixed?.nilIfEmpty == expected
        case "Selector":
            return group.now == expected
        default:
            return false
        }
    }

    private nonisolated static func selectionVerificationValue(
        _ group: MihomoProxy
    ) -> String? {
        switch group.type {
        case "URLTest", "Fallback":
            return group.fixed?.nilIfEmpty
        case "Selector":
            return group.now
        default:
            return nil
        }
    }
}

nonisolated private enum TelemetryStreamEnd: Sendable {
    case logs(String?)
    case traffic(String?)
    case cancelled
}

nonisolated private struct TelemetryAttemptOutcome: Sendable {
    let end: TelemetryStreamEnd
    let receivedTraffic: Bool
}

private actor TelemetryActivityTracker {
    private let clock: ContinuousClock
    private var lastTrafficAt: ContinuousClock.Instant
    private var receivedTraffic = false

    init() {
        let clock = ContinuousClock()
        self.clock = clock
        lastTrafficAt = clock.now
    }

    func recordTraffic() {
        receivedTraffic = true
        lastTrafficAt = clock.now
    }

    func hasReceivedTraffic() -> Bool {
        receivedTraffic
    }

    func trafficIsStale(after timeout: Duration) -> Bool {
        lastTrafficAt.duration(to: clock.now) >= timeout
    }
}

nonisolated private struct SessionTask: Sendable {
    let id: UUID
    let generation: UInt64
    let task: Task<Void, Never>
}

nonisolated private struct ModeTask: Sendable {
    let id: UUID
    let generation: UInt64
    let task: Task<MihomoConfigs, Error>
}

nonisolated private struct ProxyCatalogLoad: Sendable {
    let runtimeResponse: MihomoProxiesResponse
    let providerResponse: MihomoProxyProvidersResponse
    let catalog: ProxyCatalog
}

nonisolated private enum ProxyProviderFetchOutcome: Sendable {
    case success(MihomoProxyProvidersResponse)
    case failure(ProxyCatalogFetchError)
}

nonisolated private struct ProxyOperationTask: Sendable {
    let id: UUID
    let generation: UInt64
    let task: Task<Void, Never>

    init<Success: Sendable>(
        id: UUID,
        generation: UInt64,
        task operationTask: Task<Success, Error>
    ) {
        self.id = id
        self.generation = generation
        task = Task {
            await withTaskCancellationHandler {
                _ = try? await operationTask.value
            } onCancel: {
                operationTask.cancel()
            }
        }
    }
}

nonisolated private struct IndexedProxyDelayResult: Sendable {
    let index: Int
    let result: MihomoProxyDelayResult
}

nonisolated private struct ShutdownTask: Sendable {
    let id: UUID
    let task: Task<Void, Never>
}

nonisolated private struct LogFlushTask: Sendable {
    let id: UUID
    let task: Task<Void, Never>
}

nonisolated private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
