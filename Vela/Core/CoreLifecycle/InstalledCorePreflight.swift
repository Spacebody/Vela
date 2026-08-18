import CryptoKit
import Darwin
import Foundation
import VelaIPC

nonisolated struct CoreCompatibilityEnvironment: Equatable, Sendable {
    let velaVersion: String
    let velaBuild: UInt64
    let helperProtocol: UInt64
    let dataSchema: UInt64
    let controllerAPIProfile: String
    let macOSVersion: String
    let architecture: String

    init(
        velaVersion: String,
        velaBuild: UInt64,
        helperProtocol: UInt64,
        dataSchema: UInt64,
        controllerAPIProfile: String,
        macOSVersion: String,
        architecture: String = "arm64"
    ) {
        self.velaVersion = velaVersion
        self.velaBuild = velaBuild
        self.helperProtocol = helperProtocol
        self.dataSchema = dataSchema
        self.controllerAPIProfile = controllerAPIProfile
        self.macOSVersion = macOSVersion
        self.architecture = architecture
    }
}

nonisolated enum CoreCompatibilityEvaluator {
    static func validate(
        _ constraints: CoreCompatibilityConstraints,
        against environment: CoreCompatibilityEnvironment
    ) throws {
        if try incompatibilityReason(constraints, against: environment) != nil {
            throw InstalledCorePreflightError.incompatible
        }
    }

    static func incompatibilityReason(
        _ constraints: CoreCompatibilityConstraints,
        against environment: CoreCompatibilityEnvironment
    ) throws -> String? {
        try constraints.validate()
        if compareVersions(environment.velaVersion, constraints.minimumVelaVersion)
            == .orderedAscending
        {
            return "Requires Vela \(constraints.minimumVelaVersion) or later."
        }
        if environment.velaBuild < constraints.minimumVelaBuild {
            return "Requires Vela build \(constraints.minimumVelaBuild) or later."
        }
        if let maximum = constraints.maximumVelaBuild, environment.velaBuild > maximum {
            return "Supports Vela builds through \(maximum)."
        }
        if !(constraints.helperProtocolMinimum ... constraints.helperProtocolMaximum)
            .contains(environment.helperProtocol)
        {
            return "Requires Helper protocol \(constraints.helperProtocolMinimum)-\(constraints.helperProtocolMaximum)."
        }
        if !(constraints.dataSchemaMinimum ... constraints.dataSchemaMaximum)
            .contains(environment.dataSchema)
        {
            return "Requires data schema \(constraints.dataSchemaMinimum)-\(constraints.dataSchemaMaximum)."
        }
        if environment.controllerAPIProfile != constraints.controllerAPIProfile {
            return "Requires Controller API profile \(constraints.controllerAPIProfile)."
        }
        if compareVersions(environment.macOSVersion, constraints.minimumMacOS) == .orderedAscending {
            return "Requires macOS \(constraints.minimumMacOS) or later."
        }
        if !constraints.architectures.contains(environment.architecture) {
            return "Requires architecture \(constraints.architectures.joined(separator: ", "))."
        }
        return nil
    }

    private static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        guard let left = numericComponents(lhs),
            let right = numericComponents(rhs)
        else {
            return .orderedAscending
        }
        let count = max(left.count, right.count)
        for index in 0 ..< count {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l < r { return .orderedAscending }
            if l > r { return .orderedDescending }
        }
        return .orderedSame
    }

    private static func numericComponents(_ value: String) -> [UInt64]? {
        let normalized = value.hasPrefix("v") ? String(value.dropFirst()) : value
        let components = normalized.split(separator: ".", omittingEmptySubsequences: false)
        guard !components.isEmpty else { return nil }
        var result: [UInt64] = []
        for component in components {
            guard let number = UInt64(component) else { return nil }
            result.append(number)
        }
        return result
    }
}

nonisolated enum CoreCompatibilityTestResult: String, Codable, Sendable {
    case passed
    case failed
}

nonisolated struct CoreCompatibilityTest: Codable, Equatable, Sendable {
    let id: String
    let result: CoreCompatibilityTestResult
}

