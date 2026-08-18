import Foundation
import Testing
@testable import Vela

@MainActor
@Suite("Mihomo controller session")
struct MihomoControllerSessionTests {
    @Test("One session publishes state and telemetry, verifies mode, and closes on stop")
    func sessionLifecycle() async throws {
        let api = ControllerSessionAPIFake()
        let telemetryHub = ControllerSessionTelemetryHub()
        let session = MihomoControllerSession(
            apiClient: api,
            telemetry: ControllerSessionTelemetryFake(hub: telemetryHub),
            logUpdateInterval: .milliseconds(1)
        )
        let recorder = ControllerSessionEventRecorder()
        let events = await session.events()
        let eventTask = Task {
            for await event in events {
                await recorder.record(event)
            }
        }

        await session.start()
        await session.start()

        #expect(await waitUntil {
            let isReady = await recorder.containsReady(mode: .rule)
            let activeStreamCount = await telemetryHub.activeStreamCount()
            return isReady && activeStreamCount == 2
        })
        #expect(await api.versionCallCount() == 1)
        #expect(await api.configsCallCount() == 1)
        #expect(await telemetryHub.logStreamCount() == 1)
        #expect(await telemetryHub.trafficStreamCount() == 1)

        let controllerLog = LogEntry(
            level: .warning,
            source: .controller,
            message: "controller test log"
        )
        let traffic = TrafficSample(
            uploadBytesPerSecond: 1_024,
            downloadBytesPerSecond: 2_048,
            totalUploadBytes: 4_096,
            totalDownloadBytes: 8_192
        )
        await telemetryHub.yieldLog(controllerLog)
        await telemetryHub.yieldTraffic(traffic)

        #expect(await waitUntil {
            let hasLog = await recorder.containsLog(message: "controller test log")
            let hasTraffic = await recorder.containsTraffic(traffic)
            return hasLog && hasTraffic
        })

        try await session.changeMode(.global)
        #expect(await waitUntil { await recorder.containsReady(mode: .global) })
        #expect(await api.patchedModes() == [.global])

        await session.stop()
        #expect(await waitUntil {
            let isDisconnected = await recorder.contains(.disconnected)
            let terminationCount = await telemetryHub.terminationCount()
            return isDisconnected && terminationCount == 2
        })

        eventTask.cancel()
        await eventTask.value
    }

    @Test("An unavailable Controller is reported without an infinite restart")
    func unavailableControllerStopsAfterFiniteClientFailure() async {
        let api = ControllerSessionAPIFake(versionError: ControllerSessionTestError.offline)
        let telemetryHub = ControllerSessionTelemetryHub()
        let session = MihomoControllerSession(
            apiClient: api,
            telemetry: ControllerSessionTelemetryFake(hub: telemetryHub),
            logUpdateInterval: .zero
        )
        let recorder = ControllerSessionEventRecorder()
        let events = await session.events()
        let eventTask = Task {
            for await event in events {
                await recorder.record(event)
            }
        }

        await session.start()

        #expect(await waitUntil { await recorder.containsUnavailable() })
        #expect(await api.versionCallCount() == 1)
        #expect(await telemetryHub.activeStreamCount() == 0)

        for _ in 0..<100 {
            await Task.yield()
        }
        #expect(await api.versionCallCount() == 1)

        eventTask.cancel()
        await eventTask.value
    }

    @Test("Telemetry streams reconnect without discarding the ready Controller state")
    func telemetryStreamsReconnectAfterTransientFailure() async {
        let api = ControllerSessionAPIFake()
        let telemetryHub = ControllerSessionTelemetryHub()
        let session = MihomoControllerSession(
            apiClient: api,
            telemetry: ControllerSessionTelemetryFake(hub: telemetryHub),
            logUpdateInterval: .zero
        )
        let recorder = ControllerSessionEventRecorder()
        let events = await session.events()
        let eventTask = Task {
            for await event in events {
                await recorder.record(event)
            }
        }

        await session.start()
        #expect(await waitUntil {
            let ready = await recorder.containsReady(mode: .rule)
            let activeStreams = await telemetryHub.activeStreamCount()
            return ready && activeStreams == 2
        })

        await telemetryHub.failTraffic(ControllerSessionTestError.offline)

        #expect(await waitUntil {
            let logStreams = await telemetryHub.logStreamCount()
            let trafficStreams = await telemetryHub.trafficStreamCount()
            let activeStreams = await telemetryHub.activeStreamCount()
            return logStreams == 2 && trafficStreams == 2 && activeStreams == 2
        })
        #expect(!(await recorder.containsUnavailable()))
        #expect(await recorder.containsReady(mode: .rule))

        await session.stop()
        eventTask.cancel()
        await eventTask.value
    }

    @Test("A silent traffic stream is detected and replaced")
    func staleTrafficStreamReconnects() async {
        let api = ControllerSessionAPIFake()
        let telemetryHub = ControllerSessionTelemetryHub()
        let session = MihomoControllerSession(
            apiClient: api,
            telemetry: ControllerSessionTelemetryFake(hub: telemetryHub),
            logUpdateInterval: .zero
        )
        let recorder = ControllerSessionEventRecorder()
        let events = await session.events()
        let eventTask = Task {
            for await event in events {
                await recorder.record(event)
            }
        }

        await session.start()
        #expect(await waitUntil { await telemetryHub.activeStreamCount() == 2 })

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(7))
        var didReconnect = false
        while clock.now < deadline {
            let logStreams = await telemetryHub.logStreamCount()
            let trafficStreams = await telemetryHub.trafficStreamCount()
            if logStreams >= 2, trafficStreams >= 2 {
                didReconnect = true
                break
            }
            try? await Task.sleep(for: .milliseconds(10))
        }

        #expect(didReconnect)
        #expect(!(await recorder.containsUnavailable()))
        #expect(await recorder.containsReady(mode: .rule))

        await session.stop()
        eventTask.cancel()
        await eventTask.value
    }

    @Test("Stop wins over an in-flight refresh and prevents a late reconnect")
    func stopWinsOverRefresh() async {
        let api = ControllerSlowCancellationAPIFake()
        let session = MihomoControllerSession(
            apiClient: api,
            telemetry: ControllerSessionTelemetryFake(
                hub: ControllerSessionTelemetryHub()
            )
        )
        let recorder = ControllerSessionEventRecorder()
        let events = await session.events()
        let eventTask = Task {
            for await event in events {
                await recorder.record(event)
            }
        }

        await session.start()
        #expect(await waitUntil { await api.versionCallCount() == 1 })

        let refreshTask = Task {
            await session.refresh()
        }
        #expect(await waitUntil { await api.didObserveCancellation() })

        let stopTask = Task {
            await session.stop()
        }
        #expect(await waitUntil { !(await session.isRunningDesired()) })
        await api.releaseCancellationCleanup()
        await stopTask.value
        await refreshTask.value

        #expect(await waitUntil { await recorder.lastConnectionEventIsDisconnected() })
        #expect(await api.versionCallCount() == 1)
        #expect(!(await recorder.containsReady(mode: .rule)))

        eventTask.cancel()
        await eventTask.value
    }

    @Test("Stop cancels an in-flight mode change and rejects its stale result")
    func stopCancelsModeChange() async {
        let api = ControllerDelayedModeAPIFake()
        let telemetryHub = ControllerSessionTelemetryHub()
        let session = MihomoControllerSession(
            apiClient: api,
            telemetry: ControllerSessionTelemetryFake(hub: telemetryHub)
        )
        let recorder = ControllerSessionEventRecorder()
        let events = await session.events()
        let eventTask = Task {
            for await event in events {
                await recorder.record(event)
            }
        }

        await session.start()
        #expect(await waitUntil {
            let ready = await recorder.containsReady(mode: .rule)
            let streamCount = await telemetryHub.activeStreamCount()
            return ready && streamCount == 2
        })

        let modeTask = Task {
            try await session.changeMode(.global)
        }
        #expect(await waitUntil { await api.didStartPatch() })
        await session.stop()

        do {
            try await modeTask.value
            Issue.record("Expected the in-flight mode change to be cancelled")
        } catch is CancellationError {
            // Expected: stop owns the final lifecycle state.
        } catch {
            Issue.record("Unexpected mode-change error: \(error)")
        }

        #expect(await waitUntil { await recorder.lastConnectionEventIsDisconnected() })
        #expect(!(await recorder.containsReady(mode: .global)))
        #expect(await waitUntil { await telemetryHub.activeStreamCount() == 0 })

        eventTask.cancel()
        await eventTask.value
    }

    @Test("Proxy selection publishes only after the read-back confirms it")
    func proxySelectionWaitsForVerifiedReadBack() async throws {
        let initialGroup = makeControllerSessionProxyGroup(now: "Node A")
        let selectedGroup = makeControllerSessionProxyGroup(now: "Node B")
        let api = ControllerProxySelectionAPIFake(
            initialGroup: initialGroup,
            readBackGroup: selectedGroup,
            suspendsReadBack: true
        )
        let telemetryHub = ControllerSessionTelemetryHub()
        let session = MihomoControllerSession(
            apiClient: api,
            telemetry: ControllerSessionTelemetryFake(hub: telemetryHub)
        )
        let recorder = ControllerSessionEventRecorder()
        let events = await session.events()
        let eventTask = Task {
            for await event in events {
                await recorder.record(event)
            }
        }

        await session.start()
        #expect(await waitUntil {
            let ready = await recorder.containsReady(mode: .rule)
            let hasInitialCatalog = await recorder.containsProxySelection(
                group: "Primary",
                selectedProxy: "Node A"
            )
            let streamCount = await telemetryHub.activeStreamCount()
            return ready && hasInitialCatalog && streamCount == 2
        })

        let selectionTask = Task {
            try await session.selectProxy(group: "Primary", proxy: "Node B")
        }
        #expect(await waitUntil { await api.didStartReadBack() })
        #expect(!(await recorder.containsProxySelection(
            group: "Primary",
            selectedProxy: "Node B"
        )))

        await api.releaseReadBack()
        try await selectionTask.value

        #expect(await waitUntil {
            await recorder.containsProxySelection(
                group: "Primary",
                selectedProxy: "Node B"
            )
        })
        #expect(await api.operations() == [
            .loadCatalog,
            .select(group: "Primary", proxy: "Node B"),
            .readBack(group: "Primary"),
        ])

        await session.stop()
        eventTask.cancel()
        await eventTask.value
    }

    @Test("Ambiguous proxy mutation failures succeed when read-back already matches")
    func ambiguousProxySelectionFailureUsesReadBack() async throws {
        let ambiguousFailures: [MihomoAPIError] = [
            .transport(code: .networkConnectionLost, message: "connection lost"),
            .httpStatus(code: 503, body: "temporarily unavailable"),
            .invalidResponse(endpoint: "/proxies/Primary"),
        ]

        for failure in ambiguousFailures {
            let api = ControllerProxySelectionAPIFake(
                initialGroup: makeControllerSessionProxyGroup(now: "Node A"),
                readBackGroup: makeControllerSessionProxyGroup(now: "Node B"),
                selectionError: failure
            )
            let telemetryHub = ControllerSessionTelemetryHub()
            let session = MihomoControllerSession(
                apiClient: api,
                telemetry: ControllerSessionTelemetryFake(hub: telemetryHub)
            )
            let recorder = ControllerSessionEventRecorder()
            let events = await session.events()
            let eventTask = Task {
                for await event in events {
                    await recorder.record(event)
                }
            }

            await session.start()
            #expect(await waitUntil {
                let ready = await recorder.containsReady(mode: .rule)
                let hasInitialCatalog = await recorder.containsProxySelection(
                    group: "Primary",
                    selectedProxy: "Node A"
                )
                let streamCount = await telemetryHub.activeStreamCount()
                return ready && hasInitialCatalog && streamCount == 2
            })

            try await session.selectProxy(group: "Primary", proxy: "Node B")

            #expect(await waitUntil {
                await recorder.containsProxySelection(
                    group: "Primary",
                    selectedProxy: "Node B"
                )
            })
            #expect(await api.operations() == [
                .loadCatalog,
                .select(group: "Primary", proxy: "Node B"),
                .readBack(group: "Primary"),
            ])

            await session.stop()
            eventTask.cancel()
            await eventTask.value
        }
    }

    @Test("Automatic groups require fixed read-back even when now matches the target")
    func automaticGroupDoesNotTreatNowAsConfirmedPin() async throws {
        let failure = MihomoAPIError.transport(
            code: .networkConnectionLost,
            message: "connection lost"
        )
        let api = ControllerProxySelectionAPIFake(
            initialGroup: makeControllerSessionProxyGroup(
                type: "URLTest",
                now: "Node A"
            ),
            readBackGroup: makeControllerSessionProxyGroup(
                type: "URLTest",
                now: "Node B",
                fixed: nil
            ),
            selectionError: failure
        )
        let telemetryHub = ControllerSessionTelemetryHub()
        let session = MihomoControllerSession(
            apiClient: api,
            telemetry: ControllerSessionTelemetryFake(hub: telemetryHub)
        )
        let recorder = ControllerSessionEventRecorder()
        let events = await session.events()
        let eventTask = Task {
            for await event in events {
                await recorder.record(event)
            }
        }

        await session.start()
        #expect(await waitUntil {
            let ready = await recorder.containsReady(mode: .rule)
            let streamCount = await telemetryHub.activeStreamCount()
            return ready && streamCount == 2
        })

        do {
            try await session.selectProxy(group: "Primary", proxy: "Node B")
            Issue.record("Expected the unconfirmed automatic-group pin to fail")
        } catch let error as MihomoAPIError {
            #expect(error == failure)
        } catch {
            Issue.record("Unexpected proxy-selection error: \(error)")
        }

        #expect(!(await recorder.containsProxySelection(
            group: "Primary",
            selectedProxy: "Node B"
        )))

        await session.stop()
        eventTask.cancel()
        await eventTask.value
    }

    @Test("A mismatched proxy read-back throws verification failure without publishing")
    func proxySelectionRejectsMismatchedReadBack() async throws {
        let api = ControllerProxySelectionAPIFake(
            initialGroup: makeControllerSessionProxyGroup(now: "Node A"),
            readBackGroup: makeControllerSessionProxyGroup(now: "Node A")
        )
        let telemetryHub = ControllerSessionTelemetryHub()
        let session = MihomoControllerSession(
            apiClient: api,
            telemetry: ControllerSessionTelemetryFake(hub: telemetryHub)
        )
        let recorder = ControllerSessionEventRecorder()
        let events = await session.events()
        let eventTask = Task {
            for await event in events {
                await recorder.record(event)
            }
        }

        await session.start()
        #expect(await waitUntil {
            let ready = await recorder.containsReady(mode: .rule)
            let hasInitialCatalog = await recorder.containsProxySelection(
                group: "Primary",
                selectedProxy: "Node A"
            )
            let streamCount = await telemetryHub.activeStreamCount()
            return ready && hasInitialCatalog && streamCount == 2
        })

        do {
            try await session.selectProxy(group: "Primary", proxy: "Node B")
            Issue.record("Expected proxy selection verification to fail")
        } catch let error as MihomoControllerSessionError {
            #expect(error == .proxySelectionVerificationFailed(
                group: "Primary",
                expected: "Node B",
                actual: "Node A"
            ))
        } catch {
            Issue.record("Unexpected proxy-selection error: \(error)")
        }

        #expect(!(await recorder.containsProxySelection(
            group: "Primary",
            selectedProxy: "Node B"
        )))
        #expect(await api.operations() == [
            .loadCatalog,
            .select(group: "Primary", proxy: "Node B"),
            .readBack(group: "Primary"),
        ])

        await session.stop()
        eventTask.cancel()
        await eventTask.value
    }

    @Test("Group delay testing respects its concurrency limit and preserves input order")
    func groupDelayIsBoundedAndOrderedAcrossPartialFailures() async throws {
        let api = ControllerProxyDelayAPIFake(
            delays: [
                "Node A": 11,
                "Node B": 22,
                "Node C": 33,
                "Node D": 44,
                "Node E": 55,
            ],
            durations: [
                "Node A": .milliseconds(80),
                "Node B": .milliseconds(20),
                "Node C": .milliseconds(45),
                "Node D": .milliseconds(10),
                "Node E": .milliseconds(30),
            ],
            failingNames: ["Node B", "Node D"]
        )
        let telemetryHub = ControllerSessionTelemetryHub()
        let session = MihomoControllerSession(
            apiClient: api,
            telemetry: ControllerSessionTelemetryFake(hub: telemetryHub)
        )
        let recorder = ControllerSessionEventRecorder()
        let events = await session.events()
        let eventTask = Task {
            for await event in events {
                await recorder.record(event)
            }
        }

        await session.start()
        #expect(await waitUntil {
            let ready = await recorder.containsReady(mode: .rule)
            let streamCount = await telemetryHub.activeStreamCount()
            return ready && streamCount == 2
        })

        let names = ["Node A", "Node B", "Node C", "Node D", "Node E"]
        let results = try await session.testProxyGroupDelay(
            names: names,
            url: "https://example.com/generate_204",
            timeoutMilliseconds: 1_000,
            expectedStatus: "200-299",
            concurrencyLimit: 2
        )

        #expect(results.map(\.proxyName) == names)
        #expect(results.map(\.delayMilliseconds) == [11, nil, 33, nil, 55])
        #expect(results[0].errorDescription == nil)
        #expect(results[1].errorDescription != nil)
        #expect(results[2].errorDescription == nil)
        #expect(results[3].errorDescription != nil)
        #expect(results[4].errorDescription == nil)
        #expect(await api.peakActiveRequestCount() <= 2)
        #expect(await api.peakActiveRequestCount() == 2)

        await session.stop()
        eventTask.cancel()
        await eventTask.value
    }

    @Test("Provider catalog failure preserves runtime groups and publishes structured degradation")
    func providerCatalogFailureDegradesWithoutDisconnecting() async throws {
        let api = ControllerProviderFailureAPIFake()
        let telemetryHub = ControllerSessionTelemetryHub()
        let session = MihomoControllerSession(
            apiClient: api,
            telemetry: ControllerSessionTelemetryFake(hub: telemetryHub)
        )
        let recorder = ControllerSessionEventRecorder()
        let events = await session.events()
        let eventTask = Task {
            for await event in events {
                await recorder.record(event)
            }
        }

        await session.start()

        #expect(await waitUntil {
            let catalog = await recorder.latestProxyCatalog()
            let streamCount = await telemetryHub.activeStreamCount()
            return catalog != nil && streamCount == 2
        })
        let catalog = try #require(await recorder.latestProxyCatalog())
        #expect(catalog.group(named: "Primary")?.nodes.map(\.name) == ["DIRECT"])
        #expect(catalog.fetchErrors.count == 1)
        #expect(catalog.fetchErrors.first?.source == .proxyProviders)
        #expect(catalog.fetchErrors.first?.endpoint == "/providers/proxies")
        #expect(catalog.fetchErrors.first?.message.contains("HTTP 500") == true)
        #expect(!(await recorder.containsUnavailable()))
        #expect(await api.runtimeCallCount() == 1)
        #expect(await api.providerCallCount() == 1)
        #expect(await api.didFetchConcurrently())

        await session.stop()
        eventTask.cancel()
        await eventTask.value
    }

    @Test("Origin-aware delay routing uses runtime delay and provider healthcheck independently")
    func originAwareDelayRouting() async throws {
        let api = ControllerOriginDelayAPIFake()
        let telemetryHub = ControllerSessionTelemetryHub()
        let session = MihomoControllerSession(
            apiClient: api,
            telemetry: ControllerSessionTelemetryFake(hub: telemetryHub)
        )
        let recorder = ControllerSessionEventRecorder()
        let events = await session.events()
        let eventTask = Task {
            for await event in events {
                await recorder.record(event)
            }
        }

        await session.start()
        #expect(await waitUntil {
            let ready = await recorder.containsReady(mode: .rule)
            let streamCount = await telemetryHub.activeStreamCount()
            return ready && streamCount == 2
        })

        let runtimeID = ProxyCatalogID(origin: .runtime, name: "Runtime Node")
        let providerAID = ProxyCatalogID(
            origin: .provider(name: "Provider / A"),
            name: "Shared Provider Node"
        )
        let providerBID = ProxyCatalogID(
            origin: .provider(name: "Provider B"),
            name: "Shared Provider Node"
        )
        let runtimeResult = try await session.testProxyDelay(
            nodeID: runtimeID,
            url: "https://example.com/generate_204",
            timeoutMilliseconds: 1_000,
            expectedStatus: "204"
        )
        let providerAResult = try await session.testProxyDelay(
            nodeID: providerAID,
            url: "https://example.com/generate_204",
            timeoutMilliseconds: 1_000,
            expectedStatus: "204"
        )
        let providerBResult = try await session.testProxyDelay(
            nodeID: providerBID,
            url: "https://example.com/generate_204",
            timeoutMilliseconds: 1_000,
            expectedStatus: "204"
        )
        let groupResults = try await session.testProxyGroupDelay(
            nodeIDs: [providerAID, providerBID, runtimeID],
            url: "https://example.com/generate_204",
            timeoutMilliseconds: 1_000,
            expectedStatus: "204",
            concurrencyLimit: 2
        )

        #expect(runtimeResult.proxyID == runtimeID)
        #expect(runtimeResult.delayMilliseconds == 11)
        #expect(providerAResult.proxyID == providerAID)
        #expect(providerAResult.delayMilliseconds == 22)
        #expect(providerBResult.proxyID == providerBID)
        #expect(providerBResult.delayMilliseconds == 22)
        #expect(groupResults.map(\.proxyID) == [providerAID, providerBID, runtimeID])
        #expect(groupResults.map(\.delayMilliseconds) == [22, 22, 11])
        #expect(await api.routeCount(.runtime(name: "Runtime Node")) == 2)
        #expect(await api.routeCount(.provider(
            provider: "Provider / A",
            name: "Shared Provider Node"
        )) == 2)
        #expect(await api.routeCount(.provider(
            provider: "Provider B",
            name: "Shared Provider Node"
        )) == 2)

        await session.stop()
        eventTask.cancel()
        await eventTask.value
    }

    @Test("Stop cancels an in-flight proxy operation and rejects its late result")
    func stopCancelsProxySelectionAndRejectsLateResult() async throws {
        let api = ControllerProxySelectionAPIFake(
            initialGroup: makeControllerSessionProxyGroup(now: "Node A"),
            readBackGroup: makeControllerSessionProxyGroup(now: "Node B"),
            suspendsReadBack: true
        )
        let telemetryHub = ControllerSessionTelemetryHub()
        let session = MihomoControllerSession(
            apiClient: api,
            telemetry: ControllerSessionTelemetryFake(hub: telemetryHub)
        )
        let recorder = ControllerSessionEventRecorder()
        let events = await session.events()
        let eventTask = Task {
            for await event in events {
                await recorder.record(event)
            }
        }

        await session.start()
        #expect(await waitUntil {
            let ready = await recorder.containsReady(mode: .rule)
            let hasInitialCatalog = await recorder.containsProxySelection(
                group: "Primary",
                selectedProxy: "Node A"
            )
            let streamCount = await telemetryHub.activeStreamCount()
            return ready && hasInitialCatalog && streamCount == 2
        })

        let selectionTask = Task {
            try await session.selectProxy(group: "Primary", proxy: "Node B")
        }
        #expect(await waitUntil { await api.didStartReadBack() })

        let stopTask = Task {
            await session.stop()
        }
        #expect(await waitUntil { await api.didObserveReadBackCancellation() })
        await api.releaseReadBack()
        await stopTask.value

        do {
            try await selectionTask.value
            Issue.record("Expected the in-flight proxy selection to be cancelled")
        } catch is CancellationError {
            // Expected: the stopped lifecycle owns the final state.
        } catch {
            Issue.record("Unexpected proxy-selection error: \(error)")
        }

        #expect(await waitUntil { await recorder.lastConnectionEventIsDisconnected() })
        #expect(!(await recorder.containsProxySelection(
            group: "Primary",
            selectedProxy: "Node B"
        )))

        eventTask.cancel()
        await eventTask.value
    }

    @Test("Compatibility delay routing rejects provider origins with a typed error")
    func compatibilityDelayRoutingIsRecoverableForProviderOrigins() async throws {
        let manager = ControllerLegacyDelayManagerFake()
        let runtimeID = ProxyCatalogID(origin: .runtime, name: "Runtime Node")
        let providerID = ProxyCatalogID(
            origin: .provider(name: "Provider A"),
            name: "Provider Node"
        )

        let runtimeResult = try await manager.testProxyDelay(
            nodeID: runtimeID,
            url: "https://example.com/generate_204",
            timeoutMilliseconds: 1_000,
            expectedStatus: "204"
        )
        #expect(runtimeResult.proxyID == runtimeID)
        #expect(await manager.runtimeDelayCallCount() == 1)

        do {
            _ = try await manager.testProxyDelay(
                nodeID: providerID,
                url: "https://example.com/generate_204",
                timeoutMilliseconds: 1_000,
                expectedStatus: "204"
            )
            Issue.record("Expected provider-origin compatibility routing to fail")
        } catch let error as MihomoControllerSessionError {
            #expect(error == .providerProxyOperationUnavailable(provider: "Provider A"))
        } catch {
            Issue.record("Unexpected provider-origin error: \(error)")
        }

        do {
            _ = try await manager.testProxyGroupDelay(
                nodeIDs: [runtimeID, providerID],
                url: "https://example.com/generate_204",
                timeoutMilliseconds: 1_000,
                expectedStatus: "204",
                concurrencyLimit: 2
            )
            Issue.record("Expected provider-origin group routing to fail")
        } catch let error as MihomoControllerSessionError {
            #expect(error == .providerProxyOperationUnavailable(provider: "Provider A"))
        } catch {
            Issue.record("Unexpected provider-origin group error: \(error)")
        }
        #expect(await manager.runtimeGroupDelayCallCount() == 0)
    }

    private func waitUntil(
        _ condition: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if await condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return await condition()
    }
}

