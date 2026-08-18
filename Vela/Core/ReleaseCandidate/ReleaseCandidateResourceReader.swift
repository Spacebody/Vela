import CryptoKit
import Foundation

nonisolated struct ReleaseCandidateResourceReader: Sendable {
    static let resourceDirectoryName = "ReleaseCandidate"
    static let baselineFileName = "baseline.json"

    func read(from rootURL: URL) throws -> ReleaseCandidateResources {
        let root = try verifiedRoot(rootURL)
        let baselineData = try readResource(
            Self.baselineFileName,
            from: root,
            maximumBytes: ReleaseCandidateBaseline.maximumEncodedBytes
        )
        let baseline: ReleaseCandidateBaseline = try decode(
            baselineData,
            resource: Self.baselineFileName
        )
        do {
            try baseline.validate()
        } catch let error as ReleaseCandidateValidationError {
            throw ReleaseCandidateResourceReaderError.validationFailed(error)
        }

        let publicContractData = try readResource(
            baseline.publicContractResource,
            from: root,
            maximumBytes: ReleaseCandidateBaseline.maximumPublicContractBytes
        )
        try validateJSONObject(
            publicContractData,
            resource: baseline.publicContractResource
        )
        guard Self.sha256(publicContractData) == baseline.publicContractFileSHA256 else {
            throw ReleaseCandidateResourceReaderError.integrityMismatch(
                baseline.publicContractResource
            )
        }

        let knownData = try readResource(
            baseline.knownLimitationsResource,
            from: root,
            maximumBytes: KnownLimitationsManifest.maximumEncodedBytes
        )
        let knownLimitations: KnownLimitationsManifest = try decode(
            knownData,
            resource: baseline.knownLimitationsResource
        )
        do {
            try knownLimitations.validate()
        } catch let error as ReleaseCandidateValidationError {
            throw ReleaseCandidateResourceReaderError.validationFailed(error)
        }
        guard knownLimitations.version == baseline.marketingVersion else {
            throw ReleaseCandidateResourceReaderError.versionMismatch(
                baseline: baseline.marketingVersion,
                knownLimitations: knownLimitations.version
            )
        }

        return ReleaseCandidateResources(
            baseline: baseline,
            publicContract: publicContractData,
            knownLimitations: knownLimitations
        )
    }

    func read(
        from rootURL: URL,
        matching bundleIdentity: ReleaseCandidateBundleIdentity
    ) throws -> ReleaseCandidateResources {
        let resources = try read(from: rootURL)
        guard resources.baseline.marketingVersion == bundleIdentity.marketingVersion else {
            throw ReleaseCandidateResourceReaderError.bundleVersionMismatch(
                baseline: resources.baseline.marketingVersion,
                bundle: bundleIdentity.marketingVersion
            )
        }
        return resources
    }

    func readBundled(from bundle: Bundle = .main) throws -> ReleaseCandidateResources {
        guard let resourceURL = bundle.resourceURL else {
            throw ReleaseCandidateResourceReaderError.missingResourceRoot
        }
        let identity: ReleaseCandidateBundleIdentity
        do {
            identity = try ReleaseCandidateBundleIdentity(bundle: bundle)
        } catch let error as ReleaseCandidateBundleIdentityError {
            throw ReleaseCandidateResourceReaderError.invalidBundleIdentity(error)
        }
        return try read(
            from: resourceURL.appending(
                path: Self.resourceDirectoryName,
                directoryHint: .isDirectory
            ),
            matching: identity
        )
    }

    private func decode<Value: Decodable>(
        _ data: Data,
        resource: String
    ) throws -> Value {
        try rejectSensitiveContent(data, resource: resource)
        do {
            return try JSONDecoder().decode(Value.self, from: data)
        } catch {
            throw ReleaseCandidateResourceReaderError.decodeFailed(resource)
        }
    }

    private func validateJSONObject(_ data: Data, resource: String) throws {
        try rejectSensitiveContent(data, resource: resource)
        do {
            guard try JSONSerialization.jsonObject(with: data) is [String: Any] else {
                throw ReleaseCandidateResourceReaderError.decodeFailed(resource)
            }
        } catch let error as ReleaseCandidateResourceReaderError {
            throw error
        } catch {
            throw ReleaseCandidateResourceReaderError.decodeFailed(resource)
        }
    }

    private func rejectSensitiveContent(_ data: Data, resource: String) throws {
        let findings: [SupportSecretFinding]
        do {
            findings = try SupportSecretScanner().scan(data)
        } catch {
            throw ReleaseCandidateResourceReaderError.invalidUTF8(resource)
        }
        guard findings.isEmpty else {
            throw ReleaseCandidateResourceReaderError.sensitiveContent(
                resource,
                Set(findings.map(\.kind))
            )
        }
    }

    private func verifiedRoot(_ rootURL: URL) throws -> URL {
        guard rootURL.isFileURL else {
            throw ReleaseCandidateResourceReaderError.unsafeResourceRoot
        }
        let standardized = rootURL.standardizedFileURL
        let resolved = standardized.resolvingSymlinksInPath()
        guard standardized.path == resolved.path else {
            throw ReleaseCandidateResourceReaderError.unsafeResourceRoot
        }
        let values: URLResourceValues
        do {
            values = try standardized.resourceValues(forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
            ])
        } catch {
            throw ReleaseCandidateResourceReaderError.missingResourceRoot
        }
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw ReleaseCandidateResourceReaderError.unsafeResourceRoot
        }
        return standardized
    }

    private func readResource(
        _ relativePath: String,
        from root: URL,
        maximumBytes: Int
    ) throws -> Data {
        guard Self.isSafeResourceName(relativePath) else {
            throw ReleaseCandidateResourceReaderError.unsafeResource(relativePath)
        }
        let candidate = root.appending(path: relativePath).standardizedFileURL
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        let resolved = candidate.resolvingSymlinksInPath()
        guard candidate.path.hasPrefix(rootPrefix), resolved.path == candidate.path else {
            throw ReleaseCandidateResourceReaderError.unsafeResource(relativePath)
        }

        let before: URLResourceValues
        do {
            before = try candidate.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
            ])
        } catch CocoaError.fileReadNoSuchFile {
            throw ReleaseCandidateResourceReaderError.missingResource(relativePath)
        } catch {
            throw ReleaseCandidateResourceReaderError.missingResource(relativePath)
        }
        guard before.isRegularFile == true, before.isSymbolicLink != true else {
            throw ReleaseCandidateResourceReaderError.unsafeResource(relativePath)
        }
        guard let beforeSize = before.fileSize, beforeSize > 0,
            beforeSize <= maximumBytes
        else {
            throw ReleaseCandidateResourceReaderError.resourceTooLarge(
                relativePath,
                maximumBytes: maximumBytes
            )
        }

        let data: Data
        do {
            data = try Data(contentsOf: candidate, options: [.mappedIfSafe])
        } catch {
            throw ReleaseCandidateResourceReaderError.readFailed(relativePath)
        }
        guard !data.isEmpty, data.count <= maximumBytes else {
            throw ReleaseCandidateResourceReaderError.resourceTooLarge(
                relativePath,
                maximumBytes: maximumBytes
            )
        }

        let after = try? candidate.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
        ])
        guard after?.isRegularFile == true, after?.isSymbolicLink != true,
            after?.fileSize == beforeSize, data.count == beforeSize,
            candidate.resolvingSymlinksInPath().path == candidate.path
        else {
            throw ReleaseCandidateResourceReaderError.resourceChanged(relativePath)
        }
        return data
    }

    private static func isSafeResourceName(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128
            && !value.hasPrefix(".")
            && value.unicodeScalars.allSatisfy { scalar in
                (scalar.value >= 97 && scalar.value <= 122)
                    || (scalar.value >= 48 && scalar.value <= 57)
                    || scalar.value == 45
                    || scalar.value == 46
            }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

nonisolated enum ReleaseCandidateResourceReaderError: Error, Equatable, Sendable {
    case missingResourceRoot
    case unsafeResourceRoot
    case missingResource(String)
    case unsafeResource(String)
    case resourceTooLarge(String, maximumBytes: Int)
    case readFailed(String)
    case resourceChanged(String)
    case invalidUTF8(String)
    case sensitiveContent(String, Set<SupportSecretKind>)
    case decodeFailed(String)
    case integrityMismatch(String)
    case validationFailed(ReleaseCandidateValidationError)
    case versionMismatch(baseline: String, knownLimitations: String)
    case invalidBundleIdentity(ReleaseCandidateBundleIdentityError)
    case bundleVersionMismatch(baseline: String, bundle: String)
}
