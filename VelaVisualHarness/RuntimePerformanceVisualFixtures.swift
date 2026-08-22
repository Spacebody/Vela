#if DEBUG
import Foundation
import SwiftUI

/// Explicit, fail-closed performance scenarios for Instruments capture.
///
/// These scenarios are intentionally unavailable to production and ordinary
/// Debug launches. They require both the visual-test contract and the
/// dedicated visual-test bundle identifier, so generated scale data can never
/// reach a user's profiles, Controller, helper, System Proxy, or TUN state.
nonisolated struct VisualRuntimePerformanceProfile: Equatable, Sendable {
    static let modeKey = "-VelaRuntimePerformanceMode"
    static let scaleKey = "-VelaPerformanceScale"
    static let scenarioKey = "-VelaPerformanceScenario"
    static let dedicatedBundleIdentifier = "dev.yilin.Vela.VisualTests"

    enum Scenario: String, Equatable, Sendable {
        case steady
        case churn
        case search
        case sort
        case inspector
        case validation
        case export
    }

    let scale: Int
    let scenario: Scenario

    static func resolve(
        configuration: VisualUITestConfiguration,
        arguments: [String] = ProcessInfo.processInfo.arguments,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> Self? {
        guard let mode = value(for: modeKey, arguments: arguments) else {
            return nil
        }
        precondition(
            mode.caseInsensitiveCompare("YES") == .orderedSame,
            "The runtime performance mode must be explicitly enabled with YES."
        )
        precondition(
            bundleIdentifier == dedicatedBundleIdentifier,
            "Runtime performance fixtures require the dedicated visual-test bundle."
        )
        precondition(
            configuration.usesProductionFeatureViews,
            "Runtime performance fixtures must render production feature views."
        )
        precondition(
            configuration.state == .loaded,
            "Runtime performance fixtures require the loaded visual state."
        )
        precondition(
            Self.supportedPages.contains(configuration.page),
            "The requested page has no registered runtime performance scenario."
        )

        let scaleValue = value(for: scaleKey, arguments: arguments) ?? "1"
        guard let scale = Int(scaleValue), (1...50_000).contains(scale) else {
            preconditionFailure("The runtime performance scale must be in 1...50000.")
        }
        let scenarioValue = value(for: scenarioKey, arguments: arguments) ?? Scenario.steady.rawValue
        guard let scenario = Scenario(rawValue: scenarioValue) else {
            preconditionFailure("The runtime performance scenario is not registered.")
        }
        return Self(scale: scale, scenario: scenario)
    }

    private static let supportedPages: Set<VisualUITestConfiguration.Page> = [
        .overview, .proxies, .connections, .rules, .logs, .workbench,
    ]

    private static func value(
        for key: String,
        arguments: [String]
    ) -> String? {
        guard let index = arguments.lastIndex(of: key) else { return nil }
        let valueIndex = arguments.index(after: index)
        guard valueIndex < arguments.endIndex else { return nil }
        return arguments[valueIndex]
    }
}

struct VisualRuntimePerformanceHost: View {
    let configuration: VisualUITestConfiguration
    let profile: VisualRuntimePerformanceProfile

    @ViewBuilder
    var body: some View {
        switch configuration.page {
        case .overview:
            RuntimePerformanceOverviewView(configuration: configuration, profile: profile)
        case .proxies:
            RuntimePerformanceProxiesView(configuration: configuration, profile: profile)
        case .connections:
            RuntimePerformanceConnectionsView(configuration: configuration, profile: profile)
        case .rules:
            RuntimePerformanceRulesView(configuration: configuration, profile: profile)
        case .logs:
            RuntimePerformanceLogsView(configuration: configuration, profile: profile)
        case .workbench:
            RuntimePerformanceWorkbenchView(configuration: configuration, profile: profile)
        case .providers, .diagnostics, .settings, .tunFlow, .menuBar,
             .updateCoreRecovery, .helpSupport:
            preconditionFailure("Unregistered runtime performance page.")
        }
    }
}

// MARK: - Overview

private struct RuntimePerformanceOverviewView: View {
    let configuration: VisualUITestConfiguration
    let profile: VisualRuntimePerformanceProfile
    @State private var tick = 0

    var body: some View {
        OverviewDashboardView(
            snapshot: snapshot,
            isRefreshing: false,
            action: { _ in }
        )
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                tick &+= 1
            }
        }
    }

    private var snapshot: OverviewSnapshot {
        let strings = OverviewStrings(locale: configuration.locale)
        let base = OverviewVisualFixtureFactory.highTraffic(
            strings: strings,
            now: configuration.fixedDate
        )
        let selectedIndex = (tick / 10) % max(1, base.node?.candidates.count ?? 1)
        let node = base.node.map { node in
            let candidates = node.candidates.enumerated().map { index, candidate in
                OverviewProxyNodeSnapshot(
                    id: candidate.id,
                    name: candidate.name,
                    selectionName: candidate.selectionName,
                    regionCode: candidate.regionCode,
                    latency: "\(35 + ((tick + index * 17) % 190)) ms",
                    isSelected: index == selectedIndex
                )
            }
            let selected = candidates[selectedIndex]
            return OverviewNodeSnapshot(
                name: selected.name,
                regionCode: selected.regionCode,
                latency: selected.latency,
                groupName: node.groupName,
                candidates: candidates
            )
        }
        let downloadRate = Int64(48_000_000 + (tick % 21) * 1_250_000)
        let uploadRate = Int64(8_000_000 + (tick % 13) * 640_000)
        let point = OverviewTrafficPoint(
            timestamp: configuration.fixedDate.addingTimeInterval(Double(tick) / 10),
            downloadBytesPerSecond: downloadRate,
            uploadBytesPerSecond: uploadRate,
            totalDownloadBytes: 80_000_000_000 + Int64(tick) * downloadRate / 10,
            totalUploadBytes: 20_000_000_000 + Int64(tick) * uploadRate / 10
        )
        var points = base.metrics.trafficPoints
        points.append(point)
        if points.count > OverviewTrafficHistory.maximumPointCount {
            points.removeFirst(points.count - OverviewTrafficHistory.maximumPointCount)
        }
        let download = ByteCountFormatter.string(
            fromByteCount: downloadRate,
            countStyle: .file
        ) + "/s"
        let upload = ByteCountFormatter.string(
            fromByteCount: uploadRate,
            countStyle: .file
        ) + "/s"
        let metrics = OverviewMetricStripSnapshot(
            download: download,
            upload: upload,
            activeConnections: "\(250 + tick % 80)",
            runtime: "02:\(String(format: "%02d", (tick / 600) % 60)):\(String(format: "%02d", (tick / 10) % 60))",
            trafficPoints: points
        )
        let core = OverviewConnectionCoreSnapshot(
            state: .connected,
            statusTitle: strings.connected,
            primaryValue: download,
            download: download,
            upload: upload,
            primaryAction: base.core.primaryAction
        )
        let route = OverviewRouteState(
            sourceTitle: base.route.sourceTitle,
            sourceDetail: base.route.sourceDetail,
            destinationTitle: node?.name ?? base.route.destinationTitle,
            destinationDetail: node?.groupName ?? base.route.destinationDetail,
            mode: base.route.mode,
            modeTitle: base.route.modeTitle,
            modeIsEnabled: base.route.modeIsEnabled,
            modeDisabledReason: base.route.modeDisabledReason,
            isSystemProxyEnabled: base.route.isSystemProxyEnabled,
            systemProxyToggleIsEnabled: base.route.systemProxyToggleIsEnabled,
            systemProxyDisabledReason: base.route.systemProxyDisabledReason,
            isTunEnabled: base.route.isTunEnabled,
            tunToggleIsEnabled: base.route.tunToggleIsEnabled,
            tunDisabledReason: base.route.tunDisabledReason,
            isAvailable: base.route.isAvailable
        )
        let preview = (0..<OverviewConnectionSnapshot.maximumPreviewCount).map { index in
            OverviewConnectionItemSnapshot(
                id: "overview.performance.\(index)",
                destination: "service-\((tick + index) % 32).example.invalid",
                process: ["Safari", "Xcode", "Mail", "Music", "Terminal"][index],
                proxy: node?.name,
                uploadBytes: Int64((tick + index + 1) * 16_384),
                downloadBytes: Int64((tick + index + 1) * 131_072)
            )
        }
        return OverviewSnapshot(
            state: .connected,
            configurationName: base.configurationName,
            node: node,
            proxyGroups: node.map { [$0] } ?? base.proxyGroups,
            core: core,
            route: route,
            metrics: metrics,
            connections: OverviewConnectionSnapshot(
                activeCount: 250 + tick % 80,
                uploadTotal: point.totalUploadBytes,
                downloadTotal: point.totalDownloadBytes,
                preview: preview
            ),
            recovery: nil
        )
    }
}

