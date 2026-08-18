import Foundation
import SystemConfiguration
import Testing
@testable import Vela

@Suite("System proxy manager")
struct SystemProxyManagerTests {
    private let target = SystemProxyTarget(host: "127.0.0.1", port: Int(7890))

    @Test("Status reports every service and protocol instead of a single flag")
    func statusReportsPerServiceProtocolState() async throws {
        let partial = try proxyConfiguration(
            http: (true, "127.0.0.1", 7890),
            https: (true, "127.0.0.1", 7890),
            socks: (false, nil, nil)
        )
        let disabled = try proxyConfiguration()
        let backend = FakeSystemProxyBackend(services: [
            service(id: "wifi", name: "Wi-Fi", configuration: partial),
            service(id: "ethernet", name: "Ethernet", configuration: disabled)
        ])
        let manager = SystemProxyManager(
            backend: backend,
            recoveryStore: FakeSystemProxyRecoveryStore()
        )

        let status = try await manager.status(for: target)

        #expect(status.aggregate == .partiallyApplied)
        #expect(status.services.count == 2)
        let wifi = try #require(status.services.first { $0.id == "wifi" })
        #expect(wifi.http.matches(target))
        #expect(wifi.https.matches(target))
        #expect(!wifi.socks.isEnabled)
        #expect(wifi.ownership == .untracked)
    }

    @Test("PAC and WPAD are exposed and never reported as disabled")
    func statusExposesAutomaticProxyConfiguration() async throws {
        let pac = try proxyConfiguration(
            pacURL: "https://example.test/proxy.pac",
            pacEnabled: true,
            autoDiscoveryEnabled: true
        )
        let backend = FakeSystemProxyBackend(services: [
            service(id: "wifi", name: "Wi-Fi", configuration: pac)
        ])
        let manager = SystemProxyManager(
            backend: backend,
            recoveryStore: FakeSystemProxyRecoveryStore()
        )

        let status = try await manager.status(for: target)
        let wifi = try #require(status.services.first)

        #expect(status.aggregate == .externallyConfigured)
        #expect(wifi.automatic.isAutoConfigurationEnabled)
        #expect(wifi.automatic.autoConfigurationURL == "https://example.test/proxy.pac")
        #expect(wifi.automatic.isAutoDiscoveryEnabled)
    }

    @Test("Enable refuses to shadow active PAC or WPAD settings")
    func enableRefusesAutomaticProxyConfiguration() async throws {
        let automatic = try proxyConfiguration(autoDiscoveryEnabled: true)
        let backend = FakeSystemProxyBackend(services: [
            service(id: "wifi", name: "Wi-Fi", configuration: automatic)
        ])
        let store = FakeSystemProxyRecoveryStore()
        let manager = SystemProxyManager(backend: backend, recoveryStore: store)

        do {
            _ = try await manager.enable(target)
            Issue.record("Expected automatic proxy configuration to be rejected")
        } catch let error as SystemProxyManagerError {
            #expect(error == .automaticConfigurationEnabled(serviceNames: ["Wi-Fi"]))
        }

        #expect(await backend.applyCallCount() == 0)
        #expect(await store.storedLease() == nil)
    }

