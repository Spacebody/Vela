import Foundation

/// A small FIFO gate used across actor suspension points. Actor isolation alone
/// is reentrant, so it cannot make a multi-await start/stop transaction atomic.
///
/// Acquisition is intentionally non-cancellable. Once a privileged operation is
/// accepted, it must reach its cleanup or rollback boundary even if its client
/// task is cancelled. Every successful acquisition must therefore be paired with
/// `release()`, normally through `defer`.
final class AsyncExclusiveOperationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isHeld {
                waiters.append(continuation)
                lock.unlock()
            } else {
                isHeld = true
                lock.unlock()
                continuation.resume()
            }
        }
    }

    func release() {
        lock.lock()
        if waiters.isEmpty {
            isHeld = false
            lock.unlock()
        } else {
            let next = waiters.removeFirst()
            lock.unlock()
            next.resume()
        }
    }
}