// MARK: - Proxies

private struct RuntimePerformanceProxySnapshots: Sendable {
    let first: ProxiesPresentationSnapshot
    let second: ProxiesPresentationSnapshot
    let firstGroupID: ProxiesGroupID
    let secondGroupID: ProxiesGroupID
}

private struct RuntimePerformanceProxiesView: View {
    let configuration: VisualUITestConfiguration
    let profile: VisualRuntimePerformanceProfile
    @State private var snapshots: RuntimePerformanceProxySnapshots?
    @State private var selectedGroupID: ProxiesGroupID?
    @State private var showsInspector = true
    @State private var phase = 0

    var body: some View {
        Group {
            if let snapshots {
                ProxiesLiquidGlassDashboardView(
                    snapshot: phase.isMultiple(of: 2) ? snapshots.first : snapshots.second,
                    runtimeMode: .rule,
                    isTrafficConnected: true,
                    selectedGroupID: $selectedGroupID,
                    showsInspector: $showsInspector,
                    action: { _ in }
                )
            } else {
                ProgressView("Preparing \(profile.scale) proxy candidates…")
            }
        }
        .task(id: profile) {
            let built = await Task.detached(priority: .userInitiated) {
                RuntimePerformanceDataFactory.proxySnapshots(
                    count: profile.scale,
                    referenceDate: configuration.fixedDate
                )
            }.value
            guard !Task.isCancelled else { return }
            snapshots = built
            selectedGroupID = built.firstGroupID
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(750))
                phase &+= 1
                selectedGroupID = phase.isMultiple(of: 2)
                    ? built.firstGroupID
                    : built.secondGroupID
            }
        }
    }
}