    @Test("Enable saves the recovery lease before one multi-service apply")
    func enablePersistsBeforeMultiServiceApply() async throws {
        let recorder = SystemProxyEventRecorder()
        let original = try proxyConfiguration(exceptions: ["localhost"], pacURL: "https://example.test/pac")
        let backend = FakeSystemProxyBackend(
            services: [
                service(id: "wifi", name: "Wi-Fi", configuration: original),
                service(id: "ethernet", name: "Ethernet", configuration: original)
            ],
            recorder: recorder
        )
        let store = FakeSystemProxyRecoveryStore(recorder: recorder)
        let manager = SystemProxyManager(backend: backend, recoveryStore: store)

        let result = try await manager.enable(target)

        #expect(result.changedServiceNames == ["Ethernet", "Wi-Fi"])
        #expect(result.status.aggregate == .applied)
        #expect(await recorder.events() == ["lease.save", "backend.apply"])
        let lease = try #require(await store.storedLease())
        #expect(lease.services.map(\.name) == ["Ethernet", "Wi-Fi"])
        #expect(lease.services.allSatisfy { entry in
            SystemProxyPropertyList.configurationsEqual(entry.originalConfiguration, original)
        })
        #expect(await backend.applyCallCount() == 1)
        #expect(await backend.lastMutationNames() == ["Ethernet", "Wi-Fi"])
    }

    @Test("Repeated enable keeps the first baseline and does not write again")
    func repeatedEnableDoesNotOverwriteBaseline() async throws {
        let original = try proxyConfiguration(exceptions: ["original.example"])
        let backend = FakeSystemProxyBackend(services: [
            service(id: "wifi", name: "Wi-Fi", configuration: original)
        ])
        let store = FakeSystemProxyRecoveryStore()
        let manager = SystemProxyManager(backend: backend, recoveryStore: store)

        _ = try await manager.enable(target)
        let firstLease = try #require(await store.storedLease())
        let secondResult = try await manager.enable(target)
        let secondLease = try #require(await store.storedLease())

        #expect(secondResult.changedServiceNames.isEmpty)
        #expect(firstLease == secondLease)
        #expect(SystemProxyPropertyList.configurationsEqual(
            secondLease.services[0].originalConfiguration,
            original
        ))
        #expect(await backend.applyCallCount() == 1)
        #expect(await store.saveCallCount() == 1)
    }

    @Test("An exact external target is reported but never claimed by Vela")
    func exactExternalTargetCannotBeAdopted() async throws {
        let external = try SystemProxyPropertyList.applying(
            target: target,
            to: proxyConfiguration(exceptions: ["external.example"])
        )
        let backend = FakeSystemProxyBackend(services: [
            service(id: "wifi", name: "Wi-Fi", configuration: external)
        ])
        let store = FakeSystemProxyRecoveryStore()
        let manager = SystemProxyManager(backend: backend, recoveryStore: store)

        let before = try await manager.status(for: target)
        #expect(before.aggregate == .externallyConfigured)
        #expect(before.services.first?.ownership == .untracked)

        do {
            _ = try await manager.enable(target)
            Issue.record("Expected Vela to refuse an externally configured exact target")
        } catch let error as SystemProxyManagerError {
            #expect(error == .targetAlreadyConfiguredExternally(serviceNames: ["Wi-Fi"]))
        }

        #expect(await backend.applyCallCount() == 0)
        #expect(await store.storedLease() == nil)
        let unchanged = try #require(await backend.configuration(id: "wifi"))
        #expect(SystemProxyPropertyList.configurationsEqual(unchanged, external))
    }

    @Test("A partial external target is not folded into Vela's recovery baseline")
    func partialExternalTargetCannotBeAdopted() async throws {
        let external = try proxyConfiguration(
            http: (true, "127.0.0.1", 7890),
            https: (false, nil, nil),
            socks: (false, nil, nil),
            exceptions: ["external.example"]
        )
        let backend = FakeSystemProxyBackend(services: [
            service(id: "wifi", name: "Wi-Fi", configuration: external)
        ])
        let store = FakeSystemProxyRecoveryStore()
        let manager = SystemProxyManager(backend: backend, recoveryStore: store)

        let before = try await manager.status(for: target)
        #expect(before.aggregate == .partiallyApplied)

        do {
            _ = try await manager.enable(target)
            Issue.record("Expected Vela to refuse a partially preconfigured target")
        } catch let error as SystemProxyManagerError {
            #expect(error == .targetAlreadyConfiguredExternally(serviceNames: ["Wi-Fi"]))
        }

        #expect(await backend.applyCallCount() == 0)
        #expect(await store.storedLease() == nil)
        let unchanged = try #require(await backend.configuration(id: "wifi"))
        #expect(SystemProxyPropertyList.configurationsEqual(unchanged, external))
    }

    @Test("A legacy adoption lease remains recovery-required and blocks unsafe release")
    func legacyExactTargetLeaseIsNotReleased() async throws {
        let external = try SystemProxyPropertyList.applying(
            target: target,
            to: proxyConfiguration(exceptions: ["external.example"])
        )
        let legacyLease = SystemProxyRecoveryLease(
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            target: target,
            services: [
                SystemProxyRecoveryService(
                    id: "wifi",
                    name: "Wi-Fi",
                    originalConfiguration: external,
                    managedConfiguration: external
                )
            ]
        )
        let backend = FakeSystemProxyBackend(services: [
            service(id: "wifi", name: "Wi-Fi", configuration: external)
        ])
        let store = FakeSystemProxyRecoveryStore(lease: legacyLease)
        let manager = SystemProxyManager(backend: backend, recoveryStore: store)

        let before = try await manager.status(for: target)
        #expect(before.aggregate == .externallyConfigured)
        #expect(before.recovery == .recoveryRequired(serviceNames: ["Wi-Fi"]))
        #expect(before.services.first?.ownership == .untracked)

        let restore = try await manager.restore()

        #expect(restore.restoredServiceNames.isEmpty)
        #expect(restore.conflictedServiceNames == ["Wi-Fi"])
        #expect(restore.status.recovery == .recoveryRequired(serviceNames: ["Wi-Fi"]))
        #expect(await backend.applyCallCount() == 0)
        #expect(await store.storedLease() == legacyLease)
        let unchanged = try #require(await backend.configuration(id: "wifi"))
        #expect(SystemProxyPropertyList.configurationsEqual(unchanged, external))
    }

    @Test("Restore is idempotent and returns all managed fields to their originals")
    func restoreReturnsOriginalManagedFields() async throws {
        let base = try proxyConfiguration(
            http: (true, "proxy.before", 8080),
            exceptions: ["localhost"]
        )
        var originalDictionary = try SystemProxyPropertyList.decode(base)
        originalDictionary[kSCPropNetProxiesHTTPUser as String] = "http-user"
        originalDictionary[kSCPropNetProxiesHTTPSUser as String] = "https-user"
        originalDictionary[kSCPropNetProxiesSOCKSUser as String] = "socks-user"
        let original = try SystemProxyPropertyList.encode(originalDictionary)
        let backend = FakeSystemProxyBackend(services: [
            service(id: "wifi", name: "Wi-Fi", configuration: original)
        ])
        let store = FakeSystemProxyRecoveryStore()
        let manager = SystemProxyManager(backend: backend, recoveryStore: store)
        _ = try await manager.enable(target)
        let managed = try SystemProxyPropertyList.decode(
            try #require(await backend.configuration(id: "wifi"))
        )
        #expect(managed[kSCPropNetProxiesHTTPUser as String] == nil)
        #expect(managed[kSCPropNetProxiesHTTPSUser as String] == nil)
        #expect(managed[kSCPropNetProxiesSOCKSUser as String] == nil)

        let first = try await manager.restore()
        let second = try await manager.restore()

        #expect(first.restoredServiceNames == ["Wi-Fi"])
        #expect(first.conflictedServiceNames.isEmpty)
        #expect(first.status.aggregate == .externallyConfigured)
        #expect(second.restoredServiceNames.isEmpty)
        #expect(await store.storedLease() == nil)
        let actual = try #require(await backend.configuration(id: "wifi"))
        #expect(SystemProxyPropertyList.managedFieldsEqual(actual, original))
        let restoredDictionary = try SystemProxyPropertyList.decode(actual)
        #expect(restoredDictionary[kSCPropNetProxiesHTTPUser as String] as? String == "http-user")
        #expect(restoredDictionary[kSCPropNetProxiesHTTPSUser as String] as? String == "https-user")
        #expect(restoredDictionary[kSCPropNetProxiesSOCKSUser as String] as? String == "socks-user")
    }

    @Test("Restore preserves external PAC and bypass edits while CAS-protecting managed fields")
    func restorePreservesUnmanagedExternalEdits() async throws {
        let original = try proxyConfiguration(
            exceptions: ["old.example"],
            pacURL: "https://old.example/pac"
        )
        let backend = FakeSystemProxyBackend(services: [
            service(id: "wifi", name: "Wi-Fi", configuration: original)
        ])
        let store = FakeSystemProxyRecoveryStore()
        let manager = SystemProxyManager(backend: backend, recoveryStore: store)
        _ = try await manager.enable(target)

        let managed = try #require(await backend.configuration(id: "wifi"))
        let externallyEdited = try replacingUnmanagedFields(
            in: managed,
            exceptions: ["new.example"],
            pacURL: "https://new.example/pac"
        )
        await backend.replaceConfiguration(id: "wifi", with: externallyEdited)

        let result = try await manager.restore()
        let restored = try #require(await backend.configuration(id: "wifi"))
        let dictionary = try SystemProxyPropertyList.decode(restored)

        #expect(result.restoredServiceNames == ["Wi-Fi"])
        #expect(result.conflictedServiceNames.isEmpty)
        #expect(dictionary[kSCPropNetProxiesExceptionsList as String] as? [String] == ["new.example"])
        #expect(dictionary[kSCPropNetProxiesProxyAutoConfigURLString as String] as? String == "https://new.example/pac")
        #expect(SystemProxyPropertyList.managedFieldsEqual(restored, original))
    }

    @Test("Restore handles each managed key with CAS and preserves one external conflict")
    func restoreReleasesManagedFieldConflictWithoutOverwrite() async throws {
        let original = try proxyConfiguration()
        let backend = FakeSystemProxyBackend(services: [
            service(id: "wifi", name: "Wi-Fi", configuration: original)
        ])
        let store = FakeSystemProxyRecoveryStore()
        let manager = SystemProxyManager(backend: backend, recoveryStore: store)
        _ = try await manager.enable(target)

        var external = try SystemProxyPropertyList.decode(
            try #require(await backend.configuration(id: "wifi"))
        )
        external[kSCPropNetProxiesSOCKSPort as String] = 9999
        let externalData = try SystemProxyPropertyList.encode(external)
        await backend.replaceConfiguration(id: "wifi", with: externalData)

        let result = try await manager.restore()

        #expect(result.restoredServiceNames == ["Wi-Fi"])
        #expect(result.conflictedServiceNames == ["Wi-Fi"])
        #expect(await store.storedLease() == nil)
        let after = try #require(await backend.configuration(id: "wifi"))
        let afterDictionary = try SystemProxyPropertyList.decode(after)
        #expect(afterDictionary[kSCPropNetProxiesSOCKSPort as String] as? Int == 9999)
        let endpoints = try SystemProxyPropertyList.endpoints(in: after)
        #expect(endpoints.allSatisfy { !$0.isEnabled })
        #expect(endpoints[0].host == nil)
        #expect(endpoints[1].host == nil)
        #expect(endpoints[2].host == nil)
    }

    @Test("A partial backend failure rolls every changed service back and clears a new lease")
    func partialEnableFailureRollsBack() async throws {
        let originalWiFi = try proxyConfiguration(exceptions: ["wifi.example"])
        let originalEthernet = try proxyConfiguration(exceptions: ["ethernet.example"])
        let backend = FakeSystemProxyBackend(
            services: [
                service(id: "wifi", name: "Wi-Fi", configuration: originalWiFi),
                service(id: "ethernet", name: "Ethernet", configuration: originalEthernet)
            ],
            applyBehaviors: [.failAfterMutation(count: 1), .succeed]
        )
        let store = FakeSystemProxyRecoveryStore()
        let manager = SystemProxyManager(backend: backend, recoveryStore: store)

        do {
            _ = try await manager.enable(target)
            Issue.record("Expected enable to fail")
        } catch let error as SystemProxyManagerError {
            guard case let .enableFailed(_, rollbackReason) = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            #expect(rollbackReason == nil)
        }

        #expect(await store.storedLease() == nil)
        #expect(await backend.applyCallCount() == 2)
        let wifi = try #require(await backend.configuration(id: "wifi"))
        let ethernet = try #require(await backend.configuration(id: "ethernet"))
        #expect(SystemProxyPropertyList.managedFieldsEqual(wifi, originalWiFi))
        #expect(SystemProxyPropertyList.managedFieldsEqual(ethernet, originalEthernet))
    }

    @Test("Readback mismatch fails enable and rolls successful writes back")
    func readbackMismatchTriggersRollback() async throws {
        let originalWiFi = try proxyConfiguration()
        let originalEthernet = try proxyConfiguration()
        let backend = FakeSystemProxyBackend(
            services: [
                service(id: "wifi", name: "Wi-Fi", configuration: originalWiFi),
                service(id: "ethernet", name: "Ethernet", configuration: originalEthernet)
            ],
            applyBehaviors: [.omitMutation(serviceID: "wifi"), .succeed]
        )
        let store = FakeSystemProxyRecoveryStore()
        let manager = SystemProxyManager(backend: backend, recoveryStore: store)

        do {
            _ = try await manager.enable(target)
            Issue.record("Expected verification to fail")
        } catch let error as SystemProxyManagerError {
            guard case let .enableVerificationFailed(serviceNames, rollbackReason) = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            #expect(serviceNames == ["Wi-Fi"])
            #expect(rollbackReason == nil)
        }

        #expect(await store.storedLease() == nil)
        let ethernet = try #require(await backend.configuration(id: "ethernet"))
        #expect(SystemProxyPropertyList.managedFieldsEqual(ethernet, originalEthernet))
    }

    @Test("A failed restore retains its lease and a retry finishes idempotently")
    func failedRestoreRetainsLeaseForRetry() async throws {
        let original = try proxyConfiguration()
        let backend = FakeSystemProxyBackend(
            services: [
                service(id: "wifi", name: "Wi-Fi", configuration: original),
                service(id: "ethernet", name: "Ethernet", configuration: original)
            ],
            applyBehaviors: [.succeed, .failAfterMutation(count: 1), .succeed]
        )
        let store = FakeSystemProxyRecoveryStore()
        let manager = SystemProxyManager(backend: backend, recoveryStore: store)
        _ = try await manager.enable(target)

        do {
            _ = try await manager.restore()
            Issue.record("Expected the first restore to fail")
        } catch let error as SystemProxyManagerError {
            guard case .restoreFailed = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
        }
        #expect(await store.storedLease() != nil)

        let retry = try await manager.restore()
        #expect(retry.restoredServiceNames == ["Wi-Fi"])
        #expect(retry.alreadyRestoredServiceNames == ["Ethernet"])
        #expect(await store.storedLease() == nil)
    }

    @Test("A temporarily missing service keeps only its lease entry and restores when it returns")
    func missingServiceLeaseSurvivesUntilServiceReturns() async throws {
        let original = try proxyConfiguration(exceptions: ["baseline.example"])
        let managed = try SystemProxyPropertyList.applying(target: target, to: original)
        let lease = SystemProxyRecoveryLease(
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            target: target,
            services: [
                SystemProxyRecoveryService(
                    id: "wifi",
                    name: "Wi-Fi",
                    originalConfiguration: original,
                    managedConfiguration: managed
                ),
                SystemProxyRecoveryService(
                    id: "ethernet",
                    name: "Ethernet",
                    originalConfiguration: original,
                    managedConfiguration: managed
                )
            ]
        )
        let backend = FakeSystemProxyBackend(services: [
            service(id: "ethernet", name: "Ethernet", configuration: managed)
        ])
        let store = FakeSystemProxyRecoveryStore(lease: lease)
        let manager = SystemProxyManager(backend: backend, recoveryStore: store)

        let firstRestore = try await manager.restore()

        #expect(firstRestore.restoredServiceNames == ["Ethernet"])
        #expect(firstRestore.missingServiceNames == ["Wi-Fi"])
        #expect(firstRestore.status.recovery == .recoveryRequired(serviceNames: ["Wi-Fi"]))
        let retainedLease = try #require(await store.storedLease())
        #expect(retainedLease.services.map(\.name) == ["Wi-Fi"])

        await backend.insertService(
            service(id: "wifi", name: "Wi-Fi", configuration: managed)
        )
        let secondRestore = try await manager.restore()

        #expect(secondRestore.restoredServiceNames == ["Wi-Fi"])
        #expect(secondRestore.missingServiceNames.isEmpty)
        #expect(secondRestore.status.recovery == .none)
        #expect(await store.storedLease() == nil)
        let wifi = try #require(await backend.configuration(id: "wifi"))
        let ethernet = try #require(await backend.configuration(id: "ethernet"))
        #expect(SystemProxyPropertyList.configurationsEqual(wifi, original))
        #expect(SystemProxyPropertyList.configurationsEqual(ethernet, original))
    }

    @Test("Enable refuses a managed-field conflict under an existing lease")
    func repeatedEnableRefusesExternalManagedFieldChange() async throws {
        let original = try proxyConfiguration()
        let backend = FakeSystemProxyBackend(services: [
            service(id: "wifi", name: "Wi-Fi", configuration: original)
        ])
        let store = FakeSystemProxyRecoveryStore()
        let manager = SystemProxyManager(backend: backend, recoveryStore: store)
        _ = try await manager.enable(target)

        var external = try SystemProxyPropertyList.decode(
            try #require(await backend.configuration(id: "wifi"))
        )
        external[kSCPropNetProxiesSOCKSPort as String] = 9999
        await backend.replaceConfiguration(
            id: "wifi",
            with: try SystemProxyPropertyList.encode(external)
        )

        do {
            _ = try await manager.enable(target)
            Issue.record("Expected the external change to be rejected")
        } catch let error as SystemProxyManagerError {
            #expect(error == .externallyModified(serviceNames: ["Wi-Fi"]))
        }
        #expect(await backend.applyCallCount() == 1)
    }

    @Test("One conflicted service makes the whole multi-service lease require recovery")
    func statusDoesNotHideConflictBehindManagedService() async throws {
        let original = try proxyConfiguration()
        let backend = FakeSystemProxyBackend(services: [
            service(id: "wifi", name: "Wi-Fi", configuration: original),
            service(id: "ethernet", name: "Ethernet", configuration: original)
        ])
        let store = FakeSystemProxyRecoveryStore()
        let manager = SystemProxyManager(backend: backend, recoveryStore: store)
        _ = try await manager.enable(target)

        var conflict = try SystemProxyPropertyList.decode(
            try #require(await backend.configuration(id: "wifi"))
        )
        conflict[kSCPropNetProxiesHTTPSPort as String] = 4444
        await backend.replaceConfiguration(
            id: "wifi",
            with: try SystemProxyPropertyList.encode(conflict)
        )

        let status = try await manager.status(for: target)

        #expect(status.recovery == .recoveryRequired(serviceNames: ["Ethernet", "Wi-Fi"]))
        #expect(status.services.first { $0.id == "ethernet" }?.ownership == .managedByVela)
        #expect(status.services.first { $0.id == "wifi" }?.ownership == .externallyModified)
    }

    @Test("Backend CAS catches drift after the lease save and before commit")
    func enableDoesNotOverwriteDriftBeforeCommit() async throws {
        let recorder = SystemProxyEventRecorder()
        let original = try proxyConfiguration(exceptions: ["baseline.example"])
        var driftedDictionary = try SystemProxyPropertyList.decode(original)
        driftedDictionary[kSCPropNetProxiesHTTPProxy as String] = "corporate.proxy"
        driftedDictionary[kSCPropNetProxiesHTTPEnable as String] = 1
        driftedDictionary[kSCPropNetProxiesHTTPPort as String] = 3128
        let drifted = try SystemProxyPropertyList.encode(driftedDictionary)
        let backend = FakeSystemProxyBackend(
            services: [service(id: "wifi", name: "Wi-Fi", configuration: original)],
            applyBehaviors: [
                .driftBeforeCAS(serviceID: "wifi", configuration: drifted)
            ],
            recorder: recorder
        )
        let store = FakeSystemProxyRecoveryStore(recorder: recorder)
        let manager = SystemProxyManager(backend: backend, recoveryStore: store)

        do {
            _ = try await manager.enable(target)
            Issue.record("Expected the pre-commit CAS to reject drift")
        } catch let error as SystemProxyManagerError {
            guard case let .enableRejectedBeforeCommit(reason, cleanupReason) = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            #expect(reason.contains("Wi-Fi"))
            #expect(cleanupReason == nil)
        }

        #expect(await recorder.events() == ["lease.save", "backend.apply"])
        #expect(await backend.applyCallCount() == 1)
        #expect(await store.storedLease() == nil)
        let actual = try #require(await backend.configuration(id: "wifi"))
        #expect(SystemProxyPropertyList.configurationsEqual(actual, drifted))
    }

    @Test("Authorization failure before commit cleans metadata without proxy rollback")
    func authorizationFailureDoesNotRunBackendRollback() async throws {
        let original = try proxyConfiguration(exceptions: ["baseline.example"])
        let backend = FakeSystemProxyBackend(
            services: [service(id: "wifi", name: "Wi-Fi", configuration: original)],
            applyBehaviors: [
                .failBeforeCommit(.authorizationFailed(status: -60_005))
            ]
        )
        let store = FakeSystemProxyRecoveryStore()
        let manager = SystemProxyManager(backend: backend, recoveryStore: store)

        do {
            _ = try await manager.enable(target)
            Issue.record("Expected authorization to fail before commit")
        } catch let error as SystemProxyManagerError {
            guard case let .enableRejectedBeforeCommit(_, cleanupReason) = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            #expect(cleanupReason == nil)
        }

        #expect(await backend.applyCallCount() == 1)
        #expect(await store.storedLease() == nil)
        let actual = try #require(await backend.configuration(id: "wifi"))
        #expect(SystemProxyPropertyList.configurationsEqual(actual, original))
        #expect(!SystemProxyBackendError.commitFailed(
            serviceNames: ["Wi-Fi"],
            reason: "ambiguous"
        ).definitelyRejectedBeforeCommit)
        #expect(!SystemProxyBackendError.applyFailed(
            serviceNames: ["Wi-Fi"],
            reason: "possibly committed"
        ).definitelyRejectedBeforeCommit)
    }

    @Test("Restore waits behind an enable suspended after saving its lease")
    func restoreCannotReenterSuspendedEnable() async throws {
        let original = try proxyConfiguration(exceptions: ["baseline.example"])
        let backendPause = FakeBackendPause()
        let transactionGate = SystemProxyTransactionGate()
        let backend = FakeSystemProxyBackend(
            services: [service(id: "wifi", name: "Wi-Fi", configuration: original)],
            applyBehaviors: [.pauseBeforeCAS(backendPause)]
        )
        let store = FakeSystemProxyRecoveryStore()
        let manager = SystemProxyManager(
            backend: backend,
            recoveryStore: store,
            transactionGate: transactionGate
        )

        let enableTask = Task {
            try await manager.enable(target)
        }
        await backendPause.waitUntilPaused()
        #expect(await store.storedLease() != nil)
        let beforeApply = try #require(await backend.configuration(id: "wifi"))
        #expect(SystemProxyPropertyList.configurationsEqual(beforeApply, original))

        let restoreTask = Task {
            try await manager.restore()
        }
        await transactionGate.waitUntilQueueDepth(1)

        // Restore has reached the manager but cannot observe or clear the
        // in-flight enable lease while that transaction owns the gate.
        #expect(await store.clearCallCount() == 0)
        #expect(await store.storedLease() != nil)

        await backendPause.resume()
        let enableResult = try await enableTask.value
        let restoreResult = try await restoreTask.value

        #expect(enableResult.status.aggregate == .applied)
        #expect(restoreResult.restoredServiceNames == ["Wi-Fi"])
        #expect(await backend.applyCallCount() == 2)
        #expect(await store.clearCallCount() == 1)
        #expect(await store.storedLease() == nil)
        let finalConfiguration = try #require(await backend.configuration(id: "wifi"))
        #expect(SystemProxyPropertyList.configurationsEqual(finalConfiguration, original))
    }

    @Test("A canceled queued enable releases the FIFO gate without writing")
    func canceledQueuedEnableNeverRuns() async throws {
        let original = try proxyConfiguration(exceptions: ["baseline.example"])
        let backendPause = FakeBackendPause()
        let transactionGate = SystemProxyTransactionGate()
        let backend = FakeSystemProxyBackend(
            services: [service(id: "wifi", name: "Wi-Fi", configuration: original)],
            applyBehaviors: [.pauseBeforeCAS(backendPause)]
        )
        let store = FakeSystemProxyRecoveryStore()
        let manager = SystemProxyManager(
            backend: backend,
            recoveryStore: store,
            transactionGate: transactionGate
        )

        let firstEnable = Task {
            try await manager.enable(target)
        }
        await backendPause.waitUntilPaused()

        let canceledEnable = Task {
            try await manager.enable(SystemProxyTarget(port: Int(7891)))
        }
        await transactionGate.waitUntilQueueDepth(1)
        canceledEnable.cancel()

        let restoreTask = Task {
            try await manager.restore()
        }
        await transactionGate.waitUntilQueueDepth(2)
        await backendPause.resume()

        _ = try await firstEnable.value
        do {
            _ = try await canceledEnable.value
            Issue.record("Expected the queued enable to stay canceled")
        } catch is CancellationError {
            // Expected: the operation acquired and released the gate without
            // entering performEnable.
        } catch {
            Issue.record("Unexpected cancellation error: \(error)")
        }
        let restore = try await restoreTask.value

        #expect(restore.restoredServiceNames == ["Wi-Fi"])
        #expect(await backend.applyCallCount() == 2)
        #expect(await store.storedLease() == nil)
        let finalConfiguration = try #require(await backend.configuration(id: "wifi"))
        #expect(SystemProxyPropertyList.configurationsEqual(finalConfiguration, original))
    }
}

