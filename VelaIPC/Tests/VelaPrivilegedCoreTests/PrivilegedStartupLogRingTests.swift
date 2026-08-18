import Foundation
import Testing
import VelaIPC
@testable import VelaPrivilegedCore

@Suite("Privileged startup-only log ring")
struct PrivilegedStartupLogRingTests {
    @Test("The ring redacts secrets and drops all runtime traffic after sealing")
    func sealAndRedaction() async {
        let ring = PrivilegedStartupLogRing()
        let secret = SecretValue("controller-token-123")
        let sessionID = await ring.beginSession(secret: secret)
        await ring.append(
            Data("ready controller-token-123\n".utf8),
            channel: "stdout",
            sessionID: sessionID
        )
        await ring.seal(sessionID: sessionID)
        await ring.append(
            Data("runtime api.example.com 203.0.113.9\n".utf8),
            channel: "stdout",
            sessionID: sessionID
        )

        let entries = await ring.read(after: 0, maximumEntries: 10)
        #expect(entries.count == 1)
        #expect(entries[0].message == "ready <redacted>")
        #expect(!entries[0].message.contains("controller-token-123"))
        #expect(!entries.contains { $0.message.contains("api.example.com") })

        await ring.endSession(sessionID)
        #expect(await ring.read(after: 0, maximumEntries: 10).isEmpty)

        let nextSession = await ring.beginSession(secret: secret)
        await ring.append(
            Data("stale-session.example\n".utf8),
            channel: "stdout",
            sessionID: sessionID
        )
        #expect(await ring.read(after: 0, maximumEntries: 10).isEmpty)
        await ring.endSession(nextSession)
    }

    @Test("A controller secret is redacted across every byte split and randomized chunks")
    func chunkBoundaryRedaction() async {
        let ring = PrivilegedStartupLogRing()
        let rawSecret = "random-controller-token-0123456789"
        let secret = SecretValue(rawSecret)
        let payload = Data("level=info token=\(rawSecret) ready\n".utf8)

        for split in 1..<payload.count {
            let sessionID = await ring.beginSession(secret: secret)
            await ring.append(payload.prefix(split), channel: "stdout", sessionID: sessionID)
            await ring.append(payload.dropFirst(split), channel: "stdout", sessionID: sessionID)
            await ring.seal(sessionID: sessionID)
            let entries = await ring.read(after: 0, maximumEntries: 10)
            #expect(entries.map(\.message) == ["level=info token=<redacted> ready"])
            #expect(!entries.contains { $0.message.contains(rawSecret) })
            await ring.endSession(sessionID)
        }

        var generator = DeterministicChunkGenerator(state: 0x5645_4c41)
        for _ in 0..<64 {
            let sessionID = await ring.beginSession(secret: secret)
            var cursor = 0
            while cursor < payload.count {
                let remaining = payload.count - cursor
                let count = min(remaining, generator.next(maximum: 9))
                await ring.append(
                    payload[cursor..<(cursor + count)],
                    channel: "stderr",
                    sessionID: sessionID
                )
                cursor += count
            }
            await ring.seal(sessionID: sessionID)
            let entries = await ring.read(after: 0, maximumEntries: 10)
            #expect(entries.map(\.message) == ["level=info token=<redacted> ready"])
            #expect(!entries.contains { $0.message.contains(rawSecret) })
            await ring.endSession(sessionID)
        }
    }
}

private struct DeterministicChunkGenerator {
    var state: UInt64

    mutating func next(maximum: Int) -> Int {
        state = state &* 6_364_136_223_846_793_005 &+ 1
        return Int(state % UInt64(maximum)) + 1
    }
}
