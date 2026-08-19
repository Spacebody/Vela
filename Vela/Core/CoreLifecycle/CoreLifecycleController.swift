import Darwin
import Foundation
import Observation
import VelaIPC

nonisolated struct CoreCatalogEndpoint: Equatable, Sendable {
    let catalogURL: URL
    let signatureEnvelopeURL: URL

    init(catalogURL: URL, signatureEnvelopeURL: URL) throws {
        try CoreCatalogURLPolicy.validate(catalogURL)
        try CoreCatalogURLPolicy.validate(signatureEnvelopeURL)
        guard catalogURL.host?.lowercased() == signatureEnvelopeURL.host?.lowercased() else {
            throw CoreDownloadError.catalogHostMismatch
        }
        self.catalogURL = catalogURL
        self.signatureEnvelopeURL = signatureEnvelopeURL
    }

    static func bundled(_ bundle: Bundle = .main) -> CoreCatalogEndpoint? {
        guard let catalog = bundle.object(forInfoDictionaryKey: "VelaCoreCatalogURL") as? String,
            let signatures = bundle.object(
                forInfoDictionaryKey: "VelaCoreCatalogSignaturesURL"
            ) as? String,
            let catalogURL = URL(string: catalog),
            let signatureURL = URL(string: signatures)
        else { return nil }
        return try? CoreCatalogEndpoint(
            catalogURL: catalogURL,
            signatureEnvelopeURL: signatureURL
        )
    }
}

nonisolated enum CoreCatalogClientState: Equatable, Sendable {
    case unconfigured
    case idle
    case checking
    case verified(sequence: UInt64, expiresAt: Date, keyIDs: [String])
    case stale(sequence: UInt64, expiredAt: Date, keyIDs: [String])
    case staleUncached
    case clockSkew(String)
    case failed(String)
}

nonisolated enum CoreActivationState: Equatable, Sendable {
    case idle
    case validatingCandidate
    case snapshotting
    case stoppingCurrent
    case startingCandidate
    case verifyingCandidate
    case probation(until: Date)
    case committing
    case rollingBack
    case failed(String)
}

@MainActor
@Observable
final class CoreLifecycleController {
    typealias InstalledResolverFactory = @MainActor @Sendable (
        InstalledCoreRecord,
        CoreCatalogEntry
    ) throws -> any MihomoExecutableResolving

    private(set) var snapshot: CoreStoreSnapshot?
    private(set) var preferences = CoreSelectionPreferences()
    private(set) var catalogSnapshot: CoreCatalogSnapshot?
    private(set) var catalogState: CoreCatalogClientState
    private(set) var activationState: CoreActivationState = .idle
    private(set) var rootInventory: ListInstalledCoresResponse?
    private(set) var lastError: String?
    private(set) var isDownloading = false
    private(set) var isSyncingRootStore = false
    private(set) var isBootstrapped = false
    private(set) var updateRecoveryPending = false
    private(set) var readOnlySafeMode = false
    private(set) var manualRepairRequired = false
    private(set) var activationJournal: CoreActivationTransaction?
    private(set) var helperCatalogPolicySyncError: String?
    private(set) var helperCatalogPolicySequence: UInt64?
    private(set) var helperCatalogPolicySHA256: String?
    private(set) var helperCatalogPolicyHelperBuild: String?

    let factoryDescriptor: CoreDescriptor

    @ObservationIgnored private let store: CoreStore
    @ObservationIgnored private let directories: CoreDirectories
    @ObservationIgnored private let activeResolver: ActiveCoreResolver
    @ObservationIgnored private let engineStore: EngineStore
    @ObservationIgnored private let runtimeMutationGate: RuntimeMutationGate
    @ObservationIgnored private let catalogEndpoint: CoreCatalogEndpoint?
    @ObservationIgnored private let catalogDownloader: CoreCatalogDownloader
    @ObservationIgnored private let fileDownloader: CoreFileDownloader
    @ObservationIgnored private let catalogVerifier: CoreCatalogVerifier
    @ObservationIgnored private let compatibilityEnvironment: CoreCompatibilityEnvironment
    @ObservationIgnored private let installedResolverFactory: InstalledResolverFactory?
    @ObservationIgnored private let helperClient: (any PrivilegedHelperClientProtocol)?
    @ObservationIgnored private let privilegedComponentManager: PrivilegedComponentManager?
    @ObservationIgnored private let configurationGeneration: @MainActor @Sendable () -> UUID
    @ObservationIgnored private let probationDuration: Duration
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let automaticCheckDefaults: UserDefaults
    @ObservationIgnored private var probationTask: Task<Void, Never>?
    @ObservationIgnored private var probationLease: RuntimeMutationLease?
    @ObservationIgnored private var catalogExpiryTask: Task<Void, Never>?
    @ObservationIgnored private var automaticCheckScheduler: NSBackgroundActivityScheduler?
    @ObservationIgnored private var automaticSchedulingAllowed = false
    @ObservationIgnored private var lastControllerAPIContractRuntimeID: UUID?
    @ObservationIgnored private var lastControllerAPIContractCheckAt: Date?

    private static let lastAutomaticCheckAttemptKey =
        "dev.yilin.Vela.CoreCatalog.lastAutomaticCheckAttempt"

