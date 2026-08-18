import OSLog

nonisolated enum UpdateLog {
    static let updates = Logger(subsystem: "dev.yilin.Vela", category: "Updates")
    static let preparation = Logger(
        subsystem: "dev.yilin.Vela",
        category: "UpdatePreparation"
    )
    static let recovery = Logger(
        subsystem: "dev.yilin.Vela",
        category: "UpdateRecovery"
    )
    static let compatibility = Logger(
        subsystem: "dev.yilin.Vela",
        category: "ReleaseCompatibility"
    )
    static let sparkleBridge = Logger(
        subsystem: "dev.yilin.Vela",
        category: "SparkleBridge"
    )
}
