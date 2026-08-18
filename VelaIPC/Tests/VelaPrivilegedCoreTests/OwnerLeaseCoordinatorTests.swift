import Foundation
import Testing
@testable import VelaPrivilegedCore

@Suite("Privileged owner lease")
struct OwnerLeaseCoordinatorTests {
    @Test("Allows only one owner and reconnects the same session during grace")
    func ownerAndReconnect() async throws {
        let clock = TestLeaseClock()
        let leases = OwnerLeaseCoordinator(clock: clock, graceNanoseconds: 120)
        let firstConnection = UUID()
        let claimed = try await leases.claim(
            ownerUID: 501,
            connectionID: firstConnection,
            requestedSessionID: nil
        )

        await #expect(throws: OwnerLeaseError.ownerBusy) {
            try await leases.claim(
                ownerUID: 502,
                connectionID: UUID(),
                requestedSessionID: nil
            )
        }
        await leases.disconnected(connectionID: firstConnection)
        clock.advance(by: 100)
        let resumed = try await leases.claim(
            ownerUID: 501,
            connectionID: UUID(),
            requestedSessionID: claimed.sessionID
        )
        #expect(resumed.sessionID == claimed.sessionID)
        #expect(resumed.isConnected)
    }

    @Test("Sleep cannot cause a false expiry and wake grants a full grace")
    func sleepWake() async throws {
        let clock = TestLeaseClock()
        let leases = OwnerLeaseCoordinator(clock: clock, graceNanoseconds: 120)
        let connection = UUID()
        _ = try await leases.claim(
            ownerUID: 501,
            connectionID: connection,
            requestedSessionID: nil
        )
        await leases.disconnected(connectionID: connection)
        await leases.willSleep()
        clock.advance(by: 10_000)
        #expect(await leases.expiredOwner() == nil)
        await leases.didWake()
        clock.advance(by: 119)
        #expect(await leases.expiredOwner() == nil)
        clock.advance(by: 2)
        #expect(await leases.expiredOwner()?.ownerUID == 501)
        #expect(await leases.expiredOwner() == nil)
    }

    @Test("A relaunched same-uid app may reclaim a disconnected grace session")
    func relaunchWithoutPersistedSessionToken() async throws {
        let clock = TestLeaseClock()
        let leases = OwnerLeaseCoordinator(clock: clock, graceNanoseconds: 120)
        let oldConnection = UUID()
        let original = try await leases.claim(
            ownerUID: 501,
            connectionID: oldConnection,
            requestedSessionID: nil
        )
        await leases.disconnected(connectionID: oldConnection)

        let resumed = try await leases.claim(
            ownerUID: 501,
            connectionID: UUID(),
            requestedSessionID: nil
        )
        #expect(resumed.sessionID == original.sessionID)
        #expect(resumed.ownerUID == 501)
    }
}

private final class TestLeaseClock: LeaseMonotonicClock, @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0

    func nowNanoseconds() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(by amount: UInt64) {
        lock.lock()
        value += amount
        lock.unlock()
    }
}
