import Foundation

nonisolated struct CompatibilityMatrix: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    static let maximumEncodedBytes = 1 * 1_024 * 1_024

    let schemaVersion: Int
    let releases: [CompatibleRelease]

    var latestStableBuild: Int? {
        releases.lazy
            .filter { $0.channel == .stable }
            .map(\.appBuild)
            .max()
    }

    func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw CompatibilityMatrixValidationError.unsupportedSchema(schemaVersion)
        }
        guard !releases.isEmpty else {
            throw CompatibilityMatrixValidationError.empty
        }
        var builds = Set<Int>()
        for release in releases {
            guard release.appBuild > 0 else {
                throw CompatibilityMatrixValidationError.invalidBuild(release.appBuild)
            }
            guard builds.insert(release.appBuild).inserted else {
                throw CompatibilityMatrixValidationError.duplicateBuild(release.appBuild)
            }
            guard release.helperProtocol.isValid else {
                throw CompatibilityMatrixValidationError.invalidProtocolRange(
                    build: release.appBuild,
                    name: "helper"
                )
            }
            for (name, range) in [
                ("automation", release.automationProtocol),
                ("cli", release.cliProtocol),
            ] where range?.isValid == false {
                throw CompatibilityMatrixValidationError.invalidProtocolRange(
                    build: release.appBuild,
                    name: name
                )
            }
            guard release.dataSchema > 0,
                release.profileSchema > 0,
                release.configurationSchema > 0,
                release.sceneSchema.map({ $0 > 0 }) ?? true
            else {
                throw CompatibilityMatrixValidationError.invalidSchemaVersion(
                    build: release.appBuild
                )
            }
            guard !release.mihomo.isEmpty, !release.sparkle.isEmpty else {
                throw CompatibilityMatrixValidationError.missingComponentVersion(
                    build: release.appBuild
                )
            }
        }
    }
}
nonisolated struct CompatibleRelease: Codable, Equatable, Sendable {
    let appBuild: Int
    let channel: ReleaseChannel
    let helperProtocol: ProtocolCompatibilityRange
    let automationProtocol: ProtocolCompatibilityRange?
    let cliProtocol: ProtocolCompatibilityRange?
    let dataSchema: Int
    let profileSchema: Int
    let configurationSchema: Int
    let sceneSchema: Int?
    let mihomo: String
    let sparkle: String
}

nonisolated enum ReleaseCompatibilityIssue: Error, Equatable, Sendable {
    case helperProtocolDoesNotOverlap(
        app: ProtocolCompatibilityRange,
        helper: ProtocolCompatibilityRange
    )
    case dataSchemaTooNew(actual: Int, maximum: Int)
    case profileSchemaTooNew(actual: Int, maximum: Int)
    case configurationSchemaTooNew(actual: Int, maximum: Int)
    case unsupportedSceneSchema(Int)
    case mihomoVersionMismatch(expected: String, actual: String)
    case sparkleVersionMismatch(expected: String, actual: String)
    case architectureMismatch(expected: [String], actual: [String])
}

nonisolated struct ReleaseCompatibilityReport: Equatable, Sendable {
    let issues: [ReleaseCompatibilityIssue]

    var isCompatible: Bool { issues.isEmpty }
}

