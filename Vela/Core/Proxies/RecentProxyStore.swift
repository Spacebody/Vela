import Foundation

nonisolated struct RecentProxyRecord: Codable, Equatable, Sendable {
    let profileID: UUID
    let groupName: String
    let proxyName: String
    let usedAt: Date

    init(
        profileID: UUID,
        groupName: String,
        proxyName: String,
        usedAt: Date
    ) {
        self.profileID = profileID
        self.groupName = groupName
        self.proxyName = proxyName
        self.usedAt = usedAt
    }
}

nonisolated protocol RecentProxyStoring: Sendable {
    func load(for profileID: UUID) async throws -> [RecentProxyRecord]

    func record(
        profileID: UUID,
        groupName: String,
        proxyName: String,
        usedAt: Date
    ) async throws
}

actor RecentProxyStore: RecentProxyStoring {
    private let directories: ApplicationDirectories
    private let fileSystem: any FileSystemProviding
    private let maximumEntriesPerProfile: Int

    init(
        directories: ApplicationDirectories,
        fileSystem: any FileSystemProviding = LiveFileSystem(),
        maximumEntriesPerProfile: Int = 8
    ) {
        self.directories = directories
        self.fileSystem = fileSystem
        self.maximumEntriesPerProfile = max(1, maximumEntriesPerProfile)
    }

    func load(for profileID: UUID) async throws -> [RecentProxyRecord] {
        try prepareStorage()
        return try loadIndex().records.filter { $0.profileID == profileID }
    }

    func record(
        profileID: UUID,
        groupName: String,
        proxyName: String,
        usedAt: Date
    ) async throws {
        try prepareStorage()

        var index = try loadIndex()
        index.records.removeAll {
            $0.profileID == profileID
                && $0.groupName == groupName
                && $0.proxyName == proxyName
        }
        index.records.append(
            RecentProxyRecord(
                profileID: profileID,
                groupName: groupName,
                proxyName: proxyName,
                usedAt: usedAt
            )
        )
        index.records = normalized(index.records)
        try saveIndex(index)
    }

    private var metadataURL: URL {
        directories.metadata.appendingPathComponent(
            "recent-proxies.json",
            isDirectory: false
        )
    }

    private func prepareStorage() throws {
        do {
            try fileSystem.createDirectory(at: directories.metadata)
        } catch {
            throw RecentProxyStoreError.storagePreparationFailed(
                path: directories.metadata.path,
                reason: String(describing: error)
            )
        }
    }

    private func loadIndex() throws -> RecentProxyIndex {
        guard fileSystem.fileExists(at: metadataURL) else {
            return RecentProxyIndex()
        }

        let data: Data
        do {
            data = try fileSystem.readData(at: metadataURL)
        } catch {
            throw RecentProxyStoreError.metadataReadFailed(
                path: metadataURL.path,
                reason: String(describing: error)
            )
        }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            let index = try decoder.decode(RecentProxyIndex.self, from: data)
            return RecentProxyIndex(records: normalized(index.records))
        } catch {
            throw RecentProxyStoreError.metadataDecodeFailed(
                path: metadataURL.path,
                reason: String(describing: error)
            )
        }
    }

    private func saveIndex(_ index: RecentProxyIndex) throws {
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            data = try encoder.encode(index)
        } catch {
            throw RecentProxyStoreError.metadataEncodeFailed(
                reason: String(describing: error)
            )
        }

        do {
            try fileSystem.writeDataAtomically(data, to: metadataURL)
        } catch {
            throw RecentProxyStoreError.metadataWriteFailed(
                path: metadataURL.path,
                reason: String(describing: error)
            )
        }
    }

    private func normalized(_ records: [RecentProxyRecord]) -> [RecentProxyRecord] {
        let orderedRecords = records.sorted(by: comesBefore)
        var seenKeys: Set<RecentProxyKey> = []
        var countsByProfile: [UUID: Int] = [:]

        return orderedRecords.filter { record in
            let key = RecentProxyKey(record: record)
            guard !seenKeys.contains(key) else {
                return false
            }

            let count = countsByProfile[record.profileID, default: 0]
            guard count < maximumEntriesPerProfile else {
                return false
            }

            seenKeys.insert(key)
            countsByProfile[record.profileID] = count + 1
            return true
        }
    }

    private func comesBefore(_ lhs: RecentProxyRecord, _ rhs: RecentProxyRecord) -> Bool {
        if lhs.usedAt != rhs.usedAt {
            return lhs.usedAt > rhs.usedAt
        }
        if lhs.profileID != rhs.profileID {
            return lhs.profileID.uuidString < rhs.profileID.uuidString
        }
        if lhs.groupName != rhs.groupName {
            return lhs.groupName < rhs.groupName
        }
        return lhs.proxyName < rhs.proxyName
    }
}

nonisolated private struct RecentProxyIndex: Codable, Equatable, Sendable {
    var records: [RecentProxyRecord] = []
}

nonisolated private struct RecentProxyKey: Hashable, Sendable {
    let profileID: UUID
    let groupName: String
    let proxyName: String

    init(record: RecentProxyRecord) {
        profileID = record.profileID
        groupName = record.groupName
        proxyName = record.proxyName
    }
}

nonisolated enum RecentProxyStoreError: Error, Equatable, Sendable {
    case storagePreparationFailed(path: String, reason: String)
    case metadataReadFailed(path: String, reason: String)
    case metadataDecodeFailed(path: String, reason: String)
    case metadataEncodeFailed(reason: String)
    case metadataWriteFailed(path: String, reason: String)
}

extension RecentProxyStoreError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .storagePreparationFailed(path, reason):
            "Could not prepare recent proxy storage at \(path): \(reason)"
        case let .metadataReadFailed(path, reason):
            "Could not read recent proxy metadata at \(path): \(reason)"
        case let .metadataDecodeFailed(path, reason):
            "Could not decode recent proxy metadata at \(path): \(reason)"
        case let .metadataEncodeFailed(reason):
            "Could not encode recent proxy metadata: \(reason)"
        case let .metadataWriteFailed(path, reason):
            "Could not write recent proxy metadata at \(path): \(reason)"
        }
    }
}
