import Darwin
import Foundation
import VelaIPC

public protocol LeaseMonotonicClock: Sendable {
    func nowNanoseconds() -> UInt64
}

public struct SystemLeaseMonotonicClock: LeaseMonotonicClock {
    public init() {}

    public func nowNanoseconds() -> UInt64 {
        var value = timespec()
        guard clock_gettime(CLOCK_MONOTONIC, &value) == 0 else { return 0 }
        return UInt64(value.tv_sec) &* 1_000_000_000 &+ UInt64(value.tv_nsec)
    }
}

public struct OwnerLeaseSnapshot: Equatable, Sendable {
    public let sessionID: UUID
    public let ownerUID: UInt32
    public let connectionID: UUID
    public let isConnected: Bool
    public let isSleeping: Bool
    public let expiresAtNanoseconds: UInt64
}

public enum OwnerLeaseError: Error, Equatable, Sendable {
    case ownerBusy
    case invalidSession
    case invalidConnection
    case expired
}

/// Serializes the single privileged owner and its bounded disconnect grace.
/// Sleep state is fed only by the Helper's trusted power observer, never by XPC.
public actor OwnerLeaseCoordinator {
    public static let defaultGraceNanoseconds: UInt64 = 120 * 1_000_000_000

    private struct State: Sendable {
        var sessionID: UUID
        var ownerUID: UInt32
        var connectionID: UUID
        var isConnected: Bool
        var isSleeping: Bool
        var expiresAtNanoseconds: UInt64
    }

    private let clock: any LeaseMonotonicClock
    private let graceNanoseconds: UInt64
    private var state: State?

    public init(
        clock: any LeaseMonotonicClock = SystemLeaseMonotonicClock(),
        graceNanoseconds: UInt64 = defaultGraceNanoseconds
    ) {
        self.clock = clock
        self.graceNanoseconds = graceNanoseconds
    }

    public func claim(
        ownerUID: UInt32,
        connectionID: UUID,
        requestedSessionID: UUID?
    ) throws -> OwnerLeaseSnapshot {
        let now = clock.nowNanoseconds()
        if let current = state {
            if !current.isSleeping, now > current.expiresAtNanoseconds {
                state = nil
            } else if current.isConnected {
                guard current.ownerUID == ownerUID,
                    current.connectionID == connectionID,
                    requestedSessionID == nil || requestedSessionID == current.sessionID
                else {
                    throw OwnerLeaseError.ownerBusy
                }
                return snapshot(current)
            } else {
                guard current.ownerUID == ownerUID,
                    requestedSessionID == nil || requestedSessionID == current.sessionID
                else {
                    throw OwnerLeaseError.ownerBusy
                }
                var resumed = current
                resumed.connectionID = connectionID
                resumed.isConnected = true
                resumed.expiresAtNanoseconds = deadline(after: now)
                state = resumed
                return snapshot(resumed)
            }
        }

        let claimed = State(
            sessionID: requestedSessionID ?? UUID(),
            ownerUID: ownerUID,
            connectionID: connectionID,
            isConnected: true,
            isSleeping: false,
            expiresAtNanoseconds: deadline(after: now)
        )
        state = claimed
        return snapshot(claimed)
    }

    public func renew(
        sessionID: UUID,
        connectionID: UUID
    ) throws -> OwnerLeaseSnapshot {
        guard var current = state else { throw OwnerLeaseError.invalidSession }
        guard current.sessionID == sessionID else { throw OwnerLeaseError.invalidSession }
        guard current.connectionID == connectionID, current.isConnected else {
            throw OwnerLeaseError.invalidConnection
        }
        let now = clock.nowNanoseconds()
        guard current.isSleeping || now <= current.expiresAtNanoseconds else {
            state = nil
            throw OwnerLeaseError.expired
        }
        current.expiresAtNanoseconds = deadline(after: now)
        state = current
        return snapshot(current)
    }

    public func disconnected(connectionID: UUID) {
        guard var current = state, current.connectionID == connectionID else { return }
        current.isConnected = false
        current.expiresAtNanoseconds = deadline(after: clock.nowNanoseconds())
        state = current
    }

    public func willSleep() {
        guard var current = state else { return }
        current.isSleeping = true
        state = current
    }

    public func didWake() {
        guard var current = state else { return }
        current.isSleeping = false
        // A full grace after wake prevents a false expiry when the machine slept
        // longer than the normal lease window.
        current.expiresAtNanoseconds = deadline(after: clock.nowNanoseconds())
        state = current
    }

    public func expiredOwner() -> OwnerLeaseSnapshot? {
        guard let current = state, !current.isSleeping,
            clock.nowNanoseconds() > current.expiresAtNanoseconds
        else {
            return nil
        }
        state = nil
        return snapshot(current)
    }

    public func release(sessionID: UUID, connectionID: UUID) throws {
        guard let current = state, current.sessionID == sessionID else {
            throw OwnerLeaseError.invalidSession
        }
        guard current.connectionID == connectionID else {
            throw OwnerLeaseError.invalidConnection
        }
        state = nil
    }

    public func current() -> OwnerLeaseSnapshot? {
        state.map(snapshot)
    }

    /// Reports expiry without consuming it. The cleanup timer remains the only
    /// code path that takes the expired owner and runs bounded engine cleanup.
    public func currentValid() -> OwnerLeaseSnapshot? {
        guard let state else { return nil }
        guard state.isSleeping || clock.nowNanoseconds() <= state.expiresAtNanoseconds else {
            return nil
        }
        return snapshot(state)
    }

    private func deadline(after now: UInt64) -> UInt64 {
        let addition = now.addingReportingOverflow(graceNanoseconds)
        return addition.overflow ? UInt64.max : addition.partialValue
    }

    private func snapshot(_ state: State) -> OwnerLeaseSnapshot {
        OwnerLeaseSnapshot(
            sessionID: state.sessionID,
            ownerUID: state.ownerUID,
            connectionID: state.connectionID,
            isConnected: state.isConnected,
            isSleeping: state.isSleeping,
            expiresAtNanoseconds: state.expiresAtNanoseconds
        )
    }
}
