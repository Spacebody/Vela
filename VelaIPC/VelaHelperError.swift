import Foundation

public let VelaHelperErrorDomain = "dev.yilin.Vela.HelperError"

/// Errors crossing the privileged module boundary conform to this protocol so
/// the transport never falls back to a localized/raw implementation message.
public protocol VelaHelperStableError: Error, Sendable {
    var helperErrorCode: VelaHelperErrorCode { get }
    var helperSafeMessage: String { get }
}

public enum VelaHelperErrorCode: Int, Codable, CaseIterable, Sendable {
    case invalidPayload = 1_001
    case payloadTooLarge = 1_002
    case unsupportedSchema = 1_003
    case incompatibleProtocol = 1_004
    case unauthenticatedClient = 1_005
    case ownerBusy = 1_006
    case invalidSession = 1_007
    case invalidState = 1_008
    case invalidTransaction = 1_009
    case unsafePath = 1_010
    case resourceLimitExceeded = 1_011
    case resourceIntegrityMismatch = 1_012
    case unsupportedPrivilegedLocalResource = 1_013
    case unsafeConfiguration = 1_014
    case configurationValidationFailed = 1_015
    case mihomoPreflightFailed = 1_016
    case processStartFailed = 1_017
    case processStopFailed = 1_018
    case helperUnavailable = 1_019
    case leaseExpired = 1_020
    case cleanupFailed = 1_021
    case manualRepairRequired = 1_022
    case requestTimedOut = 1_023
    case cancelled = 1_024
    case coreCatalogRejected = 1_025
    case coreCatalogReplay = 1_026
    case coreInstallIncomplete = 1_027
    case coreNotInstalled = 1_028
    case coreInUse = 1_029
    case corePreflightFailed = 1_030
    case appUpdateInProgress = 1_031
    case unsupportedOperation = 1_032
    case internalFailure = 1_099
}

public struct VelaHelperFailure: Error, Equatable, Sendable, LocalizedError {
    public let code: VelaHelperErrorCode
    public let requestID: UUID?
    public let safeMessage: String

    public init(
        code: VelaHelperErrorCode,
        requestID: UUID? = nil,
        safeMessage: String
    ) {
        self.code = code
        self.requestID = requestID
        self.safeMessage = safeMessage
    }

    public var errorDescription: String? { safeMessage }

    public var nsError: NSError {
        var userInfo: [String: Any] = [NSLocalizedDescriptionKey: safeMessage]
        if let requestID {
            userInfo["requestID"] = requestID.uuidString
        }
        return NSError(domain: VelaHelperErrorDomain, code: code.rawValue, userInfo: userInfo)
    }

    public static func from(_ error: Error, requestID: UUID? = nil) -> VelaHelperFailure {
        if let failure = error as? VelaHelperFailure {
            guard failure.requestID == nil, let requestID else { return failure }
            return VelaHelperFailure(
                code: failure.code,
                requestID: requestID,
                safeMessage: failure.safeMessage
            )
        }
        if let stable = error as? any VelaHelperStableError {
            return VelaHelperFailure(
                code: stable.helperErrorCode,
                requestID: requestID,
                safeMessage: stable.helperSafeMessage
            )
        }
        if error is CancellationError {
            return VelaHelperFailure(
                code: .cancelled,
                requestID: requestID,
                safeMessage: "The privileged operation was cancelled."
            )
        }
        return VelaHelperFailure(
            code: .internalFailure,
            requestID: requestID,
            safeMessage: "The privileged component could not complete the request."
        )
    }
}