private actor ControllerLegacyDelayManagerFake: MihomoControllerManaging {
    private var singleDelayCalls = 0
    private var groupDelayCalls = 0

    func events() -> AsyncStream<MihomoControllerEvent> {
        AsyncStream { $0.finish() }
    }

    func start() {}
    func refresh() {}
    func stop() {}
    func changeMode(_ mode: MihomoMode) throws {}
    func refreshProxies() throws {}
    func selectProxy(group: String, proxy: String) throws {}

    func testProxyDelay(
        name: String,
        url: String,
        timeoutMilliseconds: Int,
        expectedStatus: String?
    ) -> MihomoProxyDelayResult {
        singleDelayCalls += 1
        return MihomoProxyDelayResult(proxyName: name, delayMilliseconds: 7)
    }

    func testProxyGroupDelay(
        names: [String],
        url: String,
        timeoutMilliseconds: Int,
        expectedStatus: String?,
        concurrencyLimit: Int
    ) -> [MihomoProxyDelayResult] {
        groupDelayCalls += 1
        return names.map { MihomoProxyDelayResult(proxyName: $0, delayMilliseconds: 7) }
    }

    func appendProcessOutput(_ output: MihomoProcessOutput) {}
    func clearLogs() {}

    func runtimeDelayCallCount() -> Int { singleDelayCalls }
    func runtimeGroupDelayCallCount() -> Int { groupDelayCalls }
}

