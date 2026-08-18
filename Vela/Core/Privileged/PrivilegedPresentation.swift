import Foundation
import VelaIPC

extension PrivilegedComponentState {
    var displayTitle: String {
        switch self {
        case .notInstalled: "Not Installed"
        case .registering: "Registering…"
        case .needsApproval: "Needs Approval"
        case .connecting: "Connecting…"
        case .ready: "Ready"
        case .incompatible: "Update Required"
        case .damaged: "Damaged"
        case .uninstalling: "Uninstalling…"
        case .failed: "Failed"
        }
    }

    var detail: String? {
        switch self {
        case .notInstalled, .registering, .connecting, .ready, .uninstalling:
            nil
        case .needsApproval:
            "Approve Vela in System Settings > General > Login Items & Extensions."
        case .incompatible:
            "The installed Helper protocol is incompatible with this Vela build."
        case let .damaged(message):
            message
        case let .failed(error):
            error.message
        }
    }
}

extension EngineTransitionState {
    var displayTitle: String {
        switch self {
        case .idle: "Idle"
        case .preparingTarget: "Preparing target…"
        case .disablingSystemProxy: "Disabling System Proxy…"
        case .stoppingSource: "Stopping current backend…"
        case .startingTarget: "Starting target backend…"
        case .verifyingTarget: "Verifying network…"
        case .committing: "Committing…"
        case .rollingBack: "Rolling back…"
        case let .failed(failure): "Failed at \(failure.failedPhase.rawValue)"
        }
    }
}

extension EngineBackendKind {
    var displayTitle: String {
        switch self {
        case .userProcess: "System Proxy"
        case .privilegedDaemon: "TUN"
        }
    }
}
