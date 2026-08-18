import Foundation
import VelaIPC

enum RootCoreCompatibilityReportValidator {
    private static let testOrder = [
        "version", "config-corpus", "controller-api", "websockets",
        "user-backend", "system-proxy", "tun-backend", "sleep-network",
        "rollback", "performance", "artifact-integrity",
    ]
    private static let evidenceKeys: Set<String> = [
        "candidateVersion", "factoryVersion", "configCorpus", "controllerAPI",
        "webSockets", "userBackend", "dedicatedHost", "rollback", "performance",
    ]
    private static let metricKeys: Set<String> = ["candidate", "factory", "ratios"]

    static func validate(
        _ data: Data,
        selection: VerifiedCoreCatalogSelection,
        executableSHA256: String
    ) throws {
        guard data.count > 0, data.count <= CoreFileRole.compatibility.maximumBytes,
            let root = try jsonObject(data),
            Set(root.keys) == [
                "schemaVersion", "suiteVersion", "coreID", "result", "generatedAt",
                "environment", "tests", "knownDeviations", "evidenceVersion",
                "artifacts", "evidence", "metrics",
            ],
            let environment = root["environment"] as? [String: Any],
            Set(environment.keys)
                == ["macOS", "architecture", "vela", "hostClass", "userDataAccessed"],
            let tests = root["tests"] as? [[String: Any]],
            tests.allSatisfy({ Set($0.keys) == ["id", "result"] }),
            let artifacts = root["artifacts"] as? [String: Any],
            Set(artifacts.keys) == [
                "upstreamPayloadSHA256", "candidateExecutableSHA256",
                "factoryExecutableSHA256", "suiteSHA256",
                "corpusSHA256", "apiContractSHA256", "dedicatedHostEvidenceSHA256",
                "performanceReviewSHA256",
            ],
            let evidence = root["evidence"] as? [String: Any],
            Set(evidence.keys) == evidenceKeys,
            evidence.values.allSatisfy({ $0 is [String: Any] }),
            let metrics = root["metrics"] as? [String: Any],
            Set(metrics.keys) == metricKeys,
            metrics.values.allSatisfy({ $0 is [String: Any] })
        else { throw RootCoreStoreError.preflightFailed }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: value) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            guard let date = formatter.date(from: value) else {
                throw DecodingError.dataCorruptedError(
                    in: try decoder.singleValueContainer(),
                    debugDescription: "Invalid compatibility report date."
                )
            }
            return date
        }
        let report: Report
        do { report = try decoder.decode(Report.self, from: data) }
        catch { throw RootCoreStoreError.preflightFailed }

        let mandatoryHashes = [
            report.artifacts.upstreamPayloadSHA256,
            report.artifacts.candidateExecutableSHA256,
            report.artifacts.factoryExecutableSHA256,
            report.artifacts.suiteSHA256,
            report.artifacts.corpusSHA256,
            report.artifacts.apiContractSHA256,
            report.artifacts.dedicatedHostEvidenceSHA256,
            report.artifacts.performanceReviewSHA256,
        ]
        guard report.schemaVersion == 1,
            report.suiteVersion == selection.compatibility.compatibilitySuiteVersion,
            report.coreID == selection.coreID,
            report.result == .passed,
            report.tests.map(\.id) == testOrder,
            report.tests.allSatisfy({ $0.result == .passed }),
            report.environment.architecture == "arm64",
            report.environment.hostClass == "dedicated-release-lab",
            !report.environment.userDataAccessed,
            report.knownDeviations.isEmpty,
            report.evidenceVersion == 1,
            mandatoryHashes.allSatisfy(isSHA256),
            selection.files.first(where: { $0.role == .executable })?.expectedSHA256
                == executableSHA256,
            report.artifacts.candidateExecutableSHA256
                == report.artifacts.upstreamPayloadSHA256,
            report.artifacts.candidateExecutableSHA256
                != report.artifacts.factoryExecutableSHA256
        else { throw RootCoreStoreError.preflightFailed }
    }

    private static func jsonObject(_ data: Data) throws -> [String: Any]? {
        try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48 ... 57).contains($0) || (97 ... 102).contains($0)
        }
    }

    private enum Result: String, Codable { case passed, failed }

    private struct Test: Codable {
        let id: String
        let result: Result
    }

    private struct Environment: Codable {
        let macOS: String
        let architecture: String
        let vela: String
        let hostClass: String
        let userDataAccessed: Bool
    }

    private struct Artifacts: Codable {
        let upstreamPayloadSHA256: String
        let candidateExecutableSHA256: String
        let factoryExecutableSHA256: String
        let suiteSHA256: String
        let corpusSHA256: String
        let apiContractSHA256: String
        let dedicatedHostEvidenceSHA256: String
        let performanceReviewSHA256: String
    }

    private indirect enum JSONValue: Codable {
        case null
        case bool(Bool)
        case number(Double)
        case string(String)
        case array([JSONValue])
        case object([String: JSONValue])

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() { self = .null }
            else if let value = try? container.decode(Bool.self) { self = .bool(value) }
            else if let value = try? container.decode(Double.self) {
                guard value.isFinite else {
                    throw DecodingError.dataCorruptedError(
                        in: container,
                        debugDescription: "Non-finite compatibility evidence."
                    )
                }
                self = .number(value)
            } else if let value = try? container.decode(String.self) { self = .string(value) }
            else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
            else { self = .object(try container.decode([String: JSONValue].self)) }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .null: try container.encodeNil()
            case let .bool(value): try container.encode(value)
            case let .number(value): try container.encode(value)
            case let .string(value): try container.encode(value)
            case let .array(value): try container.encode(value)
            case let .object(value): try container.encode(value)
            }
        }
    }

    private struct Report: Codable {
        let schemaVersion: Int
        let suiteVersion: Int
        let coreID: CoreID
        let result: Result
        let generatedAt: Date
        let environment: Environment
        let tests: [Test]
        let knownDeviations: [String]
        let evidenceVersion: Int
        let artifacts: Artifacts
        let evidence: [String: JSONValue]
        let metrics: [String: JSONValue]
    }
}
