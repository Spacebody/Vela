import Foundation

nonisolated enum EngineFailure: Error, Equatable, Sendable {
    case executableMissing
    case executableNotRunnable(URL)
    case coreIntegrityFailed(String)
    case configurationInvalid(String)
    case processLaunchFailed(String)
    case controllerUnavailable(String)
    case systemProxyFailed(String)
    case unexpectedTermination(exitCode: Int32)
    case stopFailed(String)
    case runtimeConfigBuildFailed(String)
    case healthCheckFailed(String)

    var summary: String {
        switch self {
        case .executableMissing:
            "The Mihomo executable is missing from the app bundle."
        case let .executableNotRunnable(url):
            "Mihomo is not executable at \(url.path)."
        case let .coreIntegrityFailed(details):
            "The bundled Mihomo core did not pass integrity checks: \(details)"
        case let .configurationInvalid(details):
            "The selected configuration is invalid: \(details)"
        case let .processLaunchFailed(details):
            "Mihomo could not be launched: \(details)"
        case let .controllerUnavailable(details):
            "The Mihomo controller is unavailable: \(details)"
        case let .systemProxyFailed(details):
            "The system proxy operation failed: \(details)"
        case let .unexpectedTermination(exitCode):
            "Mihomo exited unexpectedly with status \(exitCode)."
        case let .stopFailed(details):
            "Mihomo could not be stopped cleanly: \(details)"
        case let .runtimeConfigBuildFailed(details):
            "The runtime configuration could not be generated: \(details)"
        case let .healthCheckFailed(details):
            "The engine health check failed: \(details)"
        }
    }
}
