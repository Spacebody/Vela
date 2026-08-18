import Foundation

/// User-visible subscription scheduling defaults. Keeping the scheduler and
/// settings presentation on this policy prevents descriptive UI from drifting
/// away from the limits that are actually enforced.
nonisolated enum SubscriptionUpdatePolicy {
    static let maximumConcurrentUpdates = 2
    static let defaultSchedule: SubscriptionSchedule = .daily
    static let minimumCustomIntervalMinutes = 15
    static let maximumCustomIntervalMinutes = 30 * 24 * 60
}

nonisolated enum SubscriptionUpdateReason: String, Equatable, Sendable {
    case manual
    case scheduled
    case networkRecovery
    case wake
}

nonisolated protocol SubscriptionUpdating: Sendable {
    func update(profileID: UUID, reason: SubscriptionUpdateReason) async throws
    func scheduleRetry(
        profileID: UUID,
        failure: SubscriptionUpdateFailure,
        consecutiveFailureCount: Int,
        at date: Date
    ) async
}

extension SubscriptionUpdating {
    func scheduleRetry(
        profileID _: UUID,
        failure _: SubscriptionUpdateFailure,
        consecutiveFailureCount _: Int,
        at _: Date
    ) async {}
}

nonisolated struct SubscriptionScheduledResult: Equatable, Sendable {
    let profileID: UUID
    let result: Result<Void, SubscriptionUpdateFailure>

    static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.profileID == rhs.profileID else { return false }
        return switch (lhs.result, rhs.result) {
        case (.success, .success):
            true
        case let (.failure(lhsError), .failure(rhsError)):
            lhsError == rhsError
        default:
            false
        }
    }
}

