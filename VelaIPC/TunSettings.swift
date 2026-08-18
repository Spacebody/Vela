import Darwin
import Foundation

public enum TunStack: String, Codable, CaseIterable, Sendable {
    case mixed
    case system
    case gvisor
}

public struct TunSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var stack: TunStack
    public var autoRoute: Bool
    public var autoDetectInterface: Bool
    public var outboundInterface: String?
    public var excludedInterfaces: [String]
    public var dnsHijack: Bool
    public var allowLocalNetwork: Bool
    public var routeExcludeCIDRs: [String]
    public var device: String?
    public var mtu: Int?
    public var localMixedPort: UInt16?
    public var endpointIndependentNAT: Bool?
    public var udpTimeoutSeconds: Int?

    public init(
        enabled: Bool = true,
        stack: TunStack = .mixed,
        autoRoute: Bool = true,
        autoDetectInterface: Bool = true,
        outboundInterface: String? = nil,
        excludedInterfaces: [String] = [],
        dnsHijack: Bool = true,
        allowLocalNetwork: Bool = true,
        routeExcludeCIDRs: [String] = [],
        device: String? = nil,
        mtu: Int? = nil,
        localMixedPort: UInt16? = nil,
        endpointIndependentNAT: Bool? = nil,
        udpTimeoutSeconds: Int? = nil
    ) {
        self.enabled = enabled
        self.stack = stack
        self.autoRoute = autoRoute
        self.autoDetectInterface = autoDetectInterface
        self.outboundInterface = outboundInterface
        self.excludedInterfaces = excludedInterfaces
        self.dnsHijack = dnsHijack
        self.allowLocalNetwork = allowLocalNetwork
        self.routeExcludeCIDRs = routeExcludeCIDRs
        self.device = device
        self.mtu = mtu
        self.localMixedPort = localMixedPort
        self.endpointIndependentNAT = endpointIndependentNAT
        self.udpTimeoutSeconds = udpTimeoutSeconds
    }

    public static let defaults = TunSettings()

    public func validated() throws -> TunSettings {
        guard autoRoute else {
            throw TunSettingsValidationError.autoRouteMustRemainEnabled
        }

        if let device {
            guard Self.isValidDevice(device) else {
                throw TunSettingsValidationError.invalidDevice(device)
            }
        }

        if let mtu, !(576...9_000).contains(mtu) {
            throw TunSettingsValidationError.invalidMTU(mtu)
        }

        if let localMixedPort, localMixedPort < 1_024 {
            throw TunSettingsValidationError.invalidLocalMixedPort(localMixedPort)
        }

        if let udpTimeoutSeconds, !(1...3_600).contains(udpTimeoutSeconds) {
            throw TunSettingsValidationError.invalidUDPTimeout(udpTimeoutSeconds)
        }

        if !autoDetectInterface,
            outboundInterface?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
        {
            throw TunSettingsValidationError.fixedInterfaceRequired
        }

        if outboundInterface != nil, !excludedInterfaces.isEmpty {
            throw TunSettingsValidationError.includeExcludeInterfaceConflict
        }

        if let outboundInterface {
            try Self.validateInterfaceName(outboundInterface)
        }
        for interface in excludedInterfaces {
            try Self.validateInterfaceName(interface)
        }

        var normalized = self
        normalized.routeExcludeCIDRs = try Self.normalizeCIDRs(routeExcludeCIDRs)
        normalized.excludedInterfaces = Array(Set(excludedInterfaces)).sorted()
        normalized.outboundInterface = outboundInterface?.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        normalized.device = device?.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized
    }

    private static func isValidDevice(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count > 4,
            bytes.count <= Int(IFNAMSIZ - 1),
            bytes.starts(with: Array("utun".utf8))
        else {
            return false
        }
        let unit = bytes.dropFirst(4)
        return unit.allSatisfy { (48 ... 57).contains($0) }
    }

    private static func validateInterfaceName(_ value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= Int(IFNAMSIZ - 1) else {
            throw TunSettingsValidationError.invalidInterface(value)
        }
        guard trimmed.utf8.allSatisfy({ byte in
            (48 ... 57).contains(byte)
                || (65 ... 90).contains(byte)
                || (97 ... 122).contains(byte)
                || byte == 45 || byte == 46 || byte == 95
        }) else {
            throw TunSettingsValidationError.invalidInterface(value)
        }
    }

    private static func normalizeCIDRs(_ values: [String]) throws -> [String] {
        var unique = Set<String>()
        for rawValue in values {
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isValidCIDR(value) else {
                throw TunSettingsValidationError.invalidCIDR(rawValue)
            }
            unique.insert(value.lowercased())
        }
        return unique.sorted()
    }

    private static func isValidCIDR(_ value: String) -> Bool {
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2, let prefix = Int(components[1]) else { return false }

        var ipv4 = in_addr()
        if inet_pton(AF_INET, String(components[0]), &ipv4) == 1 {
            return (0...32).contains(prefix)
        }

        var ipv6 = in6_addr()
        if inet_pton(AF_INET6, String(components[0]), &ipv6) == 1 {
            return (0...128).contains(prefix)
        }
        return false
    }
}

public enum TunSettingsValidationError: Error, Equatable, Sendable {
    case autoRouteMustRemainEnabled
    case invalidDevice(String)
    case invalidMTU(Int)
    case invalidLocalMixedPort(UInt16)
    case invalidUDPTimeout(Int)
    case fixedInterfaceRequired
    case includeExcludeInterfaceConflict
    case invalidInterface(String)
    case invalidCIDR(String)
}

extension TunSettingsValidationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .autoRouteMustRemainEnabled:
            "TUN auto-route must remain enabled in Vela 0.3."
        case let .invalidDevice(device):
            "The TUN device name is invalid: \(device)."
        case let .invalidMTU(mtu):
            "The TUN MTU must be between 576 and 9000; received \(mtu)."
        case let .invalidLocalMixedPort(port):
            "The local mixed port must be a non-privileged port; received \(port)."
        case let .invalidUDPTimeout(seconds):
            "The UDP timeout must be between 1 and 3600 seconds; received \(seconds)."
        case .fixedInterfaceRequired:
            "A fixed outbound interface is required when auto detection is disabled."
        case .includeExcludeInterfaceConflict:
            "A fixed outbound interface and excluded interfaces cannot be set together."
        case let .invalidInterface(interface):
            "The network interface name is invalid: \(interface)."
        case let .invalidCIDR(cidr):
            "The route exclusion is not a valid CIDR: \(cidr)."
        }
    }
}

extension TunSettingsValidationError: VelaHelperStableError {
    public var helperErrorCode: VelaHelperErrorCode { .unsafeConfiguration }
    public var helperSafeMessage: String {
        "The privileged TUN settings are invalid."
    }
}
