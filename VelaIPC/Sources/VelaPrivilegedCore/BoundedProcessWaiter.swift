import Darwin
import Foundation

struct BoundedProcessTerminationResult: Equatable, Sendable {
    let timedOut: Bool
    let exited: Bool
}

enum BoundedProcessWaiter {
    static func wait(
        for process: Process,
        timeout: Duration,
        terminateGrace: Duration = .milliseconds(500),
        killGrace: Duration = .milliseconds(500)
    ) async -> BoundedProcessTerminationResult {
        if await waitForExit(process, timeout: timeout) {
            process.waitUntilExit()
            return BoundedProcessTerminationResult(timedOut: false, exited: true)
        }

        let ownedPID = process.processIdentifier
        if process.isRunning {
            process.terminate()
        }
        if await waitForExit(process, timeout: terminateGrace) {
            process.waitUntilExit()
            return BoundedProcessTerminationResult(timedOut: true, exited: true)
        }

        if process.isRunning, process.processIdentifier == ownedPID {
            _ = Darwin.kill(ownedPID, SIGKILL)
        }
        if await waitForExit(process, timeout: killGrace) {
            process.waitUntilExit()
            return BoundedProcessTerminationResult(timedOut: true, exited: true)
        }
        return BoundedProcessTerminationResult(timedOut: true, exited: false)
    }

    private static func waitForExit(_ process: Process, timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while process.isRunning, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return !process.isRunning
    }
}
