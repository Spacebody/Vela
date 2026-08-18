#if DEBUG
import Foundation

nonisolated struct VisualFixtureClock: Equatable, Sendable {
    let now: Date
}

nonisolated struct SeededVisualUUIDGenerator: Equatable, Sendable {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    }

    mutating func next() -> UUID {
        let upper = nextWord()
        let lower = nextWord()
        var bytes = withUnsafeBytes(of: upper.bigEndian, Array.init)
            + withUnsafeBytes(of: lower.bigEndian, Array.init)
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    private mutating func nextWord() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

nonisolated struct VisualFixtureEnvironment: Equatable, Sendable {
    let fixtureID: String
    let route: VisualFixtureRouteDescriptor
    let clock: VisualFixtureClock
    let uuidSeed: UInt64
    let allowsNetwork: Bool
    let allowsKeychain: Bool
    let allowsPrivilegedHelper: Bool
    let allowsSystemProxy: Bool
    let allowsTUN: Bool

    init(configuration: VisualUITestConfiguration) {
        fixtureID = configuration.fixtureID
        // `VisualUITestConfiguration.resolve` has already validated this
        // lookup. Keeping the typed route in the environment prevents page,
        // state, boundary, and inspector policy from drifting after launch.
        route = VisualFixtureRouteCatalog.route(
            page: configuration.page,
            state: configuration.state
        )!
        clock = VisualFixtureClock(now: configuration.fixedDate)
        uuidSeed = configuration.uuidSeed
        allowsNetwork = false
        allowsKeychain = false
        allowsPrivilegedHelper = false
        allowsSystemProxy = false
        allowsTUN = false
    }
}
#endif
