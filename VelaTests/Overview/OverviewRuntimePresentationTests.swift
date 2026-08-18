import Foundation
import Testing
import VelaIPC
@testable import Vela

@Suite("Runtime metric availability presentation")
struct VelaRuntimeMetricPresentationTests {
    @Test("Unavailable runtime metrics never masquerade as zero")
    func unavailableRuntimeMetricsUsePlaceholder() {
        #expect(
            VelaRuntimeMetricPresentation.value("0 KB/s", isAvailable: false)
                == VelaRuntimeMetricPresentation.unavailable
        )
        #expect(
            VelaRuntimeMetricPresentation.value("0", isAvailable: false)
                == VelaRuntimeMetricPresentation.unavailable
        )
    }

    @Test("A real zero remains visible while runtime metrics are available")
    func availableRuntimeMetricsPreserveZero() {
        #expect(VelaRuntimeMetricPresentation.value("0 KB/s", isAvailable: true) == "0 KB/s")
        #expect(VelaRuntimeMetricPresentation.value("0", isAvailable: true) == "0")
    }
}

@Suite("Overview runtime presentation semantics")
struct OverviewRuntimePresentationTests {
    @Test("Stopped state never exposes a retained backend as active")
    func stoppedStateHasNoActiveBackend() {
        let presentation = OverviewRuntimePresentation(
            engineState: .stopped,
            controllerState: .disconnected,
            selectedBackend: .userProcess,
            activeBackend: .userProcess
        )

        #expect(presentation.primaryState == .stopped)
        #expect(presentation.selectedBackend == .userProcess)
        #expect(presentation.activeBackend == nil)
        #expect(presentation.semanticStatus == .neutral)
    }

    @Test("Running state keeps selected and active backend independently")
    func runningStateSeparatesSelectedAndActiveBackend() {
        let presentation = OverviewRuntimePresentation(
            engineState: .running(healthyEngineHealth),
            controllerState: .connected,
            selectedBackend: .privilegedDaemon,
            activeBackend: .userProcess
        )

        #expect(presentation.primaryState == .healthy)
        #expect(presentation.selectedBackend == .privilegedDaemon)
        #expect(presentation.activeBackend == .userProcess)
        #expect(presentation.semanticStatus == .success)
    }

    @Test("Controller connection is a pending primary state only for degraded runtime")
    func controllerConnectionUsesPendingPrimaryState() {
        let presentation = OverviewRuntimePresentation(
            engineState: .running(degradedEngineHealth),
            controllerState: .connecting,
            selectedBackend: .userProcess,
            activeBackend: .userProcess
        )

        #expect(presentation.primaryState == .controllerConnecting)
        #expect(presentation.semanticStatus == .pending)
    }

    private var healthyEngineHealth: EngineHealth {
        engineHealth(overallState: .healthy)
    }

    private var degradedEngineHealth: EngineHealth {
        engineHealth(overallState: .degraded)
    }

    private func engineHealth(overallState: EngineHealthState) -> EngineHealth {
        EngineHealth(
            processRunning: true,
            controllerReachable: overallState == .healthy,
            configurationValid: true,
            systemProxyApplied: false,
            networkReachable: true,
            internetReachable: true,
            portsListening: true,
            lastCheckedAt: Date(timeIntervalSince1970: 1),
            overallState: overallState
        )
    }
}