private actor ControllerSessionAPIFake: MihomoAPIProviding {
    private let versionError: Error?
    private var mode: MihomoMode = .rule
    private var versionCalls = 0
    private var configsCalls = 0
    private var modes: [MihomoMode] = []

    init(versionError: Error? = nil) {
        self.versionError = versionError
    }

    func version() throws -> MihomoVersion {
        versionCalls += 1
        if let versionError {
            throw versionError
        }
        return MihomoVersion(meta: true, version: "1.19.28-test")
    }

    func configs() -> MihomoConfigs {
        configsCalls += 1
        return makeControllerSessionConfigs(mode: mode)
    }

    func patchConfigs(_ patch: MihomoConfigPatch) {
        if let requestedMode = patch.mode {
            mode = requestedMode
            modes.append(requestedMode)
        }
    }

    func proxies() -> MihomoProxiesResponse {
        MihomoProxiesResponse(proxies: [:])
    }

    func versionCallCount() -> Int { versionCalls }
    func configsCallCount() -> Int { configsCalls }
    func patchedModes() -> [MihomoMode] { modes }
}

private actor ControllerSlowCancellationAPIFake: MihomoAPIProviding {
    private let cancellationCleanupGate = ControllerSessionGate()
    private var versionCalls = 0
    private var observedCancellation = false

    func version() async throws -> MihomoVersion {
        versionCalls += 1
        do {
            try await Task.sleep(for: .seconds(30))
            return MihomoVersion(meta: true, version: "unexpected")
        } catch is CancellationError {
            observedCancellation = true
            await cancellationCleanupGate.wait()
            throw CancellationError()
        }
    }

    func configs() -> MihomoConfigs {
        makeControllerSessionConfigs(mode: .rule)
    }

    func patchConfigs(_ patch: MihomoConfigPatch) {}

    func proxies() -> MihomoProxiesResponse {
        MihomoProxiesResponse(proxies: [:])
    }

    func versionCallCount() -> Int { versionCalls }
    func didObserveCancellation() -> Bool { observedCancellation }
    func releaseCancellationCleanup() async {
        await cancellationCleanupGate.open()
    }
}

