import Foundation

nonisolated protocol EngineHealthScheduling: Sendable {
    func sleep(for duration: Duration) async throws
}

nonisolated struct ContinuousEngineHealthScheduler: EngineHealthScheduling {
    func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

nonisolated protocol EngineHealthMonitoring: Actor {
    func events() -> AsyncStream<EngineHealthReport>
    func start(context: EngineHealthCheckContext) async
    func updateContext(_ context: EngineHealthCheckContext)
    func trigger(_ trigger: HealthCheckTrigger)
    func setApplicationActive(_ active: Bool)
    func resumeAfterWake(applicationActive: Bool) async
    func stop() async
}

extension EngineHealthMonitoring {
    func resumeAfterWake(applicationActive: Bool) async {
        setApplicationActive(applicationActive)
        trigger(.wokeFromSleep)
    }
}

actor EngineHealthMonitor: EngineHealthMonitoring {
    private struct InFlightCheck: Sendable {
        let id: UUID
        let generation: UInt64
        let contextRevision: UInt64
        let task: Task<EngineHealthReport, Never>
    }

    private struct CadenceTask: Sendable {
        let id: UUID
        let generation: UInt64
        let task: Task<Void, Never>
    }

    private let checker: any EngineHealthChecking
    private let scheduler: any EngineHealthScheduling
    private let activeInterval: Duration
    private let inactiveInterval: Duration

    private var context: EngineHealthCheckContext?
    private var generation: UInt64 = 0
    private var contextRevision: UInt64 = 0
    private var sequence: UInt64 = 0
    private var applicationActive = true
    private var pendingTriggers: Set<HealthCheckTrigger> = []
    private var inFlightCheck: InFlightCheck?
    private var cadenceTask: CadenceTask?
    private var eventContinuations: [UUID: AsyncStream<EngineHealthReport>.Continuation] = [:]

    init(
        checker: any EngineHealthChecking,
        scheduler: any EngineHealthScheduling = ContinuousEngineHealthScheduler(),
        activeInterval: Duration = .seconds(5),
        inactiveInterval: Duration = .seconds(30)
    ) {
        self.checker = checker
        self.scheduler = scheduler
        self.activeInterval = activeInterval
        self.inactiveInterval = inactiveInterval
    }

    func events() -> AsyncStream<EngineHealthReport> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            eventContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id: id) }
            }
        }
    }

    func start(context: EngineHealthCheckContext) async {
        generation &+= 1
        contextRevision &+= 1
        let currentGeneration = generation
        self.context = nil
        sequence = 0
        pendingTriggers.removeAll()

        let priorCheck = inFlightCheck?.task
        let priorCadence = cadenceTask?.task
        inFlightCheck = nil
        cadenceTask = nil
        priorCheck?.cancel()
        priorCadence?.cancel()
        if let priorCheck { _ = await priorCheck.value }
        if let priorCadence { await priorCadence.value }

        guard generation == currentGeneration else { return }
        self.context = context
        beginCheck(triggers: [.startup], generation: currentGeneration)
    }

    func updateContext(_ context: EngineHealthCheckContext) {
        guard self.context?.sessionID == context.sessionID else { return }
        guard self.context != context else { return }
        self.context = context
        contextRevision &+= 1
        if inFlightCheck != nil {
            pendingTriggers.insert(.manual)
        }
    }

    func trigger(_ trigger: HealthCheckTrigger) {
        enqueue(trigger, generation: generation)
    }

    func setApplicationActive(_ active: Bool) {
        guard applicationActive != active else { return }
        applicationActive = active
        cancelCadence()
        if active {
            enqueue(.applicationActivated, generation: generation)
        } else if inFlightCheck == nil {
            scheduleCadence(generation: generation)
        }
    }

    func resumeAfterWake(applicationActive: Bool) async {
        self.applicationActive = applicationActive
        cancelCadence()
        enqueue(.wokeFromSleep, generation: generation)
    }

    func stop() async {
        generation &+= 1
        context = nil
        pendingTriggers.removeAll()

        let check = inFlightCheck?.task
        let cadence = cadenceTask?.task
        inFlightCheck = nil
        cadenceTask = nil
        check?.cancel()
        cadence?.cancel()
        if let check { _ = await check.value }
        if let cadence { await cadence.value }
    }

    private func enqueue(_ trigger: HealthCheckTrigger, generation: UInt64) {
        guard generation == self.generation, context != nil else { return }
        cancelCadence()
        if inFlightCheck != nil {
            pendingTriggers.insert(trigger)
        } else {
            beginCheck(triggers: [trigger], generation: generation)
        }
    }

    private func beginCheck(
        triggers: Set<HealthCheckTrigger>,
        generation: UInt64
    ) {
        guard generation == self.generation,
            inFlightCheck == nil,
            let context
        else { return }

        sequence &+= 1
        let sequence = self.sequence
        let orderedTriggers = HealthCheckTrigger.allCases.filter(triggers.contains)
        let id = UUID()
        let contextRevision = self.contextRevision
        let checker = self.checker
        let task = Task {
            await checker.check(
                context: context,
                triggers: orderedTriggers,
                sequence: sequence
            )
        }
        inFlightCheck = InFlightCheck(
            id: id,
            generation: generation,
            contextRevision: contextRevision,
            task: task
        )

        Task { [weak self] in
            let report = await task.value
            await self?.finishCheck(
                report,
                id: id,
                generation: generation
            )
        }
    }

    private func finishCheck(
        _ report: EngineHealthReport,
        id: UUID,
        generation: UInt64
    ) {
        guard generation == self.generation,
            inFlightCheck?.id == id,
            context?.sessionID == report.sessionID
        else { return }

        let reportMatchesCurrentContext = inFlightCheck?.contextRevision == self.contextRevision
        inFlightCheck = nil
        if reportMatchesCurrentContext {
            emit(report)
        }

        if pendingTriggers.isEmpty {
            scheduleCadence(generation: generation)
        } else {
            let triggers = pendingTriggers
            pendingTriggers.removeAll()
            beginCheck(triggers: triggers, generation: generation)
        }
    }

    private func scheduleCadence(generation: UInt64) {
        guard generation == self.generation,
            context != nil,
            inFlightCheck == nil,
            cadenceTask == nil
        else { return }

        let id = UUID()
        let interval = applicationActive ? activeInterval : inactiveInterval
        let scheduler = self.scheduler
        let task = Task { [weak self] in
            do {
                try await scheduler.sleep(for: interval)
                await self?.cadenceDidFire(id: id, generation: generation)
            } catch {
                // Cancellation suppresses the obsolete cadence.
            }
        }
        cadenceTask = CadenceTask(id: id, generation: generation, task: task)
    }

    private func cadenceDidFire(id: UUID, generation: UInt64) {
        guard generation == self.generation, cadenceTask?.id == id else { return }
        cadenceTask = nil
        enqueue(.periodic, generation: generation)
    }

    private func cancelCadence() {
        cadenceTask?.task.cancel()
        cadenceTask = nil
    }

    private func emit(_ report: EngineHealthReport) {
        for continuation in eventContinuations.values {
            continuation.yield(report)
        }
    }

    private func removeContinuation(id: UUID) {
        eventContinuations.removeValue(forKey: id)
    }
}
