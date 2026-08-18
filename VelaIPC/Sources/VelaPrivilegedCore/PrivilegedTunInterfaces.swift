import Darwin
import Foundation

public protocol PrivilegedTunInterfaceListing: Sendable {
    /// `nil` means the kernel interface table could not be inspected. Callers
    /// must treat that as unavailable, never as an empty/clean snapshot.
    func currentInterfaces() -> Set<String>?
}

public struct FoundationPrivilegedTunInterfaceLister: PrivilegedTunInterfaceListing {
    public init() {}

    public func currentInterfaces() -> Set<String>? {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return nil }
        defer { freeifaddrs(pointer) }

        var result = Set<String>()
        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let item = current {
            if let name = item.pointee.ifa_name {
                let value = String(cString: name)
                if value.hasPrefix("utun") {
                    guard PrivilegedTunInterfaceValidator.isValid(value) else {
                        return nil
                    }
                    result.insert(value)
                }
            }
            current = item.pointee.ifa_next
        }
        return result
    }
}

enum PrivilegedTunInterfaceValidator {
    /// This is a defensive journal bound, not a limit on the kernel's unit
    /// number. A normal baseline is tiny and names are additionally bounded by
    /// `IFNAMSIZ`.
    static let maximumJournalBaselineCount = 256

    static func isValid(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count > 4,
            bytes.count <= Int(IFNAMSIZ - 1),
            bytes.starts(with: Array("utun".utf8))
        else {
            return false
        }
        return bytes.dropFirst(4).allSatisfy { (48 ... 57).contains($0) }
    }

    static func isValidJournalBaseline(_ interfaces: [String]) -> Bool {
        guard interfaces.count <= maximumJournalBaselineCount,
            interfaces.allSatisfy(isValid),
            Set(interfaces).count == interfaces.count
        else {
            return false
        }
        return interfaces == interfaces.sorted()
    }
}

struct PrivilegedTunBaselineCleanupVerifier: Sendable {
    let interfaceLister: any PrivilegedTunInterfaceListing

    func waitForNoAdditions(
        since baseline: Set<String>,
        timeout: Duration
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if let current = interfaceLister.currentInterfaces(),
                current.subtracting(baseline).isEmpty
            {
                return true
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard let current = interfaceLister.currentInterfaces() else { return false }
        return current.subtracting(baseline).isEmpty
    }
}