private nonisolated func service(
    id: String,
    name: String,
    configuration: Data
) -> SystemProxyBackendService {
    SystemProxyBackendService(
        id: id,
        name: name,
        isEnabled: true,
        configuration: configuration
    )
}

private nonisolated func proxyConfiguration(
    http: (Bool, String?, Int?) = (false, nil, nil),
    https: (Bool, String?, Int?) = (false, nil, nil),
    socks: (Bool, String?, Int?) = (false, nil, nil),
    exceptions: [String]? = nil,
    pacURL: String? = nil,
    pacEnabled: Bool = false,
    autoDiscoveryEnabled: Bool = false
) throws -> Data {
    var dictionary: [String: Any] = [:]
    setEndpoint(
        http,
        in: &dictionary,
        enabledKey: kSCPropNetProxiesHTTPEnable as String,
        hostKey: kSCPropNetProxiesHTTPProxy as String,
        portKey: kSCPropNetProxiesHTTPPort as String
    )
    setEndpoint(
        https,
        in: &dictionary,
        enabledKey: kSCPropNetProxiesHTTPSEnable as String,
        hostKey: kSCPropNetProxiesHTTPSProxy as String,
        portKey: kSCPropNetProxiesHTTPSPort as String
    )
    setEndpoint(
        socks,
        in: &dictionary,
        enabledKey: kSCPropNetProxiesSOCKSEnable as String,
        hostKey: kSCPropNetProxiesSOCKSProxy as String,
        portKey: kSCPropNetProxiesSOCKSPort as String
    )
    if let exceptions {
        dictionary[kSCPropNetProxiesExceptionsList as String] = exceptions
    }
    if let pacURL {
        dictionary[kSCPropNetProxiesProxyAutoConfigURLString as String] = pacURL
    }
    dictionary[kSCPropNetProxiesProxyAutoConfigEnable as String] = pacEnabled ? 1 : 0
    dictionary[kSCPropNetProxiesProxyAutoDiscoveryEnable as String] = autoDiscoveryEnabled ? 1 : 0
    return try SystemProxyPropertyList.encode(dictionary)
}

