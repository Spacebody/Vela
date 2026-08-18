import Foundation
import Security
import VelaIPC

/// A Security.framework requirement assembled only from validated identity
/// components. Keeping the source text makes the trust policy reviewable and
/// lets tests prove that the Apple anchor is not accidentally omitted.
nonisolated struct CodeSignatureRequirement: Equatable, Sendable {
    let text: String

    static func appleGeneric(
        identifier: String,
        teamIdentifier: String
    ) throws -> CodeSignatureRequirement {
        guard isSafeIdentifier(identifier) else {
            throw CodeSignatureRequirementError.invalidSigningIdentifier(identifier)
        }
        guard isSafeTeamIdentifier(teamIdentifier) else {
            throw CodeSignatureRequirementError.invalidTeamIdentifier(teamIdentifier)
        }
        return CodeSignatureRequirement(
            text: "identifier \"\(identifier)\""
                + " and anchor apple generic"
                + " and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
        )
    }

    func validateSyntax() throws {
        _ = try makeSecurityRequirement()
    }

    fileprivate func makeSecurityRequirement() throws -> SecRequirement {
        var requirement: SecRequirement?
        let status = SecRequirementCreateWithString(
            text as CFString,
            SecCSFlags(),
            &requirement
        )
        guard status == errSecSuccess, let requirement else {
            throw CodeSignatureRequirementError.securityRequirementCreationFailed(
                status: status,
                message: Self.message(for: status)
            )
        }
        return requirement
    }

    private static func isSafeIdentifier(_ value: String) -> Bool {
        guard (1 ... 255).contains(value.utf8.count) else { return false }
        return value.utf8.allSatisfy { byte in
            (48 ... 57).contains(byte)
                || (65 ... 90).contains(byte)
                || (97 ... 122).contains(byte)
                || byte == 45
                || byte == 46
        }
    }

    private static func isSafeTeamIdentifier(_ value: String) -> Bool {
        guard (1 ... 64).contains(value.utf8.count) else { return false }
        return value.utf8.allSatisfy { byte in
            (48 ... 57).contains(byte)
                || (65 ... 90).contains(byte)
                || (97 ... 122).contains(byte)
        }
    }

    private static func message(for status: OSStatus) -> String {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "OSStatus \(status)"
    }
}

nonisolated enum CodeSignatureRequirementError: Error, Equatable, Sendable {
    case invalidSigningIdentifier(String)
    case invalidTeamIdentifier(String)
    case securityRequirementCreationFailed(status: OSStatus, message: String)
}

nonisolated struct CodeSignatureSnapshot: Equatable, Sendable {
    let url: URL
    let teamIdentifier: String?
    let signingIdentifier: String?
}

nonisolated protocol CodeSignatureInspecting: Sendable {
    func inspectCode(
        at url: URL,
        validateNestedCode: Bool,
        requirement: CodeSignatureRequirement?
    ) throws -> CodeSignatureSnapshot
}

extension CodeSignatureInspecting {
    nonisolated func inspectCode(
        at url: URL,
        validateNestedCode: Bool
    ) throws -> CodeSignatureSnapshot {
        try inspectCode(at: url, validateNestedCode: validateNestedCode, requirement: nil)
    }
}

nonisolated struct SecurityFrameworkCodeSignatureInspector: CodeSignatureInspecting, Sendable {
    func inspectCode(
        at url: URL,
        validateNestedCode: Bool,
        requirement: CodeSignatureRequirement?
    ) throws -> CodeSignatureSnapshot {
        var staticCode: SecStaticCode?
        let creationStatus = SecStaticCodeCreateWithPath(
            url as CFURL,
            SecCSFlags(),
            &staticCode
        )
        guard creationStatus == errSecSuccess, let staticCode else {
            throw CodeSignatureInspectionError.staticCodeCreationFailed(
                path: url.path,
                status: creationStatus,
                message: Self.message(for: creationStatus)
            )
        }

        var rawValidationFlags = UInt32(kSecCSStrictValidate | kSecCSCheckAllArchitectures)
        if validateNestedCode {
            rawValidationFlags |= UInt32(kSecCSCheckNestedCode)
        }
        let securityRequirement: SecRequirement?
        do {
            securityRequirement = try requirement?.makeSecurityRequirement()
        } catch let error as CodeSignatureRequirementError {
            throw CodeSignatureInspectionError.invalidRequirement(error)
        }

        var validationError: Unmanaged<CFError>?
        let validationStatus = SecStaticCodeCheckValidityWithErrors(
            staticCode,
            SecCSFlags(rawValue: rawValidationFlags),
            securityRequirement,
            &validationError
        )
        guard validationStatus == errSecSuccess else {
            let validationMessage = validationError
                .map { $0.takeRetainedValue().localizedDescription }
                ?? Self.message(for: validationStatus)
            throw CodeSignatureInspectionError.invalidSignature(
                path: url.path,
                status: validationStatus,
                message: validationMessage
            )
        }
        validationError?.release()

        var signingInformation: CFDictionary?
        let informationStatus = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: UInt32(kSecCSSigningInformation)),
            &signingInformation
        )
        guard informationStatus == errSecSuccess, let signingInformation else {
            throw CodeSignatureInspectionError.signingInformationUnavailable(
                path: url.path,
                status: informationStatus,
                message: Self.message(for: informationStatus)
            )
        }

        let values = signingInformation as NSDictionary
        return CodeSignatureSnapshot(
            url: url,
            teamIdentifier: Self.normalized(values[kSecCodeInfoTeamIdentifier] as? String),
            signingIdentifier: Self.normalized(values[kSecCodeInfoIdentifier] as? String)
        )
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty
        else {
            return nil
        }
        return value
    }

    private static func message(for status: OSStatus) -> String {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "OSStatus \(status)"
    }
}