nonisolated struct CoreCompatibilityReportEnvironment: Codable, Equatable, Sendable {
    let macOS: String
    let architecture: String
    let vela: String
    let hostClass: String
    let userDataAccessed: Bool
}

nonisolated struct CoreCompatibilityReportArtifacts: Codable, Equatable, Sendable {
    let upstreamPayloadSHA256: String
    let candidateExecutableSHA256: String
    let factoryExecutableSHA256: String
    let suiteSHA256: String
    let corpusSHA256: String
    let apiContractSHA256: String
    let dedicatedHostEvidenceSHA256: String?
    let performanceReviewSHA256: String?
}

nonisolated indirect enum CoreCompatibilityEvidenceValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([CoreCompatibilityEvidenceValue])
    case object([String: CoreCompatibilityEvidenceValue])

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            guard value.isFinite else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Compatibility evidence numbers must be finite."
                )
            }
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([CoreCompatibilityEvidenceValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode(
                [String: CoreCompatibilityEvidenceValue].self
            ))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case let .bool(value):
            try container.encode(value)
        case let .number(value):
            guard value.isFinite else {
                throw EncodingError.invalidValue(
                    value,
                    .init(
                        codingPath: encoder.codingPath,
                        debugDescription: "Compatibility evidence numbers must be finite."
                    )
                )
            }
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        }
    }

    var isObject: Bool {
        if case .object = self { return true }
        return false
    }
}

nonisolated struct CoreCompatibilityReport: Codable, Equatable, Sendable {
    static let requiredTestOrder: [String] = [
        "version", "config-corpus", "controller-api", "websockets",
        "user-backend", "system-proxy", "tun-backend", "sleep-network",
        "rollback", "performance", "artifact-integrity",
    ]
    static let requiredTests = Set(requiredTestOrder)
    private static let requiredEvidenceKeys: Set<String> = [
        "candidateVersion", "factoryVersion", "configCorpus", "controllerAPI",
        "webSockets", "userBackend", "dedicatedHost", "rollback", "performance",
    ]
    private static let requiredMetricKeys: Set<String> = ["candidate", "factory", "ratios"]

    let schemaVersion: Int
    let suiteVersion: UInt64
    let coreID: CoreID
    let result: CoreCompatibilityTestResult
    let generatedAt: Date
    let environment: CoreCompatibilityReportEnvironment
    let tests: [CoreCompatibilityTest]
    let knownDeviations: [String]
    let evidenceVersion: Int
    let artifacts: CoreCompatibilityReportArtifacts
    let evidence: [String: CoreCompatibilityEvidenceValue]
    let metrics: [String: CoreCompatibilityEvidenceValue]

    func validate(entry: CoreCatalogEntry, executableSHA256: String) throws {
        let artifactHashes = [
            artifacts.upstreamPayloadSHA256,
            artifacts.candidateExecutableSHA256,
            artifacts.factoryExecutableSHA256,
            artifacts.suiteSHA256,
            artifacts.corpusSHA256,
            artifacts.apiContractSHA256,
        ]
        guard schemaVersion == 1,
            suiteVersion == entry.vela.compatibilitySuiteVersion,
            coreID == entry.coreID,
            result == .passed,
            tests.map(\.id) == Self.requiredTestOrder,
            tests.allSatisfy({ $0.result == .passed }),
            environment.architecture == "arm64",
            environment.hostClass == "dedicated-release-lab",
            environment.userDataAccessed == false,
            knownDeviations.isEmpty,
            evidenceVersion == 1,
            Set(evidence.keys) == Self.requiredEvidenceKeys,
            evidence.values.allSatisfy(\.isObject),
            Set(metrics.keys) == Self.requiredMetricKeys,
            metrics.values.allSatisfy(\.isObject),
            artifactHashes.allSatisfy(Self.isSHA256),
            artifacts.dedicatedHostEvidenceSHA256.map(Self.isSHA256) == true,
            artifacts.performanceReviewSHA256.map(Self.isSHA256) == true,
            entry.files.first(where: { $0.role == .executable })?.sha256
                == executableSHA256,
            artifacts.candidateExecutableSHA256 == artifacts.upstreamPayloadSHA256,
            artifacts.candidateExecutableSHA256 != artifacts.factoryExecutableSHA256
        else {
            throw InstalledCorePreflightError.invalidCompatibilityReport
        }
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48 ... 57).contains($0) || (97 ... 102).contains($0)
        }
    }
}

