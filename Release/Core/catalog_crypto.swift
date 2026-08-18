#!/usr/bin/swift
import CryptoKit
import Darwin
import Foundation

enum ToolError: Error, CustomStringConvertible {
    case usage
    case invalidKey
    case invalidBase64
    case invalidSignature
    case outputExists

    var description: String {
        switch self {
        case .usage: return "usage: catalog_crypto.swift sign CATALOG PRIVATE_KEY OUTPUT | verify CATALOG PUBLIC_KEY_BASE64 SIGNATURE_BASE64"
        case .invalidKey: return "private key file must contain exactly 32 raw bytes, 64 hexadecimal characters, or Base64 for 32 bytes"
        case .invalidBase64: return "public key or signature is not valid Base64"
        case .invalidSignature: return "Ed25519 signature verification failed"
        case .outputExists: return "signature output already exists"
        }
    }
}

func decodePrivateKey(_ data: Data) throws -> Data {
    if data.count == 32 { return data }
    guard let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
        throw ToolError.invalidKey
    }
    if text.range(of: "^[0-9a-fA-F]{64}$", options: .regularExpression) != nil {
        var result = Data(capacity: 32)
        var index = text.startIndex
        for _ in 0..<32 {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { throw ToolError.invalidKey }
            result.append(byte)
            index = next
        }
        return result
    }
    if let decoded = Data(base64Encoded: text), decoded.count == 32 { return decoded }
    throw ToolError.invalidKey
}

do {
    let arguments = CommandLine.arguments
    guard arguments.count >= 2 else { throw ToolError.usage }
    switch arguments[1] {
    case "sign":
        guard arguments.count == 5 else { throw ToolError.usage }
        let catalog = try Data(contentsOf: URL(fileURLWithPath: arguments[2]), options: [.mappedIfSafe])
        let keyData = try Data(contentsOf: URL(fileURLWithPath: arguments[3]), options: [.mappedIfSafe])
        let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: decodePrivateKey(keyData))
        let signature = try privateKey.signature(for: catalog)
        let output = URL(fileURLWithPath: arguments[4])
        let descriptor = Darwin.open(output.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw ToolError.outputExists }
        defer { Darwin.close(descriptor) }
        let written = signature.withUnsafeBytes { buffer in
            Darwin.write(descriptor, buffer.baseAddress, buffer.count)
        }
        guard written == signature.count, Darwin.fsync(descriptor) == 0 else { throw CocoaError(.fileWriteUnknown) }
    case "verify":
        guard arguments.count == 5,
              let publicKeyData = Data(base64Encoded: arguments[3]), publicKeyData.count == 32,
              let signature = Data(base64Encoded: arguments[4]), signature.count == 64
        else { throw ToolError.invalidBase64 }
        let catalog = try Data(contentsOf: URL(fileURLWithPath: arguments[2]), options: [.mappedIfSafe])
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
        guard publicKey.isValidSignature(signature, for: catalog) else { throw ToolError.invalidSignature }
    default:
        throw ToolError.usage
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
