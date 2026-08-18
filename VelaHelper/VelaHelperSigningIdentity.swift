import Foundation
import Security
import VelaIPC

struct VelaHelperSigningIdentity: Equatable, Sendable {
    let teamIdentifier: String
    let signingIdentifier: String

    var mainApplicationRequirement: String {
        "identifier \"\(VelaIPCConstants.mainBundleIdentifier)\" and "
            + "anchor apple generic and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
    }

    var safeSummary: String {
        "Team ID \(teamIdentifier)"
    }
}

enum VelaHelperSigningIdentityProvider {
    static func current() throws -> VelaHelperSigningIdentity {
        var code: SecCode?
        let selfStatus = SecCodeCopySelf(SecCSFlags(), &code)
        guard selfStatus == errSecSuccess, let code else {
            throw VelaHelperSigningIdentityError.codeUnavailable(selfStatus)
        }

        // Validate and inspect the already-running Helper code object. Never
        // derive the expected Team from the mutable on-disk app/helper path.
        let validityStatus = SecCodeCheckValidity(
            code,
            SecCSFlags(rawValue: UInt32(kSecCSStrictValidate)),
            nil
        )
        guard validityStatus == errSecSuccess else {
            throw VelaHelperSigningIdentityError.invalidSignature(validityStatus)
        }

        // The SDK exposes signing-information lookup on SecStaticCode. Derive
        // that object from the already validated running guest, never by path.
        var staticCode: SecStaticCode?
        let staticStatus = SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode)
        guard staticStatus == errSecSuccess, let staticCode else {
            throw VelaHelperSigningIdentityError.codeUnavailable(staticStatus)
        }

        var information: CFDictionary?
        let informationStatus = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: UInt32(kSecCSSigningInformation)),
            &information
        )
        guard informationStatus == errSecSuccess,
            let values = information as? [CFString: Any]
        else {
            throw VelaHelperSigningIdentityError.signingInformationUnavailable(
                informationStatus
            )
        }

        guard let teamIdentifier = values[kSecCodeInfoTeamIdentifier] as? String,
            Self.isValidTeamIdentifier(teamIdentifier)
        else {
            throw VelaHelperSigningIdentityError.teamIdentifierUnavailable
        }
        guard let signingIdentifier = values[kSecCodeInfoIdentifier] as? String,
            signingIdentifier == VelaIPCConstants.helperIdentifier
        else {
            throw VelaHelperSigningIdentityError.unexpectedSigningIdentifier
        }
        if let flags = values[kSecCodeInfoFlags] as? NSNumber,
            flags.uint32Value & Self.adHocSignatureFlag != 0
        {
            throw VelaHelperSigningIdentityError.adHocSignatureRejected
        }

        let identity = VelaHelperSigningIdentity(
            teamIdentifier: teamIdentifier,
            signingIdentifier: signingIdentifier
        )
        var requirement: SecRequirement?
        let requirementStatus = SecRequirementCreateWithString(
            identity.mainApplicationRequirement as CFString,
            SecCSFlags(),
            &requirement
        )
        guard requirementStatus == errSecSuccess, requirement != nil else {
            throw VelaHelperSigningIdentityError.invalidRequirement(requirementStatus)
        }
        return identity
    }

    private static func isValidTeamIdentifier(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        return bytes.count == 10
            && bytes.allSatisfy { (65 ... 90).contains($0) || (48 ... 57).contains($0) }
    }

    /// `kSecCodeSignatureAdhoc` is declared in CSCommon.h but is not imported
    /// into Swift by every SDK overlay.
    private static let adHocSignatureFlag: UInt32 = 0x0002
}

enum VelaHelperSigningIdentityError: Error, Equatable, Sendable {
    case codeUnavailable(OSStatus)
    case invalidSignature(OSStatus)
    case signingInformationUnavailable(OSStatus)
    case teamIdentifierUnavailable
    case unexpectedSigningIdentifier
    case adHocSignatureRejected
    case invalidRequirement(OSStatus)
}
