import Foundation

nonisolated struct MihomoCoreDescriptor: Codable, Equatable, Sendable {
    static let supportedSchemaVersion = 1
    static let requiredComponent = "mihomo"
    static let requiredVersion = "v1.19.29"
    static let requiredPlatform = "darwin"
    static let requiredArchitecture = "arm64"
    static let requiredAssetName = "mihomo-darwin-arm64-v1.19.29.gz"
    static let requiredAssetURLString =
        "https://github.com/MetaCubeX/mihomo/releases/download/v1.19.29/mihomo-darwin-arm64-v1.19.29.gz"
    static let requiredUpstreamRepositoryURLString =
        "https://github.com/MetaCubeX/mihomo"
    static let requiredUpstreamReleaseURLString =
        "https://github.com/MetaCubeX/mihomo/releases/tag/v1.19.29"
    static let requiredUpstreamSourceURLString =
        "https://github.com/MetaCubeX/mihomo/tree/v1.19.29"
    static let requiredUpstreamSourceArchiveURLString =
        "https://github.com/MetaCubeX/mihomo/archive/refs/tags/v1.19.29.tar.gz"
    static let requiredArchiveSHA256 =
        "4dc25df9e899f14161911302a8ee5fc9e202ed9c976fc405bf82c50ff27466ca"
    static let requiredArchiveSizeBytes: Int64 = 15_858_351
    static let requiredExecutableName = "mihomo"
    static let requiredBundleRelativePath = "Contents/Helpers/mihomo"
    static let requiredMetadataBundleRelativePath = "Contents/Resources/ThirdParty/Mihomo"
    static let requiredMinimumMacOSVersion = "15.0"
    static let requiredLicense = "GPL-3.0"

    let schemaVersion: Int
    let component: String
    let version: String
    let releaseTag: String
    let releaseDateUTC: String
    let upstreamRepositoryURL: URL
    let upstreamReleaseURL: URL
    let upstreamSourceURL: URL
    let upstreamSourceArchiveURL: URL
    let license: String
    let platform: String
    let architecture: String
    let assetName: String
    let assetURL: URL
    let archiveSHA256: String
    let archiveSizeBytes: Int64
    let executableName: String
    let bundleRelativePath: String
    let metadataBundleRelativePath: String
    let minimumMacOSVersion: String
    let supportedArchitectures: [String]
    let runtimeDownloadAllowed: Bool

    func validate() throws {
        try require(
            schemaVersion == Self.supportedSchemaVersion,
            field: "schemaVersion",
            expected: String(Self.supportedSchemaVersion),
            actual: String(schemaVersion)
        )
        try require(component == Self.requiredComponent, field: "component", expected: Self.requiredComponent, actual: component)
        try require(version == Self.requiredVersion, field: "version", expected: Self.requiredVersion, actual: version)
        try require(releaseTag == Self.requiredVersion, field: "releaseTag", expected: Self.requiredVersion, actual: releaseTag)
        try require(platform == Self.requiredPlatform, field: "platform", expected: Self.requiredPlatform, actual: platform)
        try require(
            architecture == Self.requiredArchitecture,
            field: "architecture",
            expected: Self.requiredArchitecture,
            actual: architecture
        )
        try require(
            supportedArchitectures == [Self.requiredArchitecture],
            field: "supportedArchitectures",
            expected: Self.requiredArchitecture,
            actual: supportedArchitectures.joined(separator: ",")
        )
        try require(assetName == Self.requiredAssetName, field: "assetName", expected: Self.requiredAssetName, actual: assetName)
        try require(
            executableName == Self.requiredExecutableName,
            field: "executableName",
            expected: Self.requiredExecutableName,
            actual: executableName
        )
        try validateSafeBundlePath(
            bundleRelativePath,
            field: "bundleRelativePath",
            requiredValue: Self.requiredBundleRelativePath
        )
        try validateSafeBundlePath(
            metadataBundleRelativePath,
            field: "metadataBundleRelativePath",
            requiredValue: Self.requiredMetadataBundleRelativePath
        )
        try require(
            minimumMacOSVersion == Self.requiredMinimumMacOSVersion,
            field: "minimumMacOSVersion",
            expected: Self.requiredMinimumMacOSVersion,
            actual: minimumMacOSVersion
        )
        try require(license == Self.requiredLicense, field: "license", expected: Self.requiredLicense, actual: license)
        try require(
            !runtimeDownloadAllowed,
            field: "runtimeDownloadAllowed",
            expected: "false",
            actual: String(runtimeDownloadAllowed)
        )

        for (field, url) in [
            ("upstreamRepositoryURL", upstreamRepositoryURL),
            ("upstreamReleaseURL", upstreamReleaseURL),
            ("upstreamSourceURL", upstreamSourceURL),
            ("upstreamSourceArchiveURL", upstreamSourceArchiveURL),
            ("assetURL", assetURL),
        ] {
            try validateHTTPSURL(url, field: field)
        }
        try require(
            assetURL.absoluteString == Self.requiredAssetURLString,
            field: "assetURL",
            expected: Self.requiredAssetURLString,
            actual: assetURL.absoluteString
        )
        for (field, actual, expected) in [
            (
                "upstreamRepositoryURL",
                upstreamRepositoryURL,
                Self.requiredUpstreamRepositoryURLString
            ),
            (
                "upstreamReleaseURL",
                upstreamReleaseURL,
                Self.requiredUpstreamReleaseURLString
            ),
            (
                "upstreamSourceURL",
                upstreamSourceURL,
                Self.requiredUpstreamSourceURLString
            ),
            (
                "upstreamSourceArchiveURL",
                upstreamSourceArchiveURL,
                Self.requiredUpstreamSourceArchiveURLString
            ),
        ] {
            try require(
                actual.absoluteString == expected,
                field: field,
                expected: expected,
                actual: actual.absoluteString
            )
        }

        guard archiveSHA256.count == 64,
            archiveSHA256.unicodeScalars.allSatisfy(Self.isLowercaseHexDigit)
        else {
            throw MihomoCoreManifestError.invalidSHA256(archiveSHA256)
        }
        try require(
            archiveSHA256 == Self.requiredArchiveSHA256,
            field: "archiveSHA256",
            expected: Self.requiredArchiveSHA256,
            actual: archiveSHA256
        )
        try require(
            archiveSizeBytes == Self.requiredArchiveSizeBytes,
            field: "archiveSizeBytes",
            expected: String(Self.requiredArchiveSizeBytes),
            actual: String(archiveSizeBytes)
        )

        guard !releaseDateUTC.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MihomoCoreManifestError.invalidValue(field: "releaseDateUTC", actual: releaseDateUTC)
        }
    }

    private func require(
        _ condition: @autoclosure () -> Bool,
        field: String,
        expected: String,
        actual: String
    ) throws {
        guard condition() else {
            throw MihomoCoreManifestError.unexpectedValue(
                field: field,
                expected: expected,
                actual: actual
            )
        }
    }

    private func validateHTTPSURL(_ url: URL, field: String) throws {
        guard url.scheme?.lowercased() == "https",
            url.host != nil,
            url.user == nil,
            url.password == nil,
            url.query == nil,
            url.fragment == nil
        else {
            throw MihomoCoreManifestError.invalidHTTPSURL(field: field, value: url.absoluteString)
        }
    }

    private func validateSafeBundlePath(
        _ path: String,
        field: String,
        requiredValue: String
    ) throws {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.hasPrefix("/"),
            !path.contains("\\"),
            !components.isEmpty,
            components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else {
            throw MihomoCoreManifestError.unsafeBundlePath(field: field, value: path)
        }
        try require(path == requiredValue, field: field, expected: requiredValue, actual: path)
    }

    private static func isLowercaseHexDigit(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 48...57, 97...102:
            true
        default:
            false
        }
    }
}

