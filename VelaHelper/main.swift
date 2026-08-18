import Darwin
import Foundation
import OSLog
import VelaIPC
import VelaPrivilegedCore

private let bootstrapLogger = Logger(
    subsystem: VelaIPCConstants.helperIdentifier,
    category: "SecureBootstrap"
)

private func secureBootstrapFailureCode(_ error: any Error) -> String {
    guard let error = error as? FixedMihomoPreflightError else {
        return String(reflecting: type(of: error))
    }
    return switch error {
    case .invalidBundleLayout: "mihomo.invalidBundleLayout"
    case .executableMissing: "mihomo.executableMissing"
    case .executableIsSymlink: "mihomo.executableIsSymlink"
    case .executableNotRegular: "mihomo.executableNotRegular"
    case .executableNotRunnable: "mihomo.executableNotRunnable"
    case .invalidMachO: "mihomo.invalidMachO"
    case .architectureMismatch: "mihomo.architectureMismatch"
    case .signingIdentifierMismatch: "mihomo.signingIdentifierMismatch"
    case .teamIdentifierMismatch: "mihomo.teamIdentifierMismatch"
    case .versionProbeTimedOut: "mihomo.versionProbeTimedOut"
    case .versionProbeFailed: "mihomo.versionProbeFailed"
    case .versionMismatch: "mihomo.versionMismatch"
    case .executableChanged: "mihomo.executableChanged"
    }
}

private func currentExecutableURL() throws -> URL {
    var requiredSize: UInt32 = 0
    _ = _NSGetExecutablePath(nil, &requiredSize)
    guard requiredSize > 0 else {
        throw FixedMihomoPreflightError.invalidBundleLayout
    }

    var buffer = [CChar](repeating: 0, count: Int(requiredSize))
    let status = buffer.withUnsafeMutableBufferPointer { pointer in
        _NSGetExecutablePath(pointer.baseAddress, &requiredSize)
    }
    guard status == 0 else {
        throw FixedMihomoPreflightError.invalidBundleLayout
    }

    let executablePathBytes = buffer
        .prefix { $0 != 0 }
        .map { UInt8(bitPattern: $0) }
    return URL(
        fileURLWithPath: String(decoding: executablePathBytes, as: UTF8.self),
        isDirectory: false
    ).standardizedFileURL.resolvingSymlinksInPath()
}

do {
    guard geteuid() == 0 else {
        throw LivePrivilegedRuntimeError.daemonNotRoot
    }
    // Mihomo inherits the Helper's process umask. Set the documented
    // fail-closed value before any root data or child process is created so
    // runtime caches cannot default to group/world-readable permissions.
    _ = umask(0o077)
    let signingIdentity = try VelaHelperSigningIdentityProvider.current()
    // launchd is allowed to supply a non-absolute argv[0]. Resolve the path
    // from the kernel instead so the fixed app-bundle trust boundary is the
    // same for interactive launches and SMAppService launches.
    let helperExecutableURL = try currentExecutableURL()
    let coordinator = try await PrivilegedHelperProductionFactory.makeCoordinator(
        helperExecutableURL: helperExecutableURL,
        helperCodeSignature: PrivilegedCodeSignature(
            signingIdentifier: signingIdentity.signingIdentifier,
            teamIdentifier: signingIdentity.teamIdentifier
        ),
        signingIdentitySummary: signingIdentity.safeSummary
    )
    let delegate = VelaHelperBootstrapListenerDelegate(
        signingIdentity: signingIdentity,
        coordinator: coordinator
    )
    let powerObserver = try VelaHelperPowerObserver(coordinator: coordinator)
    let leaseMaintenance = Task {
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(5))
                try Task.checkCancellation()
            } catch {
                return
            }
            _ = await coordinator.cleanupExpiredLeaseIfNeeded()
        }
    }
    let listener = NSXPCListener(machServiceName: VelaIPCConstants.machServiceName)
    listener.delegate = delegate
    listener.resume()
    // This top-level entry point is already an async task on the main executor,
    // so calling dispatchMain() would trap. Suspend cooperatively instead: XPC
    // can continue dispatching callbacks while the loop keeps every object that
    // owns daemon state strongly referenced for the lifetime of the process.
    while !Task.isCancelled {
        _ = (delegate, powerObserver, leaseMaintenance)
        try? await Task.sleep(for: .seconds(60))
    }
    leaseMaintenance.cancel()
} catch {
    // Never include paths, configuration, process environment, or a Controller
    // secret in the daemon's bootstrap failure output.
    let failureType = secureBootstrapFailureCode(error)
    bootstrapLogger.error(
        "VelaHelper failed its secure bootstrap. category=\(failureType, privacy: .public)"
    )
    let message = Data(
        "VelaHelper failed its secure bootstrap (\(failureType)).\n".utf8
    )
    try? FileHandle.standardError.write(contentsOf: message)
    exit(EXIT_FAILURE)
}