nonisolated struct CoreBundleIntegritySnapshot: Equatable, Sendable {
    let fileSHA256: [CoreFileRole: String]
    let fileSizes: [CoreFileRole: UInt64]
}

nonisolated struct CoreBundleIntegrityVerifier: Sendable {
    private let expectedOwner: uid_t

    init(expectedOwner: uid_t = getuid()) {
        self.expectedOwner = expectedOwner
    }

    func verify(bundleURL: URL, entry: CoreCatalogEntry) throws -> CoreBundleIntegritySnapshot {
        try entry.validate()
        let root = bundleURL.standardizedFileURL
        let rootMetadata = try inspect(root)
        guard rootMetadata.kind == .directory,
            rootMetadata.owner == expectedOwner,
            rootMetadata.mode & 0o022 == 0
        else {
            throw InstalledCorePreflightError.unsafeBundleRoot
        }

        let requiredDirectories: Set<String> = [
            "Contents", "Contents/MacOS", "Contents/_CodeSignature", "Contents/Resources",
        ]
        let requiredFiles = Set(entry.files.map(\.relativePath))
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [],
            errorHandler: { _, _ in false }
        ) else {
            throw InstalledCorePreflightError.bundleEnumerationFailed
        }
        var seenDirectories: Set<String> = []
        var seenFiles: Set<String> = []
        let rootComponents = root.pathComponents
        for case let item as URL in enumerator {
            let itemComponents = item.standardizedFileURL.pathComponents
            guard itemComponents.count > rootComponents.count,
                Array(itemComponents.prefix(rootComponents.count)) == rootComponents
            else {
                throw InstalledCorePreflightError.unexpectedBundleItem(item.lastPathComponent)
            }
            let relative = itemComponents.dropFirst(rootComponents.count).joined(separator: "/")
            let metadata = try inspect(item)
            switch metadata.kind {
            case .symbolicLink:
                throw InstalledCorePreflightError.symbolicLink(relative)
            case .directory:
                guard requiredDirectories.contains(relative),
                    metadata.owner == expectedOwner,
                    metadata.mode & 0o022 == 0
                else {
                    throw InstalledCorePreflightError.unexpectedBundleItem(relative)
                }
                seenDirectories.insert(relative)
            case .regular:
                guard requiredFiles.contains(relative) else {
                    throw InstalledCorePreflightError.unexpectedBundleItem(relative)
                }
                seenFiles.insert(relative)
            case .other:
                throw InstalledCorePreflightError.unexpectedBundleItem(relative)
            }
        }
        guard seenDirectories == requiredDirectories, seenFiles == requiredFiles else {
            throw InstalledCorePreflightError.missingBundleItem
        }

        var hashes: [CoreFileRole: String] = [:]
        var sizes: [CoreFileRole: UInt64] = [:]
        for descriptor in entry.files {
            let url = root.appending(path: descriptor.role.requiredRelativePath)
            let before = try inspect(url)
            guard before.kind == .regular,
                before.owner == expectedOwner,
                before.mode == descriptor.role.requiredPOSIXMode,
                before.size == descriptor.size
            else {
                throw InstalledCorePreflightError.fileMetadataMismatch(descriptor.role)
            }
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            let after = try inspect(url)
            guard before == after, UInt64(data.count) == descriptor.size else {
                throw InstalledCorePreflightError.fileChangedDuringRead(descriptor.role)
            }
            let hash = CoreCatalogVerifier.sha256(data)
            guard hash == descriptor.sha256 else {
                throw InstalledCorePreflightError.fileHashMismatch(descriptor.role)
            }
            hashes[descriptor.role] = hash
            sizes[descriptor.role] = descriptor.size
        }
        return CoreBundleIntegritySnapshot(fileSHA256: hashes, fileSizes: sizes)
    }

    private func inspect(_ url: URL) throws -> Metadata {
        var status = stat()
        let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.lstat(path, &status)
        }
        guard result == 0 else { throw InstalledCorePreflightError.bundleItemInspectionFailed }
        let kind: Metadata.Kind = switch status.st_mode & mode_t(S_IFMT) {
        case mode_t(S_IFREG): .regular
        case mode_t(S_IFDIR): .directory
        case mode_t(S_IFLNK): .symbolicLink
        default: .other
        }
        return Metadata(
            kind: kind,
            owner: status.st_uid,
            mode: Int(status.st_mode & 0o7777),
            size: UInt64(max(status.st_size, 0)),
            device: UInt64(status.st_dev),
            inode: UInt64(status.st_ino),
            modifiedSeconds: Int64(status.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(status.st_mtimespec.tv_nsec)
        )
    }

    private struct Metadata: Equatable {
        enum Kind: Equatable { case regular, directory, symbolicLink, other }
        let kind: Kind
        let owner: uid_t
        let mode: Int
        let size: UInt64
        let device: UInt64
        let inode: UInt64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
    }
}

