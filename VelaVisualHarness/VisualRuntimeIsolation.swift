#if DEBUG
import Foundation

/// Fail-closed dependencies used by the Debug visual harness.
///
/// These are runtime barriers, not presentation flags: every external I/O
/// entry point fails before opening a socket, launching a process, consulting
/// Keychain, enumerating the host network, or changing login-item state.
nonisolated enum VisualRuntimeIsolationError: Error, Equatable, Sendable {
    case networkAccessDisabled
    case processExecutionDisabled
}

extension VisualRuntimeIsolationError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .networkAccessDisabled:
            "External network access is disabled in the visual fixture harness."
        case .processExecutionDisabled:
            "Subprocess execution is disabled in the visual fixture harness."
        }
    }
}

actor VisualIsolationProcessExecutor: ProcessExecuting {
    private var attempts = 0

    func execute(_ request: ProcessExecutionRequest) async throws -> ProcessExecutionResult {
        attempts += 1
        throw VisualRuntimeIsolationError.processExecutionDisabled
    }

    func attemptCount() -> Int {
        attempts
    }
}

actor VisualIsolationCoreHTTPTransport: CoreHTTPStreaming {
    private var attempts = 0

    func stream(for request: URLRequest) async throws -> CoreHTTPResponse {
        attempts += 1
        throw VisualRuntimeIsolationError.networkAccessDisabled
    }

    func attemptCount() -> Int {
        attempts
    }
}

actor VisualIsolationSubscriptionHTTPFetcher: SubscriptionHTTPFetching {
    private var attempts = 0

    func fetch(_ request: SubscriptionHTTPRequest) async throws -> SubscriptionHTTPOutcome {
        attempts += 1
        throw VisualRuntimeIsolationError.networkAccessDisabled
    }

    func attemptCount() -> Int {
        attempts
    }
}

nonisolated final class VisualIsolationSecureStoreBackend:
    SecureStoreBackend,
    @unchecked Sendable
{
    private struct Key: Hashable {
        let service: String
        let account: String
    }

    private let lock = NSLock()
    private var storage: [Key: Data] = [:]

    func data(service: String, account: String) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return storage[Key(service: service, account: account)]
    }

    func setData(_ data: Data, service: String, account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        storage[Key(service: service, account: account)] = data
    }

    func removeData(service: String, account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        storage.removeValue(forKey: Key(service: service, account: account))
    }

    func entryCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return storage.count
    }
}

nonisolated struct VisualIsolationLocalNetworkContextProvider:
    LocalNetworkContextProviding,
    Sendable
{
    let fixedDate: Date

    init(fixedDate: Date = .distantPast) {
        self.fixedDate = fixedDate
    }

    func currentContext() throws -> LocalNetworkContext {
        LocalNetworkContext(routes: [], collectedAt: fixedDate)
    }
}

@MainActor
final class VisualIsolationLaunchAtLoginManager: LaunchAtLoginManaging {
    private(set) var status: LaunchAtLoginStatus = .notRegistered

    func register() {
        status = .enabled
    }

    func unregister() {
        status = .notRegistered
    }

    func openSystemSettings() {}
}

/// One assembly object owns every fail-closed dependency so AppEnvironment and
/// tests exercise the same concrete instances.
@MainActor
struct VisualRuntimeIsolation {
    let processExecutor = VisualIsolationProcessExecutor()
    let controllerRouter = RuntimeControllerRouter()
    let coreHTTPTransport = VisualIsolationCoreHTTPTransport()
    let subscriptionHTTPFetcher = VisualIsolationSubscriptionHTTPFetcher()
    let secureStoreBackend = VisualIsolationSecureStoreBackend()
    let localNetworkContextProvider: VisualIsolationLocalNetworkContextProvider
    let launchAtLoginManager = VisualIsolationLaunchAtLoginManager()

    init(fixedDate: Date = .distantPast) {
        localNetworkContextProvider = VisualIsolationLocalNetworkContextProvider(
            fixedDate: fixedDate
        )
    }
}
#endif
