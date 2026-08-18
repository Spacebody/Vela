import Darwin
import Foundation
import Observation
import OSLog
import Security
import ServiceManagement
import VelaIPC

nonisolated enum PrivilegedComponentRegistrationStatus: String, Codable, Equatable, Sendable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
    case unknown
}

nonisolated struct PrivilegedBundleSnapshot: Equatable, Sendable {
    let applicationURL: URL
    let helperURL: URL
    let mihomoURL: URL
    let daemonPlistURL: URL
    let teamIdentifier: String
    let helperSigningIdentifier: String
    let isInApplications: Bool
}

nonisolated struct PrivilegedComponentSnapshot: Equatable, Sendable {
    let registrationStatus: PrivilegedComponentRegistrationStatus
    let bundle: PrivilegedBundleSnapshot
    let handshake: HelperHandshakeResponse?

    var isReady: Bool {
        registrationStatus == .enabled && handshake?.hasCompatibleProtocol == true
    }
}

nonisolated struct PrivilegedCleanupResult: Equatable, Sendable {
    let id: UUID
    let succeeded: Bool
    let message: String
    let completedAt: Date
}

nonisolated protocol PrivilegedBundlePreflighting: Sendable {
    func inspect() throws -> PrivilegedBundleSnapshot
}

nonisolated enum PrivilegedBootstrapResidueState: Equatable, Sendable {
    case absent
    case present
    case unknown
}

nonisolated protocol PrivilegedBootstrapResidueInspecting: Sendable {
    func inspect() -> PrivilegedBootstrapResidueState
}

nonisolated struct LivePrivilegedBootstrapResidueInspector: PrivilegedBootstrapResidueInspecting {
    private let rootDirectoryURL: URL

    init(
        rootDirectoryURL: URL = URL(
            filePath: "/Library/Application Support",
            directoryHint: .isDirectory
        )
        .appending(path: VelaIPCConstants.mainBundleIdentifier, directoryHint: .isDirectory)
        .appending(path: "Privileged", directoryHint: .isDirectory)
    ) {
        self.rootDirectoryURL = rootDirectoryURL
    }

    func inspect() -> PrivilegedBootstrapResidueState {
        rootDirectoryURL.withUnsafeFileSystemRepresentation { fileSystemPath in
            guard let fileSystemPath else { return .unknown }
            var information = stat()
            if Darwin.lstat(fileSystemPath, &information) == 0 {
                return .present
            }
            return errno == ENOENT ? .absent : .unknown
        }
    }
}

nonisolated enum PrivilegedComponentState: Equatable, Sendable {
    case notInstalled
    case registering
    case needsApproval(PrivilegedBundleSnapshot)
    case connecting(PrivilegedBundleSnapshot)
    case ready(PrivilegedComponentSnapshot)
    case incompatible(PrivilegedComponentSnapshot)
    case damaged(String)
    case uninstalling
    case failed(UserFacingError)
}

@MainActor
protocol PrivilegedAppServiceProviding: AnyObject {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

extension SMAppService: PrivilegedAppServiceProviding {}

@MainActor
@Observable
final class PrivilegedComponentManager {
    private nonisolated static let logger = Logger(
        subsystem: VelaIPCConstants.mainBundleIdentifier,
        category: "PrivilegedComponent"
    )

    private(set) var state: PrivilegedComponentState = .notInstalled
    private(set) var registrationStatus: PrivilegedComponentRegistrationStatus = .unknown
    private(set) var lastHandshake: HelperHandshakeResponse?
    private(set) var lastRefreshAt: Date?
    private(set) var isCleaning = false
    private(set) var lastCleanupResult: PrivilegedCleanupResult?

    @ObservationIgnored private let service: any PrivilegedAppServiceProviding
    @ObservationIgnored private let client: any PrivilegedHelperClientProtocol
    @ObservationIgnored private let preflight: any PrivilegedBundlePreflighting
    @ObservationIgnored private let bootstrapResidueInspector: any PrivilegedBootstrapResidueInspecting
    @ObservationIgnored private let openSystemSettingsAction: () -> Void
    @ObservationIgnored private let applicationVersion: String
    @ObservationIgnored private let applicationBuild: String
    @ObservationIgnored private var reconnectSessionID: UUID?
    @ObservationIgnored private var operationTask: Task<Void, Never>?
    @ObservationIgnored private var operationToken: UUID?

