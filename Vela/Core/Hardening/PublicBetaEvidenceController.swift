import Foundation
import Observation

nonisolated enum PublicBetaEvidenceControllerError: Error, Equatable, Sendable {
    case unsafeExport
}

extension PublicBetaEvidenceControllerError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .unsafeExport:
            "The reliability evidence export did not pass the local privacy scan."
        }
    }
}

/// Main-actor presentation boundary for the actor-isolated evidence ledger.
/// The controller has no network dependency and never schedules an upload.
@MainActor
@Observable
final class PublicBetaEvidenceController {
    static let recordingDefaultsKey = "dev.yilin.Vela.PublicBeta.localEvidenceEnabled"

    private(set) var localRecordingEnabled: Bool
    private(set) var aggregate: ReliabilityEvidenceAggregate?
    private(set) var lastErrorDescription: String?
    private(set) var isRefreshing = false
    private(set) var isClearing = false

    @ObservationIgnored private let store: ReliabilityEvidenceStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let redactor = SupportTextRedactor()
    @ObservationIgnored private let scanner = SupportSecretScanner()

    init(
        store: ReliabilityEvidenceStore,
        defaults: UserDefaults = .standard
    ) {
        self.store = store
        self.defaults = defaults
        if defaults.object(forKey: Self.recordingDefaultsKey) == nil {
            localRecordingEnabled = true
            defaults.set(true, forKey: Self.recordingDefaultsKey)
        } else {
            localRecordingEnabled = defaults.bool(forKey: Self.recordingDefaultsKey)
        }
    }

    var evidenceDirectoryURL: URL { store.directoryURL }

    func setLocalRecordingEnabled(_ enabled: Bool) {
        localRecordingEnabled = enabled
        defaults.set(enabled, forKey: Self.recordingDefaultsKey)
    }

    func record(_ draft: ReliabilityEventDraft) async {
        guard localRecordingEnabled else { return }
        do {
            try await store.record(draft)
            aggregate = try await store.aggregate()
            lastErrorDescription = nil
        } catch {
            lastErrorDescription = Self.safeErrorDescription(error)
        }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            aggregate = try await store.aggregate()
            lastErrorDescription = nil
        } catch {
            aggregate = nil
            lastErrorDescription = Self.safeErrorDescription(error)
        }
    }

    func clear() async {
        guard !isClearing else { return }
        isClearing = true
        defer { isClearing = false }
        do {
            try await store.clear()
            aggregate = try await store.aggregate()
            lastErrorDescription = nil
        } catch {
            lastErrorDescription = Self.safeErrorDescription(error)
        }
    }

    /// Export is always minimized by the ledger, redacted by the V0.7 rules,
    /// and rejected if the post-redaction scanner still finds sensitive data.
    func redactedExportData(maximumRecentFailures: Int = 25) async throws -> Data {
        let canonical = try await store.canonicalExportJSONString(
            maximumRecentFailures: maximumRecentFailures
        )
        let redacted = redactor.redact(canonical)
        guard scanner.scan(redacted).isEmpty else {
            throw PublicBetaEvidenceControllerError.unsafeExport
        }
        return Data(redacted.utf8)
    }

    private static func safeErrorDescription(_ error: any Error) -> String {
        if let error = error as? ReliabilityEvidenceStoreError {
            return error.localizedDescription
        }
        if let error = error as? ReliabilityEvidenceValidationError {
            return String(describing: error)
        }
        if let error = error as? PublicBetaEvidenceControllerError {
            return error.localizedDescription
        }
        return "Reliability evidence is unavailable."
    }
}