// MARK: - Connections

private enum RuntimePerformanceFixtureFailure: Error {
    case unavailable
}

private struct RuntimePerformanceConnectionsAPI: MihomoAPIProviding, Sendable {
    func version() async throws -> MihomoVersion { throw RuntimePerformanceFixtureFailure.unavailable }
    func configs() async throws -> MihomoConfigs { throw RuntimePerformanceFixtureFailure.unavailable }
    func patchConfigs(_ patch: MihomoConfigPatch) async throws { throw RuntimePerformanceFixtureFailure.unavailable }
    func proxies() async throws -> MihomoProxiesResponse { throw RuntimePerformanceFixtureFailure.unavailable }
    func connections() async throws -> ConnectionsSnapshot { throw RuntimePerformanceFixtureFailure.unavailable }
}

private struct RuntimePerformanceConnectionsStream: MihomoConnectionsStreaming, Sendable {
    func snapshots(
        generation: ConfigurationGeneration
    ) -> AsyncThrowingStream<ConnectionsStreamEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func stop() async {}
}

private struct RuntimePerformanceConnectionsView: View {
    let configuration: VisualUITestConfiguration
    let profile: VisualRuntimePerformanceProfile
    @State private var viewModel: ConnectionsViewModel

    init(
        configuration: VisualUITestConfiguration,
        profile: VisualRuntimePerformanceProfile
    ) {
        self.configuration = configuration
        self.profile = profile
        _viewModel = State(initialValue: ConnectionsViewModel(
            service: ConnectionsService(apiClient: RuntimePerformanceConnectionsAPI()),
            stream: RuntimePerformanceConnectionsStream(),
            now: { configuration.fixedDate },
            localeIdentifier: { configuration.localeIdentifier.rawValue }
        ))
    }