    init(
        service: any PrivilegedAppServiceProviding = SMAppService.daemon(
            plistName: VelaIPCConstants.launchDaemonPlistName
        ),
        client: any PrivilegedHelperClientProtocol = PrivilegedHelperClient(),
        preflight: any PrivilegedBundlePreflighting = PrivilegedBundlePreflight(),
        bootstrapResidueInspector: any PrivilegedBootstrapResidueInspecting =
            LivePrivilegedBootstrapResidueInspector(),
        openSystemSettingsAction: @escaping () -> Void = {
            SMAppService.openSystemSettingsLoginItems()
        },
        applicationVersion: String = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "0.6.0",
        applicationBuild: String = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? "2026071302"
    ) {
        self.service = service
        self.client = client
        self.preflight = preflight
        self.bootstrapResidueInspector = bootstrapResidueInspector
        self.openSystemSettingsAction = openSystemSettingsAction
        self.applicationVersion = applicationVersion
        self.applicationBuild = applicationBuild
    }

    deinit {
        operationTask?.cancel()
    }

    var isReady: Bool {
        guard case let .ready(snapshot) = state else { return false }
        return snapshot.isReady
    }

    var snapshot: PrivilegedComponentSnapshot? {
        switch state {
        case let .ready(snapshot), let .incompatible(snapshot): snapshot
        default: nil
        }
    }

    func refresh() async {
        await performExclusive { [weak self] in
            await self?.performRefresh()
        }
    }

    func install(userConfirmed: Bool, tunIsActive: Bool) async {
        guard userConfirmed else { return }
        guard !tunIsActive else {
            presentFailure(
                title: "Turn Off TUN First",
                message: "The privileged component cannot be installed or updated while TUN is active."
            )
            return
        }

        await performExclusive { [weak self] in
            await self?.performInstall()
        }
    }

    func reinstall(userConfirmed: Bool, tunIsActive: Bool) async {
        guard userConfirmed else { return }
        guard !tunIsActive else {
            presentFailure(
                title: "Turn Off TUN First",
                message: "The privileged component cannot be installed or updated while TUN is active."
            )
            return
        }

        await performExclusive { [weak self] in
            guard let self else { return }
            state = .registering

            let currentRegistrationStatus = map(service.status)
            if currentRegistrationStatus == .notRegistered
                || currentRegistrationStatus == .notFound
            {
                await performInstall()
                return
            }

            do {
                do {
                    try await verifySafeReplacementState()
                } catch {
                    guard Self.isUnreachableHelperFailure(error),
                        map(service.status) == .enabled,
                        bootstrapResidueInspector.inspect() == .absent
                    else {
                        throw error
                    }
                    Self.logger.notice(
                        "Recovering an unreachable Helper registration with no privileged bootstrap residue"
                    )
                }
                try await replaceRegistration()
            } catch {
                presentFailure(
                    title: "Privileged Component Reinstall Failed",
                    message: "Vela could not reinstall its privileged component."
                )
            }
        }
    }

    private func replaceRegistration() async throws {
        await client.invalidate()
        if service.status != .notRegistered {
            try service.unregister()
        }
        try await waitForRegistrationStatus(.notRegistered)
        try service.register()
        try await waitForRegistrationSubmission()
        await performRefresh()
    }

    private func waitForRegistrationStatus(
        _ expectedStatus: PrivilegedComponentRegistrationStatus,
        timeout: Duration = .seconds(5)
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)