nonisolated struct CoreBundleSignatureSnapshot: Equatable, Sendable {
    let application: CodeSignatureSnapshot
    let coreBundle: CodeSignatureSnapshot
}

nonisolated struct CoreBundleInfoSnapshot: Equatable, Sendable {
    let bundleIdentifier: String
    let bundleName: String
    let bundlePackageType: String
    let bundleExecutable: String
    let bundleShortVersion: String
    let bundleVersion: String
    let minimumSystemVersion: String
    let coreVersion: String
    let corePackageRevision: Int
    let coreArchitecture: String
}

nonisolated struct CoreBundleInfoVerifier: Sendable {
    private static let allowedKeys: Set<String> = [
        "CFBundleIdentifier",
        "CFBundleName",
        "CFBundlePackageType",
        "CFBundleExecutable",
        "CFBundleShortVersionString",
        "CFBundleVersion",
        "LSMinimumSystemVersion",
        "VelaCoreVersion",
        "VelaCorePackageRevision",
        "VelaCoreArchitecture",
    ]

    func verify(bundleURL: URL, entry: CoreCatalogEntry) throws -> CoreBundleInfoSnapshot {
        let infoURL = bundleURL.appending(path: CoreFileRole.infoPlist.requiredRelativePath)
        let data: Data
        do {
            data = try Data(contentsOf: infoURL, options: [.mappedIfSafe])
        } catch {
            throw InstalledCorePreflightError.invalidInfoPlist
        }

        do {
            var format = PropertyListSerialization.PropertyListFormat.xml
            let object = try PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: &format
            )
            guard let dictionary = object as? [String: Any],
                Set(dictionary.keys) == Self.allowedKeys
            else {
                throw InstalledCorePreflightError.invalidInfoPlist
            }
            let info = try PropertyListDecoder().decode(CoreBundleInfo.self, from: data)
            guard info.bundleIdentifier == VelaIPCConstants.expectedExternalCoreSigningIdentifier else {
                throw InstalledCorePreflightError.bundleIdentifierMismatch
            }
            guard info.bundleName == "Vela Mihomo Core",
                info.bundlePackageType == "BNDL",
                info.bundleExecutable == "mihomo",
                info.bundleShortVersion == String(entry.upstreamVersion.dropFirst()),
                info.bundleVersion == String(entry.packageRevision),
                info.minimumSystemVersion == "15.0",
                info.coreVersion == entry.upstreamVersion,
                info.corePackageRevision == Int(exactly: entry.packageRevision),
                info.coreArchitecture == "arm64"
            else {
                throw InstalledCorePreflightError.invalidInfoPlist
            }
            return CoreBundleInfoSnapshot(
                bundleIdentifier: info.bundleIdentifier,
                bundleName: info.bundleName,
                bundlePackageType: info.bundlePackageType,
                bundleExecutable: info.bundleExecutable,
                bundleShortVersion: info.bundleShortVersion,
                bundleVersion: info.bundleVersion,
                minimumSystemVersion: info.minimumSystemVersion,
                coreVersion: info.coreVersion,
                corePackageRevision: info.corePackageRevision,
                coreArchitecture: info.coreArchitecture
            )
        } catch let error as InstalledCorePreflightError {
            throw error
        } catch {
            throw InstalledCorePreflightError.invalidInfoPlist
        }
    }

    private struct CoreBundleInfo: Decodable {
        let bundleIdentifier: String
        let bundleName: String
        let bundlePackageType: String
        let bundleExecutable: String
        let bundleShortVersion: String
        let bundleVersion: String
        let minimumSystemVersion: String
        let coreVersion: String
        let corePackageRevision: Int
        let coreArchitecture: String

        enum CodingKeys: String, CodingKey {
            case bundleIdentifier = "CFBundleIdentifier"
            case bundleName = "CFBundleName"
            case bundlePackageType = "CFBundlePackageType"
            case bundleExecutable = "CFBundleExecutable"
            case bundleShortVersion = "CFBundleShortVersionString"
            case bundleVersion = "CFBundleVersion"
            case minimumSystemVersion = "LSMinimumSystemVersion"
            case coreVersion = "VelaCoreVersion"
            case corePackageRevision = "VelaCorePackageRevision"
            case coreArchitecture = "VelaCoreArchitecture"
        }
    }
}

