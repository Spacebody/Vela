import Foundation
import Observation

nonisolated enum PublicBetaSelfTestLevel: String, Codable, Sendable {
    case quick
    case extended
}

nonisolated enum PublicBetaSelfTestOutcome: String, Codable, Sendable {
    case passed
    case warning
    case failed
}

nonisolated enum PublicBetaSelfTestCheckID: String, CaseIterable, Codable, Sendable {
    case signatures
    case manifests
    case controller
    case configurationCompile
    case storesAndJournals
    case helperHandshake
    case diagnostics
    case helpAndSearch
    case supportRedaction
    case extendedHostGate
}

nonisolated struct PublicBetaSelfTestResult: Identifiable, Equatable, Sendable {
    var id: PublicBetaSelfTestCheckID { checkID }

    let checkID: PublicBetaSelfTestCheckID
    let outcome: PublicBetaSelfTestOutcome
}

nonisolated struct PublicBetaSelfTestReport: Identifiable, Equatable, Sendable {
    let id: UUID
    let level: PublicBetaSelfTestLevel
    let startedAt: Date
    let completedAt: Date
    let results: [PublicBetaSelfTestResult]

    var passedCount: Int { results.count(where: { $0.outcome == .passed }) }
    var hasFailures: Bool { results.contains(where: { $0.outcome == .failed }) }
}

@MainActor
@Observable
final class PublicBetaSelfTestController {
    nonisolated static let destructiveTestEnvironmentKey =
        "VELA_RUN_DESTRUCTIVE_BETA_TESTS"

    private(set) var isRunning = false
    private(set) var report: PublicBetaSelfTestReport?

    func runQuick(
        operation: @escaping @MainActor () async -> [PublicBetaSelfTestResult]
    ) async {
        guard !isRunning else { return }
        isRunning = true
        let startedAt = Date()
        let results = await operation()
        guard !Task.isCancelled else {
            isRunning = false
            return
        }
        report = PublicBetaSelfTestReport(
            id: UUID(),
            level: .quick,
            startedAt: startedAt,
            completedAt: Date(),
            results: results
        )
        isRunning = false
    }

    /// Extended tests are intentionally unavailable in normal app launches.
    /// The dedicated DEBUG harness must opt in explicitly; the harness owns
    /// state capture, restoration, and cleanup evidence.
    func showExtendedHostRequirement() {
        let now = Date()
        report = PublicBetaSelfTestReport(
            id: UUID(),
            level: .extended,
            startedAt: now,
            completedAt: now,
            results: [
                PublicBetaSelfTestResult(
                    checkID: .extendedHostGate,
                    outcome: .warning
                )
            ]
        )
    }

    nonisolated static var extendedHarnessEnabled: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment[destructiveTestEnvironmentKey] == "1"
        #else
        false
        #endif
    }
}

nonisolated enum PublicBetaStaticSelfTests {
    static func manifests(bundle: Bundle = .main) -> PublicBetaSelfTestOutcome {
        do {
            _ = try BuildManifestReader().readBundled(from: bundle)
            guard let documentationURL = bundle.url(
                forResource: "VelaDocumentationManifest",
                withExtension: "json"
            ) else {
                return .failed
            }
            let data = try Data(contentsOf: documentationURL, options: [.mappedIfSafe])
            guard data.count <= 1_024 * 1_024,
                let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                object["schemaVersion"] != nil
            else {
                return .failed
            }
            return .passed
        } catch {
            return .failed
        }
    }

    static func helpAndSearch(bundle: Bundle = .main) -> PublicBetaSelfTestOutcome {
        do {
            guard let root = HelpBundleResources.rootURL(in: bundle) else { return .failed }
            let repository = try HelpRepository.open(
                resourceRoot: root,
                preferredLanguages: ["en"]
            )
            guard let first = repository.library.articles.first else { return .failed }
            _ = try repository.loadArticle(id: first.id)
            return try repository.searchEngine.search("diagnostics").isEmpty
                ? .failed
                : .passed
        } catch {
            return .failed
        }
    }

    static func supportRedaction() -> PublicBetaSelfTestOutcome {
        guard SupportTextRedactor.rulesAreValid, SupportSecretScanner.rulesAreValid else {
            return .failed
        }
        let fixture = """
            Authorization: Bearer beta-secret
            subscription: https://example.invalid/profile?token=private
            controllerSecret=controller-private
            host=192.0.2.42
            processPath=/Users/private/Vela
            """
        let redacted = SupportTextRedactor().redact(fixture)
        return SupportSecretScanner().scan(redacted).isEmpty ? .passed : .failed
    }
}
