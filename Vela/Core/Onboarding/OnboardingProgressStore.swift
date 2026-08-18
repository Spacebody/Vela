import Foundation

nonisolated enum OnboardingProgressStoreError: Error, Equatable, Sendable {
    case invalidProgress(OnboardingProgressValidationError)
    case storagePreparationFailed
    case readFailed
    case fileTooLarge(actual: Int, maximum: Int)
    case decodeFailed
    case writeFailed
    case resetFailed
}

actor OnboardingProgressStore {
    static let privateDirectoryPermissions = 0o700
    static let privateFilePermissions = 0o600
    static let defaultMaximumBytes = 64 * 1_024

    nonisolated let directoryURL: URL
    nonisolated let progressURL: URL

    private let fileSystem: any FileSystemProviding
    private let maximumBytes: Int

    init(
        directoryURL: URL,
        fileName: String = "onboarding-progress.json",
        fileSystem: any FileSystemProviding = LiveFileSystem(),
        maximumBytes: Int = OnboardingProgressStore.defaultMaximumBytes
    ) {
        self.directoryURL = directoryURL
        progressURL = directoryURL.appendingPathComponent(
            fileName,
            isDirectory: false
        )
        self.fileSystem = fileSystem
        self.maximumBytes = max(1, maximumBytes)
    }

    func load() throws -> OnboardingProgress? {
        try Task<Never, Never>.checkCancellation()
        try prepareStorage()
        guard fileSystem.fileExists(at: progressURL) else { return nil }

        let data: Data
        do {
            data = try fileSystem.readData(at: progressURL)
        } catch {
            throw OnboardingProgressStoreError.readFailed
        }
        guard data.count <= maximumBytes else {
            throw OnboardingProgressStoreError.fileTooLarge(
                actual: data.count,
                maximum: maximumBytes
            )
        }

        let progress: OnboardingProgress
        do {
            progress = try Self.decoder().decode(OnboardingProgress.self, from: data)
        } catch {
            throw OnboardingProgressStoreError.decodeFailed
        }
        do {
            return try progress.validated()
        } catch let error as OnboardingProgressValidationError {
            throw OnboardingProgressStoreError.invalidProgress(error)
        }
    }

    func save(_ progress: OnboardingProgress) throws {
        try Task<Never, Never>.checkCancellation()
        let validated: OnboardingProgress
        do {
            validated = try progress.validated()
        } catch let error as OnboardingProgressValidationError {
            throw OnboardingProgressStoreError.invalidProgress(error)
        }

        let data: Data
        do {
            data = try Self.encoder().encode(validated)
        } catch {
            throw OnboardingProgressStoreError.writeFailed
        }
        guard data.count <= maximumBytes else {
            throw OnboardingProgressStoreError.fileTooLarge(
                actual: data.count,
                maximum: maximumBytes
            )
        }

        try prepareStorage()
        try Task<Never, Never>.checkCancellation()
        do {
            try fileSystem.writeDataAtomically(data, to: progressURL)
            try fileSystem.setPOSIXPermissions(
                Self.privateFilePermissions,
                at: progressURL
            )
        } catch {
            throw OnboardingProgressStoreError.writeFailed
        }
    }

    func reset() throws {
        try Task<Never, Never>.checkCancellation()
        guard fileSystem.fileExists(at: progressURL) else { return }
        do {
            try fileSystem.removeItem(at: progressURL)
        } catch {
            throw OnboardingProgressStoreError.resetFailed
        }
    }

    private func prepareStorage() throws {
        do {
            if !fileSystem.fileExists(at: directoryURL) {
                try fileSystem.createDirectory(at: directoryURL)
            }
            try fileSystem.setPOSIXPermissions(
                Self.privateDirectoryPermissions,
                at: directoryURL
            )
        } catch {
            throw OnboardingProgressStoreError.storagePreparationFailed
        }
    }

    private nonisolated static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private nonisolated static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
