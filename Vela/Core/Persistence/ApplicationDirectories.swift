import Foundation

nonisolated protocol FileSystemProviding: Sendable {
    func applicationSupportDirectory() -> URL?
    func createDirectory(at url: URL) throws
    func fileExists(at url: URL) -> Bool
    func contentsOfDirectory(at url: URL) throws -> [URL]
    func isRegularFile(at url: URL) -> Bool
    func readData(at url: URL) throws -> Data
    func writeDataAtomically(_ data: Data, to url: URL) throws
    func moveItem(at source: URL, to destination: URL) throws
    func removeItem(at url: URL) throws
    func setPOSIXPermissions(_ permissions: Int, at url: URL) throws
}

extension FileSystemProviding {
    func contentsOfDirectory(at _: URL) throws -> [URL] {
        // Existing focused test doubles do not need to model directory
        // enumeration. Production cleanup is provided by LiveFileSystem and
        // tests that exercise cleanup opt in explicitly.
        []
    }

    func isRegularFile(at _: URL) -> Bool { false }

    func setPOSIXPermissions(_: Int, at _: URL) throws {
        // Test file systems that do not model POSIX metadata may keep the
        // default no-op. LiveFileSystem enforces the production permissions.
    }
}

nonisolated struct LiveFileSystem: FileSystemProviding {
    func applicationSupportDirectory() -> URL? {
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first
    }

    func createDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
    }

    func fileExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    func contentsOfDirectory(at url: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsSubdirectoryDescendants]
        )
    }

    func isRegularFile(at url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    func readData(at url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    func writeDataAtomically(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }

    func moveItem(at source: URL, to destination: URL) throws {
        try FileManager.default.moveItem(at: source, to: destination)
    }

    func removeItem(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    func setPOSIXPermissions(_ permissions: Int, at url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: permissions)],
            ofItemAtPath: url.path
        )
    }
}

