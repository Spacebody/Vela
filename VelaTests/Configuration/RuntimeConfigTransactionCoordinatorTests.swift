import Foundation
import Synchronization
import Testing
@testable import Vela

@Suite("Runtime configuration transactions")
struct RuntimeConfigTransactionCoordinatorTests {
    @Test("Inactive profile validates and commits raw without touching Controller or active runtime")
    func inactiveProfileSuccess() async throws {
        let fileSystem = TransactionRecordingFileSystem()
        let api = TransactionAPIFake()
        let process = TransactionProcessFake(running: true)
        let fixture = try await makeTransactionFixture(
            active: false,
            activeData: Data("mode: direct\n".utf8),
            fileSystem: fileSystem,
            api: api,
            process: process
        )
        defer { ConfigurationTestSupport.removeTemporaryDirectory(fixture.temporaryDirectory) }
        let update = Data("mode: rule\ndns:\n  enable: true\n".utf8)
        let result = try await fixture.coordinator.apply(
            rawData: update,
            profileID: fixture.profile.id,
            sourceFileName: "remote.yaml"
        )

        #expect(result.revision != nil)
        #expect(!result.hotReloaded)
        #expect(try Data(contentsOf: fixture.directories.activeConfiguration) == Data("mode: direct\n".utf8))
        #expect(try await fixture.profileStore.readConfiguration(for: fixture.profile.id) == update)
        #expect(await api.reloadCallCount() == 0)
        #expect(await api.selectionCalls().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.directories.runtimeTransactionJournal.path))
        #expect(
            !FileManager.default.fileExists(
                atPath: fixture.directories.profileRollbackURL(
                    transactionID: result.transactionID
                ).path
            )
        )
    }

    @Test("Profile layers remain effective when a remote raw revision is replaced")
    func remoteRevisionAppliesProfileLayer() async throws {
        let fileSystem = TransactionRecordingFileSystem()
        let fixture = try await makeTransactionFixture(
            active: true,
            activeData: Data(TransactionTestValues.baseRawYAML.utf8),
            fileSystem: fileSystem,
            api: TransactionAPIFake(),
            process: TransactionProcessFake(running: false)
        )
        defer { ConfigurationTestSupport.removeTemporaryDirectory(fixture.temporaryDirectory) }

        let rules = [
            YAMLValue.string("DOMAIN,example.com,DIRECT"),
            YAMLValue.string("MATCH,Proxy"),
        ]
        let providers = OrderedYAMLMapping([
            "Example": .mapping(OrderedYAMLMapping([
                "behavior": .string("domain"),
                "path": .string("./ruleset/example.yaml"),
                "type": .string("file"),
            ])),
        ])
        let layerStore = ConfigurationLayerStore(
            directories: fixture.directories,
            fileSystem: fileSystem
        )
        _ = try await layerStore.save(
            ConfigurationLayer(
                name: "Clash Verge Rev rules",
                kind: .profile,
                operations: [
                    ConfigurationOperation(
                        order: 10,
                        path: try YAMLPointer("/rule-providers"),
                        kind: .set,
                        value: .mapping(providers)
                    ),
                    ConfigurationOperation(
                        order: 20,
                        path: try YAMLPointer("/rules"),
                        kind: .set,
                        value: .sequence(rules)
                    ),
                ]
            ),
            ownerID: fixture.profile.id
        )

        let remoteUpdate = Data(
            "mode: rule\nrule-providers: {}\nrules:\n  - MATCH,DIRECT\n".utf8
        )
        _ = try await fixture.coordinator.apply(
            rawData: remoteUpdate,
            profileID: fixture.profile.id,
            sourceFileName: "remote.yaml"
        )

        #expect(
            try await fixture.profileStore.readConfiguration(for: fixture.profile.id)
                == remoteUpdate
        )
        let active = try YAMLDocument(
            yaml: String(
                decoding: Data(contentsOf: fixture.directories.activeConfiguration),
                as: UTF8.self
            )
        )
        #expect(try active.value(at: ["rules"]) == .sequence(rules))
        #expect(try active.value(at: ["rule-providers"]) == .mapping(providers))
    }

    @Test("Concurrent apply waits in FIFO order instead of dropping the second update")
    func transactionFIFO() async throws {
        let validator = TransactionValidatorFake(
            result: TransactionTestValues.validValidation,
            delay: .milliseconds(100)
        )
        let fixture = try await makeTransactionFixture(
            active: false,
            activeData: Data("mode: direct\n".utf8),
            fileSystem: TransactionRecordingFileSystem(),
            validator: validator,
            api: TransactionAPIFake(),
            process: TransactionProcessFake(running: false)
        )
        defer { ConfigurationTestSupport.removeTemporaryDirectory(fixture.temporaryDirectory) }

        let first = Task {
            try await fixture.coordinator.apply(
                rawData: Data("mode: rule\nmarker: first\n".utf8),
                profileID: fixture.profile.id,
                sourceFileName: "first.yaml"
            )
        }
        while validator.callCount() == 0 {
            await Task.yield()
        }

        let second = Task {
            try await fixture.coordinator.apply(
                rawData: Data("mode: rule\nmarker: second\n".utf8),
                profileID: fixture.profile.id,
                sourceFileName: "second.yaml"
            )
        }
        _ = try await first.value
        _ = try await second.value

        #expect(validator.callCount() == 2)
        #expect(
            try await fixture.profileStore.readConfiguration(for: fixture.profile.id)
                == Data("mode: rule\nmarker: second\n".utf8)
        )
        #expect(try await fixture.profileStore.revisions(for: fixture.profile.id).count == 2)
    }

    @Test("Cancelling a queued transaction removes it without blocking the FIFO")
    func queuedTransactionCancellation() async throws {
        let barrier = TransactionValidationBarrier()
        let validator = TransactionValidatorFake(
            result: TransactionTestValues.validValidation,
            barrier: barrier
        )
        let fixture = try await makeTransactionFixture(
            active: false,
            activeData: Data("mode: direct\n".utf8),
            fileSystem: TransactionRecordingFileSystem(),
            validator: validator,
            api: TransactionAPIFake(),
            process: TransactionProcessFake(running: false)
        )
        defer { ConfigurationTestSupport.removeTemporaryDirectory(fixture.temporaryDirectory) }

        let first = Task {
            try await fixture.coordinator.apply(
                rawData: Data("mode: rule\nmarker: first\n".utf8),
                profileID: fixture.profile.id,
                sourceFileName: "first.yaml"
            )
        }
        #expect(await waitForValidationBarrier(barrier))
        let queued = Task {
            try await fixture.coordinator.apply(
                rawData: Data("mode: rule\nmarker: cancelled\n".utf8),
                profileID: fixture.profile.id,
                sourceFileName: "cancelled.yaml"
            )
        }
        await Task.yield()
        queued.cancel()

        do {
            _ = try await queued.value
            Issue.record("Expected the queued transaction to be cancelled")
        } catch is CancellationError {
            // Expected.
        }
        await barrier.release()
        _ = try await first.value

        #expect(validator.callCount() == 1)
        #expect(
            try await fixture.profileStore.readConfiguration(for: fixture.profile.id)
                == Data("mode: rule\nmarker: first\n".utf8)
        )
    }

    @MainActor
    @Test("Engine start waits for suspended validation and launches the committed revision")
    func engineStartWaitsForTransactionValidation() async throws {
        let barrier = TransactionValidationBarrier()
        let transactionValidator = TransactionValidatorFake(
            result: TransactionTestValues.validValidation,
            barrier: barrier
        )
        let process = TransactionProcessFake(running: false)
        let fixture = try await makeTransactionFixture(
            active: true,
            activeData: Data("mode: direct\n".utf8),
            fileSystem: TransactionRecordingFileSystem(),
            validator: transactionValidator,
            api: TransactionAPIFake(),
            process: process
        )
        defer { ConfigurationTestSupport.removeTemporaryDirectory(fixture.temporaryDirectory) }
        let engineStore = makeTransactionEngineStore(fixture)
        await engineStore.bootstrap()

        let update = Data("mode: rule\nmarker: committed-before-start\n".utf8)
        let transactionTask = Task {
            try await fixture.coordinator.apply(
                rawData: update,
                profileID: fixture.profile.id,
                sourceFileName: "remote.yaml"
            )
        }
        #expect(await waitForValidationBarrier(barrier))

        let startTask = Task { @MainActor in
            await engineStore.start()
        }
        await settleRuntimeMutationTasks()

        #expect(await process.startCallCount() == 0)
        #expect(!engineStore.isRunning)

        await barrier.release()
        _ = try await transactionTask.value
        await startTask.value

        #expect(await process.startCallCount() == 1)
        #expect(engineStore.isRunning)
        #expect(try await fixture.profileStore.readConfiguration(for: fixture.profile.id) == update)
        let active = try YAMLDocument(
            yaml: String(
                decoding: Data(contentsOf: fixture.directories.activeConfiguration),
                as: UTF8.self
            )
        )
        #expect(active["marker"] == .string("committed-before-start"))
        #expect(!FileManager.default.fileExists(
            atPath: fixture.directories.runtimeTransactionJournal.path
        ))
    }

    @MainActor
    @Test("Profile selection waits for an override-style transaction")
    func profileSelectionWaitsForOverrideTransaction() async throws {
        let barrier = TransactionValidationBarrier()
        let transactionValidator = TransactionValidatorFake(
            result: TransactionTestValues.validValidation,
            barrier: barrier
        )
        let process = TransactionProcessFake(running: false)
        let fixture = try await makeTransactionFixture(
            active: true,
            activeData: Data("mode: rule\nmarker: first\n".utf8),
            fileSystem: TransactionRecordingFileSystem(),
            validator: transactionValidator,
            api: TransactionAPIFake(),
            process: process
        )
        defer { ConfigurationTestSupport.removeTemporaryDirectory(fixture.temporaryDirectory) }
        let secondSource = try ConfigurationTestSupport.write(
            """
            mode: global
            marker: second
            proxies:
              - name: Fixture
                type: ss
                server: 192.0.2.2
                port: 8388
                cipher: aes-128-gcm
                password: fixture-password

            """,
            named: "second.yaml",
            in: fixture.temporaryDirectory
        )
        let secondProfile = try await fixture.profileStore.importProfile(from: secondSource)
        let engineStore = makeTransactionEngineStore(fixture)
        await engineStore.bootstrap()

        let transactionTask = Task {
            try await fixture.coordinator.apply(
                rawData: Data("mode: direct\nmarker: override-candidate\n".utf8),
                profileID: fixture.profile.id,
                sourceFileName: "structured-overrides.yaml",
                commitRawRevision: false
            )
        }
        #expect(await waitForValidationBarrier(barrier))

        let selectionTask = Task { @MainActor in
            await engineStore.selectProfile(id: secondProfile.id)
        }
        await settleRuntimeMutationTasks()

        #expect(engineStore.selectedProfileID == fixture.profile.id)
        #expect(try await fixture.profileStore.selectedProfileID() == fixture.profile.id)

        await barrier.release()
        _ = try await transactionTask.value
        await selectionTask.value

        #expect(engineStore.selectedProfileID == secondProfile.id)
        #expect(try await fixture.profileStore.selectedProfileID() == secondProfile.id)
        await engineStore.start()
        #expect(engineStore.isRunning)
        #expect(await process.startCallCount() == 1)
        let active = try YAMLDocument(
            yaml: String(
                decoding: Data(contentsOf: fixture.directories.activeConfiguration),
                as: UTF8.self
            )
        )
        #expect(active["marker"] == .string("second"))
        #expect(!FileManager.default.fileExists(
            atPath: fixture.directories.runtimeTransactionJournal.path
        ))
    }

    @MainActor
    @Test("Profile deletion waits for validation and leaves a startable fallback")
    func profileDeletionWaitsForTransactionValidation() async throws {
        let barrier = TransactionValidationBarrier()
        let transactionValidator = TransactionValidatorFake(
            result: TransactionTestValues.validValidation,
            barrier: barrier
        )
        let process = TransactionProcessFake(running: false)
        let fixture = try await makeTransactionFixture(
            active: true,
            activeData: Data("mode: rule\nmarker: first\n".utf8),
            fileSystem: TransactionRecordingFileSystem(),
            validator: transactionValidator,
            api: TransactionAPIFake(),
            process: process
        )
        defer { ConfigurationTestSupport.removeTemporaryDirectory(fixture.temporaryDirectory) }
        let fallbackSource = try ConfigurationTestSupport.write(
            """
            mode: global
            marker: fallback
            proxies:
              - name: Fixture
                type: ss
                server: 192.0.2.3
                port: 8388
                cipher: aes-128-gcm
                password: fixture-password

            """,
            named: "fallback.yaml",
            in: fixture.temporaryDirectory
        )
        let fallback = try await fixture.profileStore.importProfile(from: fallbackSource)
        let engineStore = makeTransactionEngineStore(fixture)
        await engineStore.bootstrap()

        let transactionTask = Task {
            try await fixture.coordinator.apply(
                rawData: Data("mode: direct\nmarker: committed-then-deleted\n".utf8),
                profileID: fixture.profile.id,
                sourceFileName: "remote.yaml"
            )
        }
        #expect(await waitForValidationBarrier(barrier))

        let deletionTask = Task { @MainActor in
            await engineStore.deleteProfile(id: fixture.profile.id)
        }
        await settleRuntimeMutationTasks()

        #expect(try await fixture.profileStore.profile(id: fixture.profile.id) != nil)
        #expect(engineStore.selectedProfileID == fixture.profile.id)

        await barrier.release()
        _ = try await transactionTask.value
        await deletionTask.value

        #expect(try await fixture.profileStore.profile(id: fixture.profile.id) == nil)
        #expect(engineStore.selectedProfileID == nil)
        #expect(try await fixture.profileStore.selectedProfileID() == nil)
        await engineStore.selectProfile(id: fallback.id)
        await engineStore.start()
        #expect(engineStore.isRunning)
        #expect(await process.startCallCount() == 1)
        let active = try YAMLDocument(
            yaml: String(
                decoding: Data(contentsOf: fixture.directories.activeConfiguration),
                as: UTF8.self
            )
        )
        #expect(active["marker"] == .string("fallback"))
        #expect(!FileManager.default.fileExists(
            atPath: fixture.directories.runtimeTransactionJournal.path
        ))
    }

    @Test("Active profile while Engine is stopped replaces active and commits without starting Engine")
    func activeStoppedSuccess() async throws {
        let fileSystem = TransactionRecordingFileSystem()
        let api = TransactionAPIFake()
        let process = TransactionProcessFake(running: false)
        let fixture = try await makeTransactionFixture(
            active: true,
            activeData: Data("mode: direct\n".utf8),
            fileSystem: fileSystem,
            api: api,
            process: process
        )
        defer { ConfigurationTestSupport.removeTemporaryDirectory(fixture.temporaryDirectory) }

        let update = Data("mode: rule\n".utf8)
        let result = try await fixture.coordinator.apply(
            rawData: update,
            profileID: fixture.profile.id,
            sourceFileName: "remote.yaml"
        )
        let active = try YAMLDocument(
            yaml: String(decoding: Data(contentsOf: fixture.directories.activeConfiguration), as: UTF8.self)
        )

        #expect(result.revision != nil)
        #expect(!result.hotReloaded)
        #expect(active["mode"] == .string("rule"))
        #expect(active["mixed-port"] == .integer(17_890))
        #expect(await api.reloadCallCount() == 0)
        #expect(await process.startCallCount() == 0)
    }

    @Test("Active running transaction waits for Controller and restores only valid selectors")
    func activeRunningDelayedControllerAndSelectorRestore() async throws {
        let fileSystem = TransactionRecordingFileSystem()
        let api = TransactionAPIFake(
            versionFailures: 2,
            proxyResponses: [
                TransactionTestValues.selectorSnapshot,
                TransactionTestValues.selectorCandidate,
                TransactionTestValues.selectorCandidate,
            ]
        )
        let process = TransactionProcessFake(running: true)
        let fixture = try await makeTransactionFixture(
            active: true,
            activeData: Data("mode: direct\n".utf8),
            fileSystem: fileSystem,
            api: api,
            process: process
        )
        defer { ConfigurationTestSupport.removeTemporaryDirectory(fixture.temporaryDirectory) }

        let result = try await fixture.coordinator.apply(
            rawData: Data("mode: rule\n".utf8),
            profileID: fixture.profile.id,
            sourceFileName: "remote.yaml"
        )

        #expect(result.hotReloaded)
        #expect(result.revision != nil)
        #expect(result.selectorRestore.restored == ["Keep": "Old"])
        #expect(result.selectorRestore.skipped == ["Removed": "Gone"])
        #expect(await api.selectionCalls() == [TransactionProxySelection(group: "Keep", proxy: "Old")])
        #expect(await api.versionCallCount() >= 3)
        #expect(await api.reloadCallCount() == 1)

        let expectedPhases: [RuntimeConfigTransactionJournal.Phase] = [
            .downloaded,
            .built,
            .validated,
            .activeReplaced,
            .controllerApplied,
            .healthVerified,
            .committed,
        ]
        #expect(fileSystem.journalPhases() == expectedPhases)
        #expect(fileSystem.permission(at: fixture.directories.runtimeTransactionJournal) == 0o600)
        #expect(
            fileSystem.permission(
                at: fixture.directories.profileStagingURL(transactionID: result.transactionID)
            ) == 0o600
        )
        #expect(
            fileSystem.permission(
                at: fixture.directories.runtimeCandidateURL(transactionID: result.transactionID)
            ) == 0o600
        )
        #expect(try posixPermissions(at: fixture.directories.activeConfiguration) == 0o600)
        #expect(try posixPermissions(at: fixture.directories.previousConfiguration) == 0o600)
        #expect(try posixPermissions(at: fixture.directories.runtime) == 0o700)
    }

    @Test("Invalid YAML fails before Mihomo validation")
    func invalidCandidateYAML() async throws {
        let validator = TransactionValidatorFake(result: TransactionTestValues.validValidation)
        let fixture = try await makeTransactionFixture(
            active: true,
            activeData: Data("mode: direct\n".utf8),
            fileSystem: TransactionRecordingFileSystem(),
            validator: validator,
            api: TransactionAPIFake(),
            process: TransactionProcessFake(running: false)
        )
        defer { ConfigurationTestSupport.removeTemporaryDirectory(fixture.temporaryDirectory) }

        let error = await capturedTransactionError {
            _ = try await fixture.coordinator.apply(
                rawData: Data("- not\n- a\n- mapping\n".utf8),
                profileID: fixture.profile.id,
                sourceFileName: "invalid.yaml"
            )
        }

        #expect(error == .runtimeBuildFailed)
        #expect(validator.callCount() == 0)
        #expect(try Data(contentsOf: fixture.directories.activeConfiguration) == Data("mode: direct\n".utf8))
    }

    @Test("Mihomo validator result is returned intact and nothing is committed")
    func validatorFailure() async throws {
        let invalid = TransactionTestValues.invalidValidation
        let validator = TransactionValidatorFake(result: invalid)
        let fixture = try await makeTransactionFixture(
            active: true,
            activeData: Data("mode: direct\n".utf8),
            fileSystem: TransactionRecordingFileSystem(),
            validator: validator,
            api: TransactionAPIFake(),
            process: TransactionProcessFake(running: true)
        )
        defer { ConfigurationTestSupport.removeTemporaryDirectory(fixture.temporaryDirectory) }

        let error = await capturedTransactionError {
            _ = try await fixture.coordinator.apply(
                rawData: Data("mode: rule\n".utf8),
                profileID: fixture.profile.id,
                sourceFileName: "invalid.yaml"
            )
        }

        #expect(error == .configurationValidationFailed(invalid))
        #expect(validator.callCount() == 1)
        #expect(try await fixture.profileStore.revisions(for: fixture.profile.id).isEmpty)
        #expect(try Data(contentsOf: fixture.directories.activeConfiguration) == Data("mode: direct\n".utf8))
        #expect(!FileManager.default.fileExists(atPath: fixture.directories.runtimeTransactionJournal.path))
    }

    @Test("Health verification failure rolls back and leaves the old revision selected")
    func healthFailureRollsBack() async throws {
        let api = TransactionAPIFake(reloadOutcomes: [true, true])
        let process = TransactionProcessFake(
            running: true,
            runningResponses: [true, false, true, true]
        )
        let activeBefore = Data("mode: direct\n".utf8)
        let fixture = try await makeTransactionFixture(
            active: true,
            activeData: activeBefore,
            fileSystem: TransactionRecordingFileSystem(),
            api: api,
            process: process
        )
        defer { ConfigurationTestSupport.removeTemporaryDirectory(fixture.temporaryDirectory) }

        let error = await capturedTransactionError {
            _ = try await fixture.coordinator.apply(
                rawData: Data("mode: rule\n".utf8),
                profileID: fixture.profile.id,
                sourceFileName: "remote.yaml"
            )
        }

        #expect(error == .healthVerificationFailed)
        #expect(try Data(contentsOf: fixture.directories.activeConfiguration) == activeBefore)
        #expect(try await fixture.profileStore.revisions(for: fixture.profile.id).isEmpty)
        #expect(await api.reloadCallCount() == 2)
        #expect(!FileManager.default.fileExists(atPath: fixture.directories.runtimeTransactionJournal.path))
    }

    @Test("Candidate reload failure restores previous config without restarting")
    func previousReloadSuccess() async throws {
        let api = TransactionAPIFake(reloadOutcomes: [false, true])
        let process = TransactionProcessFake(running: true)
        let fixture = try await makeTransactionFixture(
            active: true,
            activeData: Data("mode: direct\n".utf8),
            fileSystem: TransactionRecordingFileSystem(),
            api: api,
            process: process
        )
        defer { ConfigurationTestSupport.removeTemporaryDirectory(fixture.temporaryDirectory) }

        let error = await capturedTransactionError {
            _ = try await fixture.coordinator.apply(
                rawData: Data("mode: rule\n".utf8),
                profileID: fixture.profile.id,
                sourceFileName: "remote.yaml"
            )
        }

        #expect(error == .hotReloadFailed)
        #expect(try Data(contentsOf: fixture.directories.activeConfiguration) == Data("mode: direct\n".utf8))
        #expect(await api.reloadCallCount() == 2)
        #expect(await process.restartCallCount() == 0)
        #expect(!FileManager.default.fileExists(atPath: fixture.directories.runtimeTransactionJournal.path))
    }

    @Test("Previous reload failure performs exactly one controlled restart")
    func previousReloadFailureRestartsOnce() async throws {
        let api = TransactionAPIFake(reloadOutcomes: [false, false])
        let process = TransactionProcessFake(running: true)
        let fixture = try await makeTransactionFixture(
            active: true,
            activeData: Data("mode: direct\n".utf8),
            fileSystem: TransactionRecordingFileSystem(),
            api: api,
            process: process
        )
        defer { ConfigurationTestSupport.removeTemporaryDirectory(fixture.temporaryDirectory) }

        let error = await capturedTransactionError {
            _ = try await fixture.coordinator.apply(
                rawData: Data("mode: rule\n".utf8),
                profileID: fixture.profile.id,
                sourceFileName: "remote.yaml"
            )
        }

        #expect(error == .hotReloadFailed)
        #expect(await process.restartCallCount() == 1)
        #expect(try Data(contentsOf: fixture.directories.activeConfiguration) == Data("mode: direct\n".utf8))
        #expect(!FileManager.default.fileExists(atPath: fixture.directories.runtimeTransactionJournal.path))
    }

    @Test("Failed controlled restart returns rollbackFailed and retains rollingBack journal")
    func rollbackFailureRetainsJournal() async throws {
        let api = TransactionAPIFake(reloadOutcomes: [false, false])
        let process = TransactionProcessFake(running: true, restartFails: true)
        let fixture = try await makeTransactionFixture(
            active: true,
            activeData: Data("mode: direct\n".utf8),
            fileSystem: TransactionRecordingFileSystem(),
            api: api,
            process: process
        )
        defer { ConfigurationTestSupport.removeTemporaryDirectory(fixture.temporaryDirectory) }

        let error = await capturedTransactionError {
            _ = try await fixture.coordinator.apply(
                rawData: Data("mode: rule\n".utf8),
                profileID: fixture.profile.id,
                sourceFileName: "remote.yaml"
            )
        }

        #expect(error == .rollbackFailed)
        #expect(await process.restartCallCount() == 1)
        #expect(FileManager.default.fileExists(atPath: fixture.directories.runtimeTransactionJournal.path))
        let journal = try decodeJournal(at: fixture.directories.runtimeTransactionJournal)
        #expect(journal.phase == .rollingBack)
        #expect(try posixPermissions(at: fixture.directories.runtimeTransactionJournal) == 0o600)

        let retainedJournal = try Data(contentsOf: fixture.directories.runtimeTransactionJournal)
        let retryError = await capturedTransactionError {
            _ = try await fixture.coordinator.apply(
                rawData: Data("mode: global\n".utf8),
                profileID: fixture.profile.id,
                sourceFileName: "retry.yaml"
            )
        }
        #expect(retryError == .recoveryFailed)
        #expect(try Data(contentsOf: fixture.directories.runtimeTransactionJournal) == retainedJournal)
    }

    @Test("Recovery clears a rollback journal after its profile was deleted")
    func deletedProfileRollbackJournalDoesNotBlockNewTransactions() async throws {
        let previousRuntime = Data("mode: direct\nmarker: previous-runtime\n".utf8)
        let fixture = try await makeTransactionFixture(
            active: true,
            activeData: previousRuntime,
            fileSystem: TransactionRecordingFileSystem(),
            api: TransactionAPIFake(),
            process: TransactionProcessFake(running: false)
        )
        defer { ConfigurationTestSupport.removeTemporaryDirectory(fixture.temporaryDirectory) }

        let survivorSource = fixture.temporaryDirectory.appendingPathComponent("survivor.yaml")
        let survivorRaw = Data(
            """
            mode: rule
            marker: survivor
            proxies:
              - name: Survivor
                type: ss
                server: 192.0.2.10
                port: 8388
                cipher: aes-128-gcm
                password: fixture-password

            """.utf8
        )
        try survivorRaw.write(to: survivorSource)
        let survivor = try await fixture.profileStore.importProfile(
            from: survivorSource,
            name: "Survivor"
        )
        try await fixture.profileStore.selectProfile(id: survivor.id)
        try await fixture.profileStore.deleteProfile(id: fixture.profile.id)

        let transactionID = UUID()
        let interruptedRevisionID = UUID()
        let rawURL = fixture.directories.profileStagingURL(transactionID: transactionID)
        let previousRawURL = fixture.directories.profileRollbackURL(
            transactionID: transactionID
        )
        let candidateURL = fixture.directories.runtimeCandidateURL(
            transactionID: transactionID
        )
        let interruptedRaw = Data("mode: global\nmarker: interrupted\n".utf8)
        try writePrivate(interruptedRaw, to: rawURL)
        try writePrivate(previousRuntime, to: previousRawURL)
        try writePrivate(interruptedRaw, to: candidateURL)
        try writePrivate(previousRuntime, to: fixture.directories.previousConfiguration)
        try writeJournal(
            RuntimeConfigTransactionJournal(
                transactionID: transactionID,
                profileID: fixture.profile.id,
                phase: .rollingBack,
                candidateRawPath: rawURL.path,
                candidateRuntimePath: candidateURL.path,
                previousRuntimePath: fixture.directories.previousConfiguration.path,
                startedAt: .now,
                commitEvidence: .profileRevision(
                    rawData: interruptedRaw,
                    previousRevisionID: nil,
                    revisionID: interruptedRevisionID,
                    previousRawURL: previousRawURL
                )
            ),
            to: fixture.directories.runtimeTransactionJournal
        )

        try await fixture.coordinator.recoverIfNeeded()

        #expect(try Data(contentsOf: fixture.directories.activeConfiguration) == previousRuntime)
        #expect(
            !FileManager.default.fileExists(
                atPath: fixture.directories.runtimeTransactionJournal.path
            )
        )
        #expect(!FileManager.default.fileExists(atPath: rawURL.path))
        #expect(!FileManager.default.fileExists(atPath: previousRawURL.path))
        #expect(!FileManager.default.fileExists(atPath: candidateURL.path))

        let nextRaw = Data(
            """
            mode: direct
            marker: next-update
            proxies:
              - name: Updated Survivor
                type: ss
                server: 192.0.2.11
                port: 8388
                cipher: aes-128-gcm
                password: fixture-password

            """.utf8
        )
        _ = try await fixture.coordinator.apply(
            rawData: nextRaw,
            profileID: survivor.id,
            sourceFileName: "next.yaml"
        )

        #expect(try await fixture.profileStore.readConfiguration(for: survivor.id) == nextRaw)
        #expect(
            !FileManager.default.fileExists(
                atPath: fixture.directories.runtimeTransactionJournal.path
            )
        )
    }

    @Test("Stopped-engine crash window keeps active runtime when profile revision commit is durable")
    func stoppedProfileCommitEvidenceRecovery() async throws {
        let fileSystem = TransactionRecordingFileSystem()
        let fixture = try await makeTransactionFixture(
            active: true,
            activeData: Data("mode: direct\n".utf8),
            fileSystem: fileSystem,
            api: TransactionAPIFake(),
            process: TransactionProcessFake(running: false)
        )
        defer { ConfigurationTestSupport.removeTemporaryDirectory(fixture.temporaryDirectory) }
        let update = Data("mode: rule\nmarker: durable-profile\n".utf8)
        let previousRevisionID = try await fixture.profileStore.profile(
            id: fixture.profile.id
        )?.currentRevisionID
        let committedRevisionID = UUID()
        let transactionID = UUID()
        let rawURL = fixture.directories.profileStagingURL(transactionID: transactionID)
        let candidateURL = fixture.directories.runtimeCandidateURL(transactionID: transactionID)
        let previous = try Data(contentsOf: fixture.directories.activeConfiguration)
        let candidate = try RuntimeConfigBuilder().build(
            from: update,
            parameters: TransactionTestValues.runtimeParameters
        )
        try writePrivate(update, to: rawURL)
        try writePrivate(candidate, to: candidateURL)
        try writePrivate(previous, to: fixture.directories.previousConfiguration)
        try writePrivate(candidate, to: fixture.directories.activeConfiguration)
        try writeJournal(
            RuntimeConfigTransactionJournal(
                transactionID: transactionID,
                profileID: fixture.profile.id,
                phase: .activeReplaced,
                candidateRawPath: rawURL.path,
                candidateRuntimePath: candidateURL.path,
                previousRuntimePath: fixture.directories.previousConfiguration.path,
                startedAt: .now,
                commitEvidence: .profileRevision(
                    rawData: update,
                    previousRevisionID: previousRevisionID,
                    revisionID: committedRevisionID
                )
            ),
            to: fixture.directories.runtimeTransactionJournal
        )
        _ = try await fixture.profileStore.commitRawRevision(
            update,
            for: fixture.profile.id,
            sourceFileName: "durable-profile.yaml",
            revisionID: committedRevisionID
        )

        try await fixture.coordinator.recoverIfNeeded()

        #expect(try Data(contentsOf: fixture.directories.activeConfiguration) == candidate)
        #expect(try await fixture.profileStore.readConfiguration(for: fixture.profile.id) == update)
        #expect(
            !FileManager.default.fileExists(
                atPath: fixture.directories.runtimeTransactionJournal.path
            )
        )
    }

    @Test("Inactive validated crash restores profile raw when metadata did not commit")
    func inactivePartialProfileCommitRecovery() async throws {
        let fixture = try await makeTransactionFixture(
            active: false,
            activeData: nil,
            fileSystem: TransactionRecordingFileSystem(),
            api: TransactionAPIFake(),
            process: TransactionProcessFake(running: false)
        )
        defer { ConfigurationTestSupport.removeTemporaryDirectory(fixture.temporaryDirectory) }

        let previousRaw = try await fixture.profileStore.readConfiguration(for: fixture.profile.id)
        let previousRevision = try await fixture.profileStore.commitRawRevision(
            previousRaw,
            for: fixture.profile.id,
            sourceFileName: "previous-inactive.yaml"
        )
        let update = Data("mode: rule\nmarker: interrupted-inactive\n".utf8)
        let transactionID = UUID()
        let revisionID = UUID()
        let rawURL = fixture.directories.profileStagingURL(transactionID: transactionID)
        let previousRawURL = fixture.directories.profileRollbackURL(transactionID: transactionID)
        let candidateURL = fixture.directories.runtimeCandidateURL(transactionID: transactionID)
        let configurationURL = await fixture.profileStore.configurationURL(for: fixture.profile.id)
        let revisionURL = await fixture.profileStore.revisionURL(
            for: fixture.profile.id,
            revisionID: revisionID
        )
        try writePrivate(update, to: rawURL)
        try writePrivate(previousRaw, to: previousRawURL)
        try writePrivate(Data("candidate".utf8), to: candidateURL)
        // Simulate the two file writes in commitRawRevision succeeding before
        // the atomic metadata index write occurred.
        try writePrivate(update, to: configurationURL)
        try writePrivate(update, to: revisionURL)
        try writeJournal(
            RuntimeConfigTransactionJournal(
                transactionID: transactionID,
                profileID: fixture.profile.id,
                phase: .validated,
                candidateRawPath: rawURL.path,
                candidateRuntimePath: candidateURL.path,
                previousRuntimePath: nil,
                startedAt: .now,
                commitEvidence: .profileRevision(
                    rawData: update,
                    previousRevisionID: previousRevision.id,
                    revisionID: revisionID,
                    previousRawURL: previousRawURL
                )
            ),
            to: fixture.directories.runtimeTransactionJournal
        )

        try await fixture.coordinator.recoverIfNeeded()

        #expect(try await fixture.profileStore.readConfiguration(for: fixture.profile.id) == previousRaw)
        #expect(!FileManager.default.fileExists(atPath: revisionURL.path))
        #expect(try await fixture.profileStore.profile(id: fixture.profile.id)?.currentRevisionID == previousRevision.id)
        #expect(
            try await fixture.profileStore.revisions(for: fixture.profile.id).map(\.id)
                == [previousRevision.id]
        )
        #expect(!FileManager.default.fileExists(atPath: previousRawURL.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.directories.runtimeTransactionJournal.path))
    }

    @Test("Active health-verified crash restores profile raw and runtime when metadata did not commit")
    func activePartialProfileCommitRecovery() async throws {
        let previousRuntime = Data("mode: direct\nmarker: previous-runtime\n".utf8)
        let fixture = try await makeTransactionFixture(
            active: true,
            activeData: previousRuntime,
            fileSystem: TransactionRecordingFileSystem(),
            api: TransactionAPIFake(),
            process: TransactionProcessFake(running: false)
        )
        defer { ConfigurationTestSupport.removeTemporaryDirectory(fixture.temporaryDirectory) }

        let previousRaw = try await fixture.profileStore.readConfiguration(for: fixture.profile.id)
        let previousRevision = try await fixture.profileStore.commitRawRevision(
            previousRaw,
            for: fixture.profile.id,
            sourceFileName: "previous-active.yaml"
        )
        let update = Data("mode: rule\nmarker: interrupted-active\n".utf8)
        let candidateRuntime = Data("mode: rule\nmarker: candidate-runtime\n".utf8)
        let transactionID = UUID()
        let revisionID = UUID()
        let rawURL = fixture.directories.profileStagingURL(transactionID: transactionID)
        let previousRawURL = fixture.directories.profileRollbackURL(transactionID: transactionID)
        let candidateURL = fixture.directories.runtimeCandidateURL(transactionID: transactionID)
        let configurationURL = await fixture.profileStore.configurationURL(for: fixture.profile.id)
        let revisionURL = await fixture.profileStore.revisionURL(
            for: fixture.profile.id,
            revisionID: revisionID
        )
        try writePrivate(update, to: rawURL)
        try writePrivate(previousRaw, to: previousRawURL)
        try writePrivate(candidateRuntime, to: candidateURL)
        try writePrivate(previousRuntime, to: fixture.directories.previousConfiguration)
        try writePrivate(candidateRuntime, to: fixture.directories.activeConfiguration)
        try writePrivate(update, to: configurationURL)
        try writePrivate(update, to: revisionURL)
        try writeJournal(
            RuntimeConfigTransactionJournal(
                transactionID: transactionID,
                profileID: fixture.profile.id,
                phase: .healthVerified,
                candidateRawPath: rawURL.path,
                candidateRuntimePath: candidateURL.path,
                previousRuntimePath: fixture.directories.previousConfiguration.path,
                startedAt: .now,
                commitEvidence: .profileRevision(
                    rawData: update,
                    previousRevisionID: previousRevision.id,
                    revisionID: revisionID,
                    previousRawURL: previousRawURL
                )
            ),
            to: fixture.directories.runtimeTransactionJournal
        )

        try await fixture.coordinator.recoverIfNeeded()

        #expect(try await fixture.profileStore.readConfiguration(for: fixture.profile.id) == previousRaw)
        #expect(try Data(contentsOf: fixture.directories.activeConfiguration) == previousRuntime)
        #expect(!FileManager.default.fileExists(atPath: revisionURL.path))
        #expect(try await fixture.profileStore.profile(id: fixture.profile.id)?.currentRevisionID == previousRevision.id)
        #expect(
            try await fixture.profileStore.revisions(for: fixture.profile.id).map(\.id)
                == [previousRevision.id]
        )
        #expect(!FileManager.default.fileExists(atPath: previousRawURL.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.directories.runtimeTransactionJournal.path))
    }

    @Test("A ProfileStore rollback failure preserves evidence and next launch repairs raw and orphan revision")
    func profileStoreRollbackFailureRecoversOnNextLaunch() async throws {
        let fileSystem = TransactionRecordingFileSystem()
        let fixture = try await makeTransactionFixture(
            active: false,
            activeData: nil,
            fileSystem: fileSystem,
            api: TransactionAPIFake(),
            process: TransactionProcessFake(running: false)
        )
        defer { ConfigurationTestSupport.removeTemporaryDirectory(fixture.temporaryDirectory) }

        let previousRaw = try await fixture.profileStore.readConfiguration(for: fixture.profile.id)
        let previousRevision = try await fixture.profileStore.commitRawRevision(
            previousRaw,
            for: fixture.profile.id,
            sourceFileName: "previous.yaml"
        )
        let configurationURL = await fixture.profileStore.configurationURL(for: fixture.profile.id)
        let historyDirectory = await fixture.profileStore.historyDirectory(for: fixture.profile.id)

        // The metadata commit fails after the new raw and revision were written.
        // Its compensating raw restore and orphan removal then each fail once.
        fileSystem.configureWriteFailure(at: fixture.directories.profilesMetadata)
        fileSystem.configureWriteFailure(
            at: configurationURL,
            afterSuccessfulWrites: 1
        )
        fileSystem.configureNextRemovalFailure(in: historyDirectory)

        let update = Data("mode: rule\nmarker: interrupted-store-rollback\n".utf8)
        let error = await capturedTransactionError {
            _ = try await fixture.coordinator.apply(
                rawData: update,
                profileID: fixture.profile.id,
                sourceFileName: "interrupted.yaml"
            )
        }

        #expect(error == .rollbackFailed)
        #expect(FileManager.default.fileExists(atPath: fixture.directories.runtimeTransactionJournal.path))
        #expect(try posixPermissions(at: fixture.directories.runtimeTransactionJournal) == 0o600)
        #expect(try Data(contentsOf: configurationURL) == update)

        let journal = try decodeJournal(at: fixture.directories.runtimeTransactionJournal)
        #expect(journal.phase == .validated)
        #expect(journal.commitEvidence?.previousProfileRevisionID == previousRevision.id)
        let interruptedRevisionID = try #require(journal.commitEvidence?.profileRevisionID)
        let orphanRevisionURL = await fixture.profileStore.revisionURL(
            for: fixture.profile.id,
            revisionID: interruptedRevisionID
        )
        let previousRawPath = try #require(journal.commitEvidence?.previousProfileRawPath)
        #expect(FileManager.default.fileExists(atPath: orphanRevisionURL.path))
        #expect(FileManager.default.fileExists(atPath: previousRawPath))

        try await fixture.coordinator.recoverIfNeeded()
        try await fixture.coordinator.recoverIfNeeded()

        #expect(try await fixture.profileStore.readConfiguration(for: fixture.profile.id) == previousRaw)
        #expect(try await fixture.profileStore.profile(id: fixture.profile.id)?.currentRevisionID == previousRevision.id)
        #expect(
            try await fixture.profileStore.revisions(for: fixture.profile.id).map(\.id)
                == [previousRevision.id]
        )
        #expect(!FileManager.default.fileExists(atPath: orphanRevisionURL.path))
        #expect(!FileManager.default.fileExists(atPath: previousRawPath))
        #expect(!FileManager.default.fileExists(atPath: journal.candidateRawPath))
        #expect(!FileManager.default.fileExists(atPath: journal.candidateRuntimePath))
        #expect(!FileManager.default.fileExists(atPath: fixture.directories.runtimeTransactionJournal.path))
    }

    @Test("Running-engine crash window keeps active runtime when override commit is durable")
    func runningOverrideCommitEvidenceRecovery() async throws {
        let fileSystem = TransactionRecordingFileSystem()
        let fixture = try await makeTransactionFixture(
            active: true,
            activeData: Data("mode: direct\n".utf8),
            fileSystem: fileSystem,
            api: TransactionAPIFake(),
            process: TransactionProcessFake(running: true)
        )
        defer { ConfigurationTestSupport.removeTemporaryDirectory(fixture.temporaryDirectory) }
        let overrides = ProfileStructuredOverrides(
            dns: DNSOverrides(enable: .set(false))
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let overrideData = try encoder.encode(overrides)
        let rawData = try await fixture.profileStore.readConfiguration(for: fixture.profile.id)
        let upstream = try #require(String(data: rawData, encoding: .utf8))
        let finalYAML = try ConfigurationOverrideProcessor().process(
            upstreamYAML: upstream,
            overrides: overrides
        ).finalYAML
        let finalData = try #require(finalYAML.data(using: .utf8))
        let candidate = try RuntimeConfigBuilder().build(
            from: finalData,
            parameters: TransactionTestValues.runtimeParameters
        )
        let transactionID = UUID()
        let rawURL = fixture.directories.profileStagingURL(transactionID: transactionID)
        let candidateURL = fixture.directories.runtimeCandidateURL(transactionID: transactionID)
        let overrideURL = fixture.directories.overrideURL(for: fixture.profile.id)
        let overrideOperationID = UUID()
        let stagingURL = fixture.directories.overrideStagingURL(
            for: fixture.profile.id,
            operationID: overrideOperationID
        )
        let backupURL = fixture.directories.overrideRollbackURL(
            for: fixture.profile.id,
            operationID: overrideOperationID
        )
        let previous = try Data(contentsOf: fixture.directories.activeConfiguration)
        try writePrivate(finalData, to: rawURL)
        try writePrivate(candidate, to: candidateURL)
        try writePrivate(previous, to: fixture.directories.previousConfiguration)
        try writePrivate(candidate, to: fixture.directories.activeConfiguration)
        try writePrivate(overrideData, to: stagingURL)
        try writeJournal(
            RuntimeConfigTransactionJournal(
                transactionID: transactionID,
                profileID: fixture.profile.id,
                phase: .healthVerified,
                candidateRawPath: rawURL.path,
                candidateRuntimePath: candidateURL.path,
                previousRuntimePath: fixture.directories.previousConfiguration.path,
                startedAt: .now,
                commitEvidence: .configurationOverride(
                    data: overrideData,
                    artifactURL: overrideURL,
                    cleanupURL: stagingURL,
                    previousData: nil,
                    backupURL: backupURL
                )
            ),
            to: fixture.directories.runtimeTransactionJournal
        )
        try writePrivate(overrideData, to: overrideURL)

        try await fixture.coordinator.recoverIfNeeded()

        #expect(try Data(contentsOf: fixture.directories.activeConfiguration) == candidate)
        #expect(try JSONDecoder().decode(ProfileStructuredOverrides.self, from: Data(contentsOf: overrideURL)) == overrides)
        #expect(!FileManager.default.fileExists(atPath: stagingURL.path))
        #expect(
            !FileManager.default.fileExists(
                atPath: fixture.directories.runtimeTransactionJournal.path
            )
        )
    }

    @Test("Journal-free startup removes only transaction-shaped regular files inside Vela storage")
    func startupCleansOnlySafeStaleArtifacts() async throws {
        let fileSystem = TransactionRecordingFileSystem()
        let fixture = try await makeTransactionFixture(
            active: false,
            activeData: nil,
            fileSystem: fileSystem,
            api: TransactionAPIFake(),
            process: TransactionProcessFake(running: false)
        )
        defer { ConfigurationTestSupport.removeTemporaryDirectory(fixture.temporaryDirectory) }
        let originalProfileConfiguration = try await fixture.profileStore.readConfiguration(
            for: fixture.profile.id
        )

        let transactionID = UUID()
        let rawURL = fixture.directories.profileStagingURL(transactionID: transactionID)
        let previousRawURL = fixture.directories.profileRollbackURL(transactionID: transactionID)
        let runtimeURL = fixture.directories.runtimeCandidateURL(transactionID: transactionID)
        let overrideURL = fixture.directories.overrides.appendingPathComponent(
            ".\(fixture.profile.id.uuidString).\(transactionID.uuidString).staging.json"
        )
        for url in [rawURL, previousRawURL, runtimeURL, overrideURL] {
            try writePrivate(Data("stale".utf8), to: url)
        }

        let unrelatedProfileFile = fixture.directories.profileStaging.appendingPathComponent(
            "candidate.yaml"
        )
        let unrelatedRuntimeFile = fixture.directories.runtimeCandidates.appendingPathComponent(
            "\(transactionID.uuidString).previous.yaml"
        )
        let unrelatedOverrideFile = fixture.directories.overrides.appendingPathComponent(
            ".\(fixture.profile.id.uuidString).not-a-uuid.staging.json"
        )
        for url in [unrelatedProfileFile, unrelatedRuntimeFile, unrelatedOverrideFile] {
            try writePrivate(Data("keep".utf8), to: url)
        }

        let matchingDirectory = fixture.directories.profileStaging.appendingPathComponent(
            "\(UUID().uuidString).yaml",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: matchingDirectory,
            withIntermediateDirectories: false
        )
        try writePrivate(
            Data("keep nested".utf8),
            to: matchingDirectory.appendingPathComponent("sentinel")
        )

        let active = Data("mode: direct\nmarker: active\n".utf8)
        let previous = Data("mode: direct\nmarker: previous\n".utf8)
        try writePrivate(active, to: fixture.directories.activeConfiguration)
        try writePrivate(previous, to: fixture.directories.previousConfiguration)

        let outsideDirectory = fixture.temporaryDirectory.appendingPathComponent(
            "outside",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: outsideDirectory,
            withIntermediateDirectories: true
        )
        let outsideFile = outsideDirectory.appendingPathComponent(
            "\(UUID().uuidString).yaml"
        )
        try writePrivate(Data("outside".utf8), to: outsideFile)
        fileSystem.injectDirectoryEntry(
            outsideFile,
            whenListing: fixture.directories.profileStaging
        )

        for directory in [
            fixture.directories.profileStaging,
            fixture.directories.runtimeCandidates,
            fixture.directories.overrides,
        ] {
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o755)],
                ofItemAtPath: directory.path
            )
        }

        try await fixture.coordinator.recoverIfNeeded()

        for removed in [rawURL, previousRawURL, runtimeURL, overrideURL] {
            #expect(!FileManager.default.fileExists(atPath: removed.path))
        }
        for preserved in [
            unrelatedProfileFile,
            unrelatedRuntimeFile,
            unrelatedOverrideFile,
            matchingDirectory,
            outsideFile,
        ] {
            #expect(FileManager.default.fileExists(atPath: preserved.path))
        }
        #expect(try Data(contentsOf: fixture.directories.activeConfiguration) == active)
        #expect(try Data(contentsOf: fixture.directories.previousConfiguration) == previous)
        #expect(
            try await fixture.profileStore.readConfiguration(for: fixture.profile.id)
                == originalProfileConfiguration
        )
        #expect(try posixPermissions(at: fixture.directories.profileStaging) == 0o700)
        #expect(try posixPermissions(at: fixture.directories.runtimeCandidates) == 0o700)
        #expect(try posixPermissions(at: fixture.directories.overrides) == 0o700)
    }

    @Test("Recovery is phase-aware and idempotent for every journal phase")
    func recoveryAtEveryJournalPhase() async throws {
        for phase in RuntimeConfigTransactionJournal.Phase.allCases {
            let fileSystem = TransactionRecordingFileSystem()
            let fixture = try await makeTransactionFixture(
                active: true,
                activeData: nil,
                fileSystem: fileSystem,
                api: TransactionAPIFake(),
                process: TransactionProcessFake(running: false)
            )
            defer { ConfigurationTestSupport.removeTemporaryDirectory(fixture.temporaryDirectory) }

            let transactionID = UUID()
            let previous = Data("mode: direct\n".utf8)
            let candidate = Data("mode: rule\n".utf8)
            let replacedPhases: Set<RuntimeConfigTransactionJournal.Phase> = [
                .activeReplaced, .controllerApplied, .healthVerified, .rollingBack, .committed,
            ]
            try writePrivate(previous, to: fixture.directories.previousConfiguration)
            try writePrivate(
                replacedPhases.contains(phase) ? candidate : previous,
                to: fixture.directories.activeConfiguration
            )
            let stagedRaw = fixture.directories.profileStagingURL(transactionID: transactionID)
            let stagedRuntime = fixture.directories.runtimeCandidateURL(transactionID: transactionID)
            try writePrivate(Data("raw".utf8), to: stagedRaw)
            try writePrivate(candidate, to: stagedRuntime)
            let journal = RuntimeConfigTransactionJournal(
                transactionID: transactionID,
                profileID: fixture.profile.id,
                phase: phase,
                candidateRawPath: stagedRaw.path,
                candidateRuntimePath: stagedRuntime.path,
                previousRuntimePath: fixture.directories.previousConfiguration.path,
                startedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
            try writeJournal(journal, to: fixture.directories.runtimeTransactionJournal)

            try await fixture.coordinator.recoverIfNeeded()
            try await fixture.coordinator.recoverIfNeeded()

            let active = try Data(contentsOf: fixture.directories.activeConfiguration)
            let shouldKeepCandidate = phase == .committed
            #expect(active == (shouldKeepCandidate ? candidate : previous), "phase: \(phase)")
            #expect(!FileManager.default.fileExists(atPath: stagedRaw.path), "phase: \(phase)")
            #expect(!FileManager.default.fileExists(atPath: stagedRuntime.path), "phase: \(phase)")
            #expect(
                !FileManager.default.fileExists(atPath: fixture.directories.runtimeTransactionJournal.path),
                "phase: \(phase)"
            )
        }
    }

    @Test("Recovery rejects journal paths outside Vela storage")
    func rejectsUnsafeJournalPaths() async throws {
        let fixture = try await makeTransactionFixture(
            active: true,
            activeData: Data("mode: direct\n".utf8),
            fileSystem: TransactionRecordingFileSystem(),
            api: TransactionAPIFake(),
            process: TransactionProcessFake(running: false)
        )
        defer { ConfigurationTestSupport.removeTemporaryDirectory(fixture.temporaryDirectory) }
        let transactionID = UUID()
        let unreferencedStaleURL = fixture.directories.profileStagingURL(
            transactionID: UUID()
        )
        try writePrivate(Data("must remain while journal is unresolved".utf8), to: unreferencedStaleURL)
        let journal = RuntimeConfigTransactionJournal(
            transactionID: transactionID,
            profileID: fixture.profile.id,
            phase: .downloaded,
            candidateRawPath: "/tmp/not-vela.yaml",
            candidateRuntimePath: fixture.directories.runtimeCandidateURL(transactionID: transactionID).path,
            previousRuntimePath: nil,
            startedAt: .now
        )
        try writeJournal(journal, to: fixture.directories.runtimeTransactionJournal)

        let error = await capturedTransactionError {
            try await fixture.coordinator.recoverIfNeeded()
        }

        #expect(error == .journalCorrupt)
        #expect(FileManager.default.fileExists(atPath: fixture.directories.runtimeTransactionJournal.path))
        #expect(FileManager.default.fileExists(atPath: unreferencedStaleURL.path))
    }

    @Test("Subscription transaction applies persisted override but commits only original raw bytes")
    func subscriptionKeepsRawSeparateFromOverrides() async throws {
        let fixture = try await makeTransactionFixture(
            active: true,
            activeData: Data("mode: direct\n".utf8),
            fileSystem: TransactionRecordingFileSystem(),
            api: TransactionAPIFake(),
            process: TransactionProcessFake(running: false)
        )
        defer { ConfigurationTestSupport.removeTemporaryDirectory(fixture.temporaryDirectory) }
        let overrides = ProfileStructuredOverrides(
            dns: DNSOverrides(enable: .set(false))
        )
        let overrideData = try JSONEncoder().encode(overrides)
        try writePrivate(overrideData, to: fixture.directories.overrideURL(for: fixture.profile.id))
        let raw = Data("mode: rule\ndns:\n  enable: true\n  unknown: keep\n".utf8)

        let result = try await fixture.coordinator.apply(
            rawData: raw,
            profileID: fixture.profile.id,
            sourceFileName: "subscription.yaml"
        )

        let storedRaw = try await fixture.profileStore.readConfiguration(for: fixture.profile.id)
        let revisionData = try await fixture.profileStore.readRevision(
            profileID: fixture.profile.id,
            revisionID: try #require(result.revision?.id)
        )
        let active = try YAMLDocument(
            yaml: String(decoding: Data(contentsOf: fixture.directories.activeConfiguration), as: UTF8.self)
        )
        #expect(storedRaw == raw)
        #expect(revisionData == raw)
        #expect(try active.value(at: ["dns", "enable"]) == .bool(false))
        #expect(try active.value(at: ["dns", "unknown"]) == .string("keep"))
    }

    @Test("Post-commit revision pruning failure never rolls active back from committed raw")
    func revisionCleanupFailureRemainsCommitted() async throws {
        let fileSystem = TransactionRecordingFileSystem()
        let fixture = try await makeTransactionFixture(
            active: true,
            activeData: Data("mode: direct\n".utf8),
            fileSystem: fileSystem,
            api: TransactionAPIFake(),
            process: TransactionProcessFake(running: false)
        )
        defer { ConfigurationTestSupport.removeTemporaryDirectory(fixture.temporaryDirectory) }

        let first = try await fixture.profileStore.commitRawRevision(
            Data("mode: rule\nmarker: one\n".utf8),
            for: fixture.profile.id
        )
        _ = try await fixture.profileStore.commitRawRevision(
            Data("mode: rule\nmarker: two\n".utf8),
            for: fixture.profile.id
        )
        _ = try await fixture.profileStore.commitRawRevision(
            Data("mode: rule\nmarker: three\n".utf8),
            for: fixture.profile.id
        )
        let prunedURL = await fixture.profileStore.revisionURL(
            for: fixture.profile.id,
            revisionID: first.id
        )
        fileSystem.configureRemovalFailure(at: prunedURL)
        let fourth = Data("mode: rule\nmarker: four\n".utf8)

        let result = try await fixture.coordinator.apply(
            rawData: fourth,
            profileID: fixture.profile.id,
            sourceFileName: "four.yaml"
        )

        #expect(result.revision != nil)
        #expect(
            try await fixture.profileStore.readRevision(
                profileID: fixture.profile.id,
                revisionID: try #require(result.revision?.id)
            ) == fourth
        )
        #expect(try await fixture.profileStore.readConfiguration(for: fixture.profile.id) == fourth)
        #expect(try await fixture.profileStore.revisions(for: fixture.profile.id).count == 3)
        #expect(FileManager.default.fileExists(atPath: prunedURL.path))
        let active = try YAMLDocument(
            yaml: String(decoding: Data(contentsOf: fixture.directories.activeConfiguration), as: UTF8.self)
        )
        #expect(active["marker"] == .string("four"))
    }

    @Test("Startup scavenges an exact post-commit artifact after cleanup failure")
    func startupRecoversPostCommitCleanupResidue() async throws {
        let fileSystem = TransactionRecordingFileSystem()
        let fixture = try await makeTransactionFixture(
            active: true,
            activeData: Data("mode: direct\n".utf8),
            fileSystem: fileSystem,
            api: TransactionAPIFake(),
            process: TransactionProcessFake(running: false)
        )
        defer { ConfigurationTestSupport.removeTemporaryDirectory(fixture.temporaryDirectory) }
        fileSystem.configureNextRemovalFailure(in: fixture.directories.profileStaging)

        let result = try await fixture.coordinator.apply(
            rawData: Data("mode: rule\nmarker: committed\n".utf8),
            profileID: fixture.profile.id,
            sourceFileName: "committed.yaml"
        )
        let residue = fixture.directories.profileStagingURL(
            transactionID: result.transactionID
        )
        let nearMatch = fixture.directories.profileStaging
            .appendingPathComponent("not-a-transaction.yaml", isDirectory: false)
        try writePrivate(Data("keep".utf8), to: nearMatch)

        #expect(FileManager.default.fileExists(atPath: residue.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.directories.runtimeTransactionJournal.path))

        try await fixture.coordinator.recoverIfNeeded()

        #expect(!FileManager.default.fileExists(atPath: residue.path))
        #expect(FileManager.default.fileExists(atPath: nearMatch.path))
        #expect(
            try await fixture.profileStore.readConfiguration(for: fixture.profile.id)
                == Data("mode: rule\nmarker: committed\n".utf8)
        )
    }
}