nonisolated protocol MihomoCoreDescriptorLoading: Sendable {
    func load(from manifestURL: URL) throws -> MihomoCoreDescriptor
}

nonisolated struct JSONMihomoCoreDescriptorLoader: MihomoCoreDescriptorLoading, Sendable {
    private let fileSystem: any FileSystemProviding

    init(fileSystem: any FileSystemProviding = LiveFileSystem()) {
        self.fileSystem = fileSystem
    }

    func load(from manifestURL: URL) throws -> MihomoCoreDescriptor {
        guard fileSystem.fileExists(at: manifestURL) else {
            throw MihomoCoreManifestError.missing(manifestURL)
        }

        let data: Data
        do {
            data = try fileSystem.readData(at: manifestURL)
        } catch {
            throw MihomoCoreManifestError.readFailed(
                path: manifestURL.path,
                reason: error.localizedDescription
            )
        }

        let descriptor: MihomoCoreDescriptor
        do {
            descriptor = try JSONDecoder().decode(MihomoCoreDescriptor.self, from: data)
        } catch {
            throw MihomoCoreManifestError.decodingFailed(error.localizedDescription)
        }
        try descriptor.validate()
        return descriptor
    }
}

nonisolated enum MihomoCoreManifestError: Error, Equatable, Sendable {
    case missing(URL)
    case readFailed(path: String, reason: String)
    case decodingFailed(String)
    case unexpectedValue(field: String, expected: String, actual: String)
    case invalidValue(field: String, actual: String)
    case invalidHTTPSURL(field: String, value: String)
    case invalidSHA256(String)
    case unsafeBundlePath(field: String, value: String)
}

extension MihomoCoreManifestError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .missing(url):
            "Mihomo core manifest is missing at \(url.path)."
        case let .readFailed(path, reason):
            "Mihomo core manifest at \(path) could not be read: \(reason)"
        case let .decodingFailed(reason):
            "Mihomo core manifest is invalid JSON: \(reason)"
        case let .unexpectedValue(field, expected, actual):
            "Mihomo core manifest field \(field) must be \(expected); found \(actual)."
        case let .invalidValue(field, actual):
            "Mihomo core manifest field \(field) is invalid: \(actual)."
        case let .invalidHTTPSURL(field, value):
            "Mihomo core manifest field \(field) must be an absolute HTTPS URL without credentials, query, or fragment; found \(value)."
        case let .invalidSHA256(value):
            "Mihomo archive SHA-256 must be 64 lowercase hexadecimal characters; found \(value)."
        case let .unsafeBundlePath(field, value):
            "Mihomo core manifest field \(field) contains an unsafe bundle path: \(value)."
        }
    }
}
