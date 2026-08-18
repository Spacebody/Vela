import Foundation

@objc public protocol VelaHelperProtocol {
    func handshake(_ request: Data, withReply reply: @escaping @Sendable (Data?, NSError?) -> Void)
    func status(_ request: Data, withReply reply: @escaping @Sendable (Data?, NSError?) -> Void)
    func prepareStart(_ request: Data, withReply reply: @escaping @Sendable (Data?, NSError?) -> Void)
    func stageConfiguration(
        _ transaction: Data,
        configuration: Data,
        withReply reply: @escaping @Sendable (Data?, NSError?) -> Void
    )
    func stageResource(
        _ metadata: Data,
        file: FileHandle,
        withReply reply: @escaping @Sendable (Data?, NSError?) -> Void
    )
    func commitStart(_ request: Data, withReply reply: @escaping @Sendable (Data?, NSError?) -> Void)
    func abortStart(_ request: Data, withReply reply: @escaping @Sendable (Data?, NSError?) -> Void)
    func stop(_ request: Data, withReply reply: @escaping @Sendable (Data?, NSError?) -> Void)
    func renewLease(_ request: Data, withReply reply: @escaping @Sendable (Data?, NSError?) -> Void)
    func readLogBatch(_ request: Data, withReply reply: @escaping @Sendable (Data?, NSError?) -> Void)
    func cleanup(_ request: Data, withReply reply: @escaping @Sendable (Data?, NSError?) -> Void)
    func prepareCoreInstall(_ request: Data, withReply reply: @escaping @Sendable (Data?, NSError?) -> Void)
    func stageCoreFile(
        _ metadata: Data,
        file: FileHandle,
        withReply reply: @escaping @Sendable (Data?, NSError?) -> Void
    )
    func commitCoreInstall(_ request: Data, withReply reply: @escaping @Sendable (Data?, NSError?) -> Void)
    func abortCoreInstall(_ request: Data, withReply reply: @escaping @Sendable (Data?, NSError?) -> Void)
    func listInstalledCores(_ request: Data, withReply reply: @escaping @Sendable (Data?, NSError?) -> Void)
    func refreshCoreCatalog(_ request: Data, withReply reply: @escaping @Sendable (Data?, NSError?) -> Void)
    func removeCore(_ request: Data, withReply reply: @escaping @Sendable (Data?, NSError?) -> Void)
    func validateCore(_ request: Data, withReply reply: @escaping @Sendable (Data?, NSError?) -> Void)
}

public enum VelaHelperXPCInterface {
    public static func make() -> NSXPCInterface {
        // `Data`, `NSError`, and the directly typed `FileHandle` argument are
        // encoded by the protocol signature itself. `setClasses` is only needed
        // for object classes nested inside collection arguments.
        NSXPCInterface(with: VelaHelperProtocol.self)
    }
}
