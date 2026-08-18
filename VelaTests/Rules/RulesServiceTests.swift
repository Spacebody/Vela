import Foundation
import Testing
@testable import Vela

@Suite("Rules service")
struct RulesServiceTests {
    @Test("An aged rule snapshot remains loaded until a source event changes it")
    @MainActor
    func agedSnapshotDoesNotBecomeStaleOnTimeAlone() async throws {
        var referenceDate = Date(timeIntervalSince1970: 10_000)
        let rule = try makeRule(index: 0, type: "MATCH", payload: "", disabled: false)
        let model = RulesViewModel(
            service: RulesService(apiClient: RulesAPIFake(responses: [[rule]])),
            now: { referenceDate }
        )

        await model.refresh()
        #expect(model.workspacePhase == .loaded)

        referenceDate.addTimeInterval(7 * 24 * 60 * 60)
        #expect(model.workspacePhase == .loaded)
    }

    @Test("A 50,000-rule response decodes and refreshes within the reliability budget")
    func fiftyThousandRuleDecodeAndRefresh() async throws {
        let fixture = try RulesPerformanceFixture.make(count: 50_000)
        let clock = ContinuousClock()

        let decodeStart = clock.now
        let response = try JSONDecoder().decode(MihomoRulesResponse.self, from: fixture.data)
        let decodeDuration = decodeStart.duration(to: clock.now)

        #expect(response.rules.count == 50_000)
        #expect(response.rules.map(\.index) == fixture.originalIndices)
        #expect(Set(response.rules.map(\.index)).count == 50_000)
        #expect(response.rules[0].extra == nil)
        #expect(response.rules[1].extra?.hitAt == nil)

        let generation = ConfigurationGeneration(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000001000")!
        )
        let client = RulesAPIFake(responses: [response.rules])
        let service = RulesService(apiClient: client, generation: generation)
        let refreshStart = clock.now
        let refreshed = try await service.refresh()
        let refreshDuration = refreshStart.duration(to: clock.now)

        #expect(refreshed.count == 50_000)
        #expect(refreshed.map(\.originalIndex) == fixture.originalIndices)
        #expect(refreshed.first?.id == RuleID(
            configurationGeneration: generation,
            originalIndex: fixture.originalIndices[0]
        ))
        #expect(refreshed.last?.id == RuleID(
            configurationGeneration: generation,
            originalIndex: fixture.originalIndices[49_999]
        ))
        #expect(decodeDuration < .seconds(3))
        #expect(refreshDuration < .seconds(2))

        print(
            "[Rules 50k] JSON \(fixture.data.count) bytes; "
                + "decode \(performanceMilliseconds(decodeDuration)) ms; "
                + "refresh \(performanceMilliseconds(refreshDuration)) ms"
        )
    }

    @Test("50,000-rule search and filters preserve runtime API order without stalling MainActor")
    func fiftyThousandRulePresentationPipeline() async throws {
        let fixture = try RulesPerformanceFixture.make(count: 50_000)
        let response = try JSONDecoder().decode(MihomoRulesResponse.self, from: fixture.data)
        let client = RulesAPIFake(responses: [response.rules])
        let service = RulesService(apiClient: client)
        let model = RulesViewModel(service: service)
        let clock = ContinuousClock()

        await model.refresh()
        #expect(await waitForRulesViewModel(timeout: .seconds(5)) {
            model.visibleRules.count == 50_000
        })

        let expectedFiltered = response.rules
            .filter { rule in
                rule.type == "DOMAIN"
                    && rule.proxy == "DIRECT"
                    && rule.payload.localizedCaseInsensitiveContains("needle")
            }
        #expect(!expectedFiltered.isEmpty)

        let filteringStart = clock.now
        await MainActor.run {
            model.typeFilter = "DOMAIN"
            model.policyFilter = "DIRECT"
            model.searchText = "needle"
        }
        #expect(await waitForRulesViewModel {
            model.visibleRules.count == expectedFiltered.count
                && model.visibleRules.map(\.originalIndex) == expectedFiltered.map(\.index)
        })
        let filteringDuration = filteringStart.duration(to: clock.now)

        let filtered = await MainActor.run { model.visibleRules }
        #expect(filtered.map(\.originalIndex) == expectedFiltered.map(\.index))
        #expect(zip(filtered, expectedFiltered).allSatisfy { managed, source in
            managed.originalIndex == source.index
                && managed.value.payload == source.payload
        })

        // Reset to all 50,000 rows. The production presentation contract must
        // keep the exact Controller order rather than inventing a default sort.
        let resetStart = clock.now
        await MainActor.run {
            model.searchText = ""
            model.typeFilter = nil
            model.policyFilter = nil
        }
        let markerStart = clock.now
        let markerCount = await MainActor.run { model.visibleRules.count }
        let markerDuration = markerStart.duration(to: clock.now)
        #expect(markerCount == expectedFiltered.count || markerCount == 50_000)
        #expect(markerDuration < .seconds(1))

        #expect(await waitForRulesViewModel(timeout: .seconds(5)) {
            model.visibleRules.count == 50_000
                && model.visibleRules.first?.originalIndex == response.rules.first?.index
                && model.visibleRules.last?.originalIndex == response.rules.last?.index
        })
        let resetDuration = resetStart.duration(to: clock.now)
        let reset = await MainActor.run { model.visibleRules }
        #expect(reset.map(\.originalIndex) == fixture.originalIndices)
        #expect(resetDuration < .seconds(5))

        print(
            "[Rules 50k] filtered \(expectedFiltered.count) rows in "
                + "\(performanceMilliseconds(filteringDuration)) ms; "
                + "MainActor marker \(performanceMilliseconds(markerDuration)) ms; "
                + "reset \(performanceMilliseconds(resetDuration)) ms"
        )
    }

    @Test("Refresh preserves Mihomo original indices and rejects duplicate indices")
    func refreshIdentity() async throws {
        let generation = ConfigurationGeneration(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000009")!
        )
        let first = try makeRule(index: 18, type: "MATCH", payload: "z", disabled: false)
        let second = try makeRule(index: 3, type: "DOMAIN", payload: "a", disabled: nil)
        let client = RulesAPIFake(responses: [[first, second]])
        let service = RulesService(apiClient: client, generation: generation)

        let values = try await service.refresh()
        #expect(values.map(\.originalIndex) == [18, 3])
        #expect(values.map(\.id) == [
            RuleID(configurationGeneration: generation, originalIndex: 18),
            RuleID(configurationGeneration: generation, originalIndex: 3),
        ])

        await client.replaceResponses([[first, first]])
        let failure = await capturedRulesFailure { _ = try await service.refresh() }
        #expect(failure == .fetchFailed)
        #expect(await service.rules() == values)
    }

    @Test("PATCH uses the original index after presentation sorting and confirms disable and enable")
    func toggleUsesOriginalIndexAndConfirms() async throws {
        let rule12 = try makeRule(index: 12, type: "MATCH", payload: "z", disabled: false)
        let rule18 = try makeRule(index: 18, type: "DOMAIN", payload: "a", disabled: false)
        let disabled12 = try makeRule(index: 12, type: "MATCH", payload: "z", disabled: true)
        let enabled12 = try makeRule(index: 12, type: "MATCH", payload: "z", disabled: false)
        let client = RulesAPIFake(responses: [
            [rule12, rule18],
            [disabled12, rule18],
            [enabled12, rule18],
        ])
        let service = RulesService(apiClient: client)
        let loaded = try await service.refresh()
        let sortedForPresentation = loaded.sorted { $0.value.payload < $1.value.payload }
        let target = try #require(sortedForPresentation.first { $0.originalIndex == 12 })

        let disabled = try await service.setDisabled(true, for: target.id)
        #expect(disabled.first { $0.originalIndex == 12 }?.value.extra?.disabled == true)
        let enabled = try await service.setDisabled(false, for: target.id)
        #expect(enabled.first { $0.originalIndex == 12 }?.value.extra?.disabled == false)
        #expect(await client.recordedPatches() == [[12: true], [12: false]])
    }

    @Test("Rules without runtime extra reject temporary toggles")
    func missingExtraIsUnsupported() async throws {
        let rule = try makeRule(index: 4, type: "MATCH", payload: "", disabled: nil)
        let client = RulesAPIFake(responses: [[rule]])
        let service = RulesService(apiClient: client)
        let managed = try #require(try await service.refresh().first)

        let failure = await capturedRulesFailure {
            _ = try await service.setDisabled(true, for: managed.id)
        }
        #expect(failure == .toggleUnsupported)
        #expect(await client.recordedPatches().isEmpty)
    }

    @Test("PATCH and confirmation failures leave the last confirmed cache intact")
    func failedToggleRollsBack() async throws {
        let original = try makeRule(index: 7, type: "MATCH", payload: "", disabled: false)
        let client = RulesAPIFake(responses: [[original]])
        await client.setPatchFailure(true)
        let service = RulesService(apiClient: client)
        let managed = try #require(try await service.refresh().first)

        let patchFailure = await capturedRulesFailure {
            _ = try await service.setDisabled(true, for: managed.id)
        }
        #expect(patchFailure == .toggleFailed)
        #expect(await service.rules() == [managed])
        #expect(await service.isPending(originalIndex: 7) == false)

        await client.setPatchFailure(false)
        await client.replaceResponses([[original]])
        let confirmationFailure = await capturedRulesFailure {
            _ = try await service.setDisabled(true, for: managed.id)
        }
        #expect(confirmationFailure == .toggleFailed)
        #expect(await service.rules() == [managed])
    }

    @Test("Duplicate toggle is rejected while the first PATCH is pending")
    func duplicateToggle() async throws {
        let original = try makeRule(index: 5, type: "MATCH", payload: "", disabled: false)
        let confirmed = try makeRule(index: 5, type: "MATCH", payload: "", disabled: true)
        let client = RulesAPIFake(responses: [[original], [confirmed]])
        await client.setPatchSuspended(true)
        let service = RulesService(apiClient: client)
        let managed = try #require(try await service.refresh().first)
        let first = Task { try await service.setDisabled(true, for: managed.id) }
        #expect(await eventuallyRules { await client.patchCallCount() == 1 })
        #expect(await service.isPending(originalIndex: 5))

        let duplicate = await capturedRulesFailure {
            _ = try await service.setDisabled(true, for: managed.id)
        }
        #expect(duplicate == .operationAlreadyRunning)

        await client.releaseNextPatch()
        _ = try await first.value
        #expect(await service.isPending(originalIndex: 5) == false)
    }

    @Test("A stale generation cannot clear a new generation pending marker")
    func generationChangeIsolatesPendingOperations() async throws {
        let oldGeneration = ConfigurationGeneration(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        )
        let newGeneration = ConfigurationGeneration(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        )
        let oldRule = try makeRule(index: 9, type: "MATCH", payload: "old", disabled: false)
        let newRule = try makeRule(index: 9, type: "MATCH", payload: "new", disabled: false)
        let confirmed = try makeRule(index: 9, type: "MATCH", payload: "new", disabled: true)
        let client = RulesAPIFake(responses: [[oldRule], [newRule], [confirmed]])
        await client.setPatchSuspended(true)
        let service = RulesService(apiClient: client, generation: oldGeneration)
        let oldManaged = try #require(try await service.refresh().first)
        let oldTask = Task { try await service.setDisabled(true, for: oldManaged.id) }
        #expect(await eventuallyRules { await client.patchCallCount() == 1 })

        _ = await service.configurationDidChange(to: newGeneration)
        #expect(await service.isPending(originalIndex: 9) == false)
        let newManaged = try #require(try await service.refresh().first)
        let newTask = Task { try await service.setDisabled(true, for: newManaged.id) }
        #expect(await eventuallyRules { await client.patchCallCount() == 2 })
        #expect(await service.isPending(originalIndex: 9))

        await client.releaseNextPatch()
        let oldFailure = await taskRulesFailure(oldTask)
        #expect(oldFailure == .configurationGenerationChanged)
        #expect(await service.isPending(originalIndex: 9))

        await client.releaseNextPatch()
        _ = try await newTask.value
        #expect(await service.isPending(originalIndex: 9) == false)
    }

    @Test("A page-hidden cancellation stops refresh without presenting a fetch failure")
    @MainActor
    func visibleRefreshCancellationIsSilent() async {
        let client = RulesCancellableAPIFake()
        let model = RulesViewModel(service: RulesService(apiClient: client))
        let refresh = Task { @MainActor in
            await model.refresh()
        }

        #expect(await eventuallyRules { await client.hasStarted() })
        #expect(model.isLoading)
        refresh.cancel()
        await refresh.value

        #expect(await client.wasCancelled())
        #expect(!model.isLoading)
        #expect(model.lastError == nil)
        #expect(model.rules.isEmpty)
    }
}