    var body: some View {
        ConnectionsView(viewModel: viewModel)
            .task(id: profile) {
                let pair = await Task.detached(priority: .userInitiated) {
                    (
                        RuntimePerformanceDataFactory.connectionsSnapshot(
                            count: profile.scale,
                            revision: 0
                        ),
                        RuntimePerformanceDataFactory.connectionsSnapshot(
                            count: profile.scale,
                            revision: 1
                        )
                    )
                }.value
                var revision = 0
                while !Task.isCancelled {
                    let snapshot = revision.isMultiple(of: 2) ? pair.0 : pair.1
                    await viewModel.installVisualFixture(
                        snapshot: snapshot,
                        phase: .loaded,
                        selectedConnectionID: profile.scenario == .inspector
                            ? snapshot.connections.first?.id : nil,
                        lastSuccessfulRefreshAt: configuration.fixedDate,
                        error: nil
                    )
                    switch profile.scenario {
                    case .search:
                        viewModel.searchText = revision.isMultiple(of: 2) ? "service-17" : ""
                    case .sort:
                        viewModel.sortField = revision.isMultiple(of: 2) ? .download : .started
                        viewModel.sortAscending.toggle()
                    case .inspector:
                        viewModel.selectedConnectionID = snapshot.connections[safe: revision % max(1, snapshot.connections.count)]?.id
                    case .steady, .churn, .validation, .export:
                        break
                    }
                    revision &+= 1
                    try? await Task.sleep(for: .milliseconds(profile.scenario == .churn ? 250 : 750))
                }
            }
    }
}

// MARK: - Rules

private struct RuntimePerformanceRulesAPI: MihomoAPIProviding, Sendable {
    func version() async throws -> MihomoVersion { throw RuntimePerformanceFixtureFailure.unavailable }
    func configs() async throws -> MihomoConfigs { throw RuntimePerformanceFixtureFailure.unavailable }
    func patchConfigs(_ patch: MihomoConfigPatch) async throws { throw RuntimePerformanceFixtureFailure.unavailable }
    func proxies() async throws -> MihomoProxiesResponse { throw RuntimePerformanceFixtureFailure.unavailable }
    func rules() async throws -> MihomoRulesResponse { throw RuntimePerformanceFixtureFailure.unavailable }
}

private struct RuntimePerformanceRulesView: View {
    let configuration: VisualUITestConfiguration
    let profile: VisualRuntimePerformanceProfile
    @State private var viewModel: RulesViewModel

    init(
        configuration: VisualUITestConfiguration,
        profile: VisualRuntimePerformanceProfile
    ) {
        self.configuration = configuration
        self.profile = profile
        let generation = ConfigurationGeneration(
            id: UUID(uuidString: "73E01F68-115B-4B36-807C-5BBE97A50001")!
        )
        _viewModel = State(initialValue: RulesViewModel(
            service: RulesService(
                apiClient: RuntimePerformanceRulesAPI(),
                generation: generation
            ),
            now: { configuration.fixedDate }
        ))
    }

    var body: some View {
        RulesView(viewModel: viewModel, runtimeAvailability: .available)
            .task(id: profile) {
                let rules = await Task.detached(priority: .userInitiated) {
                    RuntimePerformanceDataFactory.managedRules(count: profile.scale)
                }.value
                await viewModel.installVisualFixture(
                    rules: rules,
                    phase: .loaded,
                    selectedRuleID: profile.scenario == .inspector ? rules.first?.id : nil,
                    provenance: [:],
                    lastSuccessfulRefreshAt: configuration.fixedDate
                )
                var revision = 0
                while !Task.isCancelled {
                    switch profile.scenario {
                    case .search:
                        viewModel.searchText = revision.isMultiple(of: 2) ? "domain-177" : ""
                    case .sort:
                        viewModel.typeFilter = revision.isMultiple(of: 2) ? "DOMAIN-SUFFIX" : nil
                    case .inspector:
                        viewModel.selectedRuleID = rules[safe: revision % max(1, rules.count)]?.id
                    case .steady, .churn, .validation, .export:
                        break
                    }
                    revision &+= 1
                    try? await Task.sleep(for: .milliseconds(750))
                }
            }
    }
}

// MARK: - Logs

private struct RuntimePerformanceLogsView: View {
    let configuration: VisualUITestConfiguration
    let profile: VisualRuntimePerformanceProfile
    @State private var entries: [LogEntry]
    @State private var filter = LogsFilterSelection()
    @State private var selectedRowID: String?
    @State private var isInspectorPresented = false
    @State private var isExporting = false
    @FocusState private var isSearchFocused: Bool