nonisolated enum CodeSignatureTeamPolicy: Equatable, Sendable {
    case developmentAllowsAdHoc
    case distribution
}

nonisolated enum CodeSignatureArtifact: String, Equatable, Sendable {
    case application
    case helper
}

nonisolated struct CodeSignatureVerification: Equatable, Sendable {
    let application: CodeSignatureSnapshot
    let helper: CodeSignatureSnapshot
    let teamIdentifier: String?
}

nonisolated protocol CodeSignatureVerifying: Sendable {
    func verify(
        applicationAt applicationURL: URL,
        helperAt helperURL: URL,
        teamPolicy: CodeSignatureTeamPolicy
    ) throws -> CodeSignatureVerification
}

nonisolated struct CodeSignatureVerifier: CodeSignatureVerifying, Sendable {
    private let inspector: any CodeSignatureInspecting

    init(inspector: any CodeSignatureInspecting = SecurityFrameworkCodeSignatureInspector()) {
        self.inspector = inspector
    }

    func verify(
        applicationAt applicationURL: URL,
        helperAt helperURL: URL,
        teamPolicy: CodeSignatureTeamPolicy
    ) throws -> CodeSignatureVerification {
        let initialHelper = try inspect(
            artifact: .helper,
            at: helperURL,
            validateNestedCode: false,
            requirement: nil
        )
        let initialApplication = try inspect(
            artifact: .application,
            at: applicationURL,
            validateNestedCode: true,
            requirement: nil
        )
        try requireIdentifier(
            initialApplication,
            artifact: .application,
            expected: VelaIPCConstants.mainBundleIdentifier
        )
        try requireIdentifier(
            initialHelper,
            artifact: .helper,
            expected: VelaIPCConstants.expectedMihomoSigningIdentifier
        )

        let applicationTeam = initialApplication.teamIdentifier
        let helperTeam = initialHelper.teamIdentifier
        switch teamPolicy {
        case .developmentAllowsAdHoc:
            guard applicationTeam == helperTeam else {
                throw CodeSignatureVerificationError.teamIdentifierMismatch(
                    application: applicationTeam,
                    helper: helperTeam
                )
            }
            // Ad-hoc is intentionally limited to the bundled Factory Core in
            // local Debug builds. Any Apple-signed development pair is still
            // checked against the same anchor/identifier/Team requirement as
            // distribution code.
            guard let applicationTeam else {
                return CodeSignatureVerification(
                    application: initialApplication,
                    helper: initialHelper,
                    teamIdentifier: nil
                )
            }
            return try verifyAppleAnchoredPair(
                applicationURL: applicationURL,
                helperURL: helperURL,
                teamIdentifier: applicationTeam
            )
        case .distribution:
            guard let applicationTeam, let helperTeam else {
                throw CodeSignatureVerificationError.distributionTeamIdentifierMissing(
                    application: applicationTeam,
                    helper: helperTeam
                )
            }
            guard applicationTeam == helperTeam else {
                throw CodeSignatureVerificationError.teamIdentifierMismatch(
                    application: applicationTeam,
                    helper: helperTeam
                )
            }
            return try verifyAppleAnchoredPair(
                applicationURL: applicationURL,
                helperURL: helperURL,
                teamIdentifier: applicationTeam
            )
        }
    }

    private func verifyAppleAnchoredPair(
        applicationURL: URL,
        helperURL: URL,
        teamIdentifier: String
    ) throws -> CodeSignatureVerification {
        let applicationRequirement: CodeSignatureRequirement
        let helperRequirement: CodeSignatureRequirement
        do {
            applicationRequirement = try .appleGeneric(
                identifier: VelaIPCConstants.mainBundleIdentifier,
                teamIdentifier: teamIdentifier
            )
            helperRequirement = try .appleGeneric(
                identifier: VelaIPCConstants.expectedMihomoSigningIdentifier,
                teamIdentifier: teamIdentifier
            )
        } catch let error as CodeSignatureRequirementError {
            throw CodeSignatureVerificationError.requirementConstructionFailed(error)
        }

        let application = try inspect(
            artifact: .application,
            at: applicationURL,
            validateNestedCode: true,
            requirement: applicationRequirement
        )
        let helper = try inspect(
            artifact: .helper,
            at: helperURL,
            validateNestedCode: false,
            requirement: helperRequirement
        )
        try requireIdentifier(
            application,
            artifact: .application,
            expected: VelaIPCConstants.mainBundleIdentifier
        )
        try requireIdentifier(
            helper,
            artifact: .helper,
            expected: VelaIPCConstants.expectedMihomoSigningIdentifier
        )
        guard application.teamIdentifier == teamIdentifier,
            helper.teamIdentifier == teamIdentifier
        else {
            throw CodeSignatureVerificationError.teamIdentifierMismatch(
                application: application.teamIdentifier,
                helper: helper.teamIdentifier
            )
        }
        return CodeSignatureVerification(
            application: application,
            helper: helper,
            teamIdentifier: teamIdentifier
        )
    }

    private func inspect(
        artifact: CodeSignatureArtifact,
        at url: URL,
        validateNestedCode: Bool,
        requirement: CodeSignatureRequirement?
    ) throws -> CodeSignatureSnapshot {
        do {
            return try inspector.inspectCode(
                at: url,
                validateNestedCode: validateNestedCode,
                requirement: requirement
            )
        } catch let error as CodeSignatureInspectionError {
            throw CodeSignatureVerificationError.inspectionFailed(artifact: artifact, error: error)
        } catch {
            throw CodeSignatureVerificationError.unexpectedInspectionFailure(
                artifact: artifact,
                message: error.localizedDescription
            )
        }
    }

    private func requireIdentifier(
        _ snapshot: CodeSignatureSnapshot,
        artifact: CodeSignatureArtifact,
        expected: String
    ) throws {
        guard snapshot.signingIdentifier == expected else {
            throw CodeSignatureVerificationError.signingIdentifierMismatch(
                artifact: artifact,
                expected: expected,
                actual: snapshot.signingIdentifier
            )
        }
    }
}

