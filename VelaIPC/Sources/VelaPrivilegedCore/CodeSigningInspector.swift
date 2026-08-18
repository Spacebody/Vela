import Foundation
import Security

public struct PrivilegedCodeSigningRequirement: Equatable, Sendable {
    public let text: String

    public static func appleGeneric(
        identifier: String,
        teamIdentifier: String
    ) throws -> PrivilegedCodeSigningRequirement {
        guard isSafeIdentifier(identifier), isSafeTeamIdentifier(teamIdentifier) else {
            throw PrivilegedCodeSigningError.invalidRequirement
        }
        return PrivilegedCodeSigningRequirement(
            text: "identifier \"\(identifier)\""
                + " and anchor apple generic"
                + " and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
        )
    }

    public func validateSyntax() throws {
        _ = try makeSecurityRequirement()
    }

    fileprivate func makeSecurityRequirement() throws -> SecRequirement {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(
            text as CFString,
            SecCSFlags(),
            &requirement
        ) == errSecSuccess,
            let requirement
        else {
            throw PrivilegedCodeSigningError.invalidRequirement
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
}

public struct PrivilegedCodeSignature: Equatable, Sendable {
    public let signingIdentifier: String
    public let teamIdentifier: String

    public init(signingIdentifier: String, teamIdentifier: String) {
        self.signingIdentifier = signingIdentifier
        self.teamIdentifier = teamIdentifier
    }
}

public protocol PrivilegedCodeSigningInspecting: Sendable {
    func inspect(
        at url: URL,
        validateNestedCode: Bool,
        requirement: PrivilegedCodeSigningRequirement?
    ) throws -> PrivilegedCodeSignature
}

public extension PrivilegedCodeSigningInspecting {
    nonisolated func inspect(
        at url: URL,
        validateNestedCode: Bool
    ) throws -> PrivilegedCodeSignature {
        try inspect(at: url, validateNestedCode: validateNestedCode, requirement: nil)
    }
}

public struct SecurityPrivilegedCodeSigningInspector: PrivilegedCodeSigningInspecting {
    public init() {}

    public func inspect(
        at url: URL,
        validateNestedCode: Bool,
        requirement: PrivilegedCodeSigningRequirement?
    ) throws -> PrivilegedCodeSignature {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &staticCode)
                == errSecSuccess,
            let staticCode
        else {
            throw PrivilegedCodeSigningError.codeObjectUnavailable
        }

        var flags = UInt32(kSecCSStrictValidate | kSecCSCheckAllArchitectures)
        if validateNestedCode { flags |= UInt32(kSecCSCheckNestedCode) }
        let securityRequirement = try requirement?.makeSecurityRequirement()
        var validationError: Unmanaged<CFError>?
        defer { validationError?.release() }
        guard SecStaticCodeCheckValidityWithErrors(
            staticCode,
            SecCSFlags(rawValue: flags),
            securityRequirement,
            &validationError
        ) == errSecSuccess else {
            throw PrivilegedCodeSigningError.invalidSignature
        }

        var rawInformation: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: UInt32(kSecCSSigningInformation)),
            &rawInformation
        ) == errSecSuccess,
            let information = rawInformation as? [CFString: Any],
            let signingIdentifier = information[kSecCodeInfoIdentifier] as? String,
            !signingIdentifier.isEmpty,
            let teamIdentifier = information[kSecCodeInfoTeamIdentifier] as? String,
            !teamIdentifier.isEmpty
        else {
            // Ad-hoc signatures deliberately fail here. The privileged boundary
            // never has a debug/release bypass for a missing Team Identifier.
            throw PrivilegedCodeSigningError.identityUnavailable
        }
        return PrivilegedCodeSignature(
            signingIdentifier: signingIdentifier,
            teamIdentifier: teamIdentifier
        )
    }
}

public enum PrivilegedCodeSigningError: Error, Equatable, Sendable {
    case codeObjectUnavailable
    case invalidSignature
    case identityUnavailable
    case invalidRequirement
}