private actor ControllerDelayedModeAPIFake: MihomoAPIProviding {
    private var mode: MihomoMode = .rule
    private var patchStarted = false

    func version() -> MihomoVersion {
        MihomoVersion(meta: true, version: "1.19.28-test")
    }

    func configs() -> MihomoConfigs {
        makeControllerSessionConfigs(mode: mode)
    }

    func patchConfigs(_ patch: MihomoConfigPatch) async throws {
        patchStarted = true
        try await Task.sleep(for: .seconds(30))
        if let requestedMode = patch.mode {
            mode = requestedMode
        }
    }

    func proxies() -> MihomoProxiesResponse {
        MihomoProxiesResponse(proxies: [:])
    }

    func didStartPatch() -> Bool { patchStarted }
}

nonisolated private enum ControllerProxySelectionOperation: Equatable, Sendable {
    case loadCatalog
    case select(group: String, proxy: String)
    case readBack(group: String)
}

private actor ControllerProxySelectionAPIFake: MihomoAPIProviding {
    private let initialGroup: MihomoProxy
    private let readBackGroup: MihomoProxy
    private let selectionError: MihomoAPIError?
    private let suspendsReadBack: Bool
    private let readBackGate = ControllerSessionGate()
    private var recordedOperations: [ControllerProxySelectionOperation] = []
    private var readBackStarted = false
    private var observedReadBackCancellation = false

    init(
        initialGroup: MihomoProxy,
        readBackGroup: MihomoProxy,
        selectionError: MihomoAPIError? = nil,
        suspendsReadBack: Bool = false
    ) {
        self.initialGroup = initialGroup
        self.readBackGroup = readBackGroup
        self.selectionError = selectionError
        self.suspendsReadBack = suspendsReadBack
    }

    func version() -> MihomoVersion {
        MihomoVersion(meta: true, version: "1.19.28-test")
    }

    func configs() -> MihomoConfigs {
        makeControllerSessionConfigs(mode: .rule)
    }

    func patchConfigs(_ patch: MihomoConfigPatch) {}

    func proxies() -> MihomoProxiesResponse {
        recordedOperations.append(.loadCatalog)
        return MihomoProxiesResponse(
            proxies: [initialGroup.name: initialGroup]
        )
    }

    func selectProxy(group: String, proxy: String) throws {
        recordedOperations.append(.select(group: group, proxy: proxy))
        if let selectionError {
            throw selectionError
        }
    }

    func proxy(named name: String) async -> MihomoProxy {
        recordedOperations.append(.readBack(group: name))
        readBackStarted = true
        if suspendsReadBack {
            await withTaskCancellationHandler {
                await readBackGate.wait()
            } onCancel: {
                Task { await self.recordReadBackCancellation() }
            }
        }
        return readBackGroup
    }

    func releaseReadBack() async {
        await readBackGate.open()
    }

    func didStartReadBack() -> Bool { readBackStarted }
    func didObserveReadBackCancellation() -> Bool { observedReadBackCancellation }
    func operations() -> [ControllerProxySelectionOperation] { recordedOperations }

    private func recordReadBackCancellation() {
        observedReadBackCancellation = true
    }
}

