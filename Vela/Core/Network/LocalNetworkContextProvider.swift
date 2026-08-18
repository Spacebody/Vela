import Darwin
import Foundation

nonisolated struct LocalNetworkRoute: Equatable, Hashable, Sendable {
    let interfaceName: String
    let cidr: String
}

nonisolated struct LocalNetworkContext: Equatable, Sendable {
    let routes: [LocalNetworkRoute]
    let collectedAt: Date

    var routeExclusions: [String] {
        Array(Set(routes.map(\.cidr))).sorted()
    }
}

nonisolated protocol LocalNetworkContextProviding: Sendable {
    func currentContext() throws -> LocalNetworkContext
}

nonisolated struct LocalNetworkContextProvider: LocalNetworkContextProviding, Sendable {
    private let now: @Sendable () -> Date

    init(now: @escaping @Sendable () -> Date = { .now }) {
        self.now = now
    }

    func currentContext() throws -> LocalNetworkContext {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let head else {
            throw LocalNetworkContextError.interfaceEnumerationFailed(errno)
        }
        defer { freeifaddrs(head) }

        var routes = Set<LocalNetworkRoute>()
        var cursor: UnsafeMutablePointer<ifaddrs>? = head
        while let entry = cursor?.pointee {
            defer { cursor = entry.ifa_next }
            guard let addressPointer = entry.ifa_addr,
                let netmaskPointer = entry.ifa_netmask
            else { continue }

            let flags = Int32(entry.ifa_flags)
            guard flags & IFF_UP != 0,
                flags & IFF_RUNNING != 0,
                flags & IFF_LOOPBACK == 0
            else { continue }

            let name = String(cString: entry.ifa_name)
            guard Self.isEligibleInterface(name) else { continue }

            switch Int32(addressPointer.pointee.sa_family) {
            case AF_INET:
                if let cidr = Self.ipv4CIDR(addressPointer, netmask: netmaskPointer) {
                    routes.insert(LocalNetworkRoute(interfaceName: name, cidr: cidr))
                }
            case AF_INET6:
                if let cidr = Self.ipv6CIDR(addressPointer, netmask: netmaskPointer) {
                    routes.insert(LocalNetworkRoute(interfaceName: name, cidr: cidr))
                }
            default:
                continue
            }
        }

        return LocalNetworkContext(
            routes: routes.sorted {
                $0.interfaceName == $1.interfaceName
                    ? $0.cidr < $1.cidr
                    : $0.interfaceName < $1.interfaceName
            },
            collectedAt: now()
        )
    }

    private static func isEligibleInterface(_ name: String) -> Bool {
        let lower = name.lowercased()
        return !lower.hasPrefix("lo")
            && !lower.hasPrefix("utun")
            && !lower.hasPrefix("ipsec")
            && !lower.hasPrefix("ppp")
            && !lower.hasPrefix("awdl")
            && !lower.hasPrefix("llw")
    }

    private static func ipv4CIDR(
        _ address: UnsafeMutablePointer<sockaddr>,
        netmask: UnsafeMutablePointer<sockaddr>
    ) -> String? {
        let address4 = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self).pointee
        let mask4 = UnsafeRawPointer(netmask).assumingMemoryBound(to: sockaddr_in.self).pointee
        let addressValue = UInt32(bigEndian: address4.sin_addr.s_addr)
        let maskValue = UInt32(bigEndian: mask4.sin_addr.s_addr)
        guard let prefix = contiguousPrefixLength(bytes: withUnsafeBytes(of: maskValue.bigEndian) {
            Array($0)
        }) else { return nil }

        let firstOctet = UInt8((addressValue >> 24) & 0xff)
        guard firstOctet != 0, firstOctet != 127, prefix < 32 else { return nil }

        var network = in_addr(s_addr: (addressValue & maskValue).bigEndian)
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &network, &buffer, socklen_t(buffer.count)) != nil else {
            return nil
        }
        return "\(decodedCString(buffer))/\(prefix)"
    }

    private static func ipv6CIDR(
        _ address: UnsafeMutablePointer<sockaddr>,
        netmask: UnsafeMutablePointer<sockaddr>
    ) -> String? {
        let address6 = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in6.self).pointee
        let mask6 = UnsafeRawPointer(netmask).assumingMemoryBound(to: sockaddr_in6.self).pointee
        let addressBytes = withUnsafeBytes(of: address6.sin6_addr) { Array($0) }
        let maskBytes = withUnsafeBytes(of: mask6.sin6_addr) { Array($0) }
        guard let prefix = contiguousPrefixLength(bytes: maskBytes), prefix < 128 else { return nil }
        guard addressBytes.count == 16, addressBytes[0] != 0xff else { return nil }
        // Link-local addresses carry a scope identifier and are already kept on-link.
        guard !(addressBytes[0] == 0xfe && (addressBytes[1] & 0xc0) == 0x80) else {
            return nil
        }

        let networkBytes = zip(addressBytes, maskBytes).map { address, mask in
            address & mask
        }
        var network = in6_addr()
        withUnsafeMutableBytes(of: &network) { destination in
            destination.copyBytes(from: networkBytes)
        }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &network, &buffer, socklen_t(buffer.count)) != nil else {
            return nil
        }
        return "\(decodedCString(buffer).lowercased())/\(prefix)"
    }

    private static func decodedCString(_ buffer: [CChar]) -> String {
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func contiguousPrefixLength(bytes: [UInt8]) -> Int? {
        var prefix = 0
        var foundZero = false
        for byte in bytes {
            for shift in stride(from: 7, through: 0, by: -1) {
                let isSet = byte & (1 << shift) != 0
                if foundZero, isSet { return nil }
                if isSet {
                    prefix += 1
                } else {
                    foundZero = true
                }
            }
        }
        return prefix
    }
}

nonisolated enum LocalNetworkContextError: Error, Equatable, Sendable {
    case interfaceEnumerationFailed(Int32)
}