private nonisolated func setEndpoint(
    _ endpoint: (Bool, String?, Int?),
    in dictionary: inout [String: Any],
    enabledKey: String,
    hostKey: String,
    portKey: String
) {
    dictionary[enabledKey] = endpoint.0 ? 1 : 0
    if let host = endpoint.1 {
        dictionary[hostKey] = host
    }
    if let port = endpoint.2 {
        dictionary[portKey] = port
    }
}

private nonisolated func replacingUnmanagedFields(
    in configuration: Data,
    exceptions: [String],
    pacURL: String
) throws -> Data {
    var dictionary = try SystemProxyPropertyList.decode(configuration)
    dictionary[kSCPropNetProxiesExceptionsList as String] = exceptions
    dictionary[kSCPropNetProxiesProxyAutoConfigURLString as String] = pacURL
    dictionary[kSCPropNetProxiesProxyAutoConfigEnable as String] = 1
    return try SystemProxyPropertyList.encode(dictionary)
}

private actor SystemProxyEventRecorder {
    private var recordedEvents: [String] = []

    func record(_ event: String) {
        recordedEvents.append(event)
    }

    func events() -> [String] {
        recordedEvents
    }
}

private enum FakeSystemProxyError: Error, LocalizedError {
    case applyFailed

    var errorDescription: String? {
        switch self {
        case .applyFailed:
            "Injected backend apply failure."
        }
    }
}