nonisolated protocol CoreBundleSignatureVerifying: Sendable {
    func verify(
        applicationURL: URL,
        coreBundleURL: URL,
        teamPolicy: CodeSignatureTeamPolicy
    ) throws -> CoreBundleSignatureSnapshot
}

nonisolated struct CoreBundleSignatureVerifier: CoreBundleSignatureVerifying, Sendable {
    private let inspector: any CodeSignatureInspecting

    init(inspector: any CodeSignatureInspecting = SecurityFrameworkCodeSignatureInspector()) {
        self.inspector = inspector
    }

    func verify(
        applicationURL: URL,
        coreBundleURL: URL,
        teamPolicy: CodeSignatureTeamPolicy
    ) throws -> CoreBundleSignatureSnapshot {
        // Read the running app's signed identity first, then bind both the app
        // and external Core to an Apple-generic designated requirement. The
        // Debug ad-hoc policy is deliberately not honored for external code;
        // ad-hoc remains a Factory/test-only convenience.
        let initialApplication = try inspector.inspectCode(
            at: applicationURL,
            validateNestedCode: false
        )
        guard initialApplication.signingIdentifier == VelaIPCConstants.mainBundleIdentifier else {
            throw InstalledCorePreflightError.bundleIdentifierMismatch
        }
        guard let expectedTeam = initialApplication.teamIdentifier,
            !expectedTeam.isEmpty
        else { throw InstalledCorePreflightError.teamIdentifierMismatch }

        let applicationRequirement: CodeSignatureRequirement
        let coreRequirement: CodeSignatureRequirement
        do {
            applicationRequirement = try .appleGeneric(
                identifier: VelaIPCConstants.mainBundleIdentifier,
                teamIdentifier: expectedTeam
            )
            coreRequirement = try .appleGeneric(
                identifier: VelaIPCConstants.expectedExternalCoreSigningIdentifier,
                teamIdentifier: expectedTeam
            )
        } catch {
            throw InstalledCorePreflightError.teamIdentifierMismatch
        }
        let application = try inspector.inspectCode(
            at: applicationURL,
            validateNestedCode: false,
            requirement: applicationRequirement
        )
        let core = try inspector.inspectCode(
            at: coreBundleURL,
            validateNestedCode: true,
            requirement: coreRequirement
        )
        guard application.signingIdentifier == VelaIPCConstants.mainBundleIdentifier else {
            throw InstalledCorePreflightError.bundleIdentifierMismatch
        }
        guard core.signingIdentifier == VelaIPCConstants.expectedExternalCoreSigningIdentifier else {
            throw InstalledCorePreflightError.bundleIdentifierMismatch
        }
        guard application.teamIdentifier == expectedTeam,
            core.teamIdentifier == expectedTeam
        else {
            throw InstalledCorePreflightError.teamIdentifierMismatch
        }
        _ = teamPolicy // Both policies intentionally enforce the same external-Core anchor.
        return CoreBundleSignatureSnapshot(application: application, coreBundle: core)
    }
}

