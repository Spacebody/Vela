#if DEBUG
import Foundation
import VelaIPC

nonisolated enum OverviewVisualFixtureFactory {
    static func snapshot(for configuration: VisualUITestConfiguration) -> OverviewSnapshot {
        let strings = OverviewStrings(locale: configuration.locale)
        let now = configuration.fixedDate
        return switch configuration.state {
        case .loaded:
            connectedTokyo(strings: strings, now: now)
        case .loading, .transitioning:
            connecting(strings: strings, now: now)
        case .offline:
            disconnected(strings: strings, now: now)
        case .empty:
            noConfiguration(strings: strings, now: now)
        case .failure, .rollbackFailed, .permissionRequired:
            error(strings: strings, now: now)
        case .stale, .partialFailure:
            degraded(strings: strings, now: now)
        case .refreshing:
            highTraffic(strings: strings, now: now)
        case .pendingMutation:
            longNodeName(strings: strings, now: now)
        }
    }

    static func connectedTokyo(strings: OverviewStrings, now: Date) -> OverviewSnapshot {
        connectedSnapshot(
            strings: strings,
            now: now,
            nodeName: "Tokyo · JP",
            latency: "42 ms",
            download: "24.6 MB/s",
            upload: "3.2 MB/s",
            connections: "38",
            runtime: "01:24:38",
            sourceDetail: "192.168.1.42",
            destinationDetail: strings.text("Active", "活跃")
        )
    }

    static func connecting(strings: OverviewStrings, now: Date) -> OverviewSnapshot {
        let node = nodeSnapshot(strings: strings, selectedName: "Tokyo · Edge 01", latency: nil)
        return OverviewSnapshot(
            state: .connecting,
            configurationName: "Main",
            node: node,
            core: core(
                state: .connecting,
                strings: strings,
                primaryValue: strings.connecting,
                action: .start,
                enabled: false,
                disabledReason: strings.operationInProgress
            ),
            route: route(strings: strings, node: node, mode: .rule, available: false),
            metrics: metrics(now: now, download: "—", upload: "—", connections: "—", runtime: "—"),
            recovery: nil
        )
    }

    static func disconnected(strings: OverviewStrings, now: Date) -> OverviewSnapshot {
        let node = nodeSnapshot(strings: strings, selectedName: "Tokyo · Edge 01", latency: "42 ms")
        return OverviewSnapshot(
            state: .disconnected,
            configurationName: "Main",
            node: node,
            core: core(
                state: .disconnected,
                strings: strings,
                primaryValue: strings.start,
                action: .start
            ),
            route: route(strings: strings, node: node, mode: .rule, available: false),
            metrics: emptyMetrics,
            recovery: nil
        )
    }

    static func noConfiguration(strings: OverviewStrings, now _: Date) -> OverviewSnapshot {
        OverviewSnapshot(
            state: .noConfiguration,
            configurationName: nil,
            node: nil,
            core: core(
                state: .noConfiguration,
                strings: strings,
                primaryValue: strings.chooseConfiguration,
                action: .chooseConfiguration
            ),
            route: route(strings: strings, node: nil, mode: nil, available: false),
            metrics: emptyMetrics,
            recovery: OverviewRecoverySnapshot(
                title: strings.noConfigurationTitle,
                detail: strings.noConfigurationDetail,
                actionTitle: strings.chooseConfiguration,
                systemImage: "doc.badge.plus",
                action: .chooseConfiguration,
                isEnabled: true,
                disabledReason: nil
            )
        )
    }

    static func error(strings: OverviewStrings, now: Date) -> OverviewSnapshot {
        let node = nodeSnapshot(strings: strings, selectedName: "Tokyo · Edge 01", latency: nil)
        return OverviewSnapshot(
            state: .error,
            configurationName: "Main",
            node: node,
            core: core(
                state: .error,
                strings: strings,
                primaryValue: strings.error,
                action: .pause
            ),
            route: route(strings: strings, node: node, mode: .rule, available: false),
            metrics: metrics(now: now, download: "—", upload: "—", connections: "—", runtime: "2h 18m"),
            recovery: OverviewRecoverySnapshot(
                title: strings.controllerErrorTitle,
                detail: strings.controllerErrorDetail,
                actionTitle: strings.retry,
                systemImage: "network.slash",
                action: .retry,
                isEnabled: true,
                disabledReason: nil
            )
        )
    }

    static func longNodeName(strings: OverviewStrings, now: Date) -> OverviewSnapshot {
        connectedSnapshot(
            strings: strings,
            now: now,
            nodeName: strings.text(
                "Tokyo · Premium Streaming · Shinjuku Edge Relay 01",
                "东京 · 高级流媒体 · 新宿边缘中继节点 · 低延迟专线 01"
            ),
            latency: "86 ms",
            download: "18.9 MB/s",
            upload: "2.7 MB/s",
            connections: "5",
            runtime: "2h 18m"
        )
    }

    static func highTraffic(strings: OverviewStrings, now: Date) -> OverviewSnapshot {
        connectedSnapshot(
            strings: strings,
            now: now,
            nodeName: "Tokyo · Edge 01",
            latency: "38 ms",
            download: "986.4 MB/s",
            upload: "248.7 MB/s",
            connections: "999",
            runtime: "102h 48m",
            scale: 32
        )
    }

    private static func degraded(strings: OverviewStrings, now: Date) -> OverviewSnapshot {
        let healthy = connectedTokyo(strings: strings, now: now)
        return OverviewSnapshot(
            state: .degraded,
            configurationName: healthy.configurationName,
            node: healthy.node,
            core: core(
                state: .degraded,
                strings: strings,
                primaryValue: healthy.core.primaryValue,
                action: .pause
            ),
            route: healthy.route,
            metrics: healthy.metrics,
            recovery: OverviewRecoverySnapshot(
                title: strings.degradedTitle,
                detail: strings.degradedDetail,
                actionTitle: strings.openDiagnostics,
                systemImage: "exclamationmark.triangle",
                action: .openDiagnostics,
                isEnabled: true,
                disabledReason: nil
            )
        )
    }

    private static func connectedSnapshot(
        strings: OverviewStrings,
        now: Date,
        nodeName: String,
        latency: String,
        download: String,
        upload: String,
        connections: String,
        runtime: String,
        sourceDetail: String? = nil,
        destinationDetail: String? = nil,
        scale: Int64 = 1
    ) -> OverviewSnapshot {
        let node = nodeSnapshot(strings: strings, selectedName: nodeName, latency: latency)
        let manualGroup = OverviewNodeSnapshot(
            name: "Hong Kong · Manual 01",
            regionCode: "HK",
            latency: "76 ms",
            groupName: "Manual",
            candidates: [
                OverviewProxyNodeSnapshot(
                    id: "overview.manual.hk",
                    name: "Hong Kong · Manual 01",
                    latency: "76 ms",
                    isSelected: true
                ),
                OverviewProxyNodeSnapshot(
                    id: "overview.manual.jp",
                    name: "Tokyo · Manual 02",
                    latency: "91 ms",
                    isSelected: false
                ),
            ]
        )
        return OverviewSnapshot(
            state: .connected,
            configurationName: "Main",
            node: node,
            proxyGroups: [node, manualGroup],
            core: core(
                state: .connected,
                strings: strings,
                primaryValue: download,
                download: download,
                upload: upload,
                action: .pause
            ),
            route: route(
                strings: strings,
                node: node,
                mode: .rule,
                available: true,
                sourceDetail: sourceDetail,
                destinationDetail: destinationDetail
            ),
            metrics: metrics(
                now: now,
                download: download,
                upload: upload,
                connections: connections,
                runtime: runtime,
                scale: scale
            ),
            recovery: nil
        )
    }

    private static func core(
        state: OverviewConnectionState,
        strings: OverviewStrings,
        primaryValue: String,
        download: String = "—",
        upload: String = "—",
        action: OverviewPrimaryAction,
        enabled: Bool = true,
        disabledReason: String? = nil
    ) -> OverviewConnectionCoreSnapshot {
        OverviewConnectionCoreSnapshot(
            state: state,
            statusTitle: statusTitle(state, strings: strings),
            primaryValue: primaryValue,
            download: download,
            upload: upload,
            primaryAction: OverviewPrimaryActionDecision(
                action: action,
                isEnabled: enabled,
                disabledReason: disabledReason
            )
        )
    }

    private static func statusTitle(
        _ state: OverviewConnectionState,
        strings: OverviewStrings
    ) -> String {
        switch state {
        case .connected: strings.connected
        case .connecting: strings.connecting
        case .disconnected: strings.disconnected
        case .noConfiguration: strings.noConfiguration
        case .error: strings.error
        case .degraded: strings.degraded
        }
    }

    private static func nodeSnapshot(
        strings: OverviewStrings,
        selectedName: String,
        latency: String?
    ) -> OverviewNodeSnapshot {
        let names = [
            selectedName,
            "Singapore · Core 02",
            "Seattle · Edge 03",
            "Frankfurt · Work 01",
            "Hong Kong · Relay 02",
        ]
        return OverviewNodeSnapshot(
            name: selectedName,
            regionCode: strings.regionCode(for: selectedName),
            latency: latency,
            groupName: "Auto Select",
            candidates: names.enumerated().map { index, name in
                OverviewProxyNodeSnapshot(
                    id: "overview.node.\(index)",
                    name: name,
                    latency: index == 0 ? latency : "\(58 + index * 21) ms",
                    isSelected: index == 0
                )
            }
        )
    }

    private static func route(
        strings: OverviewStrings,
        node: OverviewNodeSnapshot?,
        mode: MihomoMode?,
        available: Bool,
        sourceDetail: String? = nil,
        destinationDetail: String? = nil
    ) -> OverviewRouteState {
        OverviewRouteState(
            sourceTitle: strings.thisMac,
            sourceDetail: sourceDetail ?? (available ? "TUN" : strings.routeUnavailable),
            destinationTitle: node?.name ?? strings.internet,
            destinationDetail: destinationDetail ?? node?.groupName ?? strings.routeUnavailable,
            mode: mode,
            modeTitle: mode.map(strings.modeTitle) ?? strings.unavailable,
            modeIsEnabled: available,
            modeDisabledReason: available ? nil : strings.modeUnavailable,
            isSystemProxyEnabled: false,
            systemProxyToggleIsEnabled: available,
            systemProxyDisabledReason: available ? nil : strings.controllerUnavailable,
            isTunEnabled: available,
            tunToggleIsEnabled: available,
            tunDisabledReason: available ? nil : strings.tunUnavailable,
            isAvailable: available
        )
    }

    private static var emptyMetrics: OverviewMetricStripSnapshot {
        return OverviewMetricStripSnapshot(
            download: "—",
            upload: "—",
            activeConnections: "—",
            runtime: "—",
            trafficPoints: []
        )
    }

    private static func metrics(
        now: Date,
        download: String,
        upload: String,
        connections: String,
        runtime: String,
        scale: Int64 = 1
    ) -> OverviewMetricStripSnapshot {
        let trafficPoints: [OverviewTrafficPoint] = (0 ..< 60).map { index in
            let downloadRate = 8_000_000 + Int64((index * 37) % 11) * 620_000
            let uploadRate = 1_700_000 + Int64((index * 19) % 7) * 280_000
            let totalDownload = 39_900_000_000 + Int64(index) * 8_000_000
            let totalUpload = 5_200_000_000 + Int64(index) * 1_700_000

            return OverviewTrafficPoint(
                timestamp: now.addingTimeInterval(TimeInterval(index - 59)),
                downloadBytesPerSecond: scale * downloadRate,
                uploadBytesPerSecond: scale * uploadRate,
                totalDownloadBytes: scale * totalDownload,
                totalUploadBytes: scale * totalUpload
            )
        }

        return OverviewMetricStripSnapshot(
            download: download,
            upload: upload,
            activeConnections: connections,
            runtime: runtime,
            trafficPoints: trafficPoints
        )
    }
}
#endif