private enum FakeApplyBehavior: Sendable {
    case succeed
    case failAfterMutation(count: Int)
    case failBeforeCommit(SystemProxyBackendError)
    case omitMutation(serviceID: String)
    case driftBeforeCAS(serviceID: String, configuration: Data)
    case pauseBeforeCAS(FakeBackendPause)
}

private actor FakeSystemProxyBackend: SystemProxyBackend {
    private var servicesByID: [String: SystemProxyBackendService]
    private var currentServiceIDs: [String]
    private var behaviors: [FakeApplyBehavior]
    private var applyCalls: [[SystemProxyBackendMutation]] = []
    private let recorder: SystemProxyEventRecorder?

    init(
        services: [SystemProxyBackendService],
        applyBehaviors: [FakeApplyBehavior] = [],
        recorder: SystemProxyEventRecorder? = nil
    ) {
        servicesByID = Dictionary(uniqueKeysWithValues: services.map { ($0.id, $0) })
        currentServiceIDs = services.map(\.id)
        behaviors = applyBehaviors
        self.recorder = recorder
    }

    func currentServices() async throws -> [SystemProxyBackendService] {
        currentServiceIDs.compactMap { servicesByID[$0] }
    }

    func services(withIDs ids: [String]) async throws -> [SystemProxyBackendService] {
        ids.compactMap { servicesByID[$0] }
    }

    func apply(_ mutations: [SystemProxyBackendMutation]) async throws {
        guard !mutations.isEmpty else { return }
        applyCalls.append(mutations)
        await recorder?.record("backend.apply")
        let behavior = behaviors.isEmpty ? .succeed : behaviors.removeFirst()

        if case let .failBeforeCommit(error) = behavior {
            throw error
        }

        if case let .driftBeforeCAS(serviceID, configuration) = behavior {
            replaceConfiguration(id: serviceID, with: configuration)
        }
        if case let .pauseBeforeCAS(pause) = behavior {
            await pause.pause()
        }

        for mutation in mutations {
            guard
                let existing = servicesByID[mutation.serviceID],
                SystemProxyPropertyList.configurationsEqual(
                    existing.configuration,
                    mutation.expectedConfiguration
                )
            else {
                throw SystemProxyBackendError.configurationChanged(name: mutation.serviceName)
            }
        }

        for (index, mutation) in mutations.enumerated() {
            if case let .omitMutation(serviceID) = behavior, mutation.serviceID == serviceID {
                continue
            }
            if let existing = servicesByID[mutation.serviceID] {
                servicesByID[mutation.serviceID] = SystemProxyBackendService(
                    id: existing.id,
                    name: existing.name,
                    isEnabled: existing.isEnabled,
                    configuration: mutation.configuration
                )
            }
            if case let .failAfterMutation(count) = behavior, index + 1 == count {
                throw FakeSystemProxyError.applyFailed
            }
        }
    }

    func replaceConfiguration(id: String, with configuration: Data) {
        guard let existing = servicesByID[id] else { return }
        servicesByID[id] = SystemProxyBackendService(
            id: existing.id,
            name: existing.name,
            isEnabled: existing.isEnabled,
            configuration: configuration
        )
    }

    func insertService(_ service: SystemProxyBackendService) {
        servicesByID[service.id] = service
        if !currentServiceIDs.contains(service.id) {
            currentServiceIDs.append(service.id)
        }
    }

    func configuration(id: String) -> Data? {
        servicesByID[id]?.configuration
    }

    func applyCallCount() -> Int {
        applyCalls.count
    }

    func lastMutationNames() -> [String] {
        applyCalls.last?.map(\.serviceName).sorted() ?? []
    }
}

