import Foundation

nonisolated protocol BuildManifestReading: Sendable {
    func read(
        from url: URL,
        expectedBuildIdentity: ReleaseBuildIdentity?,
        validateCurrentRelease: Bool
    ) throws -> ReleaseManifest
}
nonisolated struct BuildManifestReader: BuildManifestReading, Sendable {
    static let bundledResourceName = "VelaReleaseManifest"
    static let bundledResourceExtension = "json"

    private let fileSystem: any FileSystemProviding
    private let maximumBytes: Int
    private let requirements: ReleaseCompatibilityRequirements

    init(
        fileSystem: any FileSystemProviding = LiveFileSystem(),
        maximumBytes: Int = ReleaseManifest.maximumEncodedBytes,
        requirements: ReleaseCompatibilityRequirements = .current
    ) {
        self.fileSystem = fileSystem
        self.maximumBytes = max(1, maximumBytes)
        self.requirements = requirements
    }

    func read(
        from url: URL,
        expectedBuildIdentity: ReleaseBuildIdentity? = nil,
        validateCurrentRelease: Bool = true
    ) throws -> ReleaseManifest {
        guard fileSystem.fileExists(at: url) else {
            throw BuildManifestReaderError.missing
        }

        let data: Data
        do {
            data = try fileSystem.readData(at: url)
        } catch {
            throw BuildManifestReaderError.readFailed
        }
        guard data.count <= maximumBytes else {
            throw BuildManifestReaderError.tooLarge(
                actual: data.count,
                maximum: maximumBytes
            )
        }

        do {
            try StrictJSONValidator.validateObject(data, shape: Self.manifestShape)
        } catch let error as StrictJSONValidationError {
            throw BuildManifestReaderError.invalidStructure(error)
        } catch {
            throw BuildManifestReaderError.invalidStructure(.invalidJSON)
        }

        let manifest: ReleaseManifest
        do {
            manifest = try UpdateJSONCoding.decoder().decode(
                ReleaseManifest.self,
                from: data
            )
        } catch {
            throw BuildManifestReaderError.decodeFailed
        }

        if validateCurrentRelease {
            do {
                try manifest.validateCurrentRelease(
                    expectedBuildIdentity: expectedBuildIdentity,
                    requirements: requirements
                )
            } catch let error as ReleaseManifestValidationError {
                throw BuildManifestReaderError.validationFailed(error)
            }
        }
        return manifest
    }

    func readBundled(
        from bundle: Bundle = .main,
        expectedBuildIdentity: ReleaseBuildIdentity? = nil,
        validateCurrentRelease: Bool = true
    ) throws -> ReleaseManifest {
        guard let url = bundle.url(
            forResource: Self.bundledResourceName,
            withExtension: Self.bundledResourceExtension
        ) else {
            throw BuildManifestReaderError.missing
        }
        return try read(
            from: url,
            expectedBuildIdentity: expectedBuildIdentity,
            validateCurrentRelease: validateCurrentRelease
        )
    }

    func compatibilityReport(for manifest: ReleaseManifest) -> ReleaseCompatibilityReport {
        ReleaseCompatibility.evaluate(manifest, requirements: requirements)
    }

    private static let manifestShape = StrictJSONShape(
        allowedKeys: [
            "schemaVersion", "app", "build", "platform", "components",
            "protocols", "schemas", "source", "toolchain",
        ],
        objects: [
            "app": StrictJSONShape(allowedKeys: [
                "version", "build", "channel", "prereleaseLabel", "bundleIdentifier",
            ]),
            "build": StrictJSONShape(allowedKeys: ["createdAtUTC", "sourceDirty"]),
            "platform": StrictJSONShape(allowedKeys: ["minimumMacOS", "architectures"]),
            "components": StrictJSONShape(allowedKeys: ["mihomo", "sparkle", "helper", "cli"]),
            "protocols": StrictJSONShape(allowedKeys: [
                "helperMinimum", "helperMaximum", "automationMinimum",
                "automationMaximum", "cliMinimum", "cliMaximum",
            ]),
            "schemas": StrictJSONShape(allowedKeys: [
                "data", "profiles", "configuration", "scene", "updateJournal",
            ]),
            "source": StrictJSONShape(allowedKeys: [
                "commit", "tag", "packageResolvedSHA256",
            ]),
            "toolchain": StrictJSONShape(allowedKeys: [
                "xcode", "swift", "sdk", "hostArchitecture",
            ]),
        ]
    )
}

nonisolated enum BuildManifestReaderError: Error, Equatable, Sendable {
    case missing
    case readFailed
    case tooLarge(actual: Int, maximum: Int)
    case invalidStructure(StrictJSONValidationError)
    case decodeFailed
    case validationFailed(ReleaseManifestValidationError)
}

extension BuildManifestReaderError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .missing:
            "The bundled Vela release manifest is missing."
        case .readFailed:
            "The Vela release manifest could not be read."
        case .tooLarge:
            "The Vela release manifest exceeds its size limit."
        case .invalidStructure:
            "The Vela release manifest contains an unsupported JSON structure."
        case .decodeFailed:
            "The Vela release manifest is malformed."
        case .validationFailed:
            "The Vela release manifest does not match this application build."
        }
    }
}