nonisolated struct CoreSmokeTestRequest: Equatable, Sendable {
    let descriptor: CoreDescriptor
    let executable: ResolvedMihomoExecutable
    let configurationURL: URL
    let temporaryHomeURL: URL
    let controllerAPIProfile: String
    let controllerEndpoint: URL
    let controllerSecret: String
}

nonisolated struct CoreSmokeTestResult: Equatable, Sendable {
    let controllerAPIProfile: String
    let started: Bool
    let controllerResponded: Bool
    let stoppedCleanly: Bool

    var passed: Bool { started && controllerResponded && stoppedCleanly }
}

nonisolated protocol CoreSmokeTesting: Sendable {
    func run(_ request: CoreSmokeTestRequest) async throws -> CoreSmokeTestResult
}

nonisolated struct FailClosedCoreSmokeTester: CoreSmokeTesting, Sendable {
    func run(_: CoreSmokeTestRequest) async throws -> CoreSmokeTestResult {
        throw InstalledCorePreflightError.smokeHarnessUnavailable
    }
}

nonisolated struct InstalledCorePreflightRequest: Equatable, Sendable {
    let descriptor: CoreDescriptor
    let catalogEntry: CoreCatalogEntry
    let applicationBundleURL: URL
    let signatureTeamPolicy: CodeSignatureTeamPolicy
    let compatibilityEnvironment: CoreCompatibilityEnvironment
    let configurationURL: URL
    let temporaryHomeURL: URL
    let controllerEndpoint: URL
    let controllerSecret: String
}

nonisolated struct InstalledCorePreflightResult: Equatable, Sendable {
    let descriptor: CoreDescriptor
    let integrity: CoreBundleIntegritySnapshot
    let signature: CoreBundleSignatureSnapshot
    let architecture: MachOInspection
    let version: MihomoVersionIdentity
    let configuration: ConfigurationValidationResult
    let compatibilityReport: CoreCompatibilityReport
    let smoke: CoreSmokeTestResult
    let executable: ResolvedMihomoExecutable
}

nonisolated protocol InstalledCorePreflighting: Sendable {
    func run(_ request: InstalledCorePreflightRequest) async throws -> InstalledCorePreflightResult
}

/// Adapter used by ActiveCoreResolver. The request provider is invoked on every
/// resolve, so a fresh active config, random smoke endpoint/secret and current
/// compatibility environment are used instead of caching a preflight result.
actor InstalledCoreExecutableResolver: MihomoExecutableResolving {
    typealias RequestProvider = @Sendable () async throws -> InstalledCorePreflightRequest

    private let preflight: any InstalledCorePreflighting
    private let requestProvider: RequestProvider

    init(
        preflight: any InstalledCorePreflighting = InstalledCorePreflight(),
        requestProvider: @escaping RequestProvider
    ) {
        self.preflight = preflight
        self.requestProvider = requestProvider
    }

    func resolve() async throws -> ResolvedMihomoExecutable {
        let request = try await requestProvider()
        return try await preflight.run(request).executable
    }
}

