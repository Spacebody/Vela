import Foundation
import Observation

nonisolated enum PublicBetaSafeModeReason: String, Codable, CaseIterable, Sendable {
    case explicitLaunch
    case userRequested
    case repeatedLaunchFailure
    case launchHealthUnavailable
    case updateRecovery
    case coreRecovery
    case migrationFailure
}

nonisolated struct PublicBetaLaunchDecision: Equatable, Sendable {
    let safeModeReason: PublicBetaSafeModeReason?
    let consecutiveIncompleteLaunches: Int
}

nonisolated struct PublicBetaLaunchHealthRecord: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    let schemaVersion: Int
    var launchInProgress: Bool
    var consecutiveIncompleteLaunches: Int
    var lastLaunchStartedAt: Date?
    var lastHealthyAt: Date?

    init(
        schemaVersion: Int = Self.schemaVersion,
        launchInProgress: Bool = false,
        consecutiveIncompleteLaunches: Int = 0,
        lastLaunchStartedAt: Date? = nil,
        lastHealthyAt: Date? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.launchInProgress = launchInProgress
        self.consecutiveIncompleteLaunches = consecutiveIncompleteLaunches
        self.lastLaunchStartedAt = lastLaunchStartedAt
        self.lastHealthyAt = lastHealthyAt
    }

    func validate(now: Date) throws {
        guard schemaVersion == Self.schemaVersion,
            (0 ... PublicBetaLaunchHealthStore.maximumRecordedFailures)
                .contains(consecutiveIncompleteLaunches)
        else {
            throw PublicBetaLaunchHealthError.invalidRecord
        }
        let maximumFutureDate = now.addingTimeInterval(5 * 60)
        guard lastLaunchStartedAt.map({ $0 <= maximumFutureDate }) ?? true,
            lastHealthyAt.map({ $0 <= maximumFutureDate }) ?? true
        else {
            throw PublicBetaLaunchHealthError.invalidRecord
        }
    }
}

nonisolated enum PublicBetaLaunchHealthError: Error, Equatable, Sendable {
    case invalidRecord
    case oversizedRecord
}

