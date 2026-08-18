import Foundation

public enum VelaIPCConstants: Sendable {
    public static let schemaVersion = 1
    public static let protocolMinimum = 2
    public static let protocolMaximum = 2
    public static let rootDataSchemaVersion = 3
    public static let coreDataSchemaVersion = 6

    public static let mainBundleIdentifier = "dev.yilin.Vela"
    public static let helperIdentifier = "dev.yilin.Vela.Helper"
    public static let machServiceName = helperIdentifier
    public static let launchDaemonPlistName = "\(helperIdentifier).plist"

    public static let helperSemanticVersion = "0.6.0"
    public static let helperBuild = "2026071302"
    public static let expectedMihomoVersion = "v1.19.29"
    public static let expectedMihomoSigningIdentifier = "mihomo"
    public static let expectedExternalCoreSigningIdentifier =
        "\(mainBundleIdentifier).MihomoCore"
    /// Controller compatibility is a tested API contract, not an upstream
    /// Mihomo version string. A newer upstream Core may use this profile only
    /// after the Compatibility Lab proves the same contract.
    public static let currentControllerAPIProfile = "mihomo-v1.19.28"
    public static let supportedControllerAPIProfiles = [currentControllerAPIProfile]
    public static let coreCompatibilitySuiteVersion = 1

    public static let maximumPayloadBytes = 1 * 1_024 * 1_024
    public static let maximumConfigurationBytes = 20 * 1_024 * 1_024
    public static let maximumResourceBytes = 20 * 1_024 * 1_024
    public static let maximumResourceTotalBytes = 100 * 1_024 * 1_024
    public static let maximumResourceCount = 256
    public static let maximumMihomoExecutableBytes = 128 * 1_024 * 1_024
    public static let maximumCoreCatalogBytes = 2 * 1_024 * 1_024
    public static let maximumCoreSignatureEnvelopeBytes = 64 * 1_024
    public static let maximumCoreFileBytes = 128 * 1_024 * 1_024
    public static let maximumCoreTotalBytes = 256 * 1_024 * 1_024
    public static let maximumCoreInstallPayloadBytes = 3 * 1_024 * 1_024
    /// Three bounded installed records may each retain a full immutable
    /// Catalog+signature envelope for independent Helper re-verification.
    public static let maximumCoreStoreStateBytes = 12 * 1_024 * 1_024
    public static let maximumLogBatchBytes = 1 * 1_024 * 1_024
    public static let maximumLogEntryCount = 2_000
}

public enum EngineBackendKind: String, Codable, CaseIterable, Sendable {
    case userProcess
    case privilegedDaemon
}

public enum HelperProcessState: String, Codable, Sendable {
    case stopped
    case preparing
    case running
    case stopping
    case degraded
    case manualRepairRequired
}