private struct RulesPerformanceFixture {
    let data: Data
    let originalIndices: [Int]

    static func make(count: Int) throws -> Self {
        precondition(count > 0)
        let originalIndices = (0..<count).map { offset in
            100_000 + ((offset * 7_919) % count)
        }
        let rules: [[String: Any]] = (0..<count).map { offset in
            let type = switch offset % 4 {
            case 0: "DOMAIN"
            case 1: "DOMAIN-SUFFIX"
            case 2: "IP-CIDR"
            default: "MATCH"
            }
            let payload = offset.isMultiple(of: 97)
                ? "needle-\(offset).example.com"
                : "host-\(offset).example.com"
            let proxy = switch offset % 3 {
            case 0: "DIRECT"
            case 1: "Proxy A"
            default: "Proxy B"
            }
            var object: [String: Any] = [
                "index": originalIndices[offset],
                "type": type,
                "payload": payload,
                "proxy": proxy,
                "size": payload.utf8.count,
            ]
            if !offset.isMultiple(of: 5) {
                object["extra"] = [
                    "disabled": offset.isMultiple(of: 2),
                    "hitCount": (offset * 17) % 1_000,
                    "hitAt": offset.isMultiple(of: 7)
                        ? "0001-01-01T00:00:00Z"
                        : NSNull(),
                    "missCount": offset % 41,
                    "missAt": NSNull(),
                ]
            }
            return object
        }
        let data = try JSONSerialization.data(withJSONObject: ["rules": rules])
        return Self(data: data, originalIndices: originalIndices)
    }
}

