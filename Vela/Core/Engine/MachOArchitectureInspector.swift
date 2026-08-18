import Foundation

nonisolated struct MachOInspection: Equatable, Sendable {
    nonisolated enum Architecture: String, Equatable, Sendable {
        case arm64
    }

    nonisolated enum FileType: String, Equatable, Sendable {
        case executable
    }

    let architecture: Architecture
    let fileType: FileType
    let is64Bit: Bool
    let isThin: Bool
}

nonisolated protocol MachOArchitectureInspecting: Sendable {
    func inspect(executableAt url: URL) throws -> MachOInspection
}

nonisolated protocol MachOHeaderReading: Sendable {
    func readHeader(at url: URL, maximumByteCount: Int) throws -> Data
}

nonisolated struct FileMachOHeaderReader: MachOHeaderReading, Sendable {
    func readHeader(at url: URL, maximumByteCount: Int) throws -> Data {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            return try handle.read(upToCount: maximumByteCount) ?? Data()
        } catch {
            throw MachOArchitectureInspectionError.readFailed(
                path: url.path,
                reason: error.localizedDescription
            )
        }
    }
}

nonisolated struct MachOArchitectureInspector: MachOArchitectureInspecting, Sendable {
    private static let machHeader64ByteCount = 32
    private static let machMagic64: UInt32 = 0xFEED_FACF
    private static let machMagic32: UInt32 = 0xFEED_FACE
    private static let swappedMachMagic64: UInt32 = 0xCFFA_EDFE
    private static let arm64CPUType: UInt32 = 0x0100_000C
    private static let x86_64CPUType: UInt32 = 0x0100_0007
    private static let executableFileType: UInt32 = 0x0000_0002
    private static let fatMagics: Set<UInt32> = [
        0xCAFE_BABE,
        0xBEBA_FECA,
        0xCAFE_BABF,
        0xBFBA_FECA,
    ]

    private let headerReader: any MachOHeaderReading

    init(headerReader: any MachOHeaderReading = FileMachOHeaderReader()) {
        self.headerReader = headerReader
    }

    func inspect(executableAt url: URL) throws -> MachOInspection {
        let data = try headerReader.readHeader(
            at: url,
            maximumByteCount: Self.machHeader64ByteCount
        )
        guard data.count >= Self.machHeader64ByteCount else {
            throw MachOArchitectureInspectionError.truncatedHeader(
                path: url.path,
                actualByteCount: data.count
            )
        }

        let bytes = [UInt8](data)
        let magic = Self.readLittleEndianUInt32(bytes, offset: 0)
        let bigEndianMagic = Self.readBigEndianUInt32(bytes, offset: 0)
        if Self.fatMagics.contains(magic) || Self.fatMagics.contains(bigEndianMagic) {
            throw MachOArchitectureInspectionError.fatBinary(path: url.path)
        }
        if magic == Self.machMagic32 {
            throw MachOArchitectureInspectionError.not64Bit(path: url.path)
        }
        guard magic == Self.machMagic64 else {
            if magic == Self.swappedMachMagic64 {
                throw MachOArchitectureInspectionError.unsupportedByteOrder(path: url.path)
            }
            throw MachOArchitectureInspectionError.invalidMagic(path: url.path, magic: magic)
        }

        let cpuType = Self.readLittleEndianUInt32(bytes, offset: 4)
        guard cpuType == Self.arm64CPUType else {
            let architecture = cpuType == Self.x86_64CPUType
                ? "x86_64"
                : String(format: "cpu-type-0x%08x", cpuType)
            throw MachOArchitectureInspectionError.architectureMismatch(
                path: url.path,
                actual: architecture
            )
        }

        let fileType = Self.readLittleEndianUInt32(bytes, offset: 12)
        guard fileType == Self.executableFileType else {
            throw MachOArchitectureInspectionError.notExecutableMachO(
                path: url.path,
                fileType: fileType
            )
        }

        return MachOInspection(
            architecture: .arm64,
            fileType: .executable,
            is64Bit: true,
            isThin: true
        )
    }

    private static func readLittleEndianUInt32(_ bytes: [UInt8], offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
    }

    private static func readBigEndianUInt32(_ bytes: [UInt8], offset: Int) -> UInt32 {
        UInt32(bytes[offset]) << 24
            | UInt32(bytes[offset + 1]) << 16
            | UInt32(bytes[offset + 2]) << 8
            | UInt32(bytes[offset + 3])
    }
}

nonisolated enum MachOArchitectureInspectionError: Error, Equatable, Sendable {
    case readFailed(path: String, reason: String)
    case truncatedHeader(path: String, actualByteCount: Int)
    case fatBinary(path: String)
    case not64Bit(path: String)
    case unsupportedByteOrder(path: String)
    case invalidMagic(path: String, magic: UInt32)
    case architectureMismatch(path: String, actual: String)
    case notExecutableMachO(path: String, fileType: UInt32)
}

extension MachOArchitectureInspectionError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .readFailed(path, reason):
            "Could not read the Mihomo Mach-O header at \(path): \(reason)"
        case let .truncatedHeader(path, actualByteCount):
            "Mihomo at \(path) has a truncated Mach-O header (\(actualByteCount) bytes)."
        case let .fatBinary(path):
            "Mihomo at \(path) is a fat or universal binary; a thin arm64 executable is required."
        case let .not64Bit(path):
            "Mihomo at \(path) is not a 64-bit Mach-O executable."
        case let .unsupportedByteOrder(path):
            "Mihomo at \(path) uses an unsupported Mach-O byte order."
        case let .invalidMagic(path, magic):
            "Mihomo at \(path) is not Mach-O data (magic 0x\(String(format: "%08x", magic)))."
        case let .architectureMismatch(path, actual):
            "Mihomo at \(path) must be thin arm64; found \(actual)."
        case let .notExecutableMachO(path, fileType):
            "Mihomo at \(path) is not an MH_EXECUTE Mach-O (file type \(fileType))."
        }
    }
}