struct TransactionTestFixture {
    let temporaryDirectory: URL
    let directories: ApplicationDirectories
    let profileStore: ProfileStore
    let profile: Profile
    let validator: TransactionValidatorFake
    let api: TransactionAPIFake
    let process: TransactionProcessFake
    let runtimeMutationGate: RuntimeMutationGate
    let coordinator: RuntimeConfigTransactionCoordinator
}

func makeTransactionFixture(
    active: Bool,
    activeData: Data?,
    fileSystem: TransactionRecordingFileSystem,
    validator: TransactionValidatorFake = TransactionValidatorFake(
        result: TransactionTestValues.validValidation
    ),
    api: TransactionAPIFake,
    process: TransactionProcessFake,
    runtimeMutationGate: RuntimeMutationGate = RuntimeMutationGate()
) async throws -> TransactionTestFixture {
    let temporaryDirectory = try ConfigurationTestSupport.makeTemporaryDirectory()
    let directories = ApplicationDirectories(
        root: temporaryDirectory.appendingPathComponent("store", isDirectory: true)
    )
    let source = try ConfigurationTestSupport.write(
        TransactionTestValues.baseRawYAML,
        named: "profile.yaml",
        in: temporaryDirectory
    )
    let profileStore = ProfileStore(directories: directories, fileSystem: fileSystem)
    let profile = try await profileStore.importProfile(from: source)
    if active {
        try await profileStore.selectProfile(id: profile.id)
    }
    try directories.prepare(fileSystem: fileSystem)
    if let activeData {
        try writePrivate(activeData, to: directories.activeConfiguration)
    }
    let coordinator = RuntimeConfigTransactionCoordinator(
        directories: directories,
        fileSystem: fileSystem,
        profileStore: profileStore,
        runtimeParameters: TransactionTestValues.runtimeParameters,
        configurationLayerStore: ConfigurationLayerStore(
            directories: directories,
            fileSystem: fileSystem
        ),
        executableResolver: TransactionExecutableResolverFake(),
        validator: validator,
        apiClient: api,
        processManager: process,
        runtimeMutationGate: runtimeMutationGate,
        // Keep the production retry cadence small while allowing the full,
        // highly parallel test target to survive scheduler contention.
        controllerRecoveryTimeout: .seconds(1),
        controllerPollInterval: .milliseconds(1),
        now: { Date(timeIntervalSince1970: 1_700_000_000) }
    )
    return TransactionTestFixture(
        temporaryDirectory: temporaryDirectory,
        directories: directories,
        profileStore: profileStore,
        profile: profile,
        validator: validator,
        api: api,
        process: process,
        runtimeMutationGate: runtimeMutationGate,
        coordinator: coordinator
    )
}

