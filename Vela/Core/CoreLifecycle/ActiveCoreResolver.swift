import Foundation
import VelaIPC

nonisolated struct ActiveCoreLifecycleMetadata: Equatable, Sendable {
    let activeCoreID: CoreID
    let previousKnownGoodCoreID: CoreID?
    let selectionMode: CoreSelectionMode
    let highestCatalogSequence: UInt64
    let trustRootSetVersion: Int
}

/// Single in-process source of truth for the Core selected by the lifecycle
/// transaction. The engine always resolves through this actor so validation,
/// config tests and process launch cannot accidentally fall back to a stale
/// executable captured at App startup.
actor ActiveCoreResolver: MihomoExecutableResolving {
    private let factoryResolver: any MihomoExecutableResolving
    private var selectedCoreID: CoreID = .factoryV11928
    private var selectedResolver: (any MihomoExecutableResolving)?
    private var previousKnownGoodCoreID: CoreID?
    private var selectionMode: CoreSelectionMode = .followRecommended
    private var highestCatalogSequence: UInt64 = 0
    private var trustRootSetVersion = VelaCoreCatalogTrustRoots.version

    init(factoryResolver: any MihomoExecutableResolving) {
        self.factoryResolver = factoryResolver
    }

    func coreID() -> CoreID {
        selectedCoreID
    }

    func lifecycleMetadata() -> ActiveCoreLifecycleMetadata {
        ActiveCoreLifecycleMetadata(
            activeCoreID: selectedCoreID,
            previousKnownGoodCoreID: previousKnownGoodCoreID,
            selectionMode: selectionMode,
            highestCatalogSequence: highestCatalogSequence,
            trustRootSetVersion: trustRootSetVersion
        )
    }

    func updateLifecycleMetadata(
        previousKnownGoodCoreID: CoreID?,
        selectionMode: CoreSelectionMode,
        highestCatalogSequence: UInt64,
        trustRootSetVersion: Int
    ) {
        self.previousKnownGoodCoreID = previousKnownGoodCoreID
        self.selectionMode = selectionMode
        self.highestCatalogSequence = highestCatalogSequence
        self.trustRootSetVersion = trustRootSetVersion
    }

    func selectFactory() {
        selectedCoreID = .factoryV11928
        selectedResolver = nil
    }

    func select(
        coreID: CoreID,
        resolver: any MihomoExecutableResolving
    ) throws {
        guard !coreID.isFactory else {
            selectFactory()
            return
        }
        selectedCoreID = coreID
        selectedResolver = resolver
    }

    func resolve() async throws -> ResolvedMihomoExecutable {
        if let selectedResolver {
            return try await selectedResolver.resolve()
        }
        return try await factoryResolver.resolve()
    }

    /// Resolves the immutable Factory Core without changing the currently
    /// selected lifecycle Core. Activation uses this for a pre-stop
    /// configuration test when the rollback target is Factory.
    func resolveFactory() async throws -> ResolvedMihomoExecutable {
        try await factoryResolver.resolve()
    }
}
