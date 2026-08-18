import Foundation
import VelaIPC

nonisolated struct OverviewBackendPresentation: Equatable, Sendable {
    let activeBackend: EngineBackendKind?
    let preferredBackend: EngineBackendKind
    let isTransitioning: Bool

    var primaryBackend: EngineBackendKind? { activeBackend }
}

nonisolated enum OverviewPrimaryAction: String, Equatable, Hashable, Sendable {
    case start
    case pause
    case chooseConfiguration
}

nonisolated struct OverviewPrimaryActionDecision: Equatable, Sendable {
    let action: OverviewPrimaryAction
    let isEnabled: Bool
    let disabledReason: String?

    static func resolve(
        isRunning: Bool,
        hasConfiguration: Bool,
        canStart: Bool,
        isBusy: Bool,
        busyReason: String,
        startUnavailableReason: String
    ) -> Self {
        if isRunning {
            return Self(
                action: .pause,
                isEnabled: !isBusy,
                disabledReason: isBusy ? busyReason : nil
            )
        }
        guard hasConfiguration else {
            return Self(action: .chooseConfiguration, isEnabled: true, disabledReason: nil)
        }
        return Self(
            action: .start,
            isEnabled: canStart,
            disabledReason: canStart ? nil : startUnavailableReason
        )
    }
}

nonisolated enum OverviewTunActionDecision: Equatable, Sendable {
    case showSetup
    case apply(Bool)

    static func resolve(
        requestedEnabled: Bool,
        privilegedComponentIsReady: Bool
    ) -> Self {
        if requestedEnabled, !privilegedComponentIsReady {
            return .showSetup
        }
        return .apply(requestedEnabled)
    }
}

nonisolated struct OverviewTrafficPoint: Equatable, Sendable {
    let timestamp: Date
    let downloadBytesPerSecond: Int64
    let uploadBytesPerSecond: Int64
    let totalDownloadBytes: Int64
    let totalUploadBytes: Int64
}

nonisolated struct OverviewTrafficHistory: Equatable, Sendable {
    static let maximumPointCount = 120
    static let retentionInterval: TimeInterval = 120

    private(set) var generation: String?
    private(set) var points: [OverviewTrafficPoint] = []

    mutating func beginGeneration(_ newGeneration: String) {
        guard generation != newGeneration else { return }
        generation = newGeneration
        points.removeAll(keepingCapacity: true)
    }

    mutating func record(_ point: OverviewTrafficPoint, generation incomingGeneration: String) {
        guard incomingGeneration == generation else { return }
        let cutoff = point.timestamp.addingTimeInterval(-Self.retentionInterval)
        points.removeAll { $0.timestamp < cutoff }
        if let last = points.indices.last, points[last].timestamp == point.timestamp {
            points[last] = point
        } else {
            points.append(point)
        }
        points.sort { $0.timestamp < $1.timestamp }
        if points.count > Self.maximumPointCount {
            points.removeFirst(points.count - Self.maximumPointCount)
        }
    }
}

/// The six product states defined by the approved Overview design pack.
nonisolated enum OverviewConnectionState: String, Equatable, Hashable, Sendable {
    case connected
    case connecting
    case disconnected
    case noConfiguration
    case error
    case degraded

    var isOperational: Bool { self == .connected || self == .degraded }
}

nonisolated struct OverviewProxyNodeSnapshot: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let selectionName: String
    let regionCode: String?
    let latency: String?
    let isSelected: Bool

    init(
        id: String,
        name: String,
        selectionName: String? = nil,
        regionCode: String? = nil,
        latency: String?,
        isSelected: Bool
    ) {
        self.id = id
        self.name = name
        self.selectionName = selectionName ?? name
        self.regionCode = regionCode
        self.latency = latency
        self.isSelected = isSelected
    }
}

nonisolated struct OverviewNodeSnapshot: Equatable, Sendable {
    let name: String
    let regionCode: String?
    let latency: String?
    let groupName: String
    let candidates: [OverviewProxyNodeSnapshot]
}

nonisolated struct OverviewConnectionCoreSnapshot: Equatable, Sendable {
    let state: OverviewConnectionState
    let statusTitle: String
    let primaryValue: String
    let download: String
    let upload: String
    let primaryAction: OverviewPrimaryActionDecision
}

