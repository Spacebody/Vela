import Testing
@testable import Vela

@Suite("Bundled release manifest policy")
struct BundledReleaseManifestPolicyTests {
    @Test("Local builds without a bundled manifest allow live services")
    func localBuildWithoutManifestSkipsValidation() throws {
        #expect(
            try !BundledReleaseManifestPolicy.requiresValidation(
                configuredValue: "NO",
                manifestPresent: false
            )
        )
        #expect(
            try !BundledReleaseManifestPolicy.requiresValidation(
                configuredValue: nil,
                manifestPresent: false
            )
        )
    }

    @Test("Distribution builds always validate their bundled manifest")
    func distributionBuildRequiresValidation() throws {
        #expect(
            try BundledReleaseManifestPolicy.requiresValidation(
                configuredValue: "YES",
                manifestPresent: false
            )
        )
    }

    @Test("A present manifest is validated even for a local build")
    func presentManifestRequiresValidation() throws {
        #expect(
            try BundledReleaseManifestPolicy.requiresValidation(
                configuredValue: "NO",
                manifestPresent: true
            )
        )
        #expect(
            try BundledReleaseManifestPolicy.requiresValidation(
                configuredValue: nil,
                manifestPresent: true
            )
        )
    }

    @Test("Malformed policy values fail closed")
    func malformedValueFailsClosed() {
        #expect(throws: BundledReleaseManifestPolicyError.invalidConfiguredValue) {
            try BundledReleaseManifestPolicy.requiresValidation(
                configuredValue: "sometimes",
                manifestPresent: false
            )
        }
    }
}
