import Darwin
import Foundation

public enum PrivilegedRouteProbeResult: Equatable, Sendable {
    case usesOwnedInterface
    case otherInterface
    case noRoute
    case unavailable
}

public protocol PrivilegedRouteProbing: Sendable {
    func probe(
        address: String,
        ownedInterface: String
    ) async -> PrivilegedRouteProbeResult
}

/// Selects a stable public IPv4 address that is not covered by the effective
/// route exclusions. The selected address is persisted in the root journal so
/// status, stop, and crash recovery all verify the same route.
enum PrivilegedRouteProbeSelector {
    static let candidates = [
        "1.1.1.1",
        "8.8.8.8",
        "9.9.9.9",
        "208.67.222.222",
        "4.2.2.1",
        "64.6.64.6",
        "94.140.14.14",
        "185.228.168.9",
    ]

    static func select(excluding cidrs: [String]) -> String? {
        candidates.first { candidate in
            !cidrs.contains { contains(address: candidate, cidr: $0) }
        }
    }

    static func isAllowedJournalAddress(_ address: String) -> Bool {
        candidates.contains(address)
    }

    static func contains(address: String, cidr: String) -> Bool {
        let components = cidr.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2,
            let prefix = Int(components[1]),
            (0...32).contains(prefix)
        else {
            return false
        }

        var candidate = in_addr()
        var network = in_addr()
        guard inet_pton(AF_INET, address, &candidate) == 1,
            inet_pton(AF_INET, String(components[0]), &network) == 1
        else {
            // IPv6 exclusions cannot contain an IPv4 probe.
            return false
        }

        let candidateValue = UInt32(bigEndian: candidate.s_addr)
        let networkValue = UInt32(bigEndian: network.s_addr)
        let mask = prefix == 0 ? UInt32(0) : UInt32.max << (32 - UInt32(prefix))
        return candidateValue & mask == networkValue & mask
    }
}

struct PrivilegedRouteCleanupVerifier: Sendable {
    let prober: any PrivilegedRouteProbing

    func waitForRemoval(
        address: String,
        interface: String,
        timeout: Duration
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if Self.isClean(await prober.probe(
                address: address,
                ownedInterface: interface
            )) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return Self.isClean(await prober.probe(
            address: address,
            ownedInterface: interface
        ))
    }

    private static func isClean(_ result: PrivilegedRouteProbeResult) -> Bool {
        switch result {
        case .otherInterface, .noRoute:
            true
        case .usesOwnedInterface, .unavailable:
            false
        }
    }
}

public struct FoundationPrivilegedRouteProber: PrivilegedRouteProbing {
    public init() {}

    public func probe(
        address: String,
        ownedInterface: String
    ) async -> PrivilegedRouteProbeResult {
        guard PrivilegedRouteProbeSelector.isAllowedJournalAddress(address),
            PrivilegedTunInterfaceValidator.isValid(ownedInterface)
        else {
            return .unavailable
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/route")
        process.arguments = ["-n", "get", address]
        process.environment = [
            "LANG": "C",
            "LC_ALL": "C",
            "PATH": "/usr/bin:/bin:/sbin",
        ]
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let captured = BoundedCommandOutput(maximumBytes: 16 * 1_024)
        pipe.fileHandleForReading.readabilityHandler = { readable in
            let data = readable.availableData
            if !data.isEmpty { captured.append(data) }
        }

        do {
            try process.run()
            let termination = await BoundedProcessWaiter.wait(
                for: process,
                timeout: .seconds(1),
                terminateGrace: .milliseconds(250),
                killGrace: .milliseconds(250)
            )
            pipe.fileHandleForReading.readabilityHandler = nil
            pipe.fileHandleForWriting.closeFile()
            if termination.exited {
                captured.append(pipe.fileHandleForReading.readDataToEndOfFile())
            }
            try? pipe.fileHandleForReading.close()
            guard termination.exited, !termination.timedOut else {
                return .unavailable
            }

            let output = String(decoding: captured.data(), as: UTF8.self)
            guard process.terminationStatus == 0 else {
                let normalized = output.lowercased()
                if normalized.contains("not in table")
                    || normalized.contains("no route to host")
                    || normalized.contains("route has not been found")
                {
                    return .noRoute
                }
                return .unavailable
            }

            guard let routedInterface = output
                .split(whereSeparator: \.isNewline)
                .compactMap({ line -> Substring? in
                    let components = line.split(whereSeparator: \.isWhitespace)
                    guard components.count == 2, components[0] == "interface:" else {
                        return nil
                    }
                    return components[1]
                })
                .first
            else {
                return .unavailable
            }
            return routedInterface == Substring(ownedInterface)
                ? .usesOwnedInterface
                : .otherInterface
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            pipe.fileHandleForWriting.closeFile()
            try? pipe.fileHandleForReading.close()
            return .unavailable
        }
    }
}