nonisolated struct ApplicationDirectories: Equatable, Sendable {
    static let defaultBundleIdentifier = "dev.yilin.Vela"

    let root: URL

    var profiles: URL {
        root.appendingPathComponent("profiles", isDirectory: true)
    }

    var runtime: URL {
        root.appendingPathComponent("runtime", isDirectory: true)
    }

    var profileHistory: URL {
        profiles.appendingPathComponent("history", isDirectory: true)
    }

    var profileStaging: URL {
        profiles.appendingPathComponent("staging", isDirectory: true)
    }

    var runtimeCandidates: URL {
        runtime.appendingPathComponent("candidates", isDirectory: true)
    }

    var overrides: URL {
        root.appendingPathComponent("overrides", isDirectory: true)
    }

    var configuration: URL {
        root.appendingPathComponent("configuration", isDirectory: true)
    }

    var scenes: URL {
        root.appendingPathComponent("scenes", isDirectory: true)
    }

    var scenesDocument: URL {
        scenes.appendingPathComponent("scenes.json", isDirectory: false)
    }

    var configurationLayers: URL {
        configuration.appendingPathComponent("layers.json", isDirectory: false)
    }

    var configurationMigrationBackups: URL {
        configuration.appendingPathComponent("migration-backups", isDirectory: true)
    }

    var legacyOverrideMigrationBackups: URL {
        configurationMigrationBackups.appendingPathComponent(
            "v02-overrides",
            isDirectory: true
        )
    }

    var logs: URL {
        root.appendingPathComponent("logs", isDirectory: true)
    }

    var metadata: URL {
        root.appendingPathComponent("metadata", isDirectory: true)
    }

    var mihomo: URL {
        root.appendingPathComponent("mihomo", isDirectory: true)
    }

    var activeConfiguration: URL {
        runtime.appendingPathComponent("active.yaml", isDirectory: false)
    }

    var previousConfiguration: URL {
        runtime.appendingPathComponent("previous.yaml", isDirectory: false)
    }

    var runtimeTransactionJournal: URL {
        runtime.appendingPathComponent("transaction.json", isDirectory: false)
    }

    var profilesMetadata: URL {
        metadata.appendingPathComponent("profiles.json", isDirectory: false)
    }

    var profilesMetadataV1Backup: URL {
        metadata.appendingPathComponent("profiles.json.v1.backup", isDirectory: false)
    }

    var profilesMetadataMigrationCandidate: URL {
        metadata.appendingPathComponent("profiles.json.v2.migration", isDirectory: false)
    }

    func profileHistoryDirectory(for profileID: UUID) -> URL {
        profileHistory.appendingPathComponent(profileID.uuidString, isDirectory: true)
    }

    func profileStagingDirectory(for profileID: UUID) -> URL {
        profileStaging.appendingPathComponent(profileID.uuidString, isDirectory: true)
    }

    func profileRevisionURL(profileID: UUID, revisionID: UUID) -> URL {
        profileHistoryDirectory(for: profileID).appendingPathComponent(
            "\(revisionID.uuidString).yaml",
            isDirectory: false
        )
    }

    func profileStagingURL(transactionID: UUID) -> URL {
        profileStaging.appendingPathComponent(
            "\(transactionID.uuidString).yaml",
            isDirectory: false
        )
    }

    func profileRollbackURL(transactionID: UUID) -> URL {
        profileStaging.appendingPathComponent(
            "\(transactionID.uuidString).previous.yaml",
            isDirectory: false
        )
    }

    func runtimeCandidateURL(transactionID: UUID) -> URL {
        runtimeCandidates.appendingPathComponent(
            "\(transactionID.uuidString).yaml",
            isDirectory: false
        )
    }

    func overrideURL(for profileID: UUID) -> URL {
        overrides.appendingPathComponent("\(profileID.uuidString).json", isDirectory: false)
    }

    func overrideStagingURL(for profileID: UUID, operationID: UUID) -> URL {
        overrides.appendingPathComponent(
            ".\(profileID.uuidString).\(operationID.uuidString).staging.json",
            isDirectory: false
        )
    }

    func overrideRollbackURL(for profileID: UUID, operationID: UUID) -> URL {
        overrides.appendingPathComponent(
            ".\(profileID.uuidString).\(operationID.uuidString).previous.json",
            isDirectory: false
        )
    }

    func configurationLayerCandidateURL(operationID: UUID) -> URL {
        configuration.appendingPathComponent(
            ".layers.\(operationID.uuidString).candidate.json",
            isDirectory: false
        )
    }

    func legacyOverrideMigrationBackupURL(for profileID: UUID) -> URL {
        legacyOverrideMigrationBackups.appendingPathComponent(
            "\(profileID.uuidString).json",
            isDirectory: false
        )
    }

    init(root: URL) {
        self.root = root.standardizedFileURL
    }

    static func live(
        bundleIdentifier: String = defaultBundleIdentifier,
        fileSystem: any FileSystemProviding = LiveFileSystem()
    ) throws -> ApplicationDirectories {
        guard let applicationSupport = fileSystem.applicationSupportDirectory() else {
            throw ApplicationDirectoriesError.applicationSupportDirectoryUnavailable
        }

        return ApplicationDirectories(
            root: applicationSupport.appendingPathComponent(bundleIdentifier, isDirectory: true)
        )
    }

    func prepare(fileSystem: any FileSystemProviding = LiveFileSystem()) throws {
        for directory in [
            root,
            profiles,
            profileHistory,
            profileStaging,
            runtime,
            runtimeCandidates,
            overrides,
            configuration,
            scenes,
            configurationMigrationBackups,
            legacyOverrideMigrationBackups,
            logs,
            metadata,
            mihomo,
        ] {
            do {
                try fileSystem.createDirectory(at: directory)
                try fileSystem.setPOSIXPermissions(0o700, at: directory)
            } catch {
                throw ApplicationDirectoriesError.couldNotCreateDirectory(
                    path: directory.path,
                    reason: String(describing: error)
                )
            }
        }
    }
}

nonisolated enum ApplicationDirectoriesError: Error, Equatable, Sendable {
    case applicationSupportDirectoryUnavailable
    case couldNotCreateDirectory(path: String, reason: String)
}

extension ApplicationDirectoriesError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .applicationSupportDirectoryUnavailable:
            "The Application Support directory is unavailable."
        case let .couldNotCreateDirectory(path, reason):
            "Could not create directory at \(path): \(reason)"
        }
    }
}