private actor ControllerProxyDelayAPIFake: MihomoAPIProviding {
    private let delays: [String: UInt16]
    private let durations: [String: Duration]
    private let failingNames: Set<String>
    private var activeRequests = 0
    private var peakActiveRequests = 0

    init(
        delays: [String: UInt16],
        durations: [String: Duration],
        failingNames: Set<String>
    ) {
        self.delays = delays
        self.durations = durations
        self.failingNames = failingNames
    }

    func version() -> MihomoVersion {
        MihomoVersion(meta: true, version: "1.19.28-test")
    }

    func configs() -> MihomoConfigs {
        makeControllerSessionConfigs(mode: .rule)
    }

    func patchConfigs(_ patch: MihomoConfigPatch) {}

    func proxies() -> MihomoProxiesResponse {
        MihomoProxiesResponse(proxies: [:])
    }

    func proxyDelay(
        name: String,
        url: String,
        timeoutMilliseconds: Int,
        expectedStatus: String?
    ) async throws -> MihomoProxyDelayResponse {
        activeRequests += 1
        peakActiveRequests = max(peakActiveRequests, activeRequests)
        defer { activeRequests -= 1 }

        try await Task.sleep(for: durations[name] ?? .milliseconds(1))
        if failingNames.contains(name) {
            throw ControllerProxyDelayTestError.failed(name)
        }
        return MihomoProxyDelayResponse(delay: delays[name] ?? 1)
    }

    func peakActiveRequestCount() -> Int { peakActiveRequests }
}