    init(
        store: CoreStore,
        directories: CoreDirectories,
        factoryDescriptor: CoreDescriptor,
        activeResolver: ActiveCoreResolver,
        engineStore: EngineStore,
        runtimeMutationGate: RuntimeMutationGate,
        compatibilityEnvironment: CoreCompatibilityEnvironment,
        helperClient: (any PrivilegedHelperClientProtocol)? = nil,
        privilegedComponentManager: PrivilegedComponentManager? = nil,
        catalogEndpoint: CoreCatalogEndpoint? = CoreCatalogEndpoint.bundled(),
        catalogDownloader: CoreCatalogDownloader = CoreCatalogDownloader(),
        fileDownloader: CoreFileDownloader = CoreFileDownloader(),
        catalogVerifier: CoreCatalogVerifier = CoreCatalogVerifier(),
        installedResolverFactory: InstalledResolverFactory? = nil,
        probationDuration: Duration = .seconds(10 * 60),
        configurationGeneration: @escaping @MainActor @Sendable () -> UUID,
        sleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        },
        now: @escaping @Sendable () -> Date = { .now },
        automaticCheckDefaults: UserDefaults = .standard
    ) {
        self.store = store
        self.directories = directories
        self.factoryDescriptor = factoryDescriptor
        self.activeResolver = activeResolver
        self.engineStore = engineStore
        self.runtimeMutationGate = runtimeMutationGate
        self.compatibilityEnvironment = compatibilityEnvironment
        self.helperClient = helperClient
        self.privilegedComponentManager = privilegedComponentManager
        self.catalogEndpoint = catalogEndpoint
        self.catalogDownloader = catalogDownloader
        self.fileDownloader = fileDownloader
        self.catalogVerifier = catalogVerifier
        self.installedResolverFactory = installedResolverFactory
        self.probationDuration = max(.seconds(1), probationDuration)
        self.configurationGeneration = configurationGeneration
        self.sleep = sleep
        self.now = now
        self.automaticCheckDefaults = automaticCheckDefaults
        catalogState = catalogEndpoint == nil ? .unconfigured : .idle
    }

    deinit {
        probationTask?.cancel()
        catalogExpiryTask?.cancel()
    }

    var activeDescriptor: CoreDescriptor { snapshot?.activeDescriptor ?? factoryDescriptor }
    var activeCoreID: CoreID { activeDescriptor.coreID }
    var activeRecord: InstalledCoreRecord? { snapshot?.state.record(for: activeCoreID) }
    var activeBlockedIncidentMessage: String? {
        guard activeRecord?.status == .blocked else { return nil }
        let reason = catalogSnapshot?.catalog.entries.first {
            $0.coreID == activeCoreID
        }?.blockReason
        if let reason, !reason.isEmpty {
            return "The verified Catalog blocked this active Core: \(reason) Vela will not stop or switch it remotely. Roll back or use Factory when you are ready."
        }
        return "The verified Catalog blocked this active Core. Vela will not stop or switch it remotely. Roll back or use Factory when you are ready."
    }
    var installedRecords: [InstalledCoreRecord] { snapshot?.state.installed ?? [] }
    var activeCatalogEntry: CoreCatalogEntry? {
        catalogSnapshot?.catalog.entries.first { $0.coreID == activeCoreID }
    }
    var recommendedEntry: CoreCatalogEntry? { catalogSnapshot?.catalog.recommendedEntry }
    var installableAvailableEntries: [CoreCatalogEntry] {
        (catalogSnapshot?.catalog.entries ?? [])
            .filter { $0.status == .available && isCompatible($0) }
            .sorted {
                if $0.publishedAt != $1.publishedAt {
                    return $0.publishedAt > $1.publishedAt
                }
                return $0.coreID.rawValue < $1.coreID.rawValue
            }
    }
    var recommendedCompatibilityMessage: String {
        guard let recommendedEntry else { return "No recommended Core is available." }
        do {
            return try CoreCompatibilityEvaluator.incompatibilityReason(
                recommendedEntry.vela,
                against: compatibilityEnvironment
            ) ?? "Compatible with this Vela build"
        } catch {
            return "Compatibility metadata is invalid."
        }
    }
    var isRecommendedCompatible: Bool {
        guard let recommendedEntry else { return false }
        return isCompatible(recommendedEntry)
    }
    var isBusy: Bool {
        if isDownloading || isSyncingRootStore || updateRecoveryPending || readOnlySafeMode
            || manualRepairRequired
        {
            return true
        }
        return switch activationState {
        case .idle, .failed:
            false
        case .validatingCandidate, .snapshotting, .stoppingCurrent,
            .startingCandidate, .verifyingCandidate, .probation,
            .committing, .rollingBack:
            true
        }
    }
    var productionFeedEnabled: Bool {
        catalogEndpoint != nil && !VelaCoreCatalogTrustRoots.all.isEmpty
    }
    var canRollback: Bool {
        guard !updateRecoveryPending, !readOnlySafeMode, !manualRepairRequired,
            activeCoreID != factoryDescriptor.coreID
        else {
            return false
        }
        return switch activationState {
        case .idle, .failed, .probation:
            true
        case .validatingCandidate, .snapshotting, .stoppingCurrent,
            .startingCandidate, .verifyingCandidate, .committing, .rollingBack:
            false
        }
    }
    var userRootStoreInParity: Bool? {
        guard !activeCoreID.isFactory else { return true }
        guard let rootInventory else { return nil }
        return rootInventory.cores.contains { $0.coreID == activeCoreID }
    }
    var helperSupportsCoreStore: Bool {
        helperClient != nil
            && privilegedComponentManager?.lastHandshake?.hasCompatibleProtocol == true
    }

    func rootStoreContains(_ coreID: CoreID) -> Bool? {
        if coreID.isFactory { return true }
        guard let rootInventory else { return nil }
        return rootInventory.cores.contains { $0.coreID == coreID }
    }

    /// Returns the immutable, signed Catalog entry retained with an installed
    /// User Core. This deliberately does not depend on the latest online
    /// Catalog, so verification and legal evidence remain inspectable while
    /// offline or after the entry is withdrawn from a newer feed.
    func verifiedInstalledCatalogEntry(for coreID: CoreID) async throws
        -> CoreCatalogEntry
    {
        guard !coreID.isFactory else {
            throw CoreLifecycleError.coreUnavailable(coreID)
        }
        let state = try await store.loadState(
            factoryCoreID: factoryDescriptor.coreID
        )
        guard let record = state.record(for: coreID) else {
            throw CoreLifecycleError.coreUnavailable(coreID)
        }
        return try await store.catalogEntry(for: record, verifier: catalogVerifier)
    }

    func bootstrap(
        preserveInterruptedTransactionForUpdate: Bool = false,
        forceReadOnlySafeMode: Bool = false
    ) async {
        guard !isBootstrapped else { return }
        updateRecoveryPending = preserveInterruptedTransactionForUpdate
        do {
            if forceReadOnlySafeMode {
                readOnlySafeMode = true
                await activeResolver.selectFactory()
                _ = try await activeResolver.resolve()
                snapshot = CoreStoreSnapshot(
                    state: CoreStoreState(activeCoreID: factoryDescriptor.coreID),
                    activeDescriptor: factoryDescriptor,
                    previousKnownGoodDescriptor: nil,
                    pinnedDescriptor: nil
                )
                lastError = "Public Beta Safe Mode is using the bundled Factory Core without modifying Core Store state."
                activationState = .failed(lastError ?? "Read-only Safe Mode")
                isBootstrapped = true
                return
            }
            if let schemaVersion = try await store.readOnlyStateSchemaVersion(),
                schemaVersion > CoreStoreState.supportedSchemaVersion
            {
                readOnlySafeMode = true
                await activeResolver.selectFactory()
                _ = try await activeResolver.resolve()
                await engineStore.enterUpdateRecoverySafeMode()
                lastError = "This Core Store was written by a newer Vela version (schema \(schemaVersion)). Vela is using its Factory Core in read-only Safe Mode and did not modify the newer Store. Reinstall the newer Vela version to continue."
                activationState = .failed(lastError ?? "Read-only Safe Mode")
                snapshot = CoreStoreSnapshot(
                    state: CoreStoreState(activeCoreID: factoryDescriptor.coreID),
                    activeDescriptor: factoryDescriptor,
                    previousKnownGoodDescriptor: nil,
                    pinnedDescriptor: nil
                )
                isBootstrapped = true
                return
            }
            _ = try await store.reconcileInterruptedInstallation(
                factoryCoreID: factoryDescriptor.coreID
            )
            var state = try await store.loadState(factoryCoreID: factoryDescriptor.coreID)
            preferences = try await store.loadPreferences()
            if !preserveInterruptedTransactionForUpdate {
                state = try await recoverInterruptedTransaction(state: state)
            } else {
                activationJournal = try await store.loadTransaction()
            }
            await loadPersistedCatalog(state: state)
            try await selectPersistedCore(state: &state)
            try await store.saveState(state)
            snapshot = try await store.snapshot(
                factoryDescriptor: factoryDescriptor,
                state: state
            )
            await updateResolverMetadata(state: state)
            await refreshRootInventory()
            if manualRepairRequired {
                lastError = "A previous Core activation was interrupted. Its journal is retained and all Core changes are locked until Repair & Verify Rollback succeeds."
                activationState = .failed(lastError ?? "Manual repair required")
            }
            isBootstrapped = true
        } catch {
            await activeResolver.selectFactory()
            lastError = CoreLifecycleDiagnosticText.safe(error)
            activationState = .failed(lastError ?? "Core bootstrap failed.")
            snapshot = CoreStoreSnapshot(
                state: CoreStoreState(activeCoreID: factoryDescriptor.coreID),
                activeDescriptor: factoryDescriptor,
                previousKnownGoodDescriptor: nil,
                pinnedDescriptor: nil
            )
            isBootstrapped = true
        }

    }

    /// Switches only the in-memory resolver and snapshot to the immutable
    /// bundled Core. Persisted Core Store state remains untouched so a later
    /// normal launch can recover or resume it after the triggering problem is
    /// resolved.
    func enterPublicBetaSafeMode() async {
        readOnlySafeMode = true
        automaticSchedulingAllowed = false
        automaticCheckScheduler?.invalidate()
        automaticCheckScheduler = nil
        catalogExpiryTask?.cancel()
        catalogExpiryTask = nil
        probationTask?.cancel()
        probationTask = nil
        if let probationLease {
            await runtimeMutationGate.release(probationLease)
            self.probationLease = nil
        }

        await activeResolver.selectFactory()
        do {
            _ = try await activeResolver.resolve()
        } catch {
            lastError = CoreLifecycleDiagnosticText.safe(error)
        }
        var state = snapshot?.state
            ?? CoreStoreState(activeCoreID: factoryDescriptor.coreID)
        state.activeCoreID = factoryDescriptor.coreID
        snapshot = CoreStoreSnapshot(
            state: state,
            activeDescriptor: factoryDescriptor,
            previousKnownGoodDescriptor: snapshot?.activeDescriptor.source == .user
                ? snapshot?.activeDescriptor
                : snapshot?.previousKnownGoodDescriptor,
            pinnedDescriptor: snapshot?.pinnedDescriptor
        )
        lastError = "Public Beta Safe Mode is using the bundled Factory Core without modifying Core Store state."
        activationState = .failed(lastError ?? "Read-only Safe Mode")
    }

    func checkNow() async {
        guard !readOnlySafeMode else {
            lastError = CoreLifecycleError.readOnlySafeMode.localizedDescription
            return
        }
        guard !manualRepairRequired else {
            lastError = CoreLifecycleError.manualRepairRequired.localizedDescription
            return
        }
        guard let catalogEndpoint else {
            catalogState = .unconfigured
            return
        }
        guard !updateRecoveryPending else {
            lastError = CoreLifecycleError.appUpdateInProgress.localizedDescription
            return
        }
        if case .checking = catalogState { return }
        guard !isDownloading else { return }
        catalogState = .checking
        do {
            let outcome = try await catalogDownloader.download(
                catalogURL: catalogEndpoint.catalogURL,
                signatureEnvelopeURL: catalogEndpoint.signatureEnvelopeURL,
                etag: catalogSnapshot?.etag
            )
            let lease = try await acquireCoreMutationLease()
            var automaticDownload: CoreCatalogEntry?
            var helperPolicyFailure: String?
            do {
                let state = try await store.loadState(
                    factoryCoreID: factoryDescriptor.coreID
                )
                switch outcome {
                case let .notModified(envelopeBytes, etag):
                    guard let catalogSnapshot else {
                        throw CoreLifecycleError.catalogCacheUnavailable
                    }
                    let refreshed = try catalogVerifier.verify(
                        catalogBytes: catalogSnapshot.rawBytes,
                        envelopeBytes: envelopeBytes,
                        state: state.catalogVerificationState,
                        now: now(),
                        etag: etag
                    )
                    try await store.saveVerifiedCatalog(refreshed)
                    self.catalogSnapshot = refreshed
                    catalogState = .verified(
                        sequence: refreshed.catalog.sequence,
                        expiresAt: refreshed.catalog.expiresAt,
                        keyIDs: refreshed.acceptedKeyIDs
                    )
                    scheduleCatalogExpiry(for: refreshed)
                    helperPolicyFailure = await refreshHelperCatalogPolicy(refreshed)
                case let .downloaded(catalogDownload):
                    let verified = try catalogVerifier.verify(
                        catalogBytes: catalogDownload.catalogBytes,
                        envelopeBytes: catalogDownload.envelopeBytes,
                        state: state.catalogVerificationState,
                        now: now(),
                        etag: catalogDownload.etag
                    )
                    try await store.saveVerifiedCatalog(verified)
                    var updated = applyCatalogStatuses(verified.catalog, to: state)
                    updated.highestCatalogSequence = verified.catalog.sequence
                    updated.lastCatalogSHA256 = verified.rawSHA256
                    try await store.saveState(updated)
                    snapshot = try await store.snapshot(
                        factoryDescriptor: factoryDescriptor,
                        state: updated
                    )
                    catalogSnapshot = verified
                    catalogState = .verified(
                        sequence: verified.catalog.sequence,
                        expiresAt: verified.catalog.expiresAt,
                        keyIDs: verified.acceptedKeyIDs
                    )
                    scheduleCatalogExpiry(for: verified)
                    helperPolicyFailure = await refreshHelperCatalogPolicy(verified)
                    await updateResolverMetadata(state: updated)
                    if preferences.automaticallyDownloadRecommended,
                        CoreAutomaticCatalogPolicy.allowsAutomaticDownload(
                            on: engineStore.networkPathSnapshot
                        ),
                        let entry = verified.catalog.recommendedEntry,
                        isCompatible(entry),
                        updated.record(for: entry.coreID) == nil
                    {
                        automaticDownload = entry
                    }
                }
            } catch {
                await runtimeMutationGate.release(lease)
                throw error
            }
            await runtimeMutationGate.release(lease)
            lastError = helperPolicyFailure
            if let automaticDownload {
                await download(automaticDownload)
            }
        } catch CoreCatalogVerificationError.generatedInFuture {
            let message = "The signed Core Catalog appears to come from the future. Check this Mac's date, time, and time zone, then try again."
            catalogState = .clockSkew(message)
            lastError = message
        } catch CoreCatalogVerificationError.expired {
            let message = "The downloaded signed Core Catalog has expired. Installed Cores remain usable, but new downloads are blocked until a fresh Catalog is available."
            if let cached = catalogSnapshot, cached.catalog.expiresAt <= now() {
                catalogState = .stale(
                    sequence: cached.catalog.sequence,
                    expiredAt: cached.catalog.expiresAt,
                    keyIDs: cached.acceptedKeyIDs
                )
            } else if catalogSnapshot == nil {
                catalogState = .staleUncached
            } else {
                // Do not make a still-fresh accepted checkpoint appear stale
                // because a server supplied a different expired response.
                catalogState = .failed(message)
            }
            lastError = message
        } catch {
            let message = CoreLifecycleDiagnosticText.safe(error)
            catalogState = .failed(message)
            lastError = message
        }
    }

    func downloadRecommended() async {
        guard let recommendedEntry else {
            lastError = "No verified recommended Core is available."
            return
        }
        guard isRecommendedCompatible else {
            lastError = recommendedCompatibilityMessage
            return
        }
        await download(recommendedEntry)
    }

    func download(_ entry: CoreCatalogEntry) async {
        guard !readOnlySafeMode else {
            lastError = CoreLifecycleError.readOnlySafeMode.localizedDescription
            return
        }
        guard !manualRepairRequired else {
            lastError = CoreLifecycleError.manualRepairRequired.localizedDescription
            return
        }
        guard !updateRecoveryPending else {
            lastError = CoreLifecycleError.appUpdateInProgress.localizedDescription
            return
        }
        guard productionFeedEnabled else {
            lastError = "The production Core Catalog feed is not enabled in this build."
            return
        }
        guard !isDownloading else { return }
        guard entry.status == .recommended || entry.status == .available else {
            lastError = "Blocked or withdrawn Cores cannot be downloaded."
            return
        }
        do {
            if let reason = try CoreCompatibilityEvaluator.incompatibilityReason(
                entry.vela,
                against: compatibilityEnvironment
            ) {
                lastError = reason
                return
            }
        } catch {
            lastError = "The Core compatibility metadata is invalid."
            return
        }
        guard let catalogSnapshot,
            catalogSnapshot.catalog.entries.contains(where: { $0.coreID == entry.coreID })
        else {
            lastError = "The Core entry is not part of the verified Catalog snapshot."
            return
        }
        guard catalogSnapshot.catalog.expiresAt > now() else {
            lastError = CoreLifecycleError.catalogExpired.localizedDescription
            return
        }
        isDownloading = true
        defer { isDownloading = false }
        var mutationLease: RuntimeMutationLease?
        var downloadWorkspace: CoreDownloadWorkspace?
        do {
            let workspace = try await fileDownloader.createWorkspace(in: directories.staging)
            downloadWorkspace = workspace
            var verifiedFiles: [CoreFileRole: URL] = [:]
            for file in entry.files {
                try Task.checkCancellation()
                let downloaded = try await fileDownloader.download(
                    file,
                    into: workspace.directory
                )
                verifiedFiles[downloaded.role] = downloaded.temporaryURL
            }
            let lease = try await acquireCoreMutationLease()
            mutationLease = lease
            guard self.catalogSnapshot?.rawSHA256 == catalogSnapshot.rawSHA256 else {
                throw CoreLifecycleError.catalogChangedDuringDownload
            }
            _ = try await store.reconstructBundle(
                entry: entry,
                verifiedFiles: verifiedFiles,
                catalogIdentity: CoreInstallCatalogIdentity(
                    sequence: catalogSnapshot.catalog.sequence,
                    sha256: catalogSnapshot.rawSHA256
                )
            )
            guard let revision = Int(exactly: entry.packageRevision) else {
                throw CoreLifecycleError.invalidPackageRevision
            }
            let timestamp = now()
            let record = InstalledCoreRecord(
                coreID: entry.coreID,
                upstreamVersion: entry.upstreamVersion,
                packageRevision: revision,
                catalogSequence: catalogSnapshot.catalog.sequence,
                catalogSHA256: catalogSnapshot.rawSHA256,
                installedAt: timestamp,
                lastUsedAt: timestamp
            )
            do {
                let resolver = try makeInstalledResolver(record: record, entry: entry)
                _ = try await resolver.resolve()
            } catch {
                try? await store.discardUncommittedInstallation(coreID: entry.coreID)
                throw error
            }
            var state = try await store.loadState(
                factoryCoreID: factoryDescriptor.coreID
            )
            state.installed.removeAll { $0.coreID == record.coreID }
            state.installed.append(record)
            try await store.saveState(state)
            state = try await store.cleanup(
                state: state,
                transaction: try await store.loadTransaction()
            )
            snapshot = try await store.snapshot(
                factoryDescriptor: factoryDescriptor,
                state: state
            )
            await fileDownloader.removeWorkspace(workspace)
            downloadWorkspace = nil
            await runtimeMutationGate.release(lease)
            mutationLease = nil
            lastError = nil
        } catch {
            if let downloadWorkspace {
                await fileDownloader.removeWorkspace(downloadWorkspace)
            }
            if let mutationLease {
                await runtimeMutationGate.release(mutationLease)
            }
            lastError = CoreLifecycleDiagnosticText.safe(error)
        }
    }

    func activate(_ coreID: CoreID) async {
        guard !readOnlySafeMode else {
            lastError = CoreLifecycleError.readOnlySafeMode.localizedDescription
            return
        }
        guard !manualRepairRequired else {
            lastError = CoreLifecycleError.manualRepairRequired.localizedDescription
            return
        }
        guard !updateRecoveryPending else {
            lastError = CoreLifecycleError.appUpdateInProgress.localizedDescription
            return
        }
        switch activationState {
        case .idle, .failed:
            activationState = .idle
        case .validatingCandidate, .snapshotting, .stoppingCurrent,
            .startingCandidate, .verifyingCandidate, .probation,
            .committing, .rollingBack:
            return
        }
        let lease: RuntimeMutationLease
        do {
            lease = try await runtimeMutationGate.acquire(.coreActivation)
        } catch {
            lastError = CoreLifecycleDiagnosticText.safe(error)
            return
        }
        var leaseTransferredToProbation = false

        var transaction: CoreActivationTransaction?
        var runtimeWasRunning = false
        do {
            guard var state = snapshot?.state else {
                throw CoreLifecycleError.notBootstrapped
            }
            guard coreID != state.activeCoreID else {
                await runtimeMutationGate.release(lease)
                return
            }
            guard let profileID = engineStore.selectedProfileID else {
                throw CoreLifecycleError.profileRequired
            }
            let oldCoreID = state.activeCoreID
            runtimeWasRunning = engineStore.isRunning
            let candidateResolver: (any MihomoExecutableResolving)?
            if coreID.isFactory {
                guard coreID == factoryDescriptor.coreID else {
                    throw CoreLifecycleError.coreUnavailable(coreID)
                }
                candidateResolver = nil
            } else {
                guard let record = state.record(for: coreID),
                    record.status != .blocked,
                    record.status != .quarantined
                else { throw CoreLifecycleError.coreUnavailable(coreID) }
                let entry = try await store.catalogEntry(
                    for: record,
                    verifier: catalogVerifier
                )
                guard entry.status != .blocked else {
                    throw CoreLifecycleError.coreBlocked(coreID)
                }
                if engineStore.isTunActive {
                    guard rootInventory?.cores.contains(where: { $0.coreID == coreID }) == true else {
                        throw CoreLifecycleError.rootStoreMissing(coreID)
                    }
                    try await ensureHelperPolicyReadyForTun(coreID: coreID)
                }
                candidateResolver = try makeInstalledResolver(record: record, entry: entry)
            }

            activationState = .validatingCandidate
            let candidateExecutable: ResolvedMihomoExecutable
            if let candidateResolver {
                candidateExecutable = try await candidateResolver.resolve()
            } else {
                candidateExecutable = try await activeResolver.resolveFactory()
            }
            try await engineStore.validateCoreCandidateForActivation(
                candidateExecutable
            )
            activationState = .snapshotting
            let backend: CoreBackendSelection = engineStore.isTunActive
                ? .tun
                : (engineStore.isSystemProxyApplied ? .systemProxy : .user)
            let activationSnapshot = try await engineStore.captureCoreActivationSnapshot(
                previousCoreID: oldCoreID,
                backend: backend,
                configurationGenerationID: configurationGeneration()
            )
            guard activationSnapshot.profileID == profileID else {
                throw CoreLifecycleError.activeResolverMismatch
            }
            var created = CoreActivationTransaction(
                coreID: coreID,
                phase: .activating,
                startedAt: now(),
                snapshot: activationSnapshot
            )
            try await store.createTransaction(created)
            transaction = created
            activationJournal = created

            state.activeCoreID = coreID
            if let index = state.installed.firstIndex(where: { $0.coreID == coreID }) {
                state.installed[index].lastUsedAt = now()
            }
            try await store.saveState(state)
            if let candidateResolver {
                try await activeResolver.select(coreID: coreID, resolver: candidateResolver)
            } else {
                await activeResolver.selectFactory()
            }
            activationState = .startingCandidate
            try await startCandidateWithBoundedLaunchRetry(
                restoreRunningRuntime: runtimeWasRunning,
                restoreBackend: backend
            )
            activationState = .verifyingCandidate
            try await verifyCandidateHealth(
                coreID: coreID,
                expectedRunning: runtimeWasRunning
            )
            try await engineStore.restoreCoreActivationRuntimeState(
                activationSnapshot,
                runtimeExpected: runtimeWasRunning
            )
            try await verifyCandidateHealth(
                coreID: coreID,
                expectedRunning: runtimeWasRunning
            )
            try await engineStore.completeSelectedCoreActivationBackendRestore(backend)

            created.phase = .probation
            try await store.updateTransaction(
                created,
                expectedID: created.transactionID
            )
            transaction = created
            activationJournal = created
            snapshot = try await store.snapshot(
                factoryDescriptor: factoryDescriptor,
                state: state
            )
            await updateResolverMetadata(state: state)
            beginProbation(
                transaction: created,
                previousCoreID: oldCoreID,
                expectedRunning: runtimeWasRunning,
                lease: lease
            )
            leaseTransferredToProbation = true
            lastError = nil
        } catch CoreStoreError.transactionAlreadyExists {
            activationJournal = try? await store.loadTransaction()
            manualRepairRequired = activationJournal != nil
            lastError = CoreLifecycleError.manualRepairRequired.localizedDescription
            activationState = .failed(lastError ?? "Manual repair required")
        } catch is CancellationError {
            if let transaction {
                lastError = "Cancelling safely; restoring the previous verified Core."
                // `activate` is already running in a cancelled task here. Keep
                // the safety rollback in an independent task so cancellation-
                // aware EngineStore/API work can finish and clear the journal.
                let rollbackTask = Task { @MainActor [self] in
                    await rollbackAfterFailure(
                        transaction: transaction,
                        cause: CancellationError(),
                        expectedRunning: runtimeWasRunning,
                        isManual: true
                    )
                }
                await rollbackTask.value
            } else {
                activationState = .idle
                lastError = nil
            }
        } catch {
            if transaction == nil {
                if shouldQuarantineCandidate(for: error) {
                    await recordCandidateValidationFailure(
                        coreID: coreID,
                        cause: error
                    )
                } else {
                    lastError = CoreLifecycleDiagnosticText.safe(error)
                    activationState = .failed(
                        lastError ?? "Core activation could not begin."
                    )
                }
            } else {
                await rollbackAfterFailure(
                    transaction: transaction,
                    cause: error,
                    expectedRunning: runtimeWasRunning
                )
            }
        }
        if !leaseTransferredToProbation {
            await runtimeMutationGate.release(lease)
        }
    }

    func rollback() async {
        guard !readOnlySafeMode else {
            lastError = CoreLifecycleError.readOnlySafeMode.localizedDescription
            return
        }
        guard !manualRepairRequired else {
            lastError = CoreLifecycleError.manualRepairRequired.localizedDescription
            return
        }
        guard !updateRecoveryPending else {
            lastError = CoreLifecycleError.appUpdateInProgress.localizedDescription
            return
        }
        guard let state = snapshot?.state else { return }

        if case .probation = activationState {
            probationTask?.cancel()
            do {
                guard let transaction = try await store.loadTransaction(),
                    transaction.phase == .probation,
                    transaction.coreID == state.activeCoreID
                else { throw CoreLifecycleError.rollbackFailed }

                let lease: RuntimeMutationLease
                if let probationLease {
                    lease = probationLease
                } else {
                    lease = try await runtimeMutationGate.acquire(.coreActivation)
                    probationLease = lease
                }
                await rollbackAfterFailure(
                    transaction: transaction,
                    cause: CoreLifecycleError.manualRollbackRequested,
                    expectedRunning: engineStore.isRunning,
                    isManual: true
                )
                if probationLease == lease {
                    await releaseProbationLease()
                }
            } catch {
                lastError = CoreLifecycleDiagnosticText.safe(error)
                activationState = .failed(lastError ?? "Manual Core rollback failed.")
            }
            return
        }

        let target = state.previousKnownGoodCoreID ?? factoryDescriptor.coreID
        await activate(target)
    }

    func remove(_ coreID: CoreID) async {
        guard !readOnlySafeMode else {
            lastError = CoreLifecycleError.readOnlySafeMode.localizedDescription
            return
        }
        guard !manualRepairRequired else {
            lastError = CoreLifecycleError.manualRepairRequired.localizedDescription
            return
        }
        guard !updateRecoveryPending else {
            lastError = CoreLifecycleError.appUpdateInProgress.localizedDescription
            return
        }
        guard !coreID.isFactory, snapshot?.state != nil else { return }
        var mutationLease: RuntimeMutationLease?
        do {
            let lease = try await acquireCoreMutationLease()
            mutationLease = lease
            let state = try await store.loadState(
                factoryCoreID: factoryDescriptor.coreID
            )
            let updated = try await store.removeInstalledCore(
                coreID: coreID,
                state: state
            )
            if let session = privilegedComponentManager?.lastHandshake?.sessionID,
                let helperClient
            {
                try? await helperClient.removeCore(
                    RemoveCoreRequest(sessionID: session, coreID: coreID)
                )
            }
            snapshot = try await store.snapshot(
                factoryDescriptor: factoryDescriptor,
                state: updated
            )
            await refreshRootInventory()
            await runtimeMutationGate.release(lease)
            mutationLease = nil
            lastError = nil
        } catch {
            if let mutationLease {
                await runtimeMutationGate.release(mutationLease)
            }
            lastError = CoreLifecycleDiagnosticText.safe(error)
        }
    }

    func retryVerification(_ coreID: CoreID) async {
        guard !readOnlySafeMode else {
            lastError = CoreLifecycleError.readOnlySafeMode.localizedDescription
            return
        }
        guard !manualRepairRequired else {
            lastError = CoreLifecycleError.manualRepairRequired.localizedDescription
            return
        }
        guard !updateRecoveryPending else {
            lastError = CoreLifecycleError.appUpdateInProgress.localizedDescription
            return
        }
        guard !isBusy, var state = snapshot?.state,
            let index = state.installed.firstIndex(where: { $0.coreID == coreID }),
            state.installed[index].status == .quarantined
        else { return }
        var mutationLease: RuntimeMutationLease?
        do {
            let lease = try await acquireCoreMutationLease()
            mutationLease = lease
            state = try await store.loadState(
                factoryCoreID: factoryDescriptor.coreID
            )
            guard let refreshedIndex = state.installed.firstIndex(where: {
                $0.coreID == coreID
            }), state.installed[refreshedIndex].status == .quarantined else {
                throw CoreLifecycleError.coreUnavailable(coreID)
            }
            let index = refreshedIndex
            let record = state.installed[index]
            let entry = try await store.catalogEntry(for: record, verifier: catalogVerifier)
            guard entry.status != .blocked else {
                throw CoreLifecycleError.coreBlocked(coreID)
            }
            let resolver = try makeInstalledResolver(record: record, entry: entry)
            _ = try await resolver.resolve()
            state.installed[index].status = .ready
            try await store.saveState(state)
            snapshot = try await store.snapshot(
                factoryDescriptor: factoryDescriptor,
                state: state
            )
            await runtimeMutationGate.release(lease)
            mutationLease = nil
            lastError = nil
        } catch {
            if let currentIndex = state.installed.firstIndex(where: {
                $0.coreID == coreID
            }) {
                state.installed[currentIndex].validationFailures += 1
                state.installed[currentIndex].lastFailurePhase = .failed
                state.installed[currentIndex].lastFailureAt = now()
                try? await store.saveState(state)
            }
            if let mutationLease {
                await runtimeMutationGate.release(mutationLease)
            }
            lastError = CoreLifecycleDiagnosticText.safe(error)
        }
    }

    /// Explicitly repairs User/Privileged store parity after a Helper install,
    /// upgrade, or root-store recovery. This never activates the Core.
    func prepareActiveCoreForTun() async throws {
        try await prepareCoreForTun(activeCoreID)
    }

    func prepareCoreForTun(_ coreID: CoreID) async throws {
        guard !readOnlySafeMode else { throw CoreLifecycleError.readOnlySafeMode }
        guard !manualRepairRequired else { throw CoreLifecycleError.manualRepairRequired }
        // Update recovery already owns the global update barrier and calls
        // restoreCoreForUpdate before EngineStore attempts a TUN start. Allow
        // that one controlled path to repeat the same fail-closed validation;
        // all unrelated Core mutations remain locked by updateRecoveryPending.
        guard !updateRecoveryPending || engineStore.isUpdateRecoveryInProgress else {
            throw CoreLifecycleError.appUpdateInProgress
        }
        guard !coreID.isFactory else {
            guard coreID == factoryDescriptor.coreID else {
                throw CoreLifecycleError.coreUnavailable(coreID)
            }
            return
        }
        let state = try await store.loadState(
            factoryCoreID: factoryDescriptor.coreID
        )
        guard let record = state.record(for: coreID),
            record.status != .blocked,
            record.status != .quarantined
        else { throw CoreLifecycleError.coreBlocked(coreID) }
        await refreshRootInventory()
        guard rootStoreContains(coreID) == true else {
            throw CoreLifecycleError.rootStoreMissing(coreID)
        }
        try await ensureHelperPolicyReadyForTun(coreID: coreID)
    }

    func syncCoreForTun(_ coreID: CoreID) async {
        guard !readOnlySafeMode else {
            lastError = CoreLifecycleError.readOnlySafeMode.localizedDescription
            return
        }
        guard !manualRepairRequired else {
            lastError = CoreLifecycleError.manualRepairRequired.localizedDescription
            return
        }
        guard !updateRecoveryPending else {
            lastError = CoreLifecycleError.appUpdateInProgress.localizedDescription
            return
        }
        guard !coreID.isFactory, !isBusy else { return }
        guard helperSupportsCoreStore else {
            lastError = "Install or update the compatible privileged component before syncing this Core for TUN."
            return
        }
        isSyncingRootStore = true
        defer { isSyncingRootStore = false }
        var mutationLease: RuntimeMutationLease?
        do {
            await refreshRootInventory()
            if rootStoreContains(coreID) == true {
                try await ensureHelperPolicyReadyForTun(coreID: coreID)
                lastError = nil
                return
            }
            let lease = try await acquireCoreMutationLease()
            mutationLease = lease
            let state = try await store.loadState(
                factoryCoreID: factoryDescriptor.coreID
            )
            guard let record = state.record(for: coreID),
                record.status != .blocked,
                record.status != .quarantined
            else { throw CoreLifecycleError.coreUnavailable(coreID) }
            let installedEntry = try await store.catalogEntry(
                for: record,
                verifier: catalogVerifier
            )
            guard installedEntry.status != .blocked else {
                throw CoreLifecycleError.coreBlocked(coreID)
            }
            let evidence = try await store.loadCatalogEvidence(
                sha256: record.catalogSHA256
            )
            let installedCatalog = try catalogVerifier.verifyInstalledEvidence(
                catalogBytes: evidence.catalogBytes,
                envelopeBytes: evidence.envelopeBytes,
                expectedSHA256: record.catalogSHA256
            )
            guard installedCatalog.catalog.sequence == record.catalogSequence else {
                throw CoreLifecycleError.catalogCheckpointUnavailable
            }

            let installEntry: CoreCatalogEntry
            let installCatalog: CoreCatalogSnapshot
            if let current = freshCatalogSnapshot(),
                let currentEntry = current.catalog.entries.first(where: {
                    $0.coreID == coreID
                })
            {
                guard immutableBundleIdentityMatches(
                    installedEntry,
                    currentEntry
                ) else {
                    throw CoreLifecycleError.catalogChangedDuringDownload
                }
                installEntry = currentEntry
                installCatalog = current
            } else {
                guard (rootInventory?.highestCatalogSequence ?? 0)
                    <= installedCatalog.catalog.sequence
                else {
                    throw CoreLifecycleError.currentCatalogEntryUnavailable(coreID)
                }
                installEntry = installedEntry
                installCatalog = installedCatalog
            }
            guard installEntry.status != .blocked else {
                throw CoreLifecycleError.coreBlocked(coreID)
            }
            try CoreCompatibilityEvaluator.validate(
                installEntry.vela,
                against: compatibilityEnvironment
            )

            // Re-run the complete current-config/signature/runtime preflight;
            // never mirror a stale or merely present user bundle into root.
            let resolver = try makeInstalledResolver(
                record: record,
                entry: installEntry
            )
            _ = try await resolver.resolve()
            try await ensureHelperPolicyReadyForTun(
                coreID: coreID,
                requireInstalled: false
            )
            try await installInRootStoreIfAvailable(
                entry: installEntry,
                catalog: installCatalog
            )
            await refreshRootInventory()
            guard rootStoreContains(coreID) == true else {
                throw CoreLifecycleError.privilegedStoreParityFailed
            }
            try await ensureHelperPolicyReadyForTun(coreID: coreID)
            await runtimeMutationGate.release(lease)
            mutationLease = nil
            lastError = nil
        } catch {
            if let mutationLease {
                await runtimeMutationGate.release(mutationLease)
            }
            lastError = "The User Core was kept unchanged, but TUN parity repair failed. \(CoreLifecycleDiagnosticText.safe(error))"
        }
    }

    /// User-confirmed completion of a retained crash journal. The journal is
    /// cleared only after previous/factory preflight, runtime restoration, and
    /// backend health all succeed. A second crash keeps the same latch and can
    /// never start another automatic rollback loop.
    func repairInterruptedActivation() async {
        guard manualRepairRequired else { return }
        guard !readOnlySafeMode, !updateRecoveryPending else {
            lastError = readOnlySafeMode
                ? CoreLifecycleError.readOnlySafeMode.localizedDescription
                : CoreLifecycleError.appUpdateInProgress.localizedDescription
            return
        }
        do {
            guard let transaction = try await store.loadTransaction(),
                transaction.automaticRollbackAttempts == 1,
                activationJournal?.transactionID == transaction.transactionID
            else { throw CoreLifecycleError.manualRepairJournalUnavailable }
            let lease = try await runtimeMutationGate.acquire(.coreActivation)
            await rollbackAfterFailure(
                transaction: transaction,
                cause: CoreLifecycleError.interruptedActivationRecovery,
                expectedRunning: engineStore.isRunning,
                isRecoveryRepair: true
            )
            await runtimeMutationGate.release(lease)
        } catch {
            lastError = "The retained Core rollback could not be verified. The journal remains locked for manual repair. \(CoreLifecycleDiagnosticText.safe(error))"
            activationState = .failed(lastError ?? "Manual repair required")
        }
    }

    func setAutomaticallyCheck(_ enabled: Bool) async {
        guard !readOnlySafeMode else {
            lastError = CoreLifecycleError.readOnlySafeMode.localizedDescription
            return
        }
        guard !manualRepairRequired else {
            lastError = CoreLifecycleError.manualRepairRequired.localizedDescription
            return
        }
        guard !updateRecoveryPending else {
            lastError = CoreLifecycleError.appUpdateInProgress.localizedDescription
            return
        }
        let previous = preferences
        preferences.automaticallyCheckForUpdates = enabled
        guard await savePreferences() else {
            preferences = previous
            return
        }
        if automaticSchedulingAllowed {
            if enabled {
                await startAutomaticCatalogScheduling()
            } else {
                automaticCheckScheduler?.invalidate()
                automaticCheckScheduler = nil
            }
        }
    }

    func setAutomaticallyDownload(_ enabled: Bool) async {
        guard !readOnlySafeMode else {
            lastError = CoreLifecycleError.readOnlySafeMode.localizedDescription
            return
        }
        guard !manualRepairRequired else {
            lastError = CoreLifecycleError.manualRepairRequired.localizedDescription
            return
        }
        guard !updateRecoveryPending else {
            lastError = CoreLifecycleError.appUpdateInProgress.localizedDescription
            return
        }
        let previous = preferences
        preferences.automaticallyDownloadRecommended = enabled
        guard await savePreferences() else {
            preferences = previous
            return
        }
    }

    func setSelectionMode(_ mode: CoreSelectionMode) async {
        guard !readOnlySafeMode else {
            lastError = CoreLifecycleError.readOnlySafeMode.localizedDescription
            return
        }
        guard !manualRepairRequired else {
            lastError = CoreLifecycleError.manualRepairRequired.localizedDescription
            return
        }
        guard !updateRecoveryPending else {
            lastError = CoreLifecycleError.appUpdateInProgress.localizedDescription
            return
        }
        if mode == .pinned,
            snapshot?.state.activeCoreID.isFactory != false
        {
            lastError = "Download and activate a Core before selecting Pinned."
            return
        }
        let previous = preferences
        preferences.mode = mode
        switch mode {
        case .followRecommended, .factoryOnly:
            preferences.pinnedCoreID = nil
        case .pinned:
            if preferences.pinnedCoreID == nil,
                let active = snapshot?.state.activeCoreID,
                !active.isFactory
            {
                preferences.pinnedCoreID = active
            }
        }
        guard await savePreferences() else {
            preferences = previous
            return
        }
        if mode == .factoryOnly,
            activeCoreID != factoryDescriptor.coreID
        {
            await activate(factoryDescriptor.coreID)
        }
    }

    func restoreCoreForUpdate(_ updateSnapshot: UpdateRuntimeSnapshot) async throws {
        guard !readOnlySafeMode else { throw CoreLifecycleError.readOnlySafeMode }
        guard !manualRepairRequired else { throw CoreLifecycleError.manualRepairRequired }
        var state = try await store.loadState(factoryCoreID: factoryDescriptor.coreID)
        let requestedMode = updateSnapshot.coreSelectionMode ?? preferences.mode
        let requestedCore = requestedMode == .factoryOnly
            ? factoryDescriptor.coreID
            : (updateSnapshot.activeCoreID ?? factoryDescriptor.coreID)
        var fallbackReason: String?

        if requestedCore.isFactory {
            state.activeCoreID = factoryDescriptor.coreID
            await activeResolver.selectFactory()
        } else {
            do {
                guard updateSnapshot.coreTrustRootSetVersion.map({
                    $0 <= VelaCoreCatalogTrustRoots.version
                }) ?? true else {
                    throw CoreLifecycleError.incompatibleTrustRootSet
                }
                guard updateSnapshot.highestCatalogSequence.map({
                    $0 <= state.highestCatalogSequence
                }) ?? true else {
                    throw CoreLifecycleError.catalogCheckpointUnavailable
                }
                guard let record = state.record(for: requestedCore),
                    record.status != .blocked,
                    record.status != .quarantined
                else {
                    throw CoreLifecycleError.coreUnavailable(requestedCore)
                }
                let entry = try await store.catalogEntry(
                    for: record,
                    verifier: catalogVerifier
                )
                guard entry.status != .blocked else {
                    throw CoreLifecycleError.coreBlocked(requestedCore)
                }
                if updateSnapshot.backend == .tun {
                    await refreshRootInventory()
                    guard rootInventory?.cores.contains(where: {
                        $0.coreID == requestedCore
                    }) == true else {
                        throw CoreLifecycleError.rootStoreMissing(requestedCore)
                    }
                    try await ensureHelperPolicyReadyForTun(coreID: requestedCore)
                }
                let resolver = try makeInstalledResolver(record: record, entry: entry)
                _ = try await resolver.resolve()
                try await activeResolver.select(
                    coreID: requestedCore,
                    resolver: resolver
                )
                state.activeCoreID = requestedCore
            } catch {
                fallbackReason = CoreLifecycleDiagnosticText.safe(error)
                state.activeCoreID = factoryDescriptor.coreID
                await activeResolver.selectFactory()
            }
        }

        if let previous = updateSnapshot.previousKnownGoodCoreID,
            previous.isFactory || state.record(for: previous) != nil
        {
            state.previousKnownGoodCoreID = previous
        }
        let canPersistRequestedPin = state.record(for: requestedCore) != nil
        preferences.mode = requestedMode == .pinned && !canPersistRequestedPin
            ? .factoryOnly
            : requestedMode
        preferences.pinnedCoreID = preferences.mode == .pinned
            ? requestedCore
            : nil
        state.pinnedCoreID = preferences.pinnedCoreID
        try await store.savePreferences(preferences)
        try await store.saveState(state)
        snapshot = try await store.snapshot(
            factoryDescriptor: factoryDescriptor,
            state: state
        )
        await updateResolverMetadata(state: state)
        if let fallbackReason {
            lastError = "The previous external Core is not compatible with this Vela build. Factory Core was restored. \(fallbackReason)"
        }
    }

    func finishUpdateRecovery(succeeded: Bool) async {
        guard !readOnlySafeMode else {
            lastError = CoreLifecycleError.readOnlySafeMode.localizedDescription
            return
        }
        guard updateRecoveryPending else { return }
        guard succeeded else {
            lastError = "Core operations remain disabled until App update recovery is repaired."
            activationState = .failed(lastError ?? "App update recovery failed.")
            return
        }

        updateRecoveryPending = false
        do {
            guard var transaction = try await store.loadTransaction() else {
                activationState = .idle
                return
            }
            guard transaction.phase == .probation,
                snapshot?.state.activeCoreID == transaction.coreID,
                let previous = transaction.snapshot?.previousCoreID
            else {
                transaction.phase = .failed
                transaction.automaticRollbackAttempts = 1
                try await store.updateTransaction(
                    transaction,
                    expectedID: transaction.transactionID
                )
                activationJournal = transaction
                manualRepairRequired = true
                lastError = CoreLifecycleError.manualRepairRequired.localizedDescription
                activationState = .failed(lastError ?? "Manual repair required")
                return
            }

            let lease = try await runtimeMutationGate.acquire(.coreActivation)
            beginProbation(
                transaction: transaction,
                previousCoreID: previous,
                expectedRunning: engineStore.isRunning,
                lease: lease
            )
        } catch {
            lastError = CoreLifecycleDiagnosticText.safe(error)
            activationState = .failed(lastError ?? "Core probation recovery failed.")
        }
    }

    func startAutomaticCatalogScheduling() async {
        automaticSchedulingAllowed = true
        automaticCheckScheduler?.invalidate()
        automaticCheckScheduler = nil

        guard preferences.automaticallyCheckForUpdates,
            productionFeedEnabled,
            !readOnlySafeMode,
            !manualRepairRequired,
            !updateRecoveryPending
        else { return }

        let scheduler = NSBackgroundActivityScheduler(
            identifier: "dev.yilin.Vela.CoreCatalogCheck"
        )
        scheduler.interval = CoreAutomaticCatalogPolicy.checkInterval
        scheduler.tolerance = CoreAutomaticCatalogPolicy.schedulerTolerance
        scheduler.repeats = true
        scheduler.qualityOfService = .utility
        scheduler.schedule { [weak self] completion in
            Task { @MainActor [weak self] in
                guard let self else {
                    completion(.finished)
                    return
                }
                _ = await self.checkAutomaticallyIfDue()
                completion(.finished)
            }
        }
        automaticCheckScheduler = scheduler
        _ = await checkAutomaticallyIfDue()
    }

    func automaticNetworkBecameAvailable() async {
        guard automaticSchedulingAllowed else { return }
        _ = await checkAutomaticallyIfDue()
    }

    @discardableResult
    private func checkAutomaticallyIfDue() async -> Bool {
        guard preferences.automaticallyCheckForUpdates,
            productionFeedEnabled,
            !readOnlySafeMode,
            !manualRepairRequired,
            !updateRecoveryPending,
            CoreAutomaticCatalogPolicy.allowsAutomaticCheck(
                on: engineStore.networkPathSnapshot
            )
        else { return false }

        let instant = now()
        let lastAttempt = automaticCheckDefaults.object(
            forKey: Self.lastAutomaticCheckAttemptKey
        ) as? Date
        guard CoreAutomaticCatalogPolicy.isCheckDue(
            lastAttempt: lastAttempt,
            now: instant
        ) else { return false }

        // Persist before starting so concurrent wake/network callbacks cannot
        // create duplicate checks. A failed attempt is retried by the next
        // system-coalesced interval or by an explicit user action.
        automaticCheckDefaults.set(
            instant,
            forKey: Self.lastAutomaticCheckAttemptKey
        )
        await checkNow()
        return true
    }

    func refreshRootInventory() async {
        guard let helperClient,
            let handshake = privilegedComponentManager?.lastHandshake,
            let session = handshake.sessionID
        else {
            rootInventory = nil
            invalidateHelperCatalogPolicyIdentity()
            return
        }
        bindHelperCatalogPolicyIdentity(to: handshake)
        rootInventory = try? await helperClient.listInstalledCores(
            ListInstalledCoresRequest(sessionID: session)
        )
    }

    /// Mirrors an App-verified Catalog into Helper-owned policy storage. The
    /// Helper re-verifies the raw bytes with its own embedded keyring and
    /// sequence checkpoint; a failure never invalidates the App's verified
    /// User-mode Catalog, but it does lock external TUN activation.
    private func refreshHelperCatalogPolicy(
        _ catalog: CoreCatalogSnapshot
    ) async -> String? {
        guard let helperClient,
            let handshake = privilegedComponentManager?.lastHandshake,
            handshake.hasCompatibleProtocol,
            let session = handshake.sessionID
        else {
            invalidateHelperCatalogPolicyIdentity()
            return nil
        }
        bindHelperCatalogPolicyIdentity(to: handshake)

        do {
            let response = try await helperClient.refreshCoreCatalog(
                RefreshCoreCatalogRequest(
                    sessionID: session,
                    rawCatalogData: catalog.rawBytes,
                    signatureEnvelopeData: catalog.rawEnvelopeBytes
                )
            )
            guard response.acceptedSequence == catalog.catalog.sequence,
                response.catalogSHA256.lowercased() == catalog.rawSHA256.lowercased()
            else { throw CoreLifecycleError.privilegedCatalogPolicyMismatch }
            helperCatalogPolicySequence = response.acceptedSequence
            helperCatalogPolicySHA256 = response.catalogSHA256.lowercased()
            helperCatalogPolicyHelperBuild = handshake.helperBuild
            helperCatalogPolicySyncError = nil
            return nil
        } catch {
            let message = "The Core Catalog is verified for User mode, but the privileged Core policy could not be refreshed. External TUN Core activation is locked until synchronization succeeds. \(CoreLifecycleDiagnosticText.safe(error))"
            helperCatalogPolicySyncError = message
            return message
        }
    }

    private func ensureHelperPolicyReadyForTun(
        coreID: CoreID,
        requireInstalled: Bool = true
    ) async throws {
        guard let helperClient,
            let handshake = privilegedComponentManager?.lastHandshake,
            handshake.hasCompatibleProtocol,
            let session = handshake.sessionID
        else {
            invalidateHelperCatalogPolicyIdentity()
            throw CoreLifecycleError.privilegedCatalogPolicyUnavailable
        }
        bindHelperCatalogPolicyIdentity(to: handshake)

        if let catalogSnapshot = freshCatalogSnapshot(),
            helperCatalogPolicySequence != catalogSnapshot.catalog.sequence
                || helperCatalogPolicySHA256 != catalogSnapshot.rawSHA256.lowercased()
        {
            if let failure = await refreshHelperCatalogPolicy(catalogSnapshot) {
                throw CoreLifecycleError.privilegedCatalogPolicySyncFailed(failure)
            }
        }

        guard requireInstalled else { return }
        do {
            let response = try await helperClient.validateCore(
                ValidateCoreRequest(sessionID: session, coreID: coreID)
            )
            guard response.coreID == coreID, response.valid else {
                throw CoreLifecycleError.privilegedCatalogPolicyMismatch
            }
            helperCatalogPolicySyncError = nil
        } catch let error as CoreLifecycleError {
            throw error
        } catch {
            throw CoreLifecycleError.privilegedCoreValidationFailed(
                CoreLifecycleDiagnosticText.safe(error)
            )
        }
    }

    private func loadPersistedCatalog(state: CoreStoreState) async {
        guard let sha256 = state.lastCatalogSHA256 else { return }
        do {
            let evidence = try await store.loadCatalogEvidence(sha256: sha256)
            do {
                let verified = try catalogVerifier.verify(
                    catalogBytes: evidence.catalogBytes,
                    envelopeBytes: evidence.envelopeBytes,
                    state: state.catalogVerificationState,
                    now: now()
                )
                guard verified.catalog.sequence == state.highestCatalogSequence else {
                    throw CoreLifecycleError.catalogCheckpointUnavailable
                }
                catalogSnapshot = verified
                catalogState = .verified(
                    sequence: verified.catalog.sequence,
                    expiresAt: verified.catalog.expiresAt,
                    keyIDs: verified.acceptedKeyIDs
                )
                scheduleCatalogExpiry(for: verified)
            } catch CoreCatalogVerificationError.expired {
                let historical = try catalogVerifier.verifyInstalledEvidence(
                    catalogBytes: evidence.catalogBytes,
                    envelopeBytes: evidence.envelopeBytes,
                    expectedSHA256: sha256
                )
                guard historical.catalog.sequence == state.highestCatalogSequence else {
                    throw CoreLifecycleError.catalogCheckpointUnavailable
                }
                catalogSnapshot = historical
                catalogExpiryTask?.cancel()
                catalogState = .stale(
                    sequence: historical.catalog.sequence,
                    expiredAt: historical.catalog.expiresAt,
                    keyIDs: historical.acceptedKeyIDs
                )
            }
        } catch {
            catalogExpiryTask?.cancel()
            catalogSnapshot = nil
            catalogState = .failed(CoreLifecycleDiagnosticText.safe(error))
        }
    }

    private func recoverInterruptedTransaction(
        state supplied: CoreStoreState
    ) async throws -> CoreStoreState {
        let transaction = try await store.loadTransaction()
        let plan = CoreActivationRecoveryPolicy.plan(
            transaction: transaction,
            state: supplied,
            factoryCoreID: factoryDescriptor.coreID
        )

        activationJournal = transaction
        manualRepairRequired = plan.manualRepairRequired

        switch plan.journalAction {
        case .none:
            activationJournal = nil
        case .clearCommitted:
            guard let transaction else {
                throw CoreLifecycleError.manualRepairJournalUnavailable
            }
            try await store.clearTransaction(expectedID: transaction.transactionID)
            activationJournal = nil
        case let .markFailed(automaticRollbackAttempts):
            guard var transaction else {
                throw CoreLifecycleError.manualRepairJournalUnavailable
            }
            transaction.phase = .failed
            transaction.automaticRollbackAttempts = automaticRollbackAttempts
            try await store.updateTransaction(
                transaction,
                expectedID: transaction.transactionID
            )
            activationJournal = transaction
        case .retainForRepair:
            break
        }

        var state = supplied
        state.activeCoreID = plan.selectedCoreID
        if plan.quarantineCandidate,
            let transaction,
            let index = state.installed.firstIndex(where: {
                $0.coreID == transaction.coreID
            })
        {
            state.installed[index].status = .quarantined
        }
        return state
    }

    private func selectPersistedCore(state: inout CoreStoreState) async throws {
        if state.activeCoreID.isFactory {
            guard state.activeCoreID == factoryDescriptor.coreID else {
                state.activeCoreID = factoryDescriptor.coreID
                return
            }
            await activeResolver.selectFactory()
            _ = try await activeResolver.resolve()
            return
        }
        do {
            guard let record = state.record(for: state.activeCoreID),
                record.status != .quarantined
            else { throw CoreLifecycleError.coreUnavailable(state.activeCoreID) }
            let entry = try await store.catalogEntry(for: record, verifier: catalogVerifier)
            let resolver = try makeInstalledResolver(record: record, entry: entry)
            _ = try await resolver.resolve()
            try await activeResolver.select(coreID: record.coreID, resolver: resolver)
        } catch {
            if let index = state.installed.firstIndex(where: { $0.coreID == state.activeCoreID }) {
                state.installed[index].status = .quarantined
            }
            state.activeCoreID = factoryDescriptor.coreID
            await activeResolver.selectFactory()
            lastError = "The previous external Core failed verification; Factory Core was selected."
        }
    }

    private func makeInstalledResolver(
        record: InstalledCoreRecord,
        entry: CoreCatalogEntry
    ) throws -> any MihomoExecutableResolving {
        if let installedResolverFactory {
            return try installedResolverFactory(record, entry)
        }
        let descriptor = CoreDescriptor.installed(record: record, directories: directories)
        let workspace = directories.staging.appending(
            path: "preflight-\(record.coreID.rawValue.replacingOccurrences(of: ":", with: "_"))",
            directoryHint: .isDirectory
        )
        let requestFactory = try CorePreflightRequestFactory(
            workspaceURL: workspace,
            compatibilityEnvironment: compatibilityEnvironment
        )
        let preflight = InstalledCorePreflight(smokeTester: LiveCoreSmokeTester())
        return InstalledCoreExecutableResolver(preflight: preflight) {
            try await requestFactory.request(descriptor: descriptor, catalogEntry: entry)
        }
    }

    private func verifyCandidateHealth(
        coreID: CoreID,
        expectedRunning: Bool
    ) async throws {
        guard await activeResolver.coreID() == coreID else {
            throw CoreLifecycleError.activeResolverMismatch
        }
        _ = try await activeResolver.resolve()
        guard expectedRunning else { return }
        guard engineStore.isRunning else {
            if case .failed = engineStore.state {
                throw CoreLifecycleError.unexpectedExit
            }
            throw CoreLifecycleError.probationRuntimeStopped
        }
        await engineStore.refreshHealth()
        guard engineStore.controllerState == .connected else {
            throw CoreLifecycleError.controllerUnavailable
        }
        let runtimeID = engineStore.activeRuntime?.instanceID
        let contractCheckDue = runtimeID != lastControllerAPIContractRuntimeID
            || lastControllerAPIContractCheckAt.map {
                now().timeIntervalSince($0) >= 60
            } ?? true
        if contractCheckDue {
            do {
                try await engineStore.verifyActiveCoreControllerAPIContract()
                lastControllerAPIContractRuntimeID = runtimeID
                lastControllerAPIContractCheckAt = now()
            } catch {
                throw CoreLifecycleError.healthVerificationFailed
            }
        }
        if engineStore.activeBackendKind == .privilegedDaemon,
            !engineStore.coreActivationPrivilegedHealthReady
        {
            throw CoreLifecycleError.healthVerificationFailed
        }
        let critical = engineStore.lastHealthReport?.issues.contains { issue in
            issue.severity == .error
                && issue.component != .internet
                && issue.component != .networkPath
        } == true
        guard !critical else { throw CoreLifecycleError.healthVerificationFailed }
    }

    private func startCandidateWithBoundedLaunchRetry(
        restoreRunningRuntime: Bool,
        restoreBackend: CoreBackendSelection
    ) async throws {
        var failureWindow = CoreCandidateLaunchFailureWindow()
        var launchFailures = 0
        while true {
            try Task.checkCancellation()
            do {
                try await engineStore.applySelectedCoreForActivation(
                    restoreRunningRuntime: restoreRunningRuntime,
                    restoreBackend: restoreBackend
                )
                try Task.checkCancellation()
                failureWindow.recordSuccess()
                return
            } catch EngineCoreActivationError.restartFailed {
                try Task.checkCancellation()
                launchFailures += 1
                switch failureWindow.recordFailure(at: now()) {
                case .retryCandidate:
                    // The previous runtime is already stopped and the global
                    // mutation lease remains held. Retry only the same signed
                    // candidate; no profile/Core selection is changed here.
                    guard launchFailures < 2 else {
                        throw EngineCoreActivationError.restartFailed
                    }
                    continue
                case .rollbackOnceAndQuarantine:
                    throw EngineCoreActivationError.restartFailed
                }
            }
        }
    }

    private func beginProbation(
        transaction: CoreActivationTransaction,
        previousCoreID: CoreID,
        expectedRunning: Bool,
        lease: RuntimeMutationLease?
    ) {
        probationTask?.cancel()
        probationLease = lease
        let initialDeadline = now().addingTimeInterval(probationDuration.timeInterval)
        activationState = .probation(until: initialDeadline)
        probationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var activeTransaction = transaction
            var observedHealthyRuntime = expectedRunning
            var deadline = initialDeadline
            do {
                if !expectedRunning, let lease = self.probationLease {
                    await self.runtimeMutationGate.release(lease)
                    self.probationLease = nil
                }

                while true {
                    try Task.checkCancellation()
                    if !self.engineStore.isRunning {
                        if case .failed = self.engineStore.state {
                            throw CoreLifecycleError.unexpectedExit
                        }
                        observedHealthyRuntime = false
                        deadline = self.now().addingTimeInterval(
                            self.probationDuration.timeInterval
                        )
                        self.activationState = .probation(until: deadline)
                    } else {
                        if self.probationLease == nil {
                            let acquired = try await self.runtimeMutationGate.acquire(
                                .coreActivation
                            )
                            self.probationLease = acquired
                            activeTransaction = try await self.refreshProbationSnapshot(
                                activeTransaction
                            )
                            deadline = self.now().addingTimeInterval(
                                self.probationDuration.timeInterval
                            )
                            self.activationState = .probation(until: deadline)
                        }
                        try await self.verifyCandidateHealth(
                            coreID: activeTransaction.coreID,
                            expectedRunning: true
                        )
                        if !observedHealthyRuntime {
                            observedHealthyRuntime = true
                            deadline = self.now().addingTimeInterval(
                                self.probationDuration.timeInterval
                            )
                            self.activationState = .probation(until: deadline)
                        }
                        if self.now() >= deadline { break }
                    }

                    let remaining = max(0.05, deadline.timeIntervalSince(self.now()))
                    let pollSeconds = min(5.0, remaining)
                    try await self.sleep(
                        .milliseconds(Int64((pollSeconds * 1_000).rounded(.up)))
                    )
                }

                guard observedHealthyRuntime else {
                    throw CoreLifecycleError.probationRuntimeStopped
                }
                try await self.commitProbation(
                    transaction: activeTransaction,
                    previousCoreID: previousCoreID
                )
                await self.releaseProbationLease()
            } catch is CancellationError {
                return
            } catch {
                await self.rollbackProbationFailure(
                    transaction: activeTransaction,
                    cause: error,
                    expectedRunning: observedHealthyRuntime
                )
            }
        }
    }

    private func refreshProbationSnapshot(
        _ transaction: CoreActivationTransaction
    ) async throws -> CoreActivationTransaction {
        guard let snapshot = transaction.snapshot,
            let profileID = engineStore.selectedProfileID
        else { throw CoreLifecycleError.profileRequired }
        let generation = configurationGeneration()
        let refreshedSnapshot = try await engineStore.captureCoreActivationSnapshot(
            previousCoreID: snapshot.previousCoreID,
            backend: snapshot.backend,
            configurationGenerationID: generation
        )
        guard refreshedSnapshot.profileID == profileID else {
            throw CoreLifecycleError.activeResolverMismatch
        }
        guard refreshedSnapshot != snapshot else { return transaction }

        let refreshed = CoreActivationTransaction(
            schemaVersion: transaction.schemaVersion,
            transactionID: transaction.transactionID,
            coreID: transaction.coreID,
            phase: transaction.phase,
            startedAt: transaction.startedAt,
            snapshot: refreshedSnapshot,
            automaticRollbackAttempts: transaction.automaticRollbackAttempts
        )
        try await store.updateTransaction(
            refreshed,
            expectedID: refreshed.transactionID
        )
        activationJournal = refreshed
        return refreshed
    }

    private func releaseProbationLease() async {
        guard let lease = probationLease else { return }
        probationLease = nil
        await runtimeMutationGate.release(lease)
    }

    private func rollbackProbationFailure(
        transaction: CoreActivationTransaction,
        cause: any Error,
        expectedRunning: Bool
    ) async {
        do {
            let lease: RuntimeMutationLease
            if let probationLease {
                lease = probationLease
            } else {
                lease = try await runtimeMutationGate.acquire(.coreActivation)
                probationLease = lease
            }
            await rollbackAfterFailure(
                transaction: transaction,
                cause: cause,
                expectedRunning: expectedRunning
            )
            if probationLease == lease {
                await releaseProbationLease()
            }
        } catch {
            lastError = "Probation failed, but Vela could not acquire the rollback barrier."
            activationState = .failed(lastError ?? "Core probation rollback failed.")
        }
    }

    private func commitProbation(
        transaction original: CoreActivationTransaction,
        previousCoreID: CoreID
    ) async throws {
        activationState = .committing
        var state = try await store.loadState(factoryCoreID: factoryDescriptor.coreID)
        guard let activationSnapshot = original.snapshot,
            state.activeCoreID == original.coreID,
            engineStore.selectedProfileID == activationSnapshot.profileID,
            configurationGeneration() == activationSnapshot.configurationGenerationID
        else {
            throw CoreLifecycleError.activeResolverMismatch
        }
        if let index = state.installed.firstIndex(where: { $0.coreID == original.coreID }) {
            state.installed[index].status = .knownGood
        }
        state.previousKnownGoodCoreID = previousCoreID
        try await store.saveState(state)
        var transaction = original
        transaction.phase = .committed
        try await store.updateTransaction(
            transaction,
            expectedID: transaction.transactionID
        )
        try await store.clearTransaction(expectedID: transaction.transactionID)
        activationJournal = nil
        snapshot = try await store.snapshot(factoryDescriptor: factoryDescriptor, state: state)
        await updateResolverMetadata(state: state)
        activationState = .idle
    }

    private func rollbackAfterFailure(
        transaction original: CoreActivationTransaction?,
        cause: any Error,
        expectedRunning: Bool,
        isManual: Bool = false,
        isRecoveryRepair: Bool = false
    ) async {
        activationState = .rollingBack
        var rollbackTransaction = original
        do {
            if var transaction = rollbackTransaction {
                if isRecoveryRepair {
                    guard transaction.automaticRollbackAttempts == 1 else {
                        throw CoreLifecycleError.manualRepairJournalUnavailable
                    }
                } else {
                    guard transaction.automaticRollbackAttempts == 0 else {
                        throw CoreLifecycleError.rollbackFailed
                    }
                }
                transaction.phase = .rollingBack
                if !isManual, !isRecoveryRepair {
                    transaction.automaticRollbackAttempts = 1
                }
                try await store.updateTransaction(
                    transaction,
                    expectedID: transaction.transactionID
                )
                rollbackTransaction = transaction
                activationJournal = transaction
            }

            var state = try await store.loadState(factoryCoreID: factoryDescriptor.coreID)
            let failedCoreID = original?.coreID ?? state.activeCoreID
            let previous = original?.snapshot?.previousCoreID
            if !isManual,
                let index = state.installed.firstIndex(where: { $0.coreID == failedCoreID })
            {
                state.installed[index].status = .quarantined
                state.installed[index].activationFailures += 1
                if cause as? CoreLifecycleError == .unexpectedExit {
                    state.installed[index].unexpectedExits += 1
                }
                state.installed[index].lastFailurePhase = original?.phase ?? .failed
                state.installed[index].lastFailureAt = now()
            }
            try await store.saveState(state)

            var targets: [CoreID] = []
            if let previous {
                if previous.isFactory {
                    targets.append(factoryDescriptor.coreID)
                } else if let record = state.record(for: previous),
                    record.status != .blocked,
                    record.status != .quarantined
                {
                    targets.append(previous)
                }
            }
            if !targets.contains(factoryDescriptor.coreID) {
                targets.append(factoryDescriptor.coreID)
            }

            var restoredCoreID: CoreID?
            var lastRestoreError: (any Error)?
            for target in targets {
                do {
                    if target.isFactory {
                        await activeResolver.selectFactory()
                    } else if let record = state.record(for: target) {
                        let entry = try await store.catalogEntry(
                            for: record,
                            verifier: catalogVerifier
                        )
                        let resolver = try makeInstalledResolver(
                            record: record,
                            entry: entry
                        )
                        _ = try await resolver.resolve()
                        try await activeResolver.select(
                            coreID: target,
                            resolver: resolver
                        )
                    } else {
                        throw CoreLifecycleError.coreUnavailable(target)
                    }

                    state.activeCoreID = target
                    try await store.saveState(state)
                    try await engineStore.applySelectedCoreForActivation(
                        restoreRunningRuntime: expectedRunning,
                        restoreBackend: original?.snapshot?.backend
                    )
                    try await verifyCandidateHealth(
                        coreID: target,
                        expectedRunning: expectedRunning
                    )
                    if let activationSnapshot = original?.snapshot {
                        try await engineStore.restoreCoreActivationRuntimeState(
                            activationSnapshot,
                            runtimeExpected: expectedRunning
                        )
                        try await verifyCandidateHealth(
                            coreID: target,
                            expectedRunning: expectedRunning
                        )
                    }
                    if expectedRunning {
                        try await engineStore.completeSelectedCoreActivationBackendRestore(
                            original?.snapshot?.backend
                        )
                    }
                    restoredCoreID = target
                    break
                } catch {
                    lastRestoreError = error
                    continue
                }
            }
            guard restoredCoreID != nil else {
                throw lastRestoreError ?? CoreLifecycleError.rollbackFailed
            }

            if var transaction = rollbackTransaction {
                transaction.phase = .failed
                try await store.updateTransaction(
                    transaction,
                    expectedID: transaction.transactionID
                )
                try await store.clearTransaction(expectedID: transaction.transactionID)
                activationJournal = nil
            }
            snapshot = try await store.snapshot(
                factoryDescriptor: factoryDescriptor,
                state: state
            )
            await updateResolverMetadata(state: state)
            if isRecoveryRepair {
                manualRepairRequired = false
                lastError = nil
                activationState = .idle
            } else if isManual {
                lastError = nil
                activationState = .idle
            } else {
                let message = CoreLifecycleDiagnosticText.safe(cause)
                lastError = "Core activation failed and Vela rolled back safely. \(message)"
                activationState = .failed(lastError ?? "Core activation failed.")
            }
        } catch {
            if var transaction = rollbackTransaction {
                transaction.phase = .failed
                transaction.automaticRollbackAttempts = 1
                try? await store.updateTransaction(
                    transaction,
                    expectedID: transaction.transactionID
                )
                activationJournal = transaction
                manualRepairRequired = true
            }
            let safeFailure = CoreLifecycleDiagnosticText.safe(error)
            if isRecoveryRepair {
                manualRepairRequired = true
                lastError = "The retained Core rollback still cannot be verified. Manual repair is required. \(safeFailure)"
            } else {
                lastError = isManual
                    ? "Manual Core rollback failed. Manual repair is required. \(safeFailure)"
                    : "Core activation and automatic rollback failed. Manual repair is required. \(safeFailure)"
            }
            activationState = .failed(lastError ?? "Core rollback failed.")
        }
    }

    private func recordCandidateValidationFailure(
        coreID: CoreID,
        cause: any Error
    ) async {
        do {
            var state = try await store.loadState(factoryCoreID: factoryDescriptor.coreID)
            if let index = state.installed.firstIndex(where: { $0.coreID == coreID }) {
                state.installed[index].status = .quarantined
                state.installed[index].validationFailures += 1
                state.installed[index].lastFailurePhase = .failed
                state.installed[index].lastFailureAt = now()
                try await store.saveState(state)
                snapshot = try await store.snapshot(
                    factoryDescriptor: factoryDescriptor,
                    state: state
                )
            }
            lastError = CoreLifecycleDiagnosticText.safe(cause)
            activationState = .failed(lastError ?? "Core validation failed.")
        } catch {
            lastError = "Core validation failed, and its quarantine record could not be saved."
            activationState = .failed(lastError ?? "Core validation failed.")
        }
    }

    private func shouldQuarantineCandidate(for error: any Error) -> Bool {
        guard let lifecycleError = error as? CoreLifecycleError else {
            return true
        }
        return switch lifecycleError {
        case .notBootstrapped, .readOnlySafeMode, .appUpdateInProgress,
            .profileRequired, .coreUnavailable, .coreBlocked, .rootStoreMissing,
            .manualRepairRequired, .manualRepairJournalUnavailable,
            .privilegedStoreParityFailed, .privilegedCatalogPolicyUnavailable,
            .privilegedCatalogPolicyMismatch, .privilegedCatalogPolicySyncFailed,
            .privilegedCoreValidationFailed:
            false
        default:
            true
        }
    }

    private func installInRootStoreIfAvailable(
        entry: CoreCatalogEntry,
        catalog: CoreCatalogSnapshot
    ) async throws {
        guard let helperClient,
            let session = privilegedComponentManager?.lastHandshake?.sessionID
        else { return }
        var transactionID: UUID?
        do {
            let prepared = try await helperClient.prepareCoreInstall(
                PrepareCoreInstallRequest(
                    sessionID: session,
                    ownerUID: getuid(),
                    rawCatalogData: catalog.rawBytes,
                    signatureEnvelopeData: catalog.rawEnvelopeBytes,
                    selectedCoreID: entry.coreID
                )
            )
            transactionID = prepared.transactionID
            guard Set(prepared.requiredRoles) == Set(CoreFileRole.allCases) else {
                throw CoreLifecycleError.helperRoleMismatch
            }
            guard let revision = Int(exactly: entry.packageRevision) else {
                throw CoreLifecycleError.invalidPackageRevision
            }
            let descriptor = CoreDescriptor.installed(
                record: InstalledCoreRecord(
                    coreID: entry.coreID,
                    upstreamVersion: entry.upstreamVersion,
                    packageRevision: revision,
                    catalogSequence: catalog.catalog.sequence,
                    catalogSHA256: catalog.rawSHA256,
                    installedAt: now(),
                    lastUsedAt: now()
                ),
                directories: directories
            )
            for role in CoreFileRole.allCases {
                guard let file = entry.file(for: role) else {
                    throw CoreLifecycleError.helperRoleMismatch
                }
                let handle = try FileHandle(
                    forReadingFrom: descriptor.bundleURL.appending(
                        path: role.requiredRelativePath
                    )
                )
                defer { try? handle.close() }
                try await helperClient.stageCoreFile(
                    StageCoreFileRequest(
                        sessionID: session,
                        transactionID: prepared.transactionID,
                        role: role,
                        expectedSize: Int(file.size),
                        expectedSHA256: file.sha256
                    ),
                    file: handle
                )
            }
            try await helperClient.commitCoreInstall(
                CommitCoreInstallRequest(
                    sessionID: session,
                    transactionID: prepared.transactionID
                )
            )
        } catch {
            if let transactionID {
                try? await helperClient.abortCoreInstall(
                    AbortCoreInstallRequest(
                        sessionID: session,
                        transactionID: transactionID
                    )
                )
            }
            throw CoreLifecycleError.privilegedStoreParityFailed
        }
    }

    private func isCompatible(_ entry: CoreCatalogEntry) -> Bool {
        do {
            return try CoreCompatibilityEvaluator.incompatibilityReason(
                entry.vela,
                against: compatibilityEnvironment
            ) == nil
        } catch {
            return false
        }
    }

    private func applyCatalogStatuses(
        _ catalog: CoreCatalog,
        to supplied: CoreStoreState
    ) -> CoreStoreState {
        var state = supplied
        for index in state.installed.indices {
            guard let entry = catalog.entries.first(where: {
                $0.coreID == state.installed[index].coreID
            }) else { continue }
            switch entry.status {
            case .blocked:
                state.installed[index].status = .blocked
            case .withdrawn:
                if state.installed[index].status != .quarantined {
                    state.installed[index].status = .withdrawn
                }
            case .recommended, .available:
                if state.installed[index].status == .blocked {
                    state.installed[index].status = .ready
                }
            }
        }
        return state
    }

    private func freshCatalogSnapshot() -> CoreCatalogSnapshot? {
        guard let catalogSnapshot else { return nil }
        guard catalogSnapshot.catalog.expiresAt > now() else {
            if case .verified = catalogState {
                catalogState = .stale(
                    sequence: catalogSnapshot.catalog.sequence,
                    expiredAt: catalogSnapshot.catalog.expiresAt,
                    keyIDs: catalogSnapshot.acceptedKeyIDs
                )
            }
            return nil
        }
        return catalogSnapshot
    }

    private func scheduleCatalogExpiry(for catalog: CoreCatalogSnapshot) {
        catalogExpiryTask?.cancel()
        let expectedSHA256 = catalog.rawSHA256
        catalogExpiryTask = Task { @MainActor [weak self] in
            while let self,
                self.catalogSnapshot?.rawSHA256 == expectedSHA256
            {
                let remaining = catalog.catalog.expiresAt.timeIntervalSince(self.now())
                if remaining <= 0 {
                    _ = self.freshCatalogSnapshot()
                    return
                }
                do {
                    try await Task.sleep(
                        for: .seconds(min(remaining, 60 * 60))
                    )
                } catch {
                    return
                }
            }
        }
    }

    @ObservationIgnored private var helperCatalogPolicySessionID: UUID?

    private func bindHelperCatalogPolicyIdentity(
        to handshake: HelperHandshakeResponse
    ) {
        guard let sessionID = handshake.sessionID else {
            invalidateHelperCatalogPolicyIdentity()
            return
        }
        guard helperCatalogPolicySessionID != sessionID
            || helperCatalogPolicyHelperBuild != handshake.helperBuild
        else { return }
        helperCatalogPolicySessionID = sessionID
        helperCatalogPolicyHelperBuild = handshake.helperBuild
        helperCatalogPolicySequence = nil
        helperCatalogPolicySHA256 = nil
        helperCatalogPolicySyncError = nil
    }

    private func invalidateHelperCatalogPolicyIdentity() {
        helperCatalogPolicySessionID = nil
        helperCatalogPolicyHelperBuild = nil
        helperCatalogPolicySequence = nil
        helperCatalogPolicySHA256 = nil
        helperCatalogPolicySyncError = nil
    }

    private func immutableBundleIdentityMatches(
        _ lhs: CoreCatalogEntry,
        _ rhs: CoreCatalogEntry
    ) -> Bool {
        lhs.coreID == rhs.coreID
            && lhs.upstreamVersion == rhs.upstreamVersion
            && lhs.packageRevision == rhs.packageRevision
            && Dictionary(uniqueKeysWithValues: lhs.files.map {
                ($0.role, "\($0.size):\($0.sha256)")
            }) == Dictionary(uniqueKeysWithValues: rhs.files.map {
                ($0.role, "\($0.size):\($0.sha256)")
            })
    }

    private func updateResolverMetadata(state: CoreStoreState) async {
        await activeResolver.updateLifecycleMetadata(
            previousKnownGoodCoreID: state.previousKnownGoodCoreID,
            selectionMode: preferences.mode,
            highestCatalogSequence: state.highestCatalogSequence,
            trustRootSetVersion: VelaCoreCatalogTrustRoots.version
        )
    }

    private func savePreferences() async -> Bool {
        var mutationLease: RuntimeMutationLease?
        do {
            let lease = try await acquireCoreMutationLease()
            mutationLease = lease
            try await store.savePreferences(preferences)
            var state = try await store.loadState(
                factoryCoreID: factoryDescriptor.coreID
            )
            state.pinnedCoreID = preferences.pinnedCoreID
            try await store.saveState(state)
            snapshot = try await store.snapshot(
                factoryDescriptor: factoryDescriptor,
                state: state
            )
            await updateResolverMetadata(state: state)
            await runtimeMutationGate.release(lease)
            mutationLease = nil
            lastError = nil
            return true
        } catch {
            if let mutationLease {
                await runtimeMutationGate.release(mutationLease)
            }
            lastError = CoreLifecycleDiagnosticText.safe(error)
            return false
        }
    }

    private func acquireCoreMutationLease() async throws -> RuntimeMutationLease {
        guard !readOnlySafeMode else { throw CoreLifecycleError.readOnlySafeMode }
        guard !manualRepairRequired else { throw CoreLifecycleError.manualRepairRequired }
        guard !updateRecoveryPending else {
            throw CoreLifecycleError.appUpdateInProgress
        }
        do {
            return try await runtimeMutationGate.acquire(.coreActivation)
        } catch RuntimeMutationGateError.updateInProgress {
            throw CoreLifecycleError.appUpdateInProgress
        }
    }
}

