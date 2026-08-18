import Foundation
import VelaIPC

extension SafeRelativePathError: VelaHelperStableError {
    public var helperErrorCode: VelaHelperErrorCode { .unsafePath }
    public var helperSafeMessage: String { "The privileged resource path is unsafe." }
}

extension POSIXRootFileSystemError: VelaHelperStableError {
    public var helperErrorCode: VelaHelperErrorCode {
        switch self {
        case .fileTooLarge, .treeLimitExceeded: .resourceLimitExceeded
        case .destinationExists: .invalidState
        case .symlinkRejected, .notDirectory, .notRegularFile,
            .crossDeviceEntry, .unsupportedFileType:
            .unsafePath
        case .unsafeOwnership, .unsafePermissions: .manualRepairRequired
        case .invalidBaseURL, .systemCall, .shortRead: .cleanupFailed
        }
    }
    public var helperSafeMessage: String {
        "The privileged filesystem operation was rejected."
    }
}

extension TrustedMihomoExecutableError: VelaHelperStableError {
    public var helperErrorCode: VelaHelperErrorCode { .mihomoPreflightFailed }
    public var helperSafeMessage: String {
        "The bundled Mihomo executable could not be imported safely."
    }
}

extension RootJournalError: VelaHelperStableError {
    public var helperErrorCode: VelaHelperErrorCode { .manualRepairRequired }
    public var helperSafeMessage: String { "The privileged state journal is incompatible." }
}

extension RootTransactionError: VelaHelperStableError {
    public var helperErrorCode: VelaHelperErrorCode {
        switch self {
        case .notFound: .invalidTransaction
        case .wrongSession: .invalidSession
        case .invalidResourceCount, .invalidResourceSize,
            .totalResourceSizeExceeded, .invalidConfigurationSize:
            .resourceLimitExceeded
        case .sourceNotRegularFile: .unsafePath
        case .sizeMismatch, .hashMismatch, .sourceChanged, .descriptorMismatch:
            .resourceIntegrityMismatch
        case .alreadyActive, .invalidState, .expired, .duplicateLogicalID,
            .duplicateDestination, .resourcesIncomplete, .generationRevisionOverflow:
            .invalidState
        }
    }
    public var helperSafeMessage: String {
        "The privileged start transaction was rejected."
    }
}

extension IntegrityValueError: VelaHelperStableError {
    public var helperErrorCode: VelaHelperErrorCode { .resourceIntegrityMismatch }
    public var helperSafeMessage: String { "The privileged integrity value is invalid." }
}

extension PrivilegedCoreCatalogError: VelaHelperStableError {
    public var helperErrorCode: VelaHelperErrorCode {
        switch self {
        case .replayedSequence, .equivocatedSequence: .coreCatalogReplay
        case .sizeLimit: .resourceLimitExceeded
        default: .coreCatalogRejected
        }
    }
    public var helperSafeMessage: String {
        "The signed core catalog was rejected."
    }
}

extension RootCoreStoreError: VelaHelperStableError {
    public var helperErrorCode: VelaHelperErrorCode {
        switch self {
        case .notInstalled: .coreNotInstalled
        case .protectedCore: .coreInUse
        case .preflightFailed, .policyRejected: .corePreflightFailed
        case .incomplete: .coreInstallIncomplete
        case .sizeMismatch, .storeLimit: .resourceLimitExceeded
        case .integrityMismatch, .descriptorMismatch: .resourceIntegrityMismatch
        case .ownerMismatch: .invalidSession
        case .sourceRejected, .invalidLayout: .unsafePath
        case .notPrepared: .helperUnavailable
        case .transactionActive, .alreadyInstalled, .invalidTransaction, .invalidState:
            .invalidState
        }
    }
    public var helperSafeMessage: String {
        "The privileged core operation was rejected."
    }
}

extension PrivilegedConfigSanitizerError: VelaHelperStableError {
    public var helperErrorCode: VelaHelperErrorCode {
        switch self {
        case .configurationTooLarge: .payloadTooLarge
        case .unsupportedLocalResource, .missingStagedResource,
            .duplicateStagedResource, .unusedStagedResource:
            .unsupportedPrivilegedLocalResource
        case .randomSecretUnavailable: .internalFailure
        default: .unsafeConfiguration
        }
    }
    public var helperSafeMessage: String {
        "The privileged runtime configuration was rejected."
    }
}

extension OwnerLeaseError: VelaHelperStableError {
    public var helperErrorCode: VelaHelperErrorCode {
        switch self {
        case .ownerBusy: .ownerBusy
        case .expired: .leaseExpired
        case .invalidSession, .invalidConnection: .invalidSession
        }
    }
    public var helperSafeMessage: String { "The privileged owner session is unavailable." }
}

extension PrivilegedCodeSigningError: VelaHelperStableError {
    public var helperErrorCode: VelaHelperErrorCode { .mihomoPreflightFailed }
    public var helperSafeMessage: String { "The privileged code signature is invalid." }
}

extension ProcessIdentityError: VelaHelperStableError {
    public var helperErrorCode: VelaHelperErrorCode { .manualRepairRequired }
    public var helperSafeMessage: String {
        "The privileged process identity could not be proven."
    }
}

extension FixedMihomoPreflightError: VelaHelperStableError {
    public var helperErrorCode: VelaHelperErrorCode { .mihomoPreflightFailed }
    public var helperSafeMessage: String { "The bundled Mihomo security check failed." }
}

extension FixedMihomoCommandError: VelaHelperStableError {
    public var helperErrorCode: VelaHelperErrorCode { .configurationValidationFailed }
    public var helperSafeMessage: String { "Mihomo configuration validation failed." }
}

extension ControllerPortAllocationError: VelaHelperStableError {
    public var helperErrorCode: VelaHelperErrorCode { .processStartFailed }
    public var helperSafeMessage: String { "A loopback controller port is unavailable." }
}

extension LivePrivilegedRuntimeError: VelaHelperStableError {
    public var helperErrorCode: VelaHelperErrorCode {
        switch self {
        case .configurationValidationFailed: .configurationValidationFailed
        case .launchFailed, .controllerUnavailable, .tunInterfaceUnavailable:
            .processStartFailed
        case .stopFailed: .processStopFailed
        case .manualRepairRequired, .processIdentityMismatch, .cleanupIncomplete:
            .manualRepairRequired
        case .daemonNotRoot: .helperUnavailable
        case .coreUnavailable: .coreNotInstalled
        case .alreadyRunning, .instanceMismatch: .invalidState
        }
    }
    public var helperSafeMessage: String {
        "The privileged Mihomo operation could not be completed safely."
    }
}
