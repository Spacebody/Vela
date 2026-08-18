import Foundation
import Testing
@testable import Vela

@Suite("Configuration override store transactions")
struct ConfigurationOverrideStoreTests {
    @Test("Raw editor loads the imported source configuration")
    func rawEditorLoadsImportedSource() async throws {
        let fileSystem = TransactionRecordingFileSystem()
        let fixture = try await makeTransactionFixture(
            active: false,
            activeData: nil,
            fileSystem: fileSystem,
            api: TransactionAPIFake(),
            process: TransactionProcessFake(running: false)
        )
        defer { ConfigurationTestSupport.removeTemporaryDirectory(fixture.temporaryDirectory) }
        let store = ConfigurationOverrideStore(
            profileStore: fixture.profileStore,
            directories: fixture.directories,
            fileSystem: fileSystem,
            transactionCoordinator: fixture.coordinator
        )

        let yaml = try await store.rawConfiguration(for: fixture.profile.id)

        #expect(
            yaml.trimmingCharacters(in: .whitespacesAndNewlines)
                == TransactionTestValues.baseRawYAML
        )
    }

    @Test("Raw editor commits a revision and keeps persisted overrides in the active runtime")
    func rawEditorCommitsRevisionWithOverrides() async throws {
        let fileSystem = TransactionRecordingFileSystem()
        let fixture = try await makeTransactionFixture(
            active: true,
            activeData: Data(TransactionTestValues.baseRawYAML.utf8),
            fileSystem: fileSystem,
            api: TransactionAPIFake(),
            process: TransactionProcessFake(running: false)
        )
        defer { ConfigurationTestSupport.removeTemporaryDirectory(fixture.temporaryDirectory) }
        let store = ConfigurationOverrideStore(
            profileStore: fixture.profileStore,
            directories: fixture.directories,
            fileSystem: fileSystem,
            transactionCoordinator: fixture.coordinator
        )
        _ = try await store.save(
            ProfileStructuredOverrides(dns: DNSOverrides(enable: .set(false))),
            for: fixture.profile.id,
            forcedFields: []
        )
        let editedYAML = TransactionTestValues.baseRawYAML + "\nmarker: raw-editor\n"

        let result = try await store.saveRawConfiguration(
            editedYAML,
            for: fixture.profile.id,
            sourceFileName: fixture.profile.originalFileName
        )

        #expect(result.revision != nil)
        #expect(
            try await fixture.profileStore.readConfiguration(for: fixture.profile.id)
                == Data(editedYAML.utf8)
        )
        #expect(try await fixture.profileStore.revisions(for: fixture.profile.id).count == 1)
        let active = try YAMLDocument(
            yaml: String(
                decoding: Data(contentsOf: fixture.directories.activeConfiguration),
                as: UTF8.self
            )
        )
        #expect(active["marker"] == .string("raw-editor"))
        #expect(try active.value(at: ["dns", "enable"]) == .bool(false))
    }

    @Test("Raw editor surfaces validator errors without committing a revision")
    func rawEditorValidationFailureDoesNotCommit() async throws {
        let fileSystem = TransactionRecordingFileSystem()
        let fixture = try await makeTransactionFixture(
            active: true,
            activeData: Data(TransactionTestValues.baseRawYAML.utf8),
            fileSystem: fileSystem,
            validator: TransactionValidatorFake(result: TransactionTestValues.invalidValidation),
            api: TransactionAPIFake(),
            process: TransactionProcessFake(running: false)
        )
        defer { ConfigurationTestSupport.removeTemporaryDirectory(fixture.temporaryDirectory) }
        let store = ConfigurationOverrideStore(
            profileStore: fixture.profileStore,
            directories: fixture.directories,
            fileSystem: fileSystem,
            transactionCoordinator: fixture.coordinator
        )
        let rawBefore = try await fixture.profileStore.readConfiguration(for: fixture.profile.id)

        let error = await capturedOverrideStoreError {
            _ = try await store.saveRawConfiguration(
                TransactionTestValues.baseRawYAML + "\nmarker: rejected-by-validator\n",
                for: fixture.profile.id,
                sourceFileName: fixture.profile.originalFileName
            )
        }

        #expect(error == .runtimeValidationFailed(TransactionTestValues.invalidValidation))
        #expect(try await fixture.profileStore.readConfiguration(for: fixture.profile.id) == rawBefore)
        #expect(try await fixture.profileStore.revisions(for: fixture.profile.id).isEmpty)
    }

    @Test("Save validates, hot reloads, then persists 0600 override without changing raw revision")
    func activeSaveSuccess() async throws {
        let fileSystem = TransactionRecordingFileSystem()
        let api = TransactionAPIFake()
        let fixture = try await makeTransactionFixture(
            active: true,
            activeData: Data("mode: direct\n".utf8),
            fileSystem: fileSystem,
            api: api,
            process: TransactionProcessFake(running: true)
        )
        defer { ConfigurationTestSupport.removeTemporaryDirectory(fixture.temporaryDirectory) }
        let store = ConfigurationOverrideStore(
            profileStore: fixture.profileStore,
            directories: fixture.directories,
            fileSystem: fileSystem,
            transactionCoordinator: fixture.coordinator
        )
        let rawBefore = try await fixture.profileStore.readConfiguration(for: fixture.profile.id)
        let overrides = ProfileStructuredOverrides(
            dns: DNSOverrides(enable: .set(false))
        )

        let result = try await store.save(
            overrides,
            for: fixture.profile.id,
            forcedFields: []
        )

        let overrideURL = fixture.directories.overrideURL(for: fixture.profile.id)
        let persisted = try await store.load(for: fixture.profile.id)
        let rawAfter = try await fixture.profileStore.readConfiguration(for: fixture.profile.id)
        let active = try YAMLDocument(
            yaml: String(decoding: Data(contentsOf: fixture.directories.activeConfiguration), as: UTF8.self)
        )
        #expect(persisted == result.normalizedOverrides)
        #expect(rawAfter == rawBefore)
        #expect(try await fixture.profileStore.revisions(for: fixture.profile.id).isEmpty)
        #expect(try active.value(at: ["dns", "enable"]) == .bool(false))
        #expect(await api.reloadCallCount() == 1)
        #expect(fixture.validator.callCount() == 1)
        #expect(try posixPermissions(at: overrideURL) == 0o600)
        #expect(fileSystem.permission(at: overrideURL) == 0o600)
        #expect(fileSystem.permissionsForPaths(withSuffix: ".staging.json") == [0o600])
        #expect(try posixPermissions(at: fixture.directories.overrides) == 0o700)
        #expect(try stagingOverrideFiles(in: fixture.directories.overrides).isEmpty)
    }

    @Test("Inactive Save validates and persists without touching active runtime or Controller")
    func inactiveSaveSuccess() async throws {
        let fileSystem = TransactionRecordingFileSystem()
        let api = TransactionAPIFake()
        let activeBefore = Data("mode: direct\n".utf8)
        let fixture = try await makeTransactionFixture(
            active: false,
            activeData: activeBefore,
            fileSystem: fileSystem,
            api: api,
            process: TransactionProcessFake(running: true)
        )
        defer { ConfigurationTestSupport.removeTemporaryDirectory(fixture.temporaryDirectory) }
        let store = ConfigurationOverrideStore(
            profileStore: fixture.profileStore,
            directories: fixture.directories,
            fileSystem: fileSystem,
            transactionCoordinator: fixture.coordinator
        )

        _ = try await store.save(
            ProfileStructuredOverrides(dns: DNSOverrides(ipv6: .set(false))),
            for: fixture.profile.id,
            forcedFields: []
        )

        #expect(await api.reloadCallCount() == 0)
        #expect(try Data(contentsOf: fixture.directories.activeConfiguration) == activeBefore)
        #expect(
            try await store.load(for: fixture.profile.id).dns.ipv6
                == OverrideValue<Bool>.set(false)
        )
        #expect(try await fixture.profileStore.revisions(for: fixture.profile.id).isEmpty)
    }

    @Test("Validator failure leaves previous override, raw, and active runtime unchanged")
    func validationFailureDoesNotPersist() async throws {
        let fileSystem = TransactionRecordingFileSystem()
        let validator = TransactionValidatorFake(result: TransactionTestValues.invalidValidation)
        let activeBefore = Data("mode: direct\n".utf8)
        let fixture = try await makeTransactionFixture(
            active: true,
            activeData: activeBefore,
            fileSystem: fileSystem,
            validator: validator,
            api: TransactionAPIFake(),
            process: TransactionProcessFake(running: true)
        )
        defer { ConfigurationTestSupport.removeTemporaryDirectory(fixture.temporaryDirectory) }
        let overrideURL = fixture.directories.overrideURL(for: fixture.profile.id)
        let previous = ProfileStructuredOverrides(
            dns: DNSOverrides(enable: .set(true))
        )
        let previousData = try JSONEncoder().encode(previous)
        try writePrivate(previousData, to: overrideURL)
        let rawBefore = try await fixture.profileStore.readConfiguration(for: fixture.profile.id)
        let store = ConfigurationOverrideStore(
            profileStore: fixture.profileStore,
            directories: fixture.directories,
            fileSystem: fileSystem,
            transactionCoordinator: fixture.coordinator
        )

        let error = await capturedOverrideStoreError {
            _ = try await store.save(
                ProfileStructuredOverrides(dns: DNSOverrides(enable: .set(false))),
                for: fixture.profile.id,
                forcedFields: []
            )
        }

        #expect(error == .writeFailed)
        #expect(try Data(contentsOf: overrideURL) == previousData)
        #expect(try await fixture.profileStore.readConfiguration(for: fixture.profile.id) == rawBefore)
        #expect(try Data(contentsOf: fixture.directories.activeConfiguration) == activeBefore)
        #expect(try stagingOverrideFiles(in: fixture.directories.overrides).isEmpty)
    }

    @Test("Hot reload failure rolls active runtime back and does not persist draft override")
    func activeApplyRollback() async throws {
        let fileSystem = TransactionRecordingFileSystem()
        let api = TransactionAPIFake(reloadOutcomes: [false, true])
        let activeBefore = Data("mode: direct\n".utf8)
        let fixture = try await makeTransactionFixture(
            active: true,
            activeData: activeBefore,
            fileSystem: fileSystem,
            api: api,
            process: TransactionProcessFake(running: true)
        )
        defer { ConfigurationTestSupport.removeTemporaryDirectory(fixture.temporaryDirectory) }
        let overrideURL = fixture.directories.overrideURL(for: fixture.profile.id)
        let previous = ProfileStructuredOverrides(
            dns: DNSOverrides(enable: .set(true))
        )
        let previousData = try JSONEncoder().encode(previous)
        try writePrivate(previousData, to: overrideURL)
        let store = ConfigurationOverrideStore(
            profileStore: fixture.profileStore,
            directories: fixture.directories,
            fileSystem: fileSystem,
            transactionCoordinator: fixture.coordinator
        )

        let error = await capturedOverrideStoreError {
            _ = try await store.save(
                ProfileStructuredOverrides(dns: DNSOverrides(enable: .set(false))),
                for: fixture.profile.id,
                forcedFields: []
            )
        }

        #expect(error == .writeFailed)
        #expect(try Data(contentsOf: fixture.directories.activeConfiguration) == activeBefore)
        #expect(try Data(contentsOf: overrideURL) == previousData)
        #expect(await api.reloadCallCount() == 2)
        #expect(!FileManager.default.fileExists(atPath: fixture.directories.runtimeTransactionJournal.path))
        #expect(try stagingOverrideFiles(in: fixture.directories.overrides).isEmpty)
    }

    @Test("Official override write failure rolls back already-applied runtime")
    func officialWriteFailureRollsBackRuntime() async throws {
        let fileSystem = TransactionRecordingFileSystem()
        let api = TransactionAPIFake(reloadOutcomes: [true, true])
        let activeBefore = Data("mode: direct\n".utf8)
        let fixture = try await makeTransactionFixture(
            active: true,
            activeData: activeBefore,
            fileSystem: fileSystem,
            api: api,
            process: TransactionProcessFake(running: true)
        )
        defer { ConfigurationTestSupport.removeTemporaryDirectory(fixture.temporaryDirectory) }
        let overrideURL = fixture.directories.overrideURL(for: fixture.profile.id)
        let previous = ProfileStructuredOverrides(
            dns: DNSOverrides(enable: .set(true))
        )
        let previousData = try JSONEncoder().encode(previous)
        try writePrivate(previousData, to: overrideURL)
        fileSystem.configureWriteFailure(at: overrideURL)
        let store = ConfigurationOverrideStore(
            profileStore: fixture.profileStore,
            directories: fixture.directories,
            fileSystem: fileSystem,
            transactionCoordinator: fixture.coordinator
        )

        let error = await capturedOverrideStoreError {
            _ = try await store.save(
                ProfileStructuredOverrides(dns: DNSOverrides(enable: .set(false))),
                for: fixture.profile.id,
                forcedFields: []
            )
        }

        #expect(error == .writeFailed)
        #expect(try Data(contentsOf: overrideURL) == previousData)
        #expect(try Data(contentsOf: fixture.directories.activeConfiguration) == activeBefore)
        #expect(await api.reloadCallCount() == 2)
        #expect(!FileManager.default.fileExists(atPath: fixture.directories.runtimeTransactionJournal.path))
        #expect(try stagingOverrideFiles(in: fixture.directories.overrides).isEmpty)
    }

    @Test("Startup recovery restores the previous override after chmod and compensation fail")
    func recoveryRestoresExistingOverrideAfterPartialCommit() async throws {
        let fileSystem = TransactionRecordingFileSystem()
        let activeBefore = Data("mode: direct\nmarker: previous-runtime\n".utf8)
        let fixture = try await makeTransactionFixture(
            active: true,
            activeData: activeBefore,
            fileSystem: fileSystem,
            api: TransactionAPIFake(),
            process: TransactionProcessFake(running: false)
        )
        defer { ConfigurationTestSupport.removeTemporaryDirectory(fixture.temporaryDirectory) }

        let overrideURL = fixture.directories.overrideURL(for: fixture.profile.id)
        let previous = ProfileStructuredOverrides(
            dns: DNSOverrides(enable: .set(true))
        )
        let previousData = try JSONEncoder().encode(previous)
        try writePrivate(previousData, to: overrideURL)
        // Candidate atomic replacement succeeds, chmod fails, then the
        // compensating write of the backup fails once.
        fileSystem.configurePermissionFailure(at: overrideURL)
        fileSystem.configureWriteFailure(at: overrideURL, afterSuccessfulWrites: 1)
        let store = ConfigurationOverrideStore(
            profileStore: fixture.profileStore,
            directories: fixture.directories,
            fileSystem: fileSystem,
            transactionCoordinator: fixture.coordinator
        )

        let error = await capturedOverrideStoreError {
            _ = try await store.save(
                ProfileStructuredOverrides(dns: DNSOverrides(enable: .set(false))),
                for: fixture.profile.id,
                forcedFields: []
            )
        }

        #expect(error == .writeFailed)
        let journal = try decodeJournal(at: fixture.directories.runtimeTransactionJournal)
        #expect(journal.phase == .rollingBack)
        let evidence = try #require(journal.commitEvidence)
        #expect(evidence.previousOverrideExisted == true)
        let backupPath = try #require(evidence.previousOverrideBackupPath)
        #expect(try Data(contentsOf: URL(fileURLWithPath: backupPath)) == previousData)
        #expect(try posixPermissions(at: URL(fileURLWithPath: backupPath)) == 0o600)
        #expect(try Data(contentsOf: overrideURL) != previousData)

        try await fixture.coordinator.recoverIfNeeded()
        try await fixture.coordinator.recoverIfNeeded()

        #expect(try Data(contentsOf: overrideURL) == previousData)
        #expect(try posixPermissions(at: overrideURL) == 0o600)
        #expect(try Data(contentsOf: fixture.directories.activeConfiguration) == activeBefore)
        #expect(!FileManager.default.fileExists(atPath: backupPath))
        #expect(!FileManager.default.fileExists(atPath: fixture.directories.runtimeTransactionJournal.path))
        #expect(try overrideTransactionFiles(in: fixture.directories.overrides).isEmpty)
    }

    @Test("Startup recovery removes a partially committed override that did not exist before")
    func recoveryRemovesNewOverrideAfterPartialCommit() async throws {
        let fileSystem = TransactionRecordingFileSystem()
        let activeBefore = Data("mode: direct\nmarker: previous-runtime\n".utf8)
        let fixture = try await makeTransactionFixture(
            active: true,
            activeData: activeBefore,
            fileSystem: fileSystem,
            api: TransactionAPIFake(),
            process: TransactionProcessFake(running: false)
        )
        defer { ConfigurationTestSupport.removeTemporaryDirectory(fixture.temporaryDirectory) }

        let overrideURL = fixture.directories.overrideURL(for: fixture.profile.id)
        fileSystem.configurePermissionFailure(at: overrideURL)
        fileSystem.configureRemovalFailure(at: overrideURL)
        let store = ConfigurationOverrideStore(
            profileStore: fixture.profileStore,
            directories: fixture.directories,
            fileSystem: fileSystem,
            transactionCoordinator: fixture.coordinator
        )

        let error = await capturedOverrideStoreError {
            _ = try await store.save(
                ProfileStructuredOverrides(dns: DNSOverrides(enable: .set(false))),
                for: fixture.profile.id,
                forcedFields: []
            )
        }

        #expect(error == .writeFailed)
        let journal = try decodeJournal(at: fixture.directories.runtimeTransactionJournal)
        #expect(journal.phase == .rollingBack)
        #expect(journal.commitEvidence?.previousOverrideExisted == false)
        #expect(FileManager.default.fileExists(atPath: overrideURL.path))

        try await fixture.coordinator.recoverIfNeeded()
        try await fixture.coordinator.recoverIfNeeded()

        #expect(!FileManager.default.fileExists(atPath: overrideURL.path))
        #expect(try Data(contentsOf: fixture.directories.activeConfiguration) == activeBefore)
        #expect(!FileManager.default.fileExists(atPath: fixture.directories.runtimeTransactionJournal.path))
        #expect(try overrideTransactionFiles(in: fixture.directories.overrides).isEmpty)
    }

    @Test("Save without a transaction coordinator never persists")
    func saveRequiresTransactionCoordinator() async throws {
        let fileSystem = TransactionRecordingFileSystem()
        let fixture = try await makeTransactionFixture(
            active: true,
            activeData: Data("mode: direct\n".utf8),
            fileSystem: fileSystem,
            api: TransactionAPIFake(),
            process: TransactionProcessFake(running: false)
        )
        defer { ConfigurationTestSupport.removeTemporaryDirectory(fixture.temporaryDirectory) }
        let store = ConfigurationOverrideStore(
            profileStore: fixture.profileStore,
            directories: fixture.directories,
            fileSystem: fileSystem
        )

        let error = await capturedOverrideStoreError {
            _ = try await store.save(
                ProfileStructuredOverrides(dns: DNSOverrides(enable: .set(false))),
                for: fixture.profile.id,
                forcedFields: []
            )
        }

        #expect(error == .writeFailed)
        #expect(
            !FileManager.default.fileExists(
                atPath: fixture.directories.overrideURL(for: fixture.profile.id).path
            )
        )
    }
}

private func capturedOverrideStoreError(
    _ operation: () async throws -> Void
) async -> ConfigurationOverrideStoreError? {
    do {
        try await operation()
        Issue.record("Expected override Save to fail")
        return nil
    } catch let error as ConfigurationOverrideStoreError {
        return error
    } catch {
        Issue.record("Unexpected error: \(error)")
        return nil
    }
}

private func stagingOverrideFiles(in directory: URL) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil
    ).filter { $0.lastPathComponent.hasSuffix(".staging.json") }
}

private func overrideTransactionFiles(in directory: URL) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil
    ).filter {
        $0.lastPathComponent.hasSuffix(".staging.json")
            || $0.lastPathComponent.hasSuffix(".previous.json")
    }
}
