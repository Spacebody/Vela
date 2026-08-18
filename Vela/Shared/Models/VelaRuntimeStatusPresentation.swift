import Foundation
import VelaIPC

/// Keeps unavailable runtime telemetry distinct from a real zero value.
/// Static configuration remains visible while traffic takeover is inactive,
/// but counters and rates use an em dash until a live runtime can observe them.
nonisolated enum VelaRuntimeMetricPresentation {
    static let unavailable = "—"

    static func value(_ value: String, isAvailable: Bool) -> String {
        isAvailable ? value : unavailable
    }
}

/// Localized presentation for stable runtime-domain states. Raw values remain
/// unchanged for persistence, diagnostics, IPC, and exported technical data.
nonisolated enum VelaRuntimeStatusPresentation {
    static func helperTitle(_ state: PrivilegedComponentState?) -> String {
        guard let state else {
            return VelaL10n.string(
                "runtime.status.unavailable",
                defaultValue: "Unavailable"
            )
        }
        return switch state {
        case .notInstalled:
            VelaL10n.string("runtime.helper.notInstalled", defaultValue: "Not Installed")
        case .registering:
            VelaL10n.string("runtime.helper.registering", defaultValue: "Registering…")
        case .needsApproval:
            VelaL10n.string("runtime.helper.needsApproval", defaultValue: "Needs Approval")
        case .connecting:
            VelaL10n.string("runtime.helper.connecting", defaultValue: "Connecting…")
        case .ready:
            VelaL10n.string("runtime.helper.ready", defaultValue: "Ready")
        case .incompatible:
            VelaL10n.string("runtime.helper.updateRequired", defaultValue: "Update Required")
        case .damaged:
            VelaL10n.string("runtime.helper.damaged", defaultValue: "Damaged")
        case .uninstalling:
            VelaL10n.string("runtime.helper.uninstalling", defaultValue: "Uninstalling…")
        case .failed:
            VelaL10n.string("runtime.helper.failed", defaultValue: "Failed")
        }
    }

    static func helperDetail(_ state: PrivilegedComponentState?) -> String? {
        guard let state else { return nil }
        return switch state {
        case .notInstalled, .registering, .connecting, .ready, .uninstalling:
            nil
        case .needsApproval:
            VelaL10n.string(
                "runtime.helper.needsApproval.detail",
                defaultValue:
                    "Approve Vela in System Settings > General > Login Items & Extensions."
            )
        case .incompatible:
            VelaL10n.string(
                "runtime.helper.updateRequired.detail",
                defaultValue: "The installed Helper protocol is incompatible with this Vela build."
            )
        case .damaged:
            VelaL10n.string(
                "runtime.helper.damaged.detail",
                defaultValue: "The privileged component is damaged. Reinstall it before enabling TUN."
            )
        case .failed:
            VelaL10n.string(
                "runtime.helper.failed.detail",
                defaultValue: "The privileged component operation failed. Open Diagnostics for redacted details."
            )
        }
    }

    static func transitionTitle(_ state: EngineTransitionState) -> String {
        switch state {
        case .idle:
            VelaL10n.string("runtime.transition.idle", defaultValue: "Idle")
        case .preparingTarget:
            VelaL10n.string(
                "runtime.transition.preparingTarget",
                defaultValue: "Preparing target…"
            )
        case .disablingSystemProxy:
            VelaL10n.string(
                "runtime.transition.disablingSystemProxy",
                defaultValue: "Disabling System Proxy…"
            )
        case .stoppingSource:
            VelaL10n.string(
                "runtime.transition.stoppingSource",
                defaultValue: "Stopping current backend…"
            )
        case .startingTarget:
            VelaL10n.string(
                "runtime.transition.startingTarget",
                defaultValue: "Starting target backend…"
            )
        case .verifyingTarget:
            VelaL10n.string(
                "runtime.transition.verifyingTarget",
                defaultValue: "Verifying network…"
            )
        case .committing:
            VelaL10n.string("runtime.transition.committing", defaultValue: "Committing…")
        case .rollingBack:
            VelaL10n.string("runtime.transition.rollingBack", defaultValue: "Rolling back…")
        case let .failed(failure):
            VelaL10n.string(
                "runtime.transition.failedAtObjectFormat",
                defaultValue: "Failed at %@",
                arguments: transitionPhaseTitle(failure.failedPhase)
            )
        }
    }

    static func transitionPhaseTitle(_ phase: EngineTransitionPhase) -> String {
        switch phase {
        case .preparingTarget:
            VelaL10n.string(
                "runtime.transition.phase.preparingTarget",
                defaultValue: "Preparing and Validating"
            )
        case .disablingSystemProxy:
            VelaL10n.string(
                "runtime.transition.phase.disablingSystemProxy",
                defaultValue: "Disabling System Proxy"
            )
        case .stoppingSource:
            VelaL10n.string(
                "runtime.transition.phase.stoppingSource",
                defaultValue: "Stopping Current Backend"
            )
        case .startingTarget:
            VelaL10n.string(
                "runtime.transition.phase.startingTarget",
                defaultValue: "Starting Privileged Backend"
            )
        case .verifyingTarget:
            VelaL10n.string(
                "runtime.transition.phase.verifyingTarget",
                defaultValue: "Verifying TUN, Route, and DNS"
            )
        case .committing:
            VelaL10n.string(
                "runtime.transition.phase.committing",
                defaultValue: "Committing Transition"
            )
        case .rollingBack:
            VelaL10n.string(
                "runtime.transition.phase.rollingBack",
                defaultValue: "Rolling Back"
            )
        }
    }

    static func backendTitle(_ backend: EngineBackendKind) -> String {
        switch backend {
        case .userProcess:
            VelaL10n.string(
                "runtime.backend.userProcess",
                defaultValue: "User Process"
            )
        case .privilegedDaemon:
            VelaL10n.string("runtime.backend.tun", defaultValue: "TUN")
        }
    }

    static func systemProxyTitle(_ status: SystemProxyStatus) -> String {
        switch (status.aggregate, status.recovery) {
        case (.unavailable, _):
            VelaL10n.string("runtime.systemProxy.unavailable", defaultValue: "Unavailable")
        case (.disabled, .none):
            VelaL10n.string("runtime.systemProxy.off", defaultValue: "Off")
        case (.applied, .managed):
            VelaL10n.string(
                "runtime.systemProxy.onManaged",
                defaultValue: "On · Managed by Vela"
            )
        case (.applied, .none), (.externallyConfigured, .none):
            VelaL10n.string("runtime.systemProxy.onExternal", defaultValue: "On · External")
        case (.disabled, .managed), (.disabled, .recoveryRequired):
            VelaL10n.string(
                "runtime.systemProxy.offRecoveryPending",
                defaultValue: "Off · Recovery pending"
            )
        case (.partiallyApplied, _), (.externallyConfigured, .managed),
            (.externallyConfigured, .recoveryRequired), (.applied, .recoveryRequired):
            VelaL10n.string(
                "runtime.systemProxy.partialNeedsAttention",
                defaultValue: "Partial · Needs attention"
            )
        }
    }

    static func systemProxyDetail(_ status: SystemProxyStatus) -> String? {
        switch status.recovery {
        case .none:
            switch status.aggregate {
            case .externallyConfigured:
                guard let services = configuredSystemProxyServiceList(status) else {
                    return nil
                }
                return VelaL10n.string(
                    "runtime.systemProxy.detail.externalFormat",
                    defaultValue: "External proxy settings detected on %@.",
                    arguments: services
                )
            case .applied:
                return VelaL10n.string(
                    "runtime.systemProxy.detail.unowned",
                    defaultValue: "These settings match Vela's port, but Vela does not own their recovery data."
                )
            case .partiallyApplied:
                guard let services = configuredSystemProxyServiceList(status) else {
                    return nil
                }
                return VelaL10n.string(
                    "runtime.systemProxy.detail.partialFormat",
                    defaultValue: "Proxy settings differ across %@.",
                    arguments: services
                )
            case .unavailable, .disabled:
                return nil
            }
        case let .managed(serviceNames):
            let services = systemProxyServiceList(serviceNames)
            if status.aggregate == .applied {
                return VelaL10n.string(
                    "runtime.systemProxy.detail.verifiedFormat",
                    defaultValue: "HTTP, HTTPS, and SOCKS are verified on %@.",
                    arguments: services
                )
            }
            return VelaL10n.string(
                "runtime.systemProxy.detail.recoveryDataFormat",
                defaultValue: "Vela has recovery data for %@.",
                arguments: services
            )
        case let .recoveryRequired(serviceNames):
            return VelaL10n.string(
                "runtime.systemProxy.detail.restoreFormat",
                defaultValue: "Restore or review %@ before stopping Mihomo.",
                arguments: systemProxyServiceList(serviceNames)
            )
        }
    }

    private static func configuredSystemProxyServiceList(
        _ status: SystemProxyStatus
    ) -> String? {
        let names = status.services.filter { service in
            service.endpoints.contains(where: \.isEnabled)
                || service.automatic.isEnabled
        }.map(\.name)
        guard !names.isEmpty else { return nil }
        return systemProxyServiceList(names)
    }

    private static func systemProxyServiceList(_ names: [String]) -> String {
        let uniqueNames = Array(Set(names)).sorted()
        if uniqueNames.count <= 3 {
            return uniqueNames.joined(separator: ", ")
        }
        return VelaL10n.string(
            "runtime.systemProxy.detail.moreFormat",
            defaultValue: "%@ and %lld more",
            arguments: uniqueNames.prefix(3).joined(separator: ", "),
            uniqueNames.count - 3
        )
    }

    static func engineFailureSummary(_ failure: EngineFailure) -> String {
        switch failure {
        case .executableMissing:
            VelaL10n.string(
                "runtime.engineFailure.executableMissing",
                defaultValue: "The Mihomo executable is missing from the app bundle."
            )
        case .executableNotRunnable:
            VelaL10n.string(
                "runtime.engineFailure.executableNotRunnable",
                defaultValue: "The bundled Mihomo executable cannot be run."
            )
        case .coreIntegrityFailed:
            VelaL10n.string(
                "runtime.engineFailure.coreIntegrityFailed",
                defaultValue: "The Mihomo core did not pass integrity checks."
            )
        case .configurationInvalid:
            VelaL10n.string(
                "runtime.engineFailure.configurationInvalid",
                defaultValue: "The selected configuration is invalid."
            )
        case .processLaunchFailed:
            VelaL10n.string(
                "runtime.engineFailure.processLaunchFailed",
                defaultValue: "Mihomo could not be launched."
            )
        case .controllerUnavailable:
            VelaL10n.string(
                "runtime.engineFailure.controllerUnavailable",
                defaultValue: "The Mihomo Controller is unavailable."
            )
        case .systemProxyFailed:
            VelaL10n.string(
                "runtime.engineFailure.systemProxyFailed",
                defaultValue: "The System Proxy operation failed."
            )
        case let .unexpectedTermination(exitCode):
            VelaL10n.string(
                "runtime.engineFailure.unexpectedTerminationFormat",
                defaultValue: "Mihomo exited unexpectedly with status %lld.",
                arguments: Int64(exitCode)
            )
        case .stopFailed:
            VelaL10n.string(
                "runtime.engineFailure.stopFailed",
                defaultValue: "Mihomo could not be stopped cleanly."
            )
        case .runtimeConfigBuildFailed:
            VelaL10n.string(
                "runtime.engineFailure.runtimeConfigBuildFailed",
                defaultValue: "The runtime configuration could not be generated."
            )
        case .healthCheckFailed:
            VelaL10n.string(
                "runtime.engineFailure.healthCheckFailed",
                defaultValue: "The engine health check failed."
            )
        }
    }

    static func healthIssueTitle(_ issue: EngineHealthIssue) -> String {
        switch issue.component {
        case .process:
            VelaL10n.string(
                "runtime.healthIssue.process.title",
                defaultValue: "Mihomo process needs attention"
            )
        case .controller:
            VelaL10n.string(
                "runtime.healthIssue.controller.title",
                defaultValue: "Controller needs attention"
            )
        case .configuration:
            VelaL10n.string(
                "runtime.healthIssue.configuration.title",
                defaultValue: "Configuration needs attention"
            )
        case .mixedPort:
            VelaL10n.string(
                "runtime.healthIssue.mixedPort.title",
                defaultValue: "Mixed port needs attention"
            )
        case .systemProxy:
            VelaL10n.string(
                "runtime.healthIssue.systemProxy.title",
                defaultValue: "System Proxy needs attention"
            )
        case .networkPath:
            VelaL10n.string(
                "runtime.healthIssue.networkPath.title",
                defaultValue: "Network path needs attention"
            )
        case .internet:
            VelaL10n.string(
                "runtime.healthIssue.internet.title",
                defaultValue: "Internet check needs attention"
            )
        }
    }

    static func healthIssueAction(_ issue: EngineHealthIssue) -> String {
        switch issue.component {
        case .process:
            VelaL10n.string(
                "runtime.healthIssue.process.action",
                defaultValue: "Restart Mihomo, then refresh health."
            )
        case .controller:
            VelaL10n.string(
                "runtime.healthIssue.controller.action",
                defaultValue: "Wait for the Controller to connect, then refresh health."
            )
        case .configuration:
            VelaL10n.string(
                "runtime.healthIssue.configuration.action",
                defaultValue: "Select and validate a configuration before retrying."
            )
        case .mixedPort:
            VelaL10n.string(
                "runtime.healthIssue.mixedPort.action",
                defaultValue: "Check the mixed-port conflict in Diagnostics."
            )
        case .systemProxy:
            VelaL10n.string(
                "runtime.healthIssue.systemProxy.action",
                defaultValue: "Review System Proxy ownership and recovery in Diagnostics."
            )
        case .networkPath, .internet:
            VelaL10n.string(
                "runtime.healthIssue.network.action",
                defaultValue: "Check the current network connection, then refresh health."
            )
        }
    }

    static func releaseChannelTitle(_ channel: ReleaseChannel) -> String {
        switch channel {
        case .stable:
            VelaL10n.string("settings.update.channel.stable", defaultValue: "Stable")
        case .beta:
            VelaL10n.string("settings.update.channel.beta", defaultValue: "Beta")
        }
    }

    static func updateLifecycleTitle(_ status: UpdateLifecycleStatus) -> String {
        switch status {
        case .unavailable:
            VelaL10n.string(
                "settings.update.lifecycle.unavailable",
                defaultValue: "Configuration Required"
            )
        case .idle:
            VelaL10n.string("settings.update.lifecycle.ready", defaultValue: "Ready")
        case .checking:
            VelaL10n.string(
                "settings.update.lifecycle.checking",
                defaultValue: "Checking"
            )
        case .updateAvailable:
            VelaL10n.string(
                "settings.update.lifecycle.available",
                defaultValue: "Update Available"
            )
        case .downloaded:
            VelaL10n.string(
                "settings.update.lifecycle.downloaded",
                defaultValue: "Downloaded"
            )
        case .preparing:
            VelaL10n.string(
                "settings.update.lifecycle.preparing",
                defaultValue: "Preparing to Update"
            )
        case .readyForInstaller:
            VelaL10n.string(
                "settings.update.lifecycle.readyToInstall",
                defaultValue: "Ready to Install"
            )
        case .recoveryRequired:
            VelaL10n.string(
                "settings.update.lifecycle.recoveryRequired",
                defaultValue: "Recovery Required"
            )
        case .failed:
            VelaL10n.string(
                "settings.update.lifecycle.failed",
                defaultValue: "Update Failed"
            )
        }
    }

    static func updateLifecycleDetail(_ status: UpdateLifecycleStatus) -> String? {
        switch status {
        case .unavailable:
            VelaL10n.string(
                "settings.update.lifecycle.unavailable.detail",
                defaultValue: "Secure update configuration is unavailable for this build."
            )
        case .idle:
            nil
        case .checking:
            VelaL10n.string(
                "settings.update.lifecycle.checking.detail",
                defaultValue: "Vela is securely checking the signed update feed."
            )
        case let .updateAvailable(version, build):
            VelaL10n.string(
                "settings.update.lifecycle.available.detailFormat",
                defaultValue: "Version %@ (%@)",
                arguments: version,
                build
            )
        case let .downloaded(version, build):
            VelaL10n.string(
                "settings.update.lifecycle.downloaded.detailFormat",
                defaultValue: "Version %@ (%@) is ready.",
                arguments: version,
                build
            )
        case .preparing:
            VelaL10n.string(
                "settings.update.lifecycle.preparing.detail",
                defaultValue: "Network services are moving to a verified safe stop."
            )
        case .readyForInstaller:
            VelaL10n.string(
                "settings.update.lifecycle.readyToInstall.detail",
                defaultValue: "The update installer may continue."
            )
        case let .recoveryRequired(phase, _):
            VelaL10n.string(
                "settings.update.lifecycle.recoveryRequired.detailFormat",
                defaultValue: "Update recovery requires attention at %@.",
                arguments: phase
            )
        case let .failed(code, _):
            VelaL10n.string(
                "settings.update.lifecycle.failed.detailFormat",
                defaultValue: "The update operation failed (%@).",
                arguments: code
            )
        }
    }
}