private actor ControllerProviderFailureAPIFake: MihomoAPIProviding {
    private var runtimeCalls = 0
    private var providerCalls = 0
    private var observedConcurrentFetch = false

    func version() -> MihomoVersion {
        MihomoVersion(meta: true, version: "1.19.28-test")
    }

    func configs() -> MihomoConfigs {
        makeControllerSessionConfigs(mode: .rule)
    }

    func patchConfigs(_ patch: MihomoConfigPatch) {}

    func proxies() async throws -> MihomoProxiesResponse {
        runtimeCalls += 1
        while providerCalls == 0 {
            try Task.checkCancellation()
            await Task.yield()
        }
        observedConcurrentFetch = true
        let group = makeControllerSessionProxyGroup(
            now: "DIRECT",
            all: ["DIRECT"]
        )
        let direct = makeControllerSessionProxyGroup(
            name: "DIRECT",
            type: "Direct",
            now: nil,
            all: nil
        )
        return MihomoProxiesResponse(proxies: [
            group.name: group,
            direct.name: direct,
        ])
    }

    func proxyProviders() async throws -> MihomoProxyProvidersResponse {
        providerCalls += 1
        while runtimeCalls == 0 {
            try Task.checkCancellation()
            await Task.yield()
        }
        observedConcurrentFetch = true
        throw MihomoAPIError.httpStatus(
            code: 500,
            body: #"{"message":"provider unavailable"}"#
        )
    }

    func runtimeCallCount() -> Int { runtimeCalls }
    func providerCallCount() -> Int { providerCalls }
    func didFetchConcurrently() -> Bool { observedConcurrentFetch }
}

