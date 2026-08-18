import Foundation

nonisolated struct SupportZipEntry: Equatable, Sendable {
    let path: String
    let data: Data
}

nonisolated enum SupportZipArchive {
    private struct CentralRecord {
        let name: Data
        let crc32: UInt32
        let size: UInt32
        let offset: UInt32
    }

    static func encode(_ entries: [SupportZipEntry]) throws -> Data {
        guard entries.count <= 100 else {
            throw SupportBundleError.tooManyFiles(entries.count)
        }

        var archive = Data()
        var central: [CentralRecord] = []
        for entry in entries {
            try validate(path: entry.path)
            guard entry.data.count <= Int(UInt32.max), archive.count <= Int(UInt32.max) else {
                throw SupportBundleError.payloadTooLarge(entry.data.count)
            }
            let name = Data(entry.path.utf8)
            guard !name.isEmpty, name.count <= Int(UInt16.max) else {
                throw SupportBundleError.invalidRelativePath(entry.path)
            }
            let crc = crc32(entry.data)
            let size = UInt32(entry.data.count)
            let offset = UInt32(archive.count)

            append(UInt32(0x0403_4b50), to: &archive)
            append(UInt16(20), to: &archive)
            append(UInt16(0x0800), to: &archive)
            append(UInt16(0), to: &archive)
            append(UInt16(0), to: &archive)
            append(UInt16(0), to: &archive)
            append(crc, to: &archive)
            append(size, to: &archive)
            append(size, to: &archive)
            append(UInt16(name.count), to: &archive)
            append(UInt16(0), to: &archive)
            archive.append(name)
            archive.append(entry.data)
            central.append(CentralRecord(name: name, crc32: crc, size: size, offset: offset))
        }

        guard archive.count <= Int(UInt32.max) else {
            throw SupportBundleError.payloadTooLarge(archive.count)
        }
        let centralOffset = UInt32(archive.count)
        for record in central {
            append(UInt32(0x0201_4b50), to: &archive)
            append(UInt16(0x0314), to: &archive)
            append(UInt16(20), to: &archive)
            append(UInt16(0x0800), to: &archive)
            append(UInt16(0), to: &archive)
            append(UInt16(0), to: &archive)
            append(UInt16(0), to: &archive)
            append(record.crc32, to: &archive)
            append(record.size, to: &archive)
            append(record.size, to: &archive)
            append(UInt16(record.name.count), to: &archive)
            append(UInt16(0), to: &archive)
            append(UInt16(0), to: &archive)
            append(UInt16(0), to: &archive)
            append(UInt16(0), to: &archive)
            append(UInt32(0o100600 << 16), to: &archive)
            append(record.offset, to: &archive)
            archive.append(record.name)
        }
        guard archive.count <= Int(UInt32.max) else {
            throw SupportBundleError.payloadTooLarge(archive.count)
        }
        let centralSize = UInt32(archive.count) - centralOffset
        append(UInt32(0x0605_4b50), to: &archive)
        append(UInt16(0), to: &archive)
        append(UInt16(0), to: &archive)
        append(UInt16(central.count), to: &archive)
        append(UInt16(central.count), to: &archive)
        append(centralSize, to: &archive)
        append(centralOffset, to: &archive)
        append(UInt16(0), to: &archive)
        return archive
    }

    static func validate(path: String) throws {
        guard !path.isEmpty,
            !path.hasPrefix("/"),
            !path.hasPrefix("~"),
            !path.contains("\\"),
            !path.contains("\0")
        else {
            throw SupportBundleError.invalidRelativePath(path)
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw SupportBundleError.invalidRelativePath(path)
        }
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                let mask = UInt32(bitPattern: -Int32(crc & 1))
                crc = (crc >> 1) ^ (0xedb8_8320 & mask)
            }
        }
        return crc ^ 0xffff_ffff
    }
}