nonisolated enum CodeSignatureInspectionError: Error, Equatable, Sendable {
    case staticCodeCreationFailed(path: String, status: OSStatus, message: String)
    case invalidSignature(path: String, status: OSStatus, message: String)
    case signingInformationUnavailable(path: String, status: OSStatus, message: String)
    case invalidRequirement(CodeSignatureRequirementError)
}

extension CodeSignatureInspectionError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .staticCodeCreationFailed(path, status, message):
            "Could not create a static code object for \(path): \(message) (\(status))."
        case let .invalidSignature(path, status, message):
            "Code signature validation failed for \(path): \(message) (\(status))."
        case let .signingInformationUnavailable(path, status, message):
            "Signing information is unavailable for \(path): \(message) (\(status))."
        case let .invalidRequirement(error):
            "Code signature requirement is invalid: \(error)."
        }
    }
}

nonisolated enum CodeSignatureVerificationError: Error, Equatable, Sendable {
    case inspectionFailed(artifact: CodeSignatureArtifact, error: CodeSignatureInspectionError)
    case unexpectedInspectionFailure(artifact: CodeSignatureArtifact, message: String)
    case distributionTeamIdentifierMissing(application: String?, helper: String?)
    case teamIdentifierMismatch(application: String?, helper: String?)
    case signingIdentifierMismatch(
        artifact: CodeSignatureArtifact,
        expected: String,
        actual: String?
    )
    case requirementConstructionFailed(CodeSignatureRequirementError)
}

extension CodeSignatureVerificationError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .inspectionFailed(artifact, error):
            "\(artifact.rawValue.capitalized) code signature is invalid: \(error.localizedDescription)"
        case let .unexpectedInspectionFailure(artifact, message):
            "\(artifact.rawValue.capitalized) code signature inspection failed: \(message)"
        case let .distributionTeamIdentifierMissing(application, helper):
            "Distribution signatures require Team Identifiers for both app and helper; app=\(application ?? "missing"), helper=\(helper ?? "missing")."
        case let .teamIdentifierMismatch(application, helper):
            "App and helper Team Identifiers differ; app=\(application ?? "missing"), helper=\(helper ?? "missing")."
        case let .signingIdentifierMismatch(artifact, expected, actual):
            "\(artifact.rawValue.capitalized) signing identifier must be \(expected); got \(actual ?? "missing")."
        case let .requirementConstructionFailed(error):
            "Could not construct the Apple code-signing requirement: \(error)."
        }
    }
}