private func performanceMilliseconds(_ duration: Duration) -> String {
    let components = duration.components
    let milliseconds = Double(components.seconds) * 1_000
        + Double(components.attoseconds) / 1_000_000_000_000_000
    return milliseconds.formatted(.number.precision(.fractionLength(2)))
}

private func waitForRulesViewModel(
    timeout: Duration = .seconds(3),
    condition: @escaping @MainActor () -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await MainActor.run(body: condition) { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await MainActor.run(body: condition)
}

private func makeRule(
    index: Int,
    type: String,
    payload: String,
    disabled: Bool?
) throws -> MihomoRule {
    var object: [String: Any] = [
        "index": index,
        "type": type,
        "payload": payload,
        "proxy": "DIRECT",
        "size": -1,
    ]
    if let disabled {
        object["extra"] = [
            "disabled": disabled,
            "hitCount": 0,
            "missCount": 0,
        ]
    }
    let data = try JSONSerialization.data(withJSONObject: object)
    return try JSONDecoder().decode(MihomoRule.self, from: data)
}

private func capturedRulesFailure(
    _ operation: () async throws -> Void
) async -> RulesFailure? {
    do {
        try await operation()
        return nil
    } catch let failure as RulesFailure {
        return failure
    } catch {
        Issue.record("Unexpected error: \(error)")
        return nil
    }
}

private func taskRulesFailure(
    _ task: Task<[ManagedRule], Error>
) async -> RulesFailure? {
    do {
        _ = try await task.value
        return nil
    } catch let failure as RulesFailure {
        return failure
    } catch {
        Issue.record("Unexpected error: \(error)")
        return nil
    }
}

private func eventuallyRules(
    _ condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while clock.now < deadline {
        if await condition() { return true }
        try? await clock.sleep(for: .milliseconds(1))
    }
    return await condition()
}

private actor RulesAPIFake: MihomoAPIProviding {
    enum FakeError: Error {
        case unexpectedCall
        case patchFailed
    }

    private var responses: [[MihomoRule]]
    private var patches: [[Int: Bool]] = []
    private var patchFailure = false
    private var patchSuspended = false
    private var patchWaiters: [CheckedContinuation<Void, Never>] = []

    init(responses: [[MihomoRule]]) {
        self.responses = responses
    }

    func replaceResponses(_ values: [[MihomoRule]]) {
        responses = values
    }

    func setPatchFailure(_ value: Bool) {
        patchFailure = value
    }

    func setPatchSuspended(_ value: Bool) {
        patchSuspended = value
    }

    func recordedPatches() -> [[Int: Bool]] { patches }
    func patchCallCount() -> Int { patches.count }

    func releaseNextPatch() {
        guard !patchWaiters.isEmpty else { return }
        patchWaiters.removeFirst().resume()
    }

    func rules() async throws -> MihomoRulesResponse {
        guard !responses.isEmpty else { throw FakeError.unexpectedCall }
        let value = responses.count == 1 ? responses[0] : responses.removeFirst()
        return MihomoRulesResponse(rules: value)
    }

    func setRulesDisabled(_ disabledByIndex: [Int: Bool]) async throws {
        patches.append(disabledByIndex)
        if patchSuspended {
            await withCheckedContinuation { continuation in
                patchWaiters.append(continuation)
            }
        }
        if patchFailure { throw FakeError.patchFailed }
    }

    func version() async throws -> MihomoVersion { throw FakeError.unexpectedCall }
    func configs() async throws -> MihomoConfigs { throw FakeError.unexpectedCall }
    func patchConfigs(_ patch: MihomoConfigPatch) async throws { throw FakeError.unexpectedCall }
    func proxies() async throws -> MihomoProxiesResponse { throw FakeError.unexpectedCall }
}

private actor RulesCancellableAPIFake: MihomoAPIProviding {
    private var started = false
    private var cancelled = false

    func hasStarted() -> Bool { started }
    func wasCancelled() -> Bool { cancelled }

    func rules() async throws -> MihomoRulesResponse {
        started = true
        do {
            try await Task.sleep(for: .seconds(60))
            return MihomoRulesResponse(rules: [])
        } catch is CancellationError {
            cancelled = true
            throw CancellationError()
        }
    }

    func setRulesDisabled(_ disabledByIndex: [Int: Bool]) async throws {
        throw CancellationError()
    }

    func version() async throws -> MihomoVersion { throw CancellationError() }
    func configs() async throws -> MihomoConfigs { throw CancellationError() }
    func patchConfigs(_ patch: MihomoConfigPatch) async throws { throw CancellationError() }
    func proxies() async throws -> MihomoProxiesResponse { throw CancellationError() }
}