nonisolated struct InstalledCorePreflight: InstalledCorePreflighting, Sendable {
    private let integrityVerifier: CoreBundleIntegrityVerifier
    private let signatureVerifier: any CoreBundleSignatureVerifying
    private let architectureInspector: any MachOArchitectureInspecting
    private let versionProbe: any MihomoVersionProbing
    private let configurationValidator: any ConfigurationValidating
    private let smokeTester: any CoreSmokeTesting

    init(
        integrityVerifier: CoreBundleIntegrityVerifier = CoreBundleIntegrityVerifier(),
        signatureVerifier: any CoreBundleSignatureVerifying = CoreBundleSignatureVerifier(),
        architectureInspector: any MachOArchitectureInspecting = MachOArchitectureInspector(),
        versionProbe: any MihomoVersionProbing = MihomoVersionProbe(),
        configurationValidator: any ConfigurationValidating = ConfigurationValidator(),
        smokeTester: any CoreSmokeTesting = FailClosedCoreSmokeTester()
    ) {
        self.integrityVerifier = integrityVerifier
        self.signatureVerifier = signatureVerifier
        self.architectureInspector = architectureInspector
        self.versionProbe = versionProbe
        self.configurationValidator = configurationValidator
        self.smokeTester = smokeTester
    }

    func run(_ request: InstalledCorePreflightRequest) async throws -> InstalledCorePreflightResult {
        let descriptor = request.descriptor
        let entry = request.catalogEntry
        guard descriptor.source == .user,
            !descriptor.coreID.isFactory,
            descriptor.coreID == entry.coreID,
            descriptor.upstreamVersion == entry.upstreamVersion,
            descriptor.packageRevision == Int(exactly: entry.packageRevision)
        else {
            throw InstalledCorePreflightError.descriptorMismatch
        }
        try CoreCompatibilityEvaluator.validate(
            entry.vela,
            against: request.compatibilityEnvironment
        )
        let integrity = try integrityVerifier.verify(bundleURL: descriptor.bundleURL, entry: entry)
        _ = try CoreBundleInfoVerifier().verify(bundleURL: descriptor.bundleURL, entry: entry)
        let signature = try signatureVerifier.verify(
            applicationURL: request.applicationBundleURL,
            coreBundleURL: descriptor.bundleURL,
            teamPolicy: request.signatureTeamPolicy
        )
        let architecture: MachOInspection
        do {
            architecture = try architectureInspector.inspect(executableAt: descriptor.executableURL)
        } catch let error as MachOArchitectureInspectionError {
            throw InstalledCorePreflightError.architecture(error)
        }
        let version: MihomoVersionIdentity
        do {
            version = try await versionProbe.probe(
                executableAt: descriptor.executableURL,
                expected: MihomoVersionExpectation(
                    version: entry.upstreamVersion,
                    platform: "darwin",
                    architecture: "arm64"
                ),
                currentDirectoryURL: request.temporaryHomeURL
            )
        } catch let error as MihomoVersionProbeError {
            throw InstalledCorePreflightError.version(error)
        }
        let executableSHA = integrity.fileSHA256[.executable] ?? ""
        let verifiedFileForChecks: MihomoCoreFileSnapshot
        do {
            verifiedFileForChecks = try POSIXMihomoCoreFileInspector().inspectExecutable(
                at: descriptor.executableURL
            )
        } catch {
            throw InstalledCorePreflightError.coreChangedDuringPreflight
        }
        let executableForConfiguration = ResolvedMihomoExecutable(
            url: descriptor.executableURL,
            version: version.rawOutput,
            sha256: executableSHA,
            verifiedFile: verifiedFileForChecks
        )
        let configuration = await configurationValidator.validate(
            configurationURL: request.configurationURL,
            dataDirectoryURL: request.temporaryHomeURL,
            using: executableForConfiguration,
            timeout: .seconds(10)
        )
        guard configuration.isValid else {
            throw InstalledCorePreflightError.configurationRejected
        }
        let reportData = try Data(
            contentsOf: descriptor.bundleURL.appending(path: CoreFileRole.compatibility.requiredRelativePath)
        )
        guard CoreCatalogVerifier.sha256(reportData) == entry.vela.compatibilityReportSHA256 else {
            throw InstalledCorePreflightError.compatibilityReportHashMismatch
        }
        let report = try Self.decodeCompatibilityReport(reportData)
        try report.validate(entry: entry, executableSHA256: executableSHA)
        let smoke = try await smokeTester.run(
            CoreSmokeTestRequest(
                descriptor: descriptor,
                executable: executableForConfiguration,
                configurationURL: request.configurationURL,
                temporaryHomeURL: request.temporaryHomeURL,
                controllerAPIProfile: entry.vela.controllerAPIProfile,
                controllerEndpoint: request.controllerEndpoint,
                controllerSecret: request.controllerSecret
            )
        )
        guard smoke.passed,
            smoke.controllerAPIProfile == entry.vela.controllerAPIProfile
        else {
            throw InstalledCorePreflightError.smokeFailed
        }

        let finalIntegrity = try integrityVerifier.verify(bundleURL: descriptor.bundleURL, entry: entry)
        _ = try CoreBundleInfoVerifier().verify(bundleURL: descriptor.bundleURL, entry: entry)
        let finalSignature = try signatureVerifier.verify(
            applicationURL: request.applicationBundleURL,
            coreBundleURL: descriptor.bundleURL,
            teamPolicy: request.signatureTeamPolicy
        )
        guard finalIntegrity == integrity, finalSignature == signature else {
            throw InstalledCorePreflightError.coreChangedDuringPreflight
        }
        let verifiedFile: MihomoCoreFileSnapshot
        do {
            verifiedFile = try POSIXMihomoCoreFileInspector().inspectExecutable(
                at: descriptor.executableURL
            )
        } catch {
            throw InstalledCorePreflightError.coreChangedDuringPreflight
        }
        guard verifiedFile == verifiedFileForChecks else {
            throw InstalledCorePreflightError.coreChangedDuringPreflight
        }
        let executable = ResolvedMihomoExecutable(
            url: descriptor.executableURL,
            version: version.rawOutput,
            sha256: executableSHA,
            verifiedFile: verifiedFile,
            verificationEvidence: MihomoExecutableVerificationEvidence(
                teamIdentifier: finalSignature.coreBundle.teamIdentifier,
                signingIdentifier: finalSignature.coreBundle.signingIdentifier,
                architecture: architecture.architecture.rawValue,
                versionOutput: version.rawOutput,
                configurationPassed: configuration.isValid,
                compatibilityReportSHA256: entry.vela.compatibilityReportSHA256,
                controllerSmokePassed: smoke.passed
            )
        )
        return InstalledCorePreflightResult(
            descriptor: descriptor,
            integrity: integrity,
            signature: signature,
            architecture: architecture,
            version: version,
            configuration: configuration,
            compatibilityReport: report,
            smoke: smoke,
            executable: executable
        )
    }

    private static func decodeCompatibilityReport(_ data: Data) throws -> CoreCompatibilityReport {
        let environment = CoreJSONShape(
            allowedKeys: [
                "macOS", "architecture", "vela", "hostClass", "userDataAccessed",
            ]
        )
        let test = CoreJSONShape(allowedKeys: ["id", "result"])
        let artifacts = CoreJSONShape(
            allowedKeys: [
                "upstreamPayloadSHA256", "candidateExecutableSHA256",
                "factoryExecutableSHA256", "suiteSHA256",
                "corpusSHA256", "apiContractSHA256", "dedicatedHostEvidenceSHA256",
                "performanceReviewSHA256",
            ]
        )
        let evidence = CoreJSONShape(
            allowedKeys: [
                "candidateVersion", "factoryVersion", "configCorpus", "controllerAPI",
                "webSockets", "userBackend", "dedicatedHost", "rollback", "performance",
            ]
        )
        let metrics = CoreJSONShape(allowedKeys: ["candidate", "factory", "ratios"])
        let shape = CoreJSONShape(
            allowedKeys: [
                "schemaVersion", "suiteVersion", "coreID", "result", "generatedAt",
                "environment", "tests", "knownDeviations", "evidenceVersion",
                "artifacts", "evidence", "metrics",
            ],
            objects: [
                "environment": environment,
                "artifacts": artifacts,
                "evidence": evidence,
                "metrics": metrics,
            ],
            arrays: ["tests": test]
        )
        do {
            try CoreStrictJSON.validateObject(data, shape: shape)
            return try CoreJSONCoding.decoder().decode(CoreCompatibilityReport.self, from: data)
        } catch {
            throw InstalledCorePreflightError.invalidCompatibilityReport
        }
    }
}

nonisolated enum InstalledCorePreflightError: Error, Equatable, Sendable {
    case descriptorMismatch
    case incompatible
    case unsafeBundleRoot
    case bundleEnumerationFailed
    case bundleItemInspectionFailed
    case symbolicLink(String)
    case unexpectedBundleItem(String)
    case missingBundleItem
    case fileMetadataMismatch(CoreFileRole)
    case fileChangedDuringRead(CoreFileRole)
    case fileHashMismatch(CoreFileRole)
    case invalidInfoPlist
    case bundleIdentifierMismatch
    case teamIdentifierMismatch
    case architecture(MachOArchitectureInspectionError)
    case version(MihomoVersionProbeError)
    case configurationRejected
    case compatibilityReportHashMismatch
    case invalidCompatibilityReport
    case smokeHarnessUnavailable
    case smokeFailed
    case coreChangedDuringPreflight
}