nonisolated private enum ControllerDelayRoute: Hashable, Sendable {
    case runtime(name: String)
    case provider(provider: String, name: String)
}

private actor ControllerOriginDelayAPIFake: MihomoAPIProviding {
    private var routes: [ControllerDelayRoute] = []

    func version() -> MihomoVersion {
        MihomoVersion(meta: true, version: "1.19.28-test")
    }

    func configs() -> MihomoConfigs {
        makeControllerSessionConfigs(mode: .rule)
    }

    func patchConfigs(_ patch: MihomoConfigPatch) {}

    func proxies() -> MihomoProxiesResponse {
        MihomoProxiesResponse(proxies: [:])
    }

    func proxyProviders() -> MihomoProxyProvidersResponse {
        .empty
    }

    func proxyDelay(
        name: String,
        url: String,
        timeoutMilliseconds: Int,
        expectedStatus: String?
    ) -> MihomoProxyDelayResponse {
        routes.append(.runtime(name: name))
        return MihomoProxyDelayResponse(delay: 11)
    }

    func proxyProviderProxyDelay(
        provider: String,
        name: String,
        url: String,
        timeoutMilliseconds: Int,
        expectedStatus: String?
    ) -> MihomoProxyDelayResponse {
        routes.append(.provider(provider: provider, name: name))
        return MihomoProxyDelayResponse(delay: 22)
    }

    func routeCount(_ route: ControllerDelayRoute) -> Int {
        routes.count { $0 == route }
    }
}

private actor ControllerSessionGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let continuations = waiters
        waiters.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }
}

private struct ControllerSessionTelemetryFake: MihomoTelemetryStreaming, Sendable {
    let hub: ControllerSessionTelemetryHub

    func logs(level: LogLevel?) -> AsyncThrowingStream<LogEntry, Error> {
        AsyncThrowingStream { continuation in
            Task { await hub.installLogContinuation(continuation) }
            continuation.onTermination = { @Sendable _ in
                Task { await hub.logTerminated() }
            }
        }
    }

    func traffic() -> AsyncThrowingStream<TrafficSample, Error> {
        AsyncThrowingStream { continuation in
            Task { await hub.installTrafficContinuation(continuation) }
            continuation.onTermination = { @Sendable _ in
                Task { await hub.trafficTerminated() }
            }
        }
    }
}

