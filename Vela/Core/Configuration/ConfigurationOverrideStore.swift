import Foundation

nonisolated enum ConfigurationOverrideStoreError: Error, Equatable, Sendable {
    case profileNotFound
    case configurationIsNotUTF8
    case configurationIsEmpty
    case readFailed
    case decodeFailed
    case validationFailed([ConfigurationOverrideValidationIssue])
    case runtimeValidationFailed(ConfigurationValidationResult)
    case writeFailed
}

actor ConfigurationOverrideStore {
    private let profileStore: ProfileStore
    private let directories: ApplicationDirectories
    private let fileSystem: any FileSystemProviding
    private let processor: ConfigurationOverrideProcessor
    private let transactionCoordinator: RuntimeConfigTransactionCoordinator?

    init(
        profileStore: ProfileStore,
        directories: ApplicationDirectories,
        fileSystem: any FileSystemProviding = LiveFileSystem(),
        processor: ConfigurationOverrideProcessor = ConfigurationOverrideProcessor(),
        transactionCoordinator: RuntimeConfigTransactionCoordinator? = nil
    ) {
        self.profileStore = profileStore
        self.directories = directories
        self.fileSystem = fileSystem
        self.processor = processor
        self.transactionCoordinator = transactionCoordinator
    }

    func load(for profileID: UUID) throws -> ProfileStructuredOverrides {
        do {
            try directories.prepare(fileSystem: fileSystem)
            let url = directories.overrideURL(for: profileID)
            guard fileSystem.fileExists(at: url) else {
                return ProfileStructuredOverrides()
            }
            let data = try fileSystem.readData(at: url)
            return try JSONDecoder().decode(ProfileStructuredOverrides.self, from: data)
        } catch is DecodingError {
            throw ConfigurationOverrideStoreError.decodeFailed
        } catch {
            throw ConfigurationOverrideStoreError.readFailed
        }
    }

    func rawConfiguration(for profileID: UUID) async throws -> String {
        let source: Data
        do {
            source = try await profileStore.readConfiguration(for: profileID)
        } catch {
            throw ConfigurationOverrideStoreError.profileNotFound
        }
        guard let yaml = String(data: source, encoding: .utf8) else {
            throw ConfigurationOverrideStoreError.configurationIsNotUTF8
        }
        return yaml
    }

    @discardableResult
    func saveRawConfiguration(
        _ yaml: String,
        for profileID: UUID,
        sourceFileName: String
    ) async throws -> RuntimeConfigTransactionResult {
        guard !yaml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConfigurationOverrideStoreError.configurationIsEmpty
        }
        guard let data = yaml.data(using: .utf8) else {
            throw ConfigurationOverrideStoreError.configurationIsNotUTF8
        }
        guard let transactionCoordinator else {
            throw ConfigurationOverrideStoreError.writeFailed
        }

        do {
            return try await transactionCoordinator.apply(
                rawData: data,
                profileID: profileID,
                sourceFileName: sourceFileName
            )
        } catch let RuntimeConfigTransactionError.configurationValidationFailed(result) {
            throw ConfigurationOverrideStoreError.runtimeValidationFailed(result)
        } catch {
            throw ConfigurationOverrideStoreError.writeFailed
        }
    }

    func preview(
        _ overrides: ProfileStructuredOverrides,
        for profileID: UUID,
        forcedFields: [ConfigurationForcedField]
    ) async throws -> ConfigurationOverrideResult {
        let source: Data
        do {
            source = try await profileStore.readConfiguration(for: profileID)
        } catch {
            throw ConfigurationOverrideStoreError.profileNotFound
        }
        guard let yaml = String(data: source, encoding: .utf8) else {
            throw ConfigurationOverrideStoreError.configurationIsNotUTF8
        }
        do {
            return try processor.process(
                upstreamYAML: yaml,
                overrides: overrides,
                forcedFields: forcedFields
            )
        } catch let error as ConfigurationOverrideProcessingError {
            switch error {
            case let .validationFailed(issues):
                throw ConfigurationOverrideStoreError.validationFailed(issues)
            }
        } catch {
            throw ConfigurationOverrideStoreError.decodeFailed
        }
    }

    @discardableResult
    func save(
        _ overrides: ProfileStructuredOverrides,
        for profileID: UUID,
        forcedFields: [ConfigurationForcedField]
    ) async throws -> ConfigurationOverrideResult {
        let result = try await preview(overrides, for: profileID, forcedFields: forcedFields)
        guard let transactionCoordinator else {
            // A Save is only durable after the same candidate has passed the
            // Mihomo validator and, for the active profile, the runtime apply.
            throw ConfigurationOverrideStoreError.writeFailed
        }
        guard let finalData = result.finalYAML.data(using: .utf8) else {
            throw ConfigurationOverrideStoreError.writeFailed
        }

        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            data = try encoder.encode(result.normalizedOverrides)
        } catch {
            throw ConfigurationOverrideStoreError.writeFailed
        }

        let overrideURL = directories.overrideURL(for: profileID)
        let operationID = UUID()
        let stagingURL = directories.overrideStagingURL(
            for: profileID,
            operationID: operationID
        )
        let backupURL = directories.overrideRollbackURL(
            for: profileID,
            operationID: operationID
        )
        let previousData: Data?
        do {
            try directories.prepare(fileSystem: fileSystem)
            previousData = fileSystem.fileExists(at: overrideURL)
                ? try fileSystem.readData(at: overrideURL)
                : nil
            if let previousData {
                // This private backup is the durable compensation source if
                // the official atomic write succeeds but its chmod/rollback
                // sequence is interrupted.
                try writePrivate(previousData, to: backupURL)
            }
            try writePrivate(data, to: stagingURL)
        } catch {
            for url in [stagingURL, backupURL] where fileSystem.fileExists(at: url) {
                try? fileSystem.removeItem(at: url)
            }
            throw ConfigurationOverrideStoreError.writeFailed
        }

        var preserveEvidence = false
        defer {
            if !preserveEvidence {
                for url in [stagingURL, backupURL] where fileSystem.fileExists(at: url) {
                    try? fileSystem.removeItem(at: url)
                }
            }
        }

        let transactionFileSystem = fileSystem
        let commitAction = RuntimeConfigTransactionCommitAction(
            commit: {
                let stagedData = try transactionFileSystem.readData(at: stagingURL)
                guard stagedData == data else {
                    throw ConfigurationOverrideStoreError.writeFailed
                }
                try transactionFileSystem.writeDataAtomically(stagedData, to: overrideURL)
                try transactionFileSystem.setPOSIXPermissions(0o600, at: overrideURL)
            },
            rollback: {
                if let previousData {
                    let backupData = try transactionFileSystem.readData(at: backupURL)
                    guard backupData == previousData else {
                        throw ConfigurationOverrideStoreError.writeFailed
                    }
                    try transactionFileSystem.writeDataAtomically(backupData, to: overrideURL)
                    try transactionFileSystem.setPOSIXPermissions(0o600, at: overrideURL)
                } else if transactionFileSystem.fileExists(at: overrideURL) {
                    try transactionFileSystem.removeItem(at: overrideURL)
                }
            },
            evidence: .configurationOverride(
                data: data,
                artifactURL: overrideURL,
                cleanupURL: stagingURL,
                previousData: previousData,
                backupURL: backupURL
            )
        )

        do {
            _ = try await transactionCoordinator.apply(
                rawData: finalData,
                profileID: profileID,
                sourceFileName: "structured-overrides.yaml",
                commitRawRevision: false,
                commitAction: commitAction
            )
        } catch let transactionError as RuntimeConfigTransactionError {
            preserveEvidence = transactionError == .rollbackFailed
            throw ConfigurationOverrideStoreError.writeFailed
        } catch {
            throw ConfigurationOverrideStoreError.writeFailed
        }
        return result
    }

    private func writePrivate(_ data: Data, to url: URL) throws {
        try fileSystem.createDirectory(at: url.deletingLastPathComponent())
        try fileSystem.setPOSIXPermissions(0o700, at: url.deletingLastPathComponent())
        try fileSystem.writeDataAtomically(data, to: url)
        try fileSystem.setPOSIXPermissions(0o600, at: url)
    }
}