private actor FakeSystemProxyRecoveryStore: SystemProxyRecoveryStoring {
    private var lease: SystemProxyRecoveryLease?
    private var saveCalls = 0
    private var clearCalls = 0
    private let recorder: SystemProxyEventRecorder?

    init(
        lease: SystemProxyRecoveryLease? = nil,
        recorder: SystemProxyEventRecorder? = nil
    ) {
        self.lease = lease
        self.recorder = recorder
    }

    func load() async throws -> SystemProxyRecoveryLease? {
        lease
    }

    func save(_ lease: SystemProxyRecoveryLease) async throws {
        saveCalls += 1
        self.lease = lease
        await recorder?.record("lease.save")
    }

    func clear() async throws {
        clearCalls += 1
        lease = nil
    }

    func storedLease() -> SystemProxyRecoveryLease? {
        lease
    }

    func saveCallCount() -> Int {
        saveCalls
    }

    func clearCallCount() -> Int {
        clearCalls
    }
}

private actor FakeBackendPause {
    private var isPaused = false
    private var pauseObservers: [CheckedContinuation<Void, Never>] = []
    private var resumeContinuation: CheckedContinuation<Void, Never>?

    func pause() async {
        isPaused = true
        let observers = pauseObservers
        pauseObservers.removeAll()
        observers.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            resumeContinuation = continuation
        }
    }

    func waitUntilPaused() async {
        guard !isPaused else { return }
        await withCheckedContinuation { continuation in
            pauseObservers.append(continuation)
        }
    }

    func resume() {
        resumeContinuation?.resume()
        resumeContinuation = nil
    }
}