/// A read-only presentation projection for Overview. It deliberately keeps the
/// configured backend separate from a backend that has an active runtime so a
/// stopped engine can never be presented as if System Proxy or TUN were live.
nonisolated struct OverviewRuntimePresentation: Equatable, Sendable {
    nonisolated enum PrimaryState: Equatable, Sendable {
        case stopped
        case validating
        case starting
        case healthy
        case controllerConnecting
        case degraded
        case stopping
        case recovering
        case failed
    }

    let primaryState: PrimaryState
    let selectedBackend: EngineBackendKind
    let activeBackend: EngineBackendKind?

    init(
        engineState: EngineState,
        controllerState: ControllerConnectionState,
        selectedBackend: EngineBackendKind,
        activeBackend: EngineBackendKind?
    ) {
        self.selectedBackend = selectedBackend
        self.activeBackend = if case .stopped = engineState {
            nil
        } else {
            activeBackend
        }

        primaryState = switch engineState {
        case .stopped:
            .stopped
        case .validating:
            .validating
        case .starting:
            .starting
        case let .running(health):
            if health.overallState == .healthy {
                .healthy
            } else if controllerState == .connecting {
                .controllerConnecting
            } else {
                .degraded
            }
        case .stopping:
            .stopping
        case .recovering:
            .recovering
        case .failed:
            .failed
        }
    }

    var semanticStatus: VelaSemanticStatus {
        switch primaryState {
        case .stopped:
            .neutral
        case .validating, .starting, .controllerConnecting, .stopping, .recovering:
            .pending
        case .healthy:
            .success
        case .degraded:
            .warning
        case .failed:
            .error
        }
    }
}
