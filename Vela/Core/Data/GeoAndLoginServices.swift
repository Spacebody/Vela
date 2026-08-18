import Foundation
import OSLog
import ServiceManagement

nonisolated enum GeoUpdateState: Equatable, Sendable {
    case idle
    case updating
    case succeeded(Date)
    case failed(GeoDataFailure)
    case resultUnknown
}

nonisolated enum GeoDataFailure: Error, Equatable, Sendable {
    case geoUpdateUnavailable
    case geoUpdateFailed
    case operationAlreadyRunning
    case cancelledResultUnknown
    case updateInProgress
}

actor GeoDataService {
    private nonisolated static let logger = Logger(
        subsystem: "dev.yilin.Vela",
        category: "GeoData"
    )
    private let apiClient: any MihomoAPIProviding
    private let runtimeMutationGate: RuntimeMutationGate?
    private let now: @Sendable () -> Date
    private var state: GeoUpdateState = .idle

    init(
        apiClient: any MihomoAPIProviding,
        runtimeMutationGate: RuntimeMutationGate? = nil,
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.apiClient = apiClient
        self.runtimeMutationGate = runtimeMutationGate
        self.now = now
    }

    func currentState() -> GeoUpdateState {
        state
    }

    func update() async throws {
        let lease: RuntimeMutationLease?
        do {
            lease = try await runtimeMutationGate?.acquire(.controllerMutation)
        } catch RuntimeMutationGateError.updateInProgress {
            throw GeoDataFailure.updateInProgress
        }
        do {
            try await performUpdate()
            if let lease { await runtimeMutationGate?.release(lease) }
        } catch {
            if let lease { await runtimeMutationGate?.release(lease) }
            throw error
        }
    }

    private func performUpdate() async throws {
        guard state != .updating else {
            throw GeoDataFailure.operationAlreadyRunning
        }
        state = .updating
        do {
            guard !Task.isCancelled else {
                state = .resultUnknown
                throw GeoDataFailure.cancelledResultUnknown
            }
            try await apiClient.updateGeoDatabases()
            // A transport fake or a future API implementation may ignore
            // cooperative cancellation. Once the request was issued, Vela
            // cannot truthfully claim either success or cancellation.
            guard !Task.isCancelled else {
                state = .resultUnknown
                throw GeoDataFailure.cancelledResultUnknown
            }
            state = .succeeded(now())
            Self.logger.info("Mihomo Geo database update completed")
        } catch let failure as GeoDataFailure {
            throw failure
        } catch is CancellationError {
            state = .resultUnknown
            throw GeoDataFailure.cancelledResultUnknown
        } catch {
            if Task.isCancelled {
                state = .resultUnknown
                throw GeoDataFailure.cancelledResultUnknown
            }
            let failure = mapFailure(error)
            state = .failed(failure)
            throw failure
        }
    }

    func resetPresentationState() {
        guard state != .updating else { return }
        state = .idle
    }

    private func mapFailure(_ error: any Error) -> GeoDataFailure {
        guard case let .httpStatus(code, _)? = error as? MihomoAPIError else {
            return .geoUpdateFailed
        }
        return switch code {
        case 404, 405, 501: .geoUpdateUnavailable
        default: .geoUpdateFailed
        }
    }
}

nonisolated enum LaunchAtLoginStatus: String, Codable, Equatable, Sendable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
    case unknown
}

nonisolated enum LaunchAtLoginFailure: Error, Equatable, Sendable {
    case registerFailed
    case unregisterFailed
    case statusUnavailable
}

@MainActor
protocol LaunchAtLoginManaging: AnyObject {
    var status: LaunchAtLoginStatus { get }
    func register() throws
    func unregister() throws
    func openSystemSettings()
}

@MainActor
protocol LaunchAtLoginServiceProviding: AnyObject {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

extension SMAppService: LaunchAtLoginServiceProviding {}

@MainActor
final class MainAppLaunchAtLoginManager: LaunchAtLoginManaging {
    private let service: any LaunchAtLoginServiceProviding
    private let openSystemSettingsAction: () -> Void

    init(
        service: any LaunchAtLoginServiceProviding = SMAppService.mainApp,
        openSystemSettingsAction: @escaping () -> Void = {
            SMAppService.openSystemSettingsLoginItems()
        }
    ) {
        self.service = service
        self.openSystemSettingsAction = openSystemSettingsAction
    }

    var status: LaunchAtLoginStatus {
        switch service.status {
        case .notRegistered: .notRegistered
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        @unknown default: .unknown
        }
    }

    func register() throws {
        do {
            try service.register()
        } catch {
            throw LaunchAtLoginFailure.registerFailed
        }
    }

    func unregister() throws {
        do {
            try service.unregister()
        } catch {
            throw LaunchAtLoginFailure.unregisterFailed
        }
    }

    func openSystemSettings() {
        openSystemSettingsAction()
    }
}
