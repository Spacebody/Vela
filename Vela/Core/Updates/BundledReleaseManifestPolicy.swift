import Foundation

nonisolated enum BundledReleaseManifestPolicy {
    static let infoDictionaryKey = "VelaReleaseManifestRequired"

    static func requiresValidation(in bundle: Bundle) throws -> Bool {
        let configuredValue = bundle.object(
            forInfoDictionaryKey: infoDictionaryKey
        ) as? String
        let manifestPresent = bundle.url(
            forResource: BuildManifestReader.bundledResourceName,
            withExtension: BuildManifestReader.bundledResourceExtension
        ) != nil
        return try requiresValidation(
            configuredValue: configuredValue,
            manifestPresent: manifestPresent
        )
    }

    static func requiresValidation(
        configuredValue: String?,
        manifestPresent: Bool
    ) throws -> Bool {
        guard let configuredValue else {
            // Older local Release builds did not stamp the policy key. Validate
            // any manifest that is present, while allowing a manifest-free local
            // build to use live services.
            return manifestPresent
        }

        switch configuredValue.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "YES":
            return true
        case "NO":
            return manifestPresent
        default:
            throw BundledReleaseManifestPolicyError.invalidConfiguredValue
        }
    }
}

nonisolated enum BundledReleaseManifestPolicyError: Error, Equatable, Sendable {
    case invalidConfiguredValue
}

extension BundledReleaseManifestPolicyError: LocalizedError {
    var errorDescription: String? {
        "The bundled release-manifest policy is invalid."
    }
}