nonisolated struct OverviewRouteState: Equatable, Sendable {
    let sourceTitle: String
    let sourceDetail: String
    let destinationTitle: String
    let destinationDetail: String
    let mode: MihomoMode?
    let modeTitle: String
    let modeIsEnabled: Bool
    let modeDisabledReason: String?
    let isSystemProxyEnabled: Bool
    let systemProxyToggleIsEnabled: Bool
    let systemProxyDisabledReason: String?
    let isTunEnabled: Bool
    let tunToggleIsEnabled: Bool
    let tunDisabledReason: String?
    let isAvailable: Bool
}

nonisolated struct OverviewMetricStripSnapshot: Equatable, Sendable {
    let download: String
    let upload: String
    let activeConnections: String
    let runtime: String
    let trafficPoints: [OverviewTrafficPoint]
}

nonisolated struct OverviewConnectionItemSnapshot: Identifiable, Equatable, Sendable {
    let id: String
    let destination: String
    let process: String?
    let proxy: String?
    let uploadBytes: Int64
    let downloadBytes: Int64
}

nonisolated struct OverviewConnectionSnapshot: Equatable, Sendable {
    static let maximumPreviewCount = 5
    static let empty = OverviewConnectionSnapshot(
        activeCount: 0,
        uploadTotal: 0,
        downloadTotal: 0,
        preview: []
    )

    let activeCount: Int
    let uploadTotal: Int64
    let downloadTotal: Int64
    let preview: [OverviewConnectionItemSnapshot]

    init(
        activeCount: Int,
        uploadTotal: Int64,
        downloadTotal: Int64,
        preview: [OverviewConnectionItemSnapshot]
    ) {
        self.activeCount = max(0, activeCount)
        self.uploadTotal = max(0, uploadTotal)
        self.downloadTotal = max(0, downloadTotal)
        self.preview = Array(preview.prefix(Self.maximumPreviewCount))
    }

    init(snapshot: ConnectionsSnapshot) {
        let rankedConnections = snapshot.connections.sorted { lhs, rhs in
            let lhsTraffic = max(0, lhs.upload) + max(0, lhs.download)
            let rhsTraffic = max(0, rhs.upload) + max(0, rhs.download)
            if lhsTraffic != rhsTraffic {
                return lhsTraffic > rhsTraffic
            }
            return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
        }

        self.init(
            activeCount: snapshot.connections.count,
            uploadTotal: snapshot.uploadTotal,
            downloadTotal: snapshot.downloadTotal,
            preview: rankedConnections.map { connection in
                OverviewConnectionItemSnapshot(
                    id: connection.id,
                    destination: connection.metadata.host
                        ?? connection.metadata.remoteDestination
                        ?? connection.metadata.destinationIP
                        ?? connection.id,
                    process: connection.metadata.process,
                    proxy: connection.chains.first,
                    uploadBytes: max(0, connection.upload),
                    downloadBytes: max(0, connection.download)
                )
            }
        )
    }
}

nonisolated enum OverviewRecoveryAction: String, Equatable, Hashable, Sendable {
    case chooseConfiguration
    case start
    case retry
    case openDiagnostics
}

nonisolated struct OverviewRecoverySnapshot: Equatable, Sendable {
    let title: String
    let detail: String
    let actionTitle: String
    let systemImage: String
    let action: OverviewRecoveryAction
    let isEnabled: Bool
    let disabledReason: String?
}

/// A single deterministic projection is the only input accepted by the visual hierarchy.
/// Production stores are flattened in `OverviewView`; Debug fixtures create this value directly.
nonisolated struct OverviewSnapshot: Equatable, Sendable {
    let state: OverviewConnectionState
    let configurationName: String?
    let node: OverviewNodeSnapshot?
    let proxyGroups: [OverviewNodeSnapshot]
    let core: OverviewConnectionCoreSnapshot
    let route: OverviewRouteState
    let metrics: OverviewMetricStripSnapshot
    let connections: OverviewConnectionSnapshot
    let recovery: OverviewRecoverySnapshot?

    init(
        state: OverviewConnectionState,
        configurationName: String?,
        node: OverviewNodeSnapshot?,
        proxyGroups: [OverviewNodeSnapshot] = [],
        core: OverviewConnectionCoreSnapshot,
        route: OverviewRouteState,
        metrics: OverviewMetricStripSnapshot,
        connections: OverviewConnectionSnapshot = .empty,
        recovery: OverviewRecoverySnapshot?
    ) {
        self.state = state
        self.configurationName = configurationName
        self.node = node
        self.proxyGroups = proxyGroups.isEmpty ? node.map { [$0] } ?? [] : proxyGroups
        self.core = core
        self.route = route
        self.metrics = metrics
        self.connections = connections
        self.recovery = recovery
    }
}