/// A deliberately tiny, local-only launch marker used to break startup crash
/// loops. It contains no device identifier, path, user content, or raw error.
nonisolated struct PublicBetaLaunchHealthStore: Sendable {
    static let explicitLaunchArgument = "--vela-safe-mode"
    static let repeatedFailureThreshold = 3
    static let maximumRecordedFailures = 10
    static let crashLoopWindow: TimeInterval = 15 * 60
    static let maximumRecordBytes = 16 * 1024

    private static let allowedKeys: Set<String> = [
        "schemaVersion",
        "launchInProgress",
        "consecutiveIncompleteLaunches",
        "lastLaunchStartedAt",
        "lastHealthyAt",
    ]
    private static let requiredKeys: Set<String> = [
        "schemaVersion",
        "launchInProgress",
        "consecutiveIncompleteLaunches",
    ]

    let directoryURL: URL
    let fileSystem: any FileSystemProviding

    init(directoryURL: URL, fileSystem: any FileSystemProviding = LiveFileSystem()) {
        self.directoryURL = directoryURL.standardizedFileURL
        self.fileSystem = fileSystem
    }

    var recordURL: URL {
        directoryURL.appendingPathComponent("launch-health.json", isDirectory: false)
    }

    func beginLaunch(
        arguments: [String],
        userRequested: Bool,
        now: Date = .now
    ) -> PublicBetaLaunchDecision {
        let loaded: PublicBetaLaunchHealthRecord
        let loadFailedClosed: Bool
        do {
            loaded = try load(now: now)
            loadFailedClosed = false
        } catch {
            quarantineUnreadableRecord()
            loaded = PublicBetaLaunchHealthRecord()
            loadFailedClosed = true
        }

        var record = loaded
        if record.launchInProgress {
            let remainsInCrashLoopWindow = record.lastLaunchStartedAt.map {
                now.timeIntervalSince($0) >= 0
                    && now.timeIntervalSince($0) <= Self.crashLoopWindow
            } ?? false
            record.consecutiveIncompleteLaunches = remainsInCrashLoopWindow
                ? min(
                    record.consecutiveIncompleteLaunches + 1,
                    Self.maximumRecordedFailures
                )
                : 1
        }
        record.launchInProgress = true
        record.lastLaunchStartedAt = now
        let persistenceFailed: Bool
        do {
            try save(record)
            persistenceFailed = false
        } catch {
            persistenceFailed = true
        }

        let reason: PublicBetaSafeModeReason?
        if arguments.contains(Self.explicitLaunchArgument) {
            reason = .explicitLaunch
        } else if userRequested {
            reason = .userRequested
        } else if loadFailedClosed || persistenceFailed {
            reason = .launchHealthUnavailable
        } else if record.consecutiveIncompleteLaunches >= Self.repeatedFailureThreshold {
            reason = .repeatedLaunchFailure
        } else {
            reason = nil
        }
        return PublicBetaLaunchDecision(
            safeModeReason: reason,
            consecutiveIncompleteLaunches: record.consecutiveIncompleteLaunches
        )
    }

    func markHealthy(now: Date = .now) throws {
        var record = (try? load(now: now)) ?? PublicBetaLaunchHealthRecord()
        record.launchInProgress = false
        record.consecutiveIncompleteLaunches = 0
        record.lastHealthyAt = now
        try save(record)
    }

    func load(now: Date = .now) throws -> PublicBetaLaunchHealthRecord {
        guard fileSystem.fileExists(at: recordURL) else {
            return PublicBetaLaunchHealthRecord()
        }
        let data = try fileSystem.readData(at: recordURL)
        guard data.count <= Self.maximumRecordBytes else {
            throw PublicBetaLaunchHealthError.oversizedRecord
        }
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any],
            Set(dictionary.keys).isSubset(of: Self.allowedKeys),
            Self.requiredKeys.isSubset(of: Set(dictionary.keys))
        else {
            throw PublicBetaLaunchHealthError.invalidRecord
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(PublicBetaLaunchHealthRecord.self, from: data)
        try record.validate(now: now)
        return record
    }

    func save(_ record: PublicBetaLaunchHealthRecord) throws {
        try fileSystem.createDirectory(at: directoryURL)
        try fileSystem.setPOSIXPermissions(0o700, at: directoryURL)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(record)
        guard data.count <= Self.maximumRecordBytes else {
            throw PublicBetaLaunchHealthError.oversizedRecord
        }
        try fileSystem.writeDataAtomically(data, to: recordURL)
        try fileSystem.setPOSIXPermissions(0o600, at: recordURL)
    }

    private func quarantineUnreadableRecord() {
        guard fileSystem.fileExists(at: recordURL) else { return }
        let quarantineURL = directoryURL.appendingPathComponent(
            "launch-health.corrupt-\(UUID().uuidString).json",
            isDirectory: false
        )
        try? fileSystem.moveItem(at: recordURL, to: quarantineURL)
        try? fileSystem.setPOSIXPermissions(0o600, at: quarantineURL)
    }
}

@MainActor
@Observable
final class PublicBetaSafeModeController {
    static let requestedDefaultsKey = "dev.yilin.Vela.PublicBeta.safeModeOnNextLaunch"

    private(set) var reason: PublicBetaSafeModeReason?
    private(set) var consecutiveIncompleteLaunches = 0
    private(set) var launchHealthErrorCode: String?

    @ObservationIgnored private let launchHealthStore: PublicBetaLaunchHealthStore
    @ObservationIgnored private let defaults: UserDefaults

    init(
        launchHealthStore: PublicBetaLaunchHealthStore,
        defaults: UserDefaults = .standard
    ) {
        self.launchHealthStore = launchHealthStore
        self.defaults = defaults
    }

    var isActive: Bool { reason != nil }

    var isRequestedForNextLaunch: Bool {
        defaults.bool(forKey: Self.requestedDefaultsKey)
    }

    @discardableResult
    func beginLaunch(arguments: [String] = ProcessInfo.processInfo.arguments) -> PublicBetaSafeModeReason? {
        let requested = isRequestedForNextLaunch
        if requested {
            defaults.removeObject(forKey: Self.requestedDefaultsKey)
        }
        let decision = launchHealthStore.beginLaunch(
            arguments: arguments,
            userRequested: requested
        )
        consecutiveIncompleteLaunches = decision.consecutiveIncompleteLaunches
        reason = decision.safeModeReason
        return reason
    }

    func activate(_ reason: PublicBetaSafeModeReason) {
        self.reason = reason
    }

    func requestForNextLaunch() {
        defaults.set(true, forKey: Self.requestedDefaultsKey)
    }

    func cancelRequest() {
        defaults.removeObject(forKey: Self.requestedDefaultsKey)
    }

    func markLaunchHealthy() {
        do {
            try launchHealthStore.markHealthy()
            launchHealthErrorCode = nil
            consecutiveIncompleteLaunches = 0
        } catch {
            launchHealthErrorCode = "launchHealthWriteFailed"
        }
    }
}