nonisolated enum CoreLifecycleError: Error, Equatable, Sendable {
    case notBootstrapped
    case readOnlySafeMode
    case appUpdateInProgress
    case catalogCacheUnavailable
    case catalogExpired
    case catalogChangedDuringDownload
    case catalogCheckpointUnavailable
    case currentCatalogEntryUnavailable(CoreID)
    case incompatibleTrustRootSet
    case invalidPackageRevision
    case profileRequired
    case coreUnavailable(CoreID)
    case coreBlocked(CoreID)
    case rootStoreMissing(CoreID)
    case activeResolverMismatch
    case controllerUnavailable
    case unexpectedExit
    case probationRuntimeStopped
    case healthVerificationFailed
    case rollbackFailed
    case manualRollbackRequested
    case interruptedActivationRecovery
    case manualRepairRequired
    case manualRepairJournalUnavailable
    case helperRoleMismatch
    case privilegedStoreParityFailed
    case privilegedCatalogPolicyUnavailable
    case privilegedCatalogPolicyMismatch
    case privilegedCatalogPolicySyncFailed(String)
    case privilegedCoreValidationFailed(String)
}

extension CoreLifecycleError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .notBootstrapped:
            "The signed Core lifecycle has not finished bootstrapping."
        case .readOnlySafeMode:
            "Core changes are disabled because this Store belongs to a newer Vela version. Reinstall the newer Vela version to leave read-only Safe Mode."
        case .appUpdateInProgress:
            "An App update is in progress. Core changes are temporarily unavailable."
        case .catalogCacheUnavailable:
            "The server returned Not Modified, but no verified Catalog is cached."
        case .catalogExpired:
            "The verified Core Catalog has expired. Check for a fresh Catalog before downloading."
        case .catalogChangedDuringDownload:
            "The verified Core Catalog changed while the package was downloading. Retry the download."
        case .catalogCheckpointUnavailable:
            "The Core Catalog checkpoint required by update recovery is unavailable."
        case let .currentCatalogEntryUnavailable(coreID):
            "The Helper has accepted a newer Catalog that does not carry immutable evidence for Core \(coreID.rawValue). Publish that Core as available or withdrawn in a fresh Catalog before syncing it for TUN."
        case .incompatibleTrustRootSet:
            "The Core Catalog trust-root set required by the previous build is not supported."
        case .invalidPackageRevision:
            "The Core package revision is outside the supported range."
        case .profileRequired:
            "Select a profile before activating a different Core."
        case let .coreUnavailable(coreID):
            "Core \(coreID.rawValue) is not installed or is quarantined."
        case let .coreBlocked(coreID):
            "Core \(coreID.rawValue) is blocked by the verified Catalog."
        case let .rootStoreMissing(coreID):
            "Core \(coreID.rawValue) is not installed in the privileged Core Store."
        case .activeResolverMismatch:
            "The runtime Core selection changed during activation."
        case .controllerUnavailable:
            "The candidate Core did not expose its required Controller API."
        case .unexpectedExit:
            "The candidate Core exited unexpectedly during probation."
        case .probationRuntimeStopped:
            "Probation is waiting for the runtime to be started again."
        case .healthVerificationFailed:
            "The candidate Core failed a required runtime health check."
        case .rollbackFailed:
            "Neither the previous Known Good Core nor Factory Core could be restored."
        case .manualRollbackRequested:
            "The user requested a rollback from the candidate Core."
        case .interruptedActivationRecovery:
            "Vela is verifying rollback from an interrupted Core activation."
        case .manualRepairRequired:
            "A retained Core activation journal requires Repair & Verify Rollback before any other Core change."
        case .manualRepairJournalUnavailable:
            "The retained Core activation journal is missing or no longer matches."
        case .helperRoleMismatch:
            "The privileged component requested an invalid Core file set."
        case .privilegedStoreParityFailed:
            "The Core is installed for User mode, but privileged-store parity could not be established."
        case .privilegedCatalogPolicyUnavailable:
            "A compatible privileged component session is required to verify this Core for TUN."
        case .privilegedCatalogPolicyMismatch:
            "The privileged component returned a Core policy checkpoint that did not match the verified Catalog."
        case let .privilegedCatalogPolicySyncFailed(message):
            message
        case let .privilegedCoreValidationFailed(message):
            "The privileged Core could not be validated for TUN. \(message)"
        }
    }
}

nonisolated enum CoreLifecycleDiagnosticText {
    static func safe(_ error: any Error) -> String {
        DiagnosticTextSanitizer.redact(error.localizedDescription)
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds)
            + TimeInterval(parts.attoseconds) / 1_000_000_000_000_000_000
    }
}