actor SubscriptionUpdateScheduler {
    static let minimumScheduleMinutes = SubscriptionUpdatePolicy.minimumCustomIntervalMinutes
    static let maximumScheduleMinutes = SubscriptionUpdatePolicy.maximumCustomIntervalMinutes
    static let retryBackoffMinutes = [5, 15, 60, 6 * 60]

    private struct ActiveUpdate: Sendable {
        let token: UUID
        let batchID: UUID?
        let task: Task<SubscriptionScheduledResult, Never>
    }

    private struct ActiveCompletion: Sendable {
        let token: UUID
        let result: SubscriptionScheduledResult
    }

    private let updater: any SubscriptionUpdating
    private let maximumConcurrentUpdates: Int
    private let jitterFraction: @Sendable () -> Double
    private let now: @Sendable () -> Date
    private var inFlight: Set<UUID> = []
    private var activeUpdates: [UUID: ActiveUpdate] = [:]
    private var consecutiveFailures: [UUID: Int] = [:]
    private var cancelledProfiles: Set<UUID> = []

    init(
        updater: any SubscriptionUpdating,
        maximumConcurrentUpdates: Int = SubscriptionUpdatePolicy.maximumConcurrentUpdates,
        jitterFraction: @escaping @Sendable () -> Double = {
            Double.random(in: -0.05 ... 0.05)
        },
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.updater = updater
        self.maximumConcurrentUpdates = max(1, maximumConcurrentUpdates)
        self.jitterFraction = jitterFraction
        self.now = now
    }

    func updateNow(profileID: UUID) async -> SubscriptionScheduledResult? {
        guard !inFlight.contains(profileID), !cancelledProfiles.contains(profileID) else {
            return nil
        }
        inFlight.insert(profileID)
        let active = launch(profileID: profileID, reason: .manual, batchID: nil)
        let result = await withTaskCancellationHandler {
            await active.task.value
        } onCancel: {
            active.task.cancel()
        }
        await finish(result, token: active.token, at: now())
        return result
    }

    func runDueUpdates(
        profiles: [Profile],
        at now: Date = .now,
        networkAvailable: Bool,
        reason: SubscriptionUpdateReason = .scheduled
    ) async -> [SubscriptionScheduledResult] {
        guard networkAvailable else { return [] }
        let due = profiles
            .filter { profile in
                profile.sourceKind == .remoteSubscription
                    && profile.remote?.autoUpdateEnabled == true
                    && (profile.remote?.nextScheduledUpdateAt ?? .distantPast) <= now
                    && !inFlight.contains(profile.id)
                    && !cancelledProfiles.contains(profile.id)
            }
            .sorted { lhs, rhs in
                let lhsDate = lhs.remote?.nextScheduledUpdateAt ?? .distantPast
                let rhsDate = rhs.remote?.nextScheduledUpdateAt ?? .distantPast
                if lhsDate == rhsDate { return lhs.id.uuidString < rhs.id.uuidString }
                return lhsDate < rhsDate
            }

        let profileIDs = due.map(\.id)
        inFlight.formUnion(profileIDs)
        let batchID = UUID()
        let results = await withTaskCancellationHandler {
            await executeBatches(
                profileIDs: profileIDs,
                batchID: batchID,
                reason: reason
            )
        } onCancel: {
            Task { await self.cancelBatch(batchID) }
        }
        return results.sorted { $0.profileID.uuidString < $1.profileID.uuidString }
    }

    func updateAllNow(profileIDs: [UUID]) async -> [SubscriptionScheduledResult] {
        var seen: Set<UUID> = []
        let eligible = profileIDs.filter { profileID in
            seen.insert(profileID).inserted
                && !inFlight.contains(profileID)
                && !cancelledProfiles.contains(profileID)
        }
        guard !eligible.isEmpty else { return [] }

        inFlight.formUnion(eligible)
        let batchID = UUID()
        let results = await withTaskCancellationHandler {
            await executeBatches(
                profileIDs: eligible,
                batchID: batchID,
                reason: .manual
            )
        } onCancel: {
            Task { await self.cancelBatch(batchID) }
        }
        return results.sorted { $0.profileID.uuidString < $1.profileID.uuidString }
    }

    func profileDeleted(_ profileID: UUID) async {
        cancelledProfiles.insert(profileID)
        consecutiveFailures.removeValue(forKey: profileID)
        guard let active = activeUpdates[profileID] else {
            inFlight.remove(profileID)
            return
        }
        active.task.cancel()
        _ = await active.task.value
        if activeUpdates[profileID]?.token == active.token {
            activeUpdates.removeValue(forKey: profileID)
            inFlight.remove(profileID)
        }
    }

    func profileRestored(_ profileID: UUID) {
        cancelledProfiles.remove(profileID)
    }

    func isUpdating(_ profileID: UUID) -> Bool {
        inFlight.contains(profileID)
    }

    func cancelUpdate(_ profileID: UUID) async {
        guard let active = activeUpdates[profileID] else { return }
        active.task.cancel()
        _ = await active.task.value
    }

    /// Cancels and joins every active subscription request. Update
    /// installation uses this as a quiescence barrier; cancellation alone is
    /// not evidence that a URLSession request or configuration apply ended.
    func cancelAllUpdatesAndWait() async {
        let active = Array(activeUpdates.values)
        for update in active {
            update.task.cancel()
        }
        for update in active {
            _ = await update.task.value
        }
        let completedTokens = Set(active.map(\.token))
        let completedProfileIDs = activeUpdates.compactMap { profileID, update in
            completedTokens.contains(update.token) ? profileID : nil
        }
        for profileID in completedProfileIDs {
            activeUpdates.removeValue(forKey: profileID)
            inFlight.remove(profileID)
        }
    }

    func nextScheduledDate(after date: Date, schedule: SubscriptionSchedule) -> Date {
        let minutes = Self.normalizedMinutes(for: schedule)
        let baseInterval = TimeInterval(minutes * 60)
        let boundedJitter = min(max(jitterFraction(), -0.05), 0.05)
        return date.addingTimeInterval(baseInterval * (1 + boundedJitter))
    }

    func retryDate(after date: Date, profileID: UUID) -> Date {
        let attempt = consecutiveFailures[profileID, default: 0]
        let backoffMinutes = Self.retryBackoffMinutes[
            min(max(attempt - 1, 0), Self.retryBackoffMinutes.count - 1)
        ]
        return date.addingTimeInterval(TimeInterval(backoffMinutes * 60))
    }

    static func normalizedMinutes(for schedule: SubscriptionSchedule) -> Int {
        min(max(schedule.minutes, minimumScheduleMinutes), maximumScheduleMinutes)
    }

    private func launch(
        profileID: UUID,
        reason: SubscriptionUpdateReason,
        batchID: UUID?
    ) -> ActiveUpdate {
        let updater = self.updater
        let token = UUID()
        let task = Task {
            await Self.perform(updater: updater, profileID: profileID, reason: reason)
        }
        let active = ActiveUpdate(token: token, batchID: batchID, task: task)
        activeUpdates[profileID] = active
        return active
    }

    private func executeBatches(
        profileIDs: [UUID],
        batchID: UUID,
        reason: SubscriptionUpdateReason
    ) async -> [SubscriptionScheduledResult] {
        var results: [SubscriptionScheduledResult] = []
        var nextIndex = 0

        while nextIndex < profileIDs.count, !Task.isCancelled {
            let upperBound = min(nextIndex + maximumConcurrentUpdates, profileIDs.count)
            let ids = Array(profileIDs[nextIndex ..< upperBound])
            nextIndex = upperBound
            var active: [ActiveUpdate] = []

            for profileID in ids {
                guard !cancelledProfiles.contains(profileID) else {
                    inFlight.remove(profileID)
                    results.append(
                        SubscriptionScheduledResult(
                            profileID: profileID,
                            result: .failure(.cancelled)
                        )
                    )
                    continue
                }
                active.append(launch(profileID: profileID, reason: reason, batchID: batchID))
            }

            let completions = await withTaskGroup(of: ActiveCompletion.self) { group in
                for item in active {
                    group.addTask {
                        ActiveCompletion(token: item.token, result: await item.task.value)
                    }
                }
                var values: [ActiveCompletion] = []
                for await completion in group {
                    values.append(completion)
                }
                return values
            }
            for completion in completions {
                await finish(completion.result, token: completion.token, at: now())
                results.append(completion.result)
            }
        }

        if nextIndex < profileIDs.count {
            for profileID in profileIDs[nextIndex...] {
                inFlight.remove(profileID)
                results.append(
                    SubscriptionScheduledResult(
                        profileID: profileID,
                        result: .failure(.cancelled)
                    )
                )
            }
        }
        return results
    }

    private func cancelBatch(_ batchID: UUID) {
        for active in activeUpdates.values where active.batchID == batchID {
            active.task.cancel()
        }
    }

    private func finish(
        _ result: SubscriptionScheduledResult,
        token: UUID,
        at date: Date
    ) async {
        if activeUpdates[result.profileID]?.token == token {
            activeUpdates.removeValue(forKey: result.profileID)
        }
        inFlight.remove(result.profileID)
        guard !cancelledProfiles.contains(result.profileID) else { return }
        await record(result.result, for: result.profileID, at: date)
    }

    private static func perform(
        updater: any SubscriptionUpdating,
        profileID: UUID,
        reason: SubscriptionUpdateReason
    ) async -> SubscriptionScheduledResult {
        do {
            try await updater.update(profileID: profileID, reason: reason)
            return SubscriptionScheduledResult(profileID: profileID, result: .success(()))
        } catch let error as SubscriptionUpdateFailure {
            return SubscriptionScheduledResult(profileID: profileID, result: .failure(error))
        } catch is CancellationError {
            return SubscriptionScheduledResult(profileID: profileID, result: .failure(.cancelled))
        } catch {
            return SubscriptionScheduledResult(
                profileID: profileID,
                result: .failure(.transportFailed)
            )
        }
    }

    private func record(
        _ result: Result<Void, SubscriptionUpdateFailure>,
        for profileID: UUID,
        at date: Date
    ) async {
        switch result {
        case .success:
            consecutiveFailures.removeValue(forKey: profileID)
        case .failure(.cancelled):
            break
        case let .failure(failure):
            consecutiveFailures[profileID, default: 0] += 1
            await updater.scheduleRetry(
                profileID: profileID,
                failure: failure,
                consecutiveFailureCount: consecutiveFailures[profileID, default: 1],
                at: date
            )
        }
    }
}