private actor ControllerSessionTelemetryHub {
    private var logContinuation: AsyncThrowingStream<LogEntry, Error>.Continuation?
    private var trafficContinuation: AsyncThrowingStream<TrafficSample, Error>.Continuation?
    private var logStarts = 0
    private var trafficStarts = 0
    private var terminations = 0

    func installLogContinuation(
        _ continuation: AsyncThrowingStream<LogEntry, Error>.Continuation
    ) {
        logStarts += 1
        logContinuation = continuation
    }

    func installTrafficContinuation(
        _ continuation: AsyncThrowingStream<TrafficSample, Error>.Continuation
    ) {
        trafficStarts += 1
        trafficContinuation = continuation
    }

    func logTerminated() {
        logContinuation = nil
        terminations += 1
    }

    func trafficTerminated() {
        trafficContinuation = nil
        terminations += 1
    }

    func yieldLog(_ entry: LogEntry) {
        logContinuation?.yield(entry)
    }

    func yieldTraffic(_ sample: TrafficSample) {
        trafficContinuation?.yield(sample)
    }

    func failTraffic(_ error: any Error & Sendable) {
        trafficContinuation?.finish(throwing: error)
    }

    func activeStreamCount() -> Int {
        (logContinuation == nil ? 0 : 1) + (trafficContinuation == nil ? 0 : 1)
    }

    func logStreamCount() -> Int { logStarts }
    func trafficStreamCount() -> Int { trafficStarts }
    func terminationCount() -> Int { terminations }
}

private actor ControllerSessionEventRecorder {
    private var events: [MihomoControllerEvent] = []

    func record(_ event: MihomoControllerEvent) {
        events.append(event)
    }

    func contains(_ event: MihomoControllerEvent) -> Bool {
        events.contains(event)
    }

    func containsReady(mode: MihomoMode) -> Bool {
        events.contains { event in
            guard case let .ready(snapshot) = event else { return false }
            return snapshot.configs.mode == mode
        }
    }

    func containsLog(message: String) -> Bool {
        events.contains { event in
            guard case let .logsUpdated(entries) = event else { return false }
            return entries.contains { $0.message == message }
        }
    }

    func containsTraffic(_ traffic: TrafficSample) -> Bool {
        events.contains(.trafficUpdated(traffic))
    }

    func containsProxySelection(group: String, selectedProxy: String) -> Bool {
        events.contains { event in
            switch event {
            case let .proxiesUpdated(response):
                guard let proxyGroup = response.proxies[group] else { return false }
                switch proxyGroup.type {
                case "URLTest", "Fallback":
                    return proxyGroup.fixed.flatMap { $0.isEmpty ? nil : $0 }
                        == selectedProxy
                case "Selector":
                    return proxyGroup.now == selectedProxy
                default:
                    return false
                }
            case let .proxyCatalogUpdated(catalog):
                guard let proxyGroup = catalog.group(named: group) else { return false }
                switch proxyGroup.type {
                case "URLTest", "Fallback":
                    return proxyGroup.fixed.flatMap { $0.isEmpty ? nil : $0 }
                        == selectedProxy
                case "Selector":
                    return proxyGroup.now == selectedProxy
                default:
                    return false
                }
            default:
                return false
            }
        }
    }

    func latestProxyCatalog() -> ProxyCatalog? {
        for event in events.reversed() {
            if case let .proxyCatalogUpdated(catalog) = event {
                return catalog
            }
        }
        return nil
    }

    func containsUnavailable() -> Bool {
        events.contains { event in
            if case .unavailable = event {
                return true
            }
            return false
        }
    }

    func lastConnectionEventIsDisconnected() -> Bool {
        for event in events.reversed() {
            switch event {
            case .connecting, .ready, .unavailable, .disconnected:
                return event == .disconnected
            case .proxiesUpdated,
                .proxyCatalogUpdated,
                .proxiesUnavailable,
                .logsUpdated,
                .trafficUpdated:
                continue
            }
        }
        return false
    }
}

nonisolated private func makeControllerSessionConfigs(mode: MihomoMode) -> MihomoConfigs {
    MihomoConfigs(
        port: 0,
        socksPort: 0,
        redirPort: 0,
        tproxyPort: 0,
        mixedPort: 7_890,
        allowLan: false,
        bindAddress: "*",
        mode: mode,
        logLevel: "info",
        ipv6: true,
        unifiedDelay: false,
        tcpConcurrent: true,
        findProcessMode: "strict",
        interfaceName: "",
        sniffing: false
    )
}

nonisolated private enum ControllerSessionTestError: Error, Sendable {
    case offline
}

nonisolated private enum ControllerProxyDelayTestError: Error, Sendable {
    case failed(String)
}

nonisolated private func makeControllerSessionProxyGroup(
    name: String = "Primary",
    type: String = "Selector",
    now: String?,
    fixed: String? = nil,
    all: [String]? = ["Node A", "Node B"]
) -> MihomoProxy {
    MihomoProxy(
        id: "\(name)-id",
        name: name,
        type: type,
        alive: true,
        udp: true,
        uot: nil,
        xudp: nil,
        tfo: nil,
        mptcp: nil,
        smux: nil,
        interfaceName: nil,
        routingMark: nil,
        providerName: nil,
        dialerProxy: nil,
        now: now,
        all: all,
        testURL: "https://example.com/generate_204",
        expectedStatus: "200-299",
        fixed: fixed,
        hidden: false,
        icon: nil,
        emptyFallback: nil,
        history: nil,
        extra: nil
    )
}
