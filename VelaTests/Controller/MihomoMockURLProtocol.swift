import Foundation
import Synchronization

nonisolated struct MihomoMockHTTPResponse: Sendable {
    let statusCode: Int
    let headers: [String: String]
    let data: Data

    init(
        statusCode: Int,
        headers: [String: String] = ["Content-Type": "application/json"],
        data: Data = Data()
    ) {
        self.statusCode = statusCode
        self.headers = headers
        self.data = data
    }
}

nonisolated final class MihomoMockURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> MihomoMockHTTPResponse

    private static let handlerStorage = Mutex<Handler?>(nil)

    static func setHandler(_ handler: @escaping Handler) {
        handlerStorage.withLock { storedHandler in
            storedHandler = handler
        }
    }

    static func reset() {
        handlerStorage.withLock { storedHandler in
            storedHandler = nil
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let handler = Self.handlerStorage.withLock { $0 }
        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        let request = self.request
        do {
            let stub = try handler(request)
            guard let url = request.url,
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: stub.statusCode,
                    httpVersion: "HTTP/1.1",
                    headerFields: stub.headers
                )
            else {
                client?.urlProtocol(
                    self,
                    didFailWithError: URLError(.badServerResponse)
                )
                return
            }

            client?.urlProtocol(
                self,
                didReceive: response,
                cacheStoragePolicy: .notAllowed
            )
            if !stub.data.isEmpty {
                client?.urlProtocol(self, didLoad: stub.data)
            }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

nonisolated final class MihomoHangingURLProtocol: URLProtocol, @unchecked Sendable {
    private struct State: Sendable {
        var startCount = 0
        var stopCount = 0
        var nextStartWaiterID: UInt64 = 0
        var startWaiters: [UInt64: CheckedContinuation<Bool, Never>] = [:]
    }

    private static let stateStorage = Mutex(State())

    static func reset() {
        let waiters = stateStorage.withLock { state in
            let waiters = Array(state.startWaiters.values)
            state.startCount = 0
            state.stopCount = 0
            state.startWaiters.removeAll()
            return waiters
        }
        for waiter in waiters {
            waiter.resume(returning: false)
        }
    }

    static func startCount() -> Int {
        stateStorage.withLock { $0.startCount }
    }

    static func stopCount() -> Int {
        stateStorage.withLock { $0.stopCount }
    }

    static func pendingStartWaiterCount() -> Int {
        stateStorage.withLock { $0.startWaiters.count }
    }

    static func waitUntilStarted(timeout: Duration = .seconds(2)) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await waitForStartSignal()
            }
            group.addTask {
                do {
                    try await Task.sleep(for: timeout)
                    return false
                } catch {
                    return false
                }
            }

            let didStart = await group.next() ?? false
            group.cancelAll()
            return didStart
        }
    }

    private static func waitForStartSignal() async -> Bool {
        let waiterID = stateStorage.withLock { state in
            defer { state.nextStartWaiterID &+= 1 }
            return state.nextStartWaiterID
        }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let immediateResult = stateStorage.withLock { state -> Bool? in
                    if state.startCount > 0 {
                        return true
                    }
                    if Task.isCancelled {
                        return false
                    }
                    state.startWaiters[waiterID] = continuation
                    return nil
                }
                if let immediateResult {
                    continuation.resume(returning: immediateResult)
                }
            }
        } onCancel: {
            let waiter = stateStorage.withLock { state in
                state.startWaiters.removeValue(forKey: waiterID)
            }
            waiter?.resume(returning: false)
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let waiters = Self.stateStorage.withLock { state in
            state.startCount += 1
            let waiters = Array(state.startWaiters.values)
            state.startWaiters.removeAll()
            return waiters
        }
        for waiter in waiters {
            waiter.resume(returning: true)
        }
    }

    override func stopLoading() {
        Self.stateStorage.withLock { $0.stopCount += 1 }
    }
}

nonisolated final class MihomoRequestRecorder: @unchecked Sendable {
    private let storage = Mutex<[URLRequest]>([])

    func record(_ request: URLRequest) {
        storage.withLock { $0.append(request) }
    }

    func requests() -> [URLRequest] {
        storage.withLock { $0 }
    }
}

nonisolated final class MihomoRequestCounter: @unchecked Sendable {
    private let storage = Mutex(0)

    func increment() -> Int {
        storage.withLock { value in
            value += 1
            return value
        }
    }

    func value() -> Int {
        storage.withLock { $0 }
    }
}
