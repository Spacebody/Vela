import CryptoKit
import Foundation

nonisolated struct RuntimeConfigurationFingerprint: Codable, Equatable, Sendable {
    let url: URL
    let sha256: String
    let byteCount: Int

    init(url: URL, sha256: String, byteCount: Int) {
        self.url = url.standardizedFileURL
        self.sha256 = sha256
        self.byteCount = byteCount
    }
}

nonisolated enum RuntimeConfigurationInspection: Equatable, Sendable {
    case matches(RuntimeConfigurationFingerprint)
    case changed(expected: RuntimeConfigurationFingerprint, actual: RuntimeConfigurationFingerprint)
    case missing(URL)
    case unavailable(String)
    case notRequired

    var isMatch: Bool {
        if case .matches = self { return true }
        return false
    }

    var checkState: HealthCheckState {
        switch self {
        case .matches: .passing
        case .changed, .missing: .degraded
        case .unavailable: .unknown
        case .notRequired: .skipped
        }
    }

    var summary: String {
        switch self {
        case .matches:
            "The runtime configuration matches its validated fingerprint."
        case .changed:
            "The runtime configuration changed after validation."
        case .missing:
            "The validated runtime configuration is missing."
        case .unavailable:
            "The runtime configuration could not be inspected."
        case .notRequired:
            "Runtime configuration inspection is not required."
        }
    }

    var technicalDetails: String? {
        switch self {
        case .matches, .notRequired:
            nil
        case let .changed(expected, actual):
            "Expected SHA256 \(expected.sha256) (\(expected.byteCount) bytes), found \(actual.sha256) (\(actual.byteCount) bytes)."
        case let .missing(url):
            url.path
        case let .unavailable(details):
            details
        }
    }
}

nonisolated protocol RuntimeConfigurationInspecting: Sendable {
    func fingerprint(at url: URL) async throws -> RuntimeConfigurationFingerprint
    func inspect(expected: RuntimeConfigurationFingerprint) async -> RuntimeConfigurationInspection
}

actor RuntimeConfigurationInspector: RuntimeConfigurationInspecting {
    private let fileSystem: any FileSystemProviding

    init(fileSystem: any FileSystemProviding = LiveFileSystem()) {
        self.fileSystem = fileSystem
    }

    func fingerprint(at url: URL) async throws -> RuntimeConfigurationFingerprint {
        let data: Data
        do {
            data = try fileSystem.readData(at: url)
        } catch {
            throw RuntimeConfigurationInspectorError.readFailed(
                path: url.path,
                reason: error.localizedDescription
            )
        }
        return Self.makeFingerprint(url: url, data: data)
    }

    func inspect(expected: RuntimeConfigurationFingerprint) async -> RuntimeConfigurationInspection {
        guard fileSystem.fileExists(at: expected.url) else {
            return .missing(expected.url)
        }
        do {
            let actual = try await fingerprint(at: expected.url)
            return actual == expected
                ? .matches(actual)
                : .changed(expected: expected, actual: actual)
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }

    private nonisolated static func makeFingerprint(url: URL, data: Data) -> RuntimeConfigurationFingerprint {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return RuntimeConfigurationFingerprint(
            url: url,
            sha256: digest,
            byteCount: data.count
        )
    }
}

nonisolated enum RuntimeConfigurationInspectorError: Error, Equatable, Sendable {
    case readFailed(path: String, reason: String)
}

extension RuntimeConfigurationInspectorError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .readFailed(path, reason):
            "Could not read runtime configuration at \(path): \(reason)"
        }
    }
}