@MainActor
func makeTransactionEngineStore(_ fixture: TransactionTestFixture) -> EngineStore {
    EngineStore(
        profileStore: fixture.profileStore,
        runtimeParameters: TransactionTestValues.runtimeParameters,
        executableResolver: TransactionExecutableResolverFake(),
        configurationValidator: TransactionValidatorFake(
            result: TransactionTestValues.validValidation
        ),
        processManager: fixture.process,
        runtimeMutationGate: fixture.runtimeMutationGate,
        mihomoDataDirectoryURL: fixture.directories.mihomo
    )
}

func waitForValidationBarrier(_ barrier: TransactionValidationBarrier) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while clock.now < deadline {
        if await barrier.hasStarted() { return true }
        try? await clock.sleep(for: .milliseconds(1))
    }
    return await barrier.hasStarted()
}

@MainActor
func settleRuntimeMutationTasks() async {
    for _ in 0..<50 {
        await Task.yield()
    }
}

nonisolated enum TransactionTestValues {
    static let baseRawYAML = """
    mode: rule
    dns:
      enable: true
    proxies: []
    proxy-groups: []
    rules: []
    """

    static let runtimeParameters = RuntimeConfigParameters(
        externalController: "127.0.0.1:19090",
        secret: "transaction-test-secret",
        mixedPort: 17_890
    )

    static let validValidation = ConfigurationValidationResult(
        status: .valid,
        stdout: "configuration file is valid",
        stderr: "",
        issues: [],
        duration: .milliseconds(1)
    )

    static let invalidValidation = ConfigurationValidationResult(
        status: .invalid(exitCode: 1),
        stdout: "",
        stderr: "yaml: line 4: invalid field",
        issues: [
            ConfigurationValidationIssue(
                source: .stderr,
                message: "yaml: line 4: invalid field",
                lineNumber: 4
            )
        ],
        duration: .milliseconds(2)
    )

    static let configs = MihomoConfigs(
        port: 0,
        socksPort: 0,
        redirPort: 0,
        tproxyPort: 0,
        mixedPort: 17_890,
        allowLan: false,
        bindAddress: "127.0.0.1",
        mode: .rule,
        logLevel: "info",
        ipv6: false,
        unifiedDelay: false,
        tcpConcurrent: false,
        findProcessMode: "off",
        interfaceName: "",
        sniffing: false
    )

    static let emptyProxies = decodeProxies(#"{"proxies":{}}"#)
    static let selectorSnapshot = decodeProxies(
        #"{"proxies":{"Keep":{"name":"Keep","type":"Selector","now":"Old","all":["Old","New"]},"Removed":{"name":"Removed","type":"Selector","now":"Gone","all":["Gone","New"]}}}"#
    )
    static let selectorCandidate = decodeProxies(
        #"{"proxies":{"Keep":{"name":"Keep","type":"Selector","now":"New","all":["Old","New"]},"Removed":{"name":"Removed","type":"Selector","now":"New","all":["New"]}}}"#
    )

    private static func decodeProxies(_ json: String) -> MihomoProxiesResponse {
        do {
            return try JSONDecoder().decode(MihomoProxiesResponse.self, from: Data(json.utf8))
        } catch {
            preconditionFailure("Invalid transaction test proxy fixture: \(error)")
        }
    }
}

struct TransactionExecutableResolverFake: MihomoExecutableResolving {
    func resolve() async throws -> ResolvedMihomoExecutable {
        ResolvedMihomoExecutable(
            url: URL(fileURLWithPath: "/tmp/mihomo-transaction-test"),
            version: "v1.19.28",
            sha256: String(repeating: "a", count: 64)
        )
    }
}

final class TransactionValidatorFake: ConfigurationValidating, Sendable {
    private struct State: Sendable {
        var calls = 0
        var URLs: [URL] = []
    }

    private let result: ConfigurationValidationResult
    private let delay: Duration
    private let barrier: TransactionValidationBarrier?
    private let state = Mutex(State())

    init(
        result: ConfigurationValidationResult,
        delay: Duration = .zero,
        barrier: TransactionValidationBarrier? = nil
    ) {
        self.result = result
        self.delay = delay
        self.barrier = barrier
    }

    func validate(
        configurationURL: URL,
        using executable: ResolvedMihomoExecutable,
        timeout: Duration
    ) async -> ConfigurationValidationResult {
        state.withLock {
            $0.calls += 1
            $0.URLs.append(configurationURL)
        }
        if let barrier {
            await barrier.suspendValidation()
        } else if delay != .zero {
            try? await Task.sleep(for: delay)
        }
        return result
    }

    func callCount() -> Int {
        state.withLock { $0.calls }
    }

    func validatedURLs() -> [URL] {
        state.withLock { $0.URLs }
    }
}

actor TransactionValidationBarrier {
    private var started = false
    private var continuation: CheckedContinuation<Void, Never>?

    func suspendValidation() async {
        started = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func hasStarted() -> Bool { started }

    func release() {
        let continuation = continuation
        self.continuation = nil
        continuation?.resume()
    }
}

struct TransactionProxySelection: Equatable, Sendable {
    let group: String
    let proxy: String
}

actor TransactionAPIFake: MihomoAPIProviding {
    enum FakeError: Error {
        case expectedFailure
    }

    private var reloadOutcomes: [Bool]
    private var remainingVersionFailures: Int
    private var proxyResponses: [MihomoProxiesResponse]
    private var reloads: [URL] = []
    private var versionCalls = 0
    private var selections: [TransactionProxySelection] = []

    init(
        reloadOutcomes: [Bool] = [true],
        versionFailures: Int = 0,
        proxyResponses: [MihomoProxiesResponse] = [TransactionTestValues.emptyProxies]
    ) {
        self.reloadOutcomes = reloadOutcomes
        remainingVersionFailures = versionFailures
        self.proxyResponses = proxyResponses
    }

    func version() async throws -> MihomoVersion {
        versionCalls += 1
        if remainingVersionFailures > 0 {
            remainingVersionFailures -= 1
            throw FakeError.expectedFailure
        }
        return MihomoVersion(meta: true, version: "v1.19.28")
    }

    func configs() async throws -> MihomoConfigs { TransactionTestValues.configs }
    func patchConfigs(_ patch: MihomoConfigPatch) async throws {}

    func reloadConfiguration(at configurationURL: URL, force: Bool) async throws {
        reloads.append(configurationURL)
        let succeeds = reloadOutcomes.isEmpty ? true : reloadOutcomes.removeFirst()
        if !succeeds { throw FakeError.expectedFailure }
    }

    func proxies() async throws -> MihomoProxiesResponse {
        guard !proxyResponses.isEmpty else { return TransactionTestValues.emptyProxies }
        if proxyResponses.count == 1 { return proxyResponses[0] }
        return proxyResponses.removeFirst()
    }

    func proxyProviders() async throws -> MihomoProxyProvidersResponse { .empty }
    func ruleProviders() async throws -> MihomoRuleProvidersResponse { .empty }
    func rules() async throws -> MihomoRulesResponse { MihomoRulesResponse(rules: []) }

    func selectProxy(group: String, proxy: String) async throws {
        selections.append(TransactionProxySelection(group: group, proxy: proxy))
    }

    func reloadCallCount() -> Int { reloads.count }
    func versionCallCount() -> Int { versionCalls }
    func selectionCalls() -> [TransactionProxySelection] { selections }
}

actor TransactionProcessFake: MihomoProcessManaging {
    enum FakeError: Error {
        case restartFailed
    }

    private var running: Bool
    private var runningResponses: [Bool]
    private let restartFails: Bool
    private var restartCalls = 0
    private var startCalls = 0
    private var stopCalls = 0

    init(running: Bool, runningResponses: [Bool] = [], restartFails: Bool = false) {
        self.running = running
        self.runningResponses = runningResponses
        self.restartFails = restartFails
    }

    func start(
        configurationURL: URL,
        dataDirectoryURL: URL?,
        additionalArguments: [String],
        validationTimeout: Duration
    ) async throws -> MihomoProcessSnapshot {
        startCalls += 1
        running = true
        return runningSnapshot(configurationURL: configurationURL)
    }

    func stop(timeout: Duration) async throws -> MihomoProcessTermination? {
        stopCalls += 1
        running = false
        return nil
    }

    func restart(
        configurationURL: URL,
        dataDirectoryURL: URL?,
        additionalArguments: [String],
        validationTimeout: Duration,
        stopTimeout: Duration
    ) async throws -> MihomoProcessSnapshot {
        restartCalls += 1
        if restartFails { throw FakeError.restartFailed }
        running = true
        return runningSnapshot(configurationURL: configurationURL)
    }

    func isRunning() async -> Bool {
        if !runningResponses.isEmpty {
            running = runningResponses.removeFirst()
        }
        return running
    }

    func snapshot() async -> MihomoProcessSnapshot {
        running ? runningSnapshot(configurationURL: nil) : .stopped
    }

    func events() async -> AsyncStream<MihomoProcessEvent> {
        AsyncStream { continuation in continuation.finish() }
    }

    func restartCallCount() -> Int { restartCalls }
    func startCallCount() -> Int { startCalls }
    func stopCallCount() -> Int { stopCalls }

    private func runningSnapshot(configurationURL: URL?) -> MihomoProcessSnapshot {
        MihomoProcessSnapshot(
            pid: 42,
            isRunning: true,
            executable: nil,
            configurationURL: configurationURL,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }
}

final class TransactionRecordingFileSystem: FileSystemProviding, @unchecked Sendable {
    enum FakeError: Error {
        case expectedWriteFailure
    }

    private let live = LiveFileSystem()
    private let lock = NSLock()
    private var recordedJournalData: [Data] = []
    private var recordedPermissions: [String: Int] = [:]
    private var writeFailurePlans: [String: WriteFailurePlan] = [:]
    private var permissionFailures: [String: Int] = [:]
    private var removalFailures: [String: Int] = [:]
    private var removalDirectoryFailures: [String: Int] = [:]
    private var injectedDirectoryEntries: [String: [URL]] = [:]

    private struct WriteFailurePlan {
        var successfulWritesBeforeFailure: Int
        var remainingFailures: Int
    }

    func configureWriteFailure(
        at url: URL,
        count: Int = 1,
        afterSuccessfulWrites: Int = 0
    ) {
        lock.lock()
        writeFailurePlans[url.standardizedFileURL.path] = WriteFailurePlan(
            successfulWritesBeforeFailure: afterSuccessfulWrites,
            remainingFailures: count
        )
        lock.unlock()
    }

    func configureRemovalFailure(at url: URL, count: Int = 1) {
        lock.lock()
        removalFailures[url.standardizedFileURL.path] = count
        lock.unlock()
    }

    func configurePermissionFailure(at url: URL, count: Int = 1) {
        lock.lock()
        permissionFailures[url.standardizedFileURL.path] = count
        lock.unlock()
    }

    func configureNextRemovalFailure(in directory: URL, count: Int = 1) {
        lock.lock()
        removalDirectoryFailures[directory.standardizedFileURL.path] = count
        lock.unlock()
    }

    func injectDirectoryEntry(_ entry: URL, whenListing directory: URL) {
        lock.lock()
        injectedDirectoryEntries[directory.standardizedFileURL.path, default: []]
            .append(entry)
        lock.unlock()
    }

    func applicationSupportDirectory() -> URL? { live.applicationSupportDirectory() }
    func createDirectory(at url: URL) throws { try live.createDirectory(at: url) }
    func fileExists(at url: URL) -> Bool { live.fileExists(at: url) }
    func isRegularFile(at url: URL) -> Bool { live.isRegularFile(at: url) }

    func contentsOfDirectory(at url: URL) throws -> [URL] {
        let liveEntries = try live.contentsOfDirectory(at: url)
        lock.lock()
        let injected = injectedDirectoryEntries[url.standardizedFileURL.path] ?? []
        lock.unlock()
        return liveEntries + injected
    }

    func readData(at url: URL) throws -> Data { try live.readData(at: url) }

    func writeDataAtomically(_ data: Data, to url: URL) throws {
        lock.lock()
        let path = url.standardizedFileURL.path
        var shouldFail = false
        if var plan = writeFailurePlans[path] {
            if plan.successfulWritesBeforeFailure > 0 {
                plan.successfulWritesBeforeFailure -= 1
                writeFailurePlans[path] = plan
            } else if plan.remainingFailures > 0 {
                plan.remainingFailures -= 1
                shouldFail = true
                if plan.remainingFailures == 0 {
                    writeFailurePlans.removeValue(forKey: path)
                } else {
                    writeFailurePlans[path] = plan
                }
            }
        }
        if url.lastPathComponent == "transaction.json" {
            recordedJournalData.append(data)
        }
        lock.unlock()
        if shouldFail { throw FakeError.expectedWriteFailure }
        try live.writeDataAtomically(data, to: url)
    }

    func moveItem(at source: URL, to destination: URL) throws {
        try live.moveItem(at: source, to: destination)
    }

    func removeItem(at url: URL) throws {
        lock.lock()
        let path = url.standardizedFileURL.path
        let directoryPath = url.deletingLastPathComponent().standardizedFileURL.path
        var shouldFail = false
        if let remaining = removalFailures[path], remaining > 0 {
            shouldFail = true
            if remaining == 1 {
                removalFailures.removeValue(forKey: path)
            } else {
                removalFailures[path] = remaining - 1
            }
        } else if let remaining = removalDirectoryFailures[directoryPath], remaining > 0 {
            shouldFail = true
            if remaining == 1 {
                removalDirectoryFailures.removeValue(forKey: directoryPath)
            } else {
                removalDirectoryFailures[directoryPath] = remaining - 1
            }
        }
        lock.unlock()
        if shouldFail { throw FakeError.expectedWriteFailure }
        try live.removeItem(at: url)
    }

    func setPOSIXPermissions(_ permissions: Int, at url: URL) throws {
        lock.lock()
        let path = url.standardizedFileURL.path
        recordedPermissions[path] = permissions
        var shouldFail = false
        if let remaining = permissionFailures[path], remaining > 0 {
            shouldFail = true
            if remaining == 1 {
                permissionFailures.removeValue(forKey: path)
            } else {
                permissionFailures[path] = remaining - 1
            }
        }
        lock.unlock()
        if shouldFail { throw FakeError.expectedWriteFailure }
        try live.setPOSIXPermissions(permissions, at: url)
    }

    func journalPhases() -> [RuntimeConfigTransactionJournal.Phase] {
        lock.lock()
        let data = recordedJournalData
        lock.unlock()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return data.compactMap {
            try? decoder.decode(RuntimeConfigTransactionJournal.self, from: $0).phase
        }
    }

    func permission(at url: URL) -> Int? {
        lock.lock()
        let value = recordedPermissions[url.standardizedFileURL.path]
        lock.unlock()
        return value
    }

    func permissionsForPaths(withSuffix suffix: String) -> [Int] {
        lock.lock()
        let values = recordedPermissions
            .filter { $0.key.hasSuffix(suffix) }
            .map(\.value)
        lock.unlock()
        return values
    }
}

func capturedTransactionError(
    _ operation: () async throws -> Void
) async -> RuntimeConfigTransactionError? {
    do {
        try await operation()
        Issue.record("Expected transaction to fail")
        return nil
    } catch let error as RuntimeConfigTransactionError {
        return error
    } catch {
        Issue.record("Unexpected error: \(error)")
        return nil
    }
}

func writePrivate(_ data: Data, to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try data.write(to: url, options: .atomic)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o600)],
        ofItemAtPath: url.path
    )
}

func writeJournal(_ journal: RuntimeConfigTransactionJournal, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try writePrivate(encoder.encode(journal), to: url)
}

func decodeJournal(at url: URL) throws -> RuntimeConfigTransactionJournal {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(RuntimeConfigTransactionJournal.self, from: Data(contentsOf: url))
}

func posixPermissions(at url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
    return permissions.intValue & 0o777
}