        while true {
            let currentStatus = map(service.status)
            registrationStatus = currentStatus
            if currentStatus == expectedStatus {
                return
            }
            guard clock.now < deadline else {
                throw PrivilegedComponentMutationError.registrationStateUnverified
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private func waitForRegistrationSubmission(timeout: Duration = .seconds(5)) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)

        while true {
            let currentStatus = map(service.status)
            registrationStatus = currentStatus
            if currentStatus != .notRegistered {
                return
            }
            guard clock.now < deadline else {
                throw PrivilegedComponentMutationError.registrationStateUnverified
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private nonisolated static func isUnreachableHelperFailure(_ error: Error) -> Bool {
        guard let failure = error as? VelaHelperFailure else { return false }
        return failure.code == .requestTimedOut || failure.code == .helperUnavailable
    }

    func uninstall(
        userConfirmed: Bool,
        tunIsActive: Bool,
        cleanupMode: PrivilegedCleanupMode = .removeRuntimeData
    ) async {
        guard userConfirmed else { return }
        guard !tunIsActive else {
            presentFailure(
                title: "Turn Off TUN First",
                message: "The privileged component cannot be uninstalled while TUN is active."
            )
            return
        }

        await performExclusive { [weak self] in
            guard let self else { return }
            state = .uninstalling
            do {
                let context = try await authenticatedMutationContext()
                try await stopAndCleanup(
                    initialStatus: context.status,
                    sessionID: context.sessionID,
                    cleanupMode: cleanupMode,
                    stopReason: .uninstall
                )
                await client.invalidate()
                if service.status != .notRegistered {
                    try service.unregister()
                }
                registrationStatus = map(service.status)
                guard registrationStatus == .notRegistered else {
                    throw PrivilegedComponentMutationError.registrationStateUnverified
                }
                lastHandshake = nil
                reconnectSessionID = nil
                state = .notInstalled
            } catch {
                presentFailure(
                    title: "Privileged Component Uninstall Failed",
                    message: "Vela could not safely uninstall its privileged component."
                )
            }
        }
    }

    func runCleanup(userConfirmed: Bool) async {
        guard userConfirmed else { return }

        await performExclusive { [weak self] in
            guard let self else { return }
            isCleaning = true
            lastCleanupResult = nil
            defer { isCleaning = false }
            do {
                let context = try await authenticatedMutationContext()
                try await stopAndCleanup(
                    initialStatus: context.status,
                    sessionID: context.sessionID,
                    cleanupMode: .runtimeOnly,
                    stopReason: .recovery
                )
                lastCleanupResult = PrivilegedCleanupResult(
                    id: UUID(),
                    succeeded: true,
                    message: "Owned process, interface, routes, and staging are clean. "
                        + "The current and previous root configurations remain retained until uninstall.",
                    completedAt: .now
                )
            } catch {
                lastCleanupResult = PrivilegedCleanupResult(
                    id: UUID(),
                    succeeded: false,
                    message: "Vela could not prove that privileged cleanup completed.",
                    completedAt: .now
                )
                presentFailure(
                    title: "Privileged Cleanup Failed",
                    message: "Vela could not safely clean its owned privileged runtime."
                )
            }
        }
    }

    private func authenticatedMutationContext() async throws -> (
        status: HelperStatusResponse,
        sessionID: UUID
    ) {
        registrationStatus = map(service.status)
        guard registrationStatus == .enabled else {
            throw PrivilegedComponentMutationError.componentNotEnabled
        }
        _ = try preflight.inspect()

        let requestedSessionID = reconnectSessionID ?? lastHandshake?.sessionID
        await client.invalidate()
        let handshake = try await client.handshake(
            clientVersion: applicationVersion,
            clientBuild: applicationBuild,
            requestedSessionID: requestedSessionID
        )
        guard handshake.hasCompatibleProtocol, let sessionID = handshake.sessionID else {
            throw PrivilegedComponentMutationError.incompatibleOrMissingSession
        }
        lastHandshake = handshake
        reconnectSessionID = sessionID
        let status = try await client.status()
        return (status, sessionID)
    }

    private func verifySafeReplacementState() async throws {
        registrationStatus = map(service.status)
        guard registrationStatus == .enabled else {
            throw PrivilegedComponentMutationError.componentNotEnabled
        }
        _ = try preflight.inspect()

        let requestedSessionID = reconnectSessionID ?? lastHandshake?.sessionID
        await client.invalidate()
        let handshake = try await client.handshake(
            clientVersion: applicationVersion,
            clientBuild: applicationBuild,
            requestedSessionID: requestedSessionID
        )
        lastHandshake = handshake

        if handshake.hasCompatibleProtocol {
            guard let sessionID = handshake.sessionID else {
                throw PrivilegedComponentMutationError.incompatibleOrMissingSession
            }
            reconnectSessionID = sessionID
            let status = try await client.status()
            try await verifyStableCleanStatus(
                initialStatus: status,
                sessionID: sessionID
            )
            return
        }

        try Self.requireSafeIncompatibleReplacementProbe(handshake)
        let status = try await client.status()
        try Self.requireSafeIncompatibleReplacementStatus(status)
        reconnectSessionID = nil
        try await Task.sleep(for: .milliseconds(200))
        await client.invalidate()
        let confirmation = try await client.handshake(
            clientVersion: applicationVersion,
            clientBuild: applicationBuild,
            requestedSessionID: nil
        )
        try Self.requireSafeIncompatibleReplacementProbe(confirmation)
        let confirmationStatus = try await client.status()
        try Self.requireSafeIncompatibleReplacementStatus(confirmationStatus)
        lastHandshake = confirmation
    }

    private nonisolated static func requireSafeIncompatibleReplacementProbe(
        _ response: HelperHandshakeResponse
    ) throws {
        guard !response.hasCompatibleProtocol,
            response.sessionID == nil,
            response.state == .stopped,
            response.processID == nil,
            response.currentOwnerUID == nil
        else {
            throw PrivilegedComponentMutationError.runtimeNotClean
        }
    }

    private nonisolated static func requireSafeIncompatibleReplacementStatus(
        _ status: HelperStatusResponse
    ) throws {
        guard isCleanlyStopped(status),
            status.currentOwnerUID == nil,
            !status.health.ownerLeaseValid,
            !status.health.controllerReachable,
            !status.health.configurationHashMatches,
            !status.health.tunEnabledInController,
            !status.health.dnsReady
        else {
            throw PrivilegedComponentMutationError.runtimeNotClean
        }
    }

    private func verifyStableCleanStatus(
        initialStatus: HelperStatusResponse,
        sessionID _: UUID
    ) async throws {
        guard Self.isCleanlyStopped(initialStatus) else {
            throw PrivilegedComponentMutationError.runtimeNotClean
        }
        try await Task.sleep(for: .milliseconds(200))
        let confirmation = try await client.status()
        guard Self.isCleanlyStopped(confirmation) else {
            throw PrivilegedComponentMutationError.runtimeNotClean
        }
    }

    private func stopAndCleanup(
        initialStatus: HelperStatusResponse,
        sessionID: UUID,
        cleanupMode: PrivilegedCleanupMode,
        stopReason: HelperStopReason
    ) async throws {
        var status = initialStatus
        for _ in 0..<4 {
            if status.health.processRunning
                || status.state != .stopped
                || status.instanceID != nil
            {
                guard let instanceID = status.instanceID else {
                    throw PrivilegedComponentMutationError.runtimeIdentityMissing
                }
                try await client.stop(StopHelperRequest(
                    sessionID: sessionID,
                    instanceID: instanceID,
                    reason: stopReason
                ))
            }

            try await client.cleanup(CleanupHelperRequest(
                sessionID: sessionID,
                mode: cleanupMode
            ))
            let first = try await client.status()
            guard Self.isCleanlyStopped(first) else {
                status = first
                continue
            }
            try await Task.sleep(for: .milliseconds(200))
            let confirmation = try await client.status()
            if Self.isCleanlyStopped(confirmation) {
                return
            }
            status = confirmation
        }
        throw PrivilegedComponentMutationError.runtimeNotClean
    }

    private nonisolated static func isCleanlyStopped(
        _ status: HelperStatusResponse
    ) -> Bool {
        status.state == .stopped
            && status.processID == nil
            && status.instanceID == nil
            && !status.health.processRunning
            && !status.health.tunInterfacePresent
            && !status.health.routeApplied
            && status.health.tunInterface == nil
    }

    func openSystemSettings() {
        openSystemSettingsAction()
    }

    func invalidateConnection() async {
        await client.invalidate()
        lastHandshake = nil
        if case let .ready(snapshot) = state {
            state = .connecting(snapshot.bundle)
        }
    }

    private func performExclusive(_ operation: @escaping @MainActor () async -> Void) async {
        guard operationTask == nil else { return }
        let token = UUID()
        let task = Task { @MainActor in await operation() }
        operationToken = token
        operationTask = task
        await task.value
        if operationToken == token {
            operationTask = nil
            operationToken = nil
        }
    }

    private func performInstall() async {
        state = .registering
        do {
            let bundle: PrivilegedBundleSnapshot
            do {
                bundle = try preflight.inspect()
            } catch {
                state = .damaged(Self.safePreflightFailureMessage(for: error))
                return
            }
            guard bundle.isInApplications || Self.isDebugBuild else {
                state = .damaged(
                    "Move Vela to /Applications before installing its privileged component."
                )
                return
            }
            if service.status == .notRegistered || service.status == .notFound {
                try service.register()
            }
            registrationStatus = map(service.status)
            switch registrationStatus {
            case .requiresApproval:
                state = .needsApproval(bundle)
            case .enabled:
                state = .connecting(bundle)
                await connect(bundle: bundle)
            case .notRegistered, .notFound, .unknown:
                state = .damaged("The system did not enable the privileged component.")
            }
        } catch {
            presentFailure(
                title: "Privileged Component Installation Failed",
                message: "Vela could not install its privileged component.",
                technicalDetails: error.localizedDescription
            )
        }
    }

    private func performRefresh() async {
        lastRefreshAt = .now
        registrationStatus = map(service.status)

        guard registrationStatus != .notRegistered else {
            await client.invalidate()
            lastHandshake = nil
            state = .notInstalled
            return
        }

        do {
            let bundle = try preflight.inspect()
            switch registrationStatus {
            case .requiresApproval:
                state = .needsApproval(bundle)
            case .enabled:
                state = .connecting(bundle)
                await connect(bundle: bundle)
            case .notFound:
                state = .damaged("The registered privileged component is missing from the app bundle.")
            case .unknown:
                state = .damaged("The privileged component registration status is unknown.")
            case .notRegistered:
                state = .notInstalled
            }
        } catch {
            state = .damaged(Self.safePreflightFailureMessage(for: error))
        }
    }

    private func connect(bundle: PrivilegedBundleSnapshot) async {
        do {
            let handshake = try await client.handshake(
                clientVersion: applicationVersion,
                clientBuild: applicationBuild,
                requestedSessionID: reconnectSessionID
            )
            lastHandshake = handshake
            if let sessionID = handshake.sessionID {
                reconnectSessionID = sessionID
            }
            let snapshot = PrivilegedComponentSnapshot(
                registrationStatus: registrationStatus,
                bundle: bundle,
                handshake: handshake
            )
            state = handshake.hasCompatibleProtocol ? .ready(snapshot) : .incompatible(snapshot)
            Self.logger.info("Privileged helper handshake completed")
        } catch let failure as VelaHelperFailure where failure.code == .incompatibleProtocol {
            let snapshot = PrivilegedComponentSnapshot(
                registrationStatus: registrationStatus,
                bundle: bundle,
                handshake: lastHandshake
            )
            state = .incompatible(snapshot)
        } catch {
            state = .damaged("The privileged component is enabled but could not be authenticated.")
        }
    }

    private func map(_ status: SMAppService.Status) -> PrivilegedComponentRegistrationStatus {
        switch status {
        case .notRegistered: .notRegistered
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        @unknown default: .unknown
        }
    }

    private func presentFailure(
        title: String,
        message: String,
        technicalDetails: String? = nil
    ) {
        state = .failed(
            UserFacingError(
                title: title,
                message: message,
                technicalDetails: technicalDetails,
                suggestedAction: "Open Privileged Component settings and try again.",
                isRetryable: true
            )
        )
    }

    private nonisolated static func safePreflightFailureMessage(for error: Error) -> String {
        if case let CodeSignatureInspectionError.invalidSignature(_, status, _) = error,
            status == CSSMERR_TP_NOT_TRUSTED || status == errSecNotTrusted
        {
            return PrivilegedBundleFailurePresentation.untrustedCodeSignature
        }
        return PrivilegedBundleFailurePresentation.integrityCheckFailed
    }

    private nonisolated static var isDebugBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }
}

nonisolated enum PrivilegedBundleFailurePresentation {
    static let untrustedCodeSignature =
        "Vela's development signing identity is missing, expired, or not trusted. "
        + "Create a valid Apple Development certificate in Xcode, rebuild Vela, then reinstall the privileged component."

    static let integrityCheckFailed =
        "Vela could not verify the app, privileged component, and Mihomo signatures as one trusted bundle."
}

nonisolated private enum PrivilegedComponentMutationError: Error, Sendable {
    case componentNotEnabled
    case incompatibleOrMissingSession
    case runtimeIdentityMissing
    case runtimeNotClean
    case registrationStateUnverified
}

nonisolated struct PrivilegedBundlePreflight: PrivilegedBundlePreflighting, Sendable {
    private let bundleURL: URL
    private let signatureInspector: any CodeSignatureInspecting

    init(
        bundleURL: URL = Bundle.main.bundleURL,
        signatureInspector: any CodeSignatureInspecting = SecurityFrameworkCodeSignatureInspector()
    ) {
        self.bundleURL = bundleURL
        self.signatureInspector = signatureInspector
    }

    func inspect() throws -> PrivilegedBundleSnapshot {
        let helperURL = bundleURL.appendingPathComponent(
            "Contents/Library/LaunchServices/VelaHelper",
            isDirectory: false
        )
        let mihomoURL = bundleURL.appendingPathComponent(
            "Contents/Helpers/mihomo",
            isDirectory: false
        )
        let daemonPlistURL = bundleURL.appendingPathComponent(
            "Contents/Library/LaunchDaemons/\(VelaIPCConstants.launchDaemonPlistName)",
            isDirectory: false
        )

        try validateRegularFile(helperURL, executable: true)
        try validateRegularFile(mihomoURL, executable: true)
        try validateRegularFile(daemonPlistURL, executable: false)
        try validateDaemonPlist(at: daemonPlistURL)

        let application = try signatureInspector.inspectCode(at: bundleURL, validateNestedCode: true)
        let helper = try signatureInspector.inspectCode(at: helperURL, validateNestedCode: false)
        let mihomo = try signatureInspector.inspectCode(at: mihomoURL, validateNestedCode: false)

        guard application.signingIdentifier == VelaIPCConstants.mainBundleIdentifier else {
            throw PrivilegedBundlePreflightError.invalidApplicationIdentifier
        }
        guard helper.signingIdentifier == VelaIPCConstants.helperIdentifier else {
            throw PrivilegedBundlePreflightError.invalidHelperIdentifier
        }
        guard mihomo.signingIdentifier == VelaIPCConstants.expectedMihomoSigningIdentifier else {
            throw PrivilegedBundlePreflightError.invalidMihomoIdentifier
        }
        guard let team = application.teamIdentifier, !team.isEmpty,
            helper.teamIdentifier == team, mihomo.teamIdentifier == team
        else {
            throw PrivilegedBundlePreflightError.teamIdentifierMismatch
        }

        return PrivilegedBundleSnapshot(
            applicationURL: bundleURL,
            helperURL: helperURL,
            mihomoURL: mihomoURL,
            daemonPlistURL: daemonPlistURL,
            teamIdentifier: team,
            helperSigningIdentifier: helper.signingIdentifier ?? "",
            isInApplications: bundleURL.standardizedFileURL.path.hasPrefix("/Applications/")
        )
    }

    private func validateRegularFile(_ url: URL, executable: Bool) throws {
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .isExecutableKey,
        ])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw PrivilegedBundlePreflightError.missingOrUnsafeFile(url.path)
        }
        if executable, values.isExecutable != true {
            throw PrivilegedBundlePreflightError.notExecutable(url.path)
        }
    }

    private func validateDaemonPlist(at url: URL) throws {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.count <= 128 * 1_024,
            let plist = try PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            ) as? [String: Any],
            plist["Label"] as? String == VelaIPCConstants.helperIdentifier,
            plist["BundleProgram"] as? String
                == "Contents/Library/LaunchServices/VelaHelper",
            let services = plist["MachServices"] as? [String: Any],
            services[VelaIPCConstants.machServiceName] as? Bool == true,
            let associated = plist["AssociatedBundleIdentifiers"] as? [String],
            associated == [VelaIPCConstants.mainBundleIdentifier]
        else {
            throw PrivilegedBundlePreflightError.invalidDaemonPlist
        }

        let text = String(decoding: data, as: UTF8.self)
        guard !text.contains("__PLACEHOLDER__"), !text.contains("__HELPER_") else {
            throw PrivilegedBundlePreflightError.invalidDaemonPlist
        }
    }
}

nonisolated enum PrivilegedBundlePreflightError: Error, Equatable, Sendable {
    case missingOrUnsafeFile(String)
    case notExecutable(String)
    case invalidDaemonPlist
    case invalidApplicationIdentifier
    case invalidHelperIdentifier
    case invalidMihomoIdentifier
    case teamIdentifierMismatch
}