    init(
        configuration: VisualUITestConfiguration,
        profile: VisualRuntimePerformanceProfile
    ) {
        self.configuration = configuration
        self.profile = profile
        _entries = State(initialValue: RuntimePerformanceDataFactory.logEntries(
            count: min(profile.scale, 2_000),
            referenceDate: configuration.fixedDate,
            firstSequence: 1
        ))
    }

    var body: some View {
        LogsWorkspaceView(
            snapshot: snapshot,
            filter: $filter,
            selectedRowID: $selectedRowID,
            isInspectorPresented: $isInspectorPresented,
            isExporting: isExporting,
            isSearchFocused: $isSearchFocused,
            onTogglePause: {},
            onRetry: {},
            onClear: { entries.removeAll(keepingCapacity: true) },
            onCopy: { _ in },
            onExport: { exportSnapshot() },
            onCancelExport: {}
        )
        .task(id: profile) {
            var sequence = UInt64(entries.count + 1)
            var revision = 0
            while !Task.isCancelled {
                let appended = RuntimePerformanceDataFactory.logEntries(
                    count: 24,
                    referenceDate: configuration.fixedDate.addingTimeInterval(Double(revision)),
                    firstSequence: sequence
                )
                sequence &+= UInt64(appended.count)
                entries.append(contentsOf: appended)
                if entries.count > 2_000 {
                    entries.removeFirst(entries.count - 2_000)
                }
                switch profile.scenario {
                case .search:
                    filter.query = revision.isMultiple(of: 2) ? "provider" : ""
                case .sort:
                    filter.levels = revision.isMultiple(of: 2) ? [.warning, .error] : []
                case .inspector:
                    isInspectorPresented = true
                    selectedRowID = snapshot.rows.last?.id
                case .export where revision.isMultiple(of: 10):
                    exportSnapshot()
                case .steady, .churn, .validation, .export:
                    break
                }
                revision &+= 1
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private var snapshot: LogsPresentationSnapshot {
        LogsPresentationSnapshot(
            entries: entries,
            filter: filter,
            controllerState: .connected,
            isRuntimeRunning: true,
            isLoading: false,
            isPaused: false,
            newCount: 0
        )
    }

    private func exportSnapshot() {
        guard !isExporting else { return }
        let captured = snapshot
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(
            "vela-runtime-performance-logs-\(ProcessInfo.processInfo.processIdentifier).jsonl"
        )
        isExporting = true
        Task {
            defer { isExporting = false }
            try? await LogJSONLExportWriter().write(
                snapshot: captured,
                to: destination,
                exportedAt: configuration.fixedDate
            )
        }
    }
}

// MARK: - Configuration Workbench

private struct RuntimePerformanceWorkbenchView: View {
    let configuration: VisualUITestConfiguration
    let profile: VisualRuntimePerformanceProfile
    @State private var yaml: String
    @State private var mode: ConfigurationWorkbenchMode = .editor
    @State private var validationRevision = 0

    init(
        configuration: VisualUITestConfiguration,
        profile: VisualRuntimePerformanceProfile
    ) {
        self.configuration = configuration
        self.profile = profile
        _yaml = State(initialValue: RuntimePerformanceDataFactory.largeYAML(
            ruleCount: profile.scale
        ))
    }

    var body: some View {
        ConfigurationLiquidGlassWorkbenchView(
            snapshot: ConfigurationWorkbenchSnapshot.fixture(
                activeProfileName: "Runtime Performance",
                profileOptions: [
                    ConfigurationWorkbenchProfileOption(
                        id: UUID(uuidString: "BE04FA7A-0D7F-47B6-A91A-111FCDBF0001")!,
                        name: "Runtime Performance"
                    ),
                ],
                preview: preview,
                status: ConfigurationWorkbenchStatus(
                    kind: preview.validation.issues.isEmpty ? .draft : .invalid,
                    changeCount: 1,
                    issueCount: preview.validation.issues.count
                ),
                isLoading: false,
                errorMessage: nil,
                mutationAllowed: true
            ),
            overrides: nil,
            mode: $mode,
            prefersInspector: profile.scenario == .inspector,
            identifierNamespace: "configuration.runtime-performance",
            action: { _ in }
        )
        .velaPageRoot()
        .task(id: profile) {
            while !Task.isCancelled {
                switch profile.scenario {
                case .validation:
                    validationRevision &+= 1
                case .search:
                    mode = mode == .editor ? .effective : .editor
                case .churn:
                    yaml.append("\n# edit-\(validationRevision)")
                    validationRevision &+= 1
                    if validationRevision.isMultiple(of: 20) {
                        yaml = RuntimePerformanceDataFactory.largeYAML(ruleCount: profile.scale)
                    }
                case .steady, .sort, .inspector, .export:
                    break
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    private var preview: ConfigurationPreview {
        let issues: [ConfigurationOverrideValidationIssue]
        if profile.scenario == .validation, !validationRevision.isMultiple(of: 2) {
            issues = [ConfigurationOverrideValidationIssue(
                severity: .error,
                code: .invalidEnhancedMode,
                path: "dns.enhanced-mode",
                message: "Enhanced mode must be fake-ip or redir-host."
            )]
        } else {
            issues = []
        }
        return ConfigurationPreview(
            rawYAML: yaml,
            finalYAML: yaml,
            semanticDiff: [],
            validation: ConfigurationOverrideValidationResult(issues: issues)
        )
    }
}

// MARK: - Deterministic scale data

nonisolated private enum RuntimePerformanceDataFactory {
    static func proxySnapshots(
        count: Int,
        referenceDate: Date
    ) -> RuntimePerformanceProxySnapshots {
        let names = (0..<count).map { "Performance Node \(String(format: "%05d", $0))" }
        var proxies: [String: Any] = [:]
        proxies.reserveCapacity(count + 2)
        for (index, name) in names.enumerated() {
            proxies[name] = [
                "name": name,
                "type": index.isMultiple(of: 2) ? "VLESS" : "Shadowsocks",
                "alive": true,
                "history": [[
                    "time": "2026-08-22T00:00:00Z",
                    "delay": 25 + (index % 320),
                ]],
            ]
        }
        let firstName = "Performance Auto"
        let secondName = "Performance Streaming"
        proxies[firstName] = [
            "name": firstName,
            "type": "Selector",
            "now": names.first ?? "DIRECT",
            "all": names,
            "history": [],
        ]
        proxies[secondName] = [
            "name": secondName,
            "type": "URLTest",
            "now": names.dropFirst().first ?? names.first ?? "DIRECT",
            "all": Array(names.reversed()),
            "history": [],
        ]
        guard
            let data = try? JSONSerialization.data(withJSONObject: ["proxies": proxies]),
            let response = try? JSONDecoder().decode(MihomoProxiesResponse.self, from: data)
        else {
            preconditionFailure("The performance proxy catalog must decode.")
        }
        let catalog = ProxyCatalog(
            runtimeResponse: response,
            providerResponse: .empty,
            updatedAt: referenceDate
        )
        let firstID = ProxiesGroupID(rawValue: firstName)
        let secondID = ProxiesGroupID(rawValue: secondName)
        let firstDelays = delayStates(in: catalog, offset: 0)
        let secondDelays = delayStates(in: catalog, offset: 47)
        return RuntimePerformanceProxySnapshots(
            first: ProxiesPresentationFactory.make(
                catalog: catalog,
                controllerState: .connected,
                isLoading: false,
                operation: nil,
                delayStates: firstDelays,
                selectedGroupID: firstID,
                errorSummary: nil,
                referenceDate: referenceDate,
                stateOverride: .loaded
            ),
            second: ProxiesPresentationFactory.make(
                catalog: catalog,
                controllerState: .connected,
                isLoading: false,
                operation: nil,
                delayStates: secondDelays,
                selectedGroupID: secondID,
                errorSummary: nil,
                referenceDate: referenceDate,
                stateOverride: .loaded
            ),
            firstGroupID: firstID,
            secondGroupID: secondID
        )
    }

    static func connectionsSnapshot(
        count: Int,
        revision: Int
    ) -> ConnectionsSnapshot {
        let rows: [[String: Any]] = (0..<count).map { index in
            [
                "id": "connection-\(revision)-\(index)",
                "metadata": [
                    "network": index.isMultiple(of: 4) ? "udp" : "tcp",
                    "type": index.isMultiple(of: 4) ? "QUIC" : "HTTPS",
                    "destinationIP": "198.51.\((index / 250) % 255).\(index % 250 + 1)",
                    "destinationPort": index.isMultiple(of: 4) ? 443 : 8443,
                    "host": "service-\(index % 257).example.invalid",
                    "process": ["Safari", "Xcode", "Mail", "Music", "Terminal"][index % 5],
                ],
                "upload": (index + revision + 1) * 4_096,
                "download": (count - index + revision) * 16_384,
                "start": "2026-08-22T00:\(String(format: "%02d", (index / 60) % 60)):\(String(format: "%02d", index % 60))Z",
                "chains": ["Performance Node \(index % 128)", "Auto"],
                "providerChains": ["Performance Provider"],
                "rule": ["DomainSuffix", "DomainKeyword", "GeoIP", "Match"][index % 4],
                "rulePayload": "service-\(index % 257)",
            ]
        }
        guard
            let data = try? JSONSerialization.data(withJSONObject: [
                "downloadTotal": count * 16_384,
                "uploadTotal": count * 4_096,
                "memory": 96 * 1_024 * 1_024,
                "connections": rows,
            ]),
            let snapshot = try? JSONDecoder().decode(ConnectionsSnapshot.self, from: data)
        else {
            preconditionFailure("The performance connection snapshot must decode.")
        }
        return snapshot
    }

    static func managedRules(count: Int) -> [ManagedRule] {
        let generation = ConfigurationGeneration(
            id: UUID(uuidString: "73E01F68-115B-4B36-807C-5BBE97A50001")!
        )
        let types = ["DOMAIN-SUFFIX", "DOMAIN-KEYWORD", "IP-CIDR", "GEOIP", "RULE-SET"]
        let policies = ["Auto", "DIRECT", "REJECT", "Streaming"]
        return (0..<count).map { index in
            ManagedRule(
                id: RuleID(configurationGeneration: generation, originalIndex: index),
                value: MihomoRule(
                    index: index,
                    type: types[index % types.count],
                    payload: "domain-\(index % 2_047).example.invalid",
                    proxy: policies[index % policies.count],
                    size: index % 31 + 1,
                    extra: nil
                )
            )
        }
    }

    static func logEntries(
        count: Int,
        referenceDate: Date,
        firstSequence: UInt64
    ) -> [LogEntry] {
        let sessionID = UUID(uuidString: "11B49399-0B45-4DAA-A41A-3F09EAFE0001")!
        let levels: [LogLevel] = [.debug, .info, .warning, .error]
        let sources: [LogSource] = [.application, .controller, .mihomoStdout, .mihomoStderr]
        return (0..<count).map { index in
            let sequence = firstSequence + UInt64(index)
            return LogEntry(
                id: UUID(),
                timestamp: referenceDate.addingTimeInterval(Double(index) / 100),
                level: levels[index % levels.count],
                source: sources[index % sources.count],
                message: "provider health sample \(sequence) completed for service-\(index % 257).example.invalid",
                eventIdentity: LogEventIdentity(
                    sessionID: sessionID,
                    source: sources[index % sources.count],
                    sequence: sequence
                ),
                eventCode: "runtime.performance.sample",
                redactionState: .verifiedRedacted
            )
        }
    }

    static func largeYAML(ruleCount: Int) -> String {
        var lines = [
            "mode: rule",
            "mixed-port: 7890",
            "allow-lan: false",
            "dns:",
            "  enable: true",
            "  enhanced-mode: fake-ip",
            "rules:",
        ]
        lines.reserveCapacity(ruleCount + 7)
        for index in 0..<ruleCount {
            lines.append("  - DOMAIN-SUFFIX,domain-\(index).example.invalid,Auto")
        }
        return lines.joined(separator: "\n")
    }

    private static func delayStates(
        in catalog: ProxyCatalog,
        offset: Int
    ) -> [ProxiesDelayKey: ProxyDelayState] {
        var result: [ProxiesDelayKey: ProxyDelayState] = [:]
        for group in catalog.groups {
            let groupID = ProxiesGroupID(rawValue: group.name)
            for (index, node) in group.nodes.enumerated() {
                result[ProxiesDelayKey(groupID: groupID, nodeID: node.id)] = .measured(
                    milliseconds: UInt16(25 + ((index + offset) % 320))
                )
            }
        }
        return result
    }
}

nonisolated private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
#endif