nonisolated enum ReleaseCompatibility {
    static func evaluate(
        _ manifest: ReleaseManifest,
        requirements: ReleaseCompatibilityRequirements = .current
    ) -> ReleaseCompatibilityReport {
        var issues: [ReleaseCompatibilityIssue] = []
        if !manifest.protocols.helper.overlaps(requirements.helperProtocol) {
            issues.append(.helperProtocolDoesNotOverlap(
                app: requirements.helperProtocol,
                helper: manifest.protocols.helper
            ))
        }
        if manifest.schemas.data > requirements.dataSchema {
            issues.append(.dataSchemaTooNew(
                actual: manifest.schemas.data,
                maximum: requirements.dataSchema
            ))
        }
        if manifest.schemas.profiles > requirements.profileSchema {
            issues.append(.profileSchemaTooNew(
                actual: manifest.schemas.profiles,
                maximum: requirements.profileSchema
            ))
        }
        if manifest.schemas.configuration > requirements.configurationSchema {
            issues.append(.configurationSchemaTooNew(
                actual: manifest.schemas.configuration,
                maximum: requirements.configurationSchema
            ))
        }
        if requirements.sceneSchema == nil, let scene = manifest.schemas.scene {
            issues.append(.unsupportedSceneSchema(scene))
        } else if let maximum = requirements.sceneSchema,
            let scene = manifest.schemas.scene,
            scene > maximum
        {
            issues.append(.unsupportedSceneSchema(scene))
        }
        if manifest.components.mihomo != requirements.mihomoVersion {
            issues.append(.mihomoVersionMismatch(
                expected: requirements.mihomoVersion,
                actual: manifest.components.mihomo
            ))
        }
        if manifest.components.sparkle != requirements.sparkleVersion {
            issues.append(.sparkleVersionMismatch(
                expected: requirements.sparkleVersion,
                actual: manifest.components.sparkle
            ))
        }
        if manifest.platform.architectures != requirements.architectures {
            issues.append(.architectureMismatch(
                expected: requirements.architectures,
                actual: manifest.platform.architectures
            ))
        }
        return ReleaseCompatibilityReport(issues: issues)
    }

    static func evaluate(
        helperRange: ProtocolCompatibilityRange,
        appRange: ProtocolCompatibilityRange = .init(
            min: ReleaseCompatibilityRequirements.current.helperProtocol.min,
            max: ReleaseCompatibilityRequirements.current.helperProtocol.max
        )
    ) -> ReleaseCompatibilityReport {
        guard helperRange.overlaps(appRange) else {
            return ReleaseCompatibilityReport(issues: [
                .helperProtocolDoesNotOverlap(app: appRange, helper: helperRange),
            ])
        }
        return ReleaseCompatibilityReport(issues: [])
    }
}

nonisolated struct CompatibilityMatrixReader: Sendable {
    private let fileSystem: any FileSystemProviding
    private let maximumBytes: Int

    init(
        fileSystem: any FileSystemProviding = LiveFileSystem(),
        maximumBytes: Int = CompatibilityMatrix.maximumEncodedBytes
    ) {
        self.fileSystem = fileSystem
        self.maximumBytes = max(1, maximumBytes)
    }

    func read(from url: URL) throws -> CompatibilityMatrix {
        guard fileSystem.fileExists(at: url) else {
            throw CompatibilityMatrixReaderError.missing
        }
        let data: Data
        do {
            data = try fileSystem.readData(at: url)
        } catch {
            throw CompatibilityMatrixReaderError.readFailed
        }
        guard data.count <= maximumBytes else {
            throw CompatibilityMatrixReaderError.tooLarge
        }
        do {
            try StrictJSONValidator.validateObject(data, shape: Self.matrixShape)
        } catch let error as StrictJSONValidationError {
            throw CompatibilityMatrixReaderError.invalidStructure(error)
        } catch {
            throw CompatibilityMatrixReaderError.invalidStructure(.invalidJSON)
        }
        let matrix: CompatibilityMatrix
        do {
            matrix = try UpdateJSONCoding.decoder().decode(
                CompatibilityMatrix.self,
                from: data
            )
        } catch {
            throw CompatibilityMatrixReaderError.decodeFailed
        }
        do {
            try matrix.validate()
        } catch let error as CompatibilityMatrixValidationError {
            throw CompatibilityMatrixReaderError.validationFailed(error)
        }
        return matrix
    }

    private static let matrixShape = StrictJSONShape(
        allowedKeys: ["schemaVersion", "releases"],
        arrays: [
            "releases": StrictJSONShape(
                allowedKeys: [
                    "appBuild", "channel", "helperProtocol", "automationProtocol",
                    "cliProtocol", "dataSchema", "profileSchema",
                    "configurationSchema", "sceneSchema", "mihomo", "sparkle",
                ],
                objects: [
                    "helperProtocol": StrictJSONShape(allowedKeys: ["min", "max"]),
                    "automationProtocol": StrictJSONShape(allowedKeys: ["min", "max"]),
                    "cliProtocol": StrictJSONShape(allowedKeys: ["min", "max"]),
                ]
            ),
        ]
    )
}

nonisolated enum CompatibilityMatrixValidationError: Error, Equatable, Sendable {
    case unsupportedSchema(Int)
    case empty
    case invalidBuild(Int)
    case duplicateBuild(Int)
    case invalidProtocolRange(build: Int, name: String)
    case invalidSchemaVersion(build: Int)
    case missingComponentVersion(build: Int)
}

nonisolated enum CompatibilityMatrixReaderError: Error, Equatable, Sendable {
    case missing
    case readFailed
    case tooLarge
    case invalidStructure(StrictJSONValidationError)
    case decodeFailed
    case validationFailed(CompatibilityMatrixValidationError)
}
