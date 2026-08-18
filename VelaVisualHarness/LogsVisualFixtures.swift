#if DEBUG
import SwiftUI

nonisolated enum LogsVisualFixtureFactory {
    private static let sessionID = UUID(uuidString: "7A1E7A10-2026-4719-9000-000000000001")!

    static func snapshot(
        configuration: VisualUITestConfiguration,
        filter: LogsFilterSelection? = nil
    ) -> LogsPresentationSnapshot {
        let state = configuration.state
        let entries: [LogEntry]
        let controllerState: ControllerConnectionState
        let isRunning: Bool
        let isLoading: Bool
        let isPaused: Bool
        let newCount: Int

        switch state {
        case .loading:
            entries = []
            controllerState = .connecting
            isRunning = true
            isLoading = true
            isPaused = false
            newCount = 0
        case .empty, .offline:
            entries = []
            controllerState = .disconnected
            isRunning = false
            isLoading = false
            isPaused = false
            newCount = 0
        case .refreshing:
            entries = fixtureEntries(configuration: configuration)
            controllerState = .connecting
            isRunning = true
            isLoading = false
            isPaused = false
            newCount = 0
        case .pendingMutation:
            entries = fixtureEntries(configuration: configuration)
            controllerState = .connected
            isRunning = true
            isLoading = false
            isPaused = true
            newCount = 7
        case .partialFailure:
            entries = fixtureEntries(configuration: configuration)
            controllerState = .unavailable(localized(
                configuration,
                english: "The Controller log stream closed unexpectedly.",
                chinese: "Controller 日志流意外关闭。"
            ))
            isRunning = true
            isLoading = false
            isPaused = false
            newCount = 0
        case .failure:
            entries = []
            controllerState = .unavailable(localized(
                configuration,
                english: "The Controller source is unavailable.",
                chinese: "Controller 来源不可用。"
            ))
            isRunning = true
            isLoading = false
            isPaused = false
            newCount = 0
        case .stale:
            entries = fixtureEntries(configuration: configuration)
            controllerState = .disconnected
            isRunning = false
            isLoading = false
            isPaused = false
            newCount = 0
        case .rollbackFailed:
            entries = fixtureEntries(configuration: configuration, firstSequence: 61)
            controllerState = .connected
            isRunning = true
            isLoading = false
            isPaused = false
            newCount = 0
        case .loaded, .permissionRequired, .transitioning:
            entries = fixtureEntries(configuration: configuration)
            controllerState = .connected
            isRunning = true
            isLoading = false
            isPaused = false
            newCount = 0
        }

        let resolvedFilter: LogsFilterSelection
        if let filter {
            resolvedFilter = filter
        } else if state == .transitioning {
            resolvedFilter = LogsFilterSelection(
                levels: [.error],
                sources: [.controller],
                query: "no-event-matches-this-query"
            )
        } else {
            resolvedFilter = LogsFilterSelection()
        }

        return LogsPresentationSnapshot(
            entries: entries,
            filter: resolvedFilter,
            controllerState: controllerState,
            isRuntimeRunning: isRunning,
            isLoading: isLoading,
            isPaused: isPaused,
            newCount: newCount
        )
    }

    static func fixtureEntries(
        configuration: VisualUITestConfiguration,
        firstSequence: UInt64 = 1
    ) -> [LogEntry] {
        let messages: [(LogLevel, LogSource, String, String?)] = [
            (.info, .application, localized(configuration, english: "Connected to Mihomo 1.19.28.", chinese: "已连接到 Mihomo 1.19.28。"), "controller.connected"),
            (.debug, .controller, "[TCP] route matched policy DIRECT", nil),
            (.info, .application, localized(configuration, english: "Runtime mode changed to rule.", chinese: "运行模式已切换为规则。"), "runtime.mode.changed"),
            (.warning, .mihomoStderr, localized(configuration, english: "DNS fallback is using the cached resolver result.", chinese: "DNS 回退正在使用缓存的解析结果。"), nil),
            (.info, .controller, "[UDP] tunnel established through Proxy", nil),
            (.debug, .mihomoStdout, "provider health check completed", nil),
            (.info, .application, localized(configuration, english: "Proxy group GLOBAL switched to Auto.", chinese: "代理组 GLOBAL 已切换到 Auto。"), "proxy.selection.changed"),
            (.error, .controller, localized(configuration, english: "Connection attempt timed out after 5 seconds.", chinese: "连接尝试在 5 秒后超时。"), nil),
            (.info, .controller, "[TCP] connection closed normally", nil),
            (.debug, .application, localized(configuration, english: "Health snapshot refreshed.", chinese: "健康快照已刷新。"), "application.event"),
            (.warning, .controller, localized(configuration, english: "Rule provider response used the previous verified generation.", chinese: "规则提供器响应使用了上一已验证代次。"), nil),
            (.info, .mihomoStdout, "configuration reload completed", nil),
        ]

        return messages.enumerated().map { index, value in
            LogEntry(
                id: deterministicUUID(index: index),
                timestamp: configuration.fixedDate.addingTimeInterval(Double(index - messages.count) * 3.25),
                level: value.0,
                source: value.1,
                message: value.2,
                eventIdentity: LogEventIdentity(
                    sessionID: sessionID,
                    source: value.1,
                    sequence: firstSequence + UInt64(index)
                ),
                eventCode: value.3,
                redactionState: .verifiedRedacted
            )
        }
    }

    private static func deterministicUUID(index: Int) -> UUID {
        UUID(uuidString: String(format: "7A1E7A10-2026-4719-9000-%012d", index + 1))!
    }

    private static func localized(
        _ configuration: VisualUITestConfiguration,
        english: String,
        chinese: String
    ) -> String {
        configuration.localeIdentifier == .simplifiedChinese ? chinese : english
    }
}

struct LogsVisualFixtureView: View {
    let configuration: VisualUITestConfiguration

    @State private var filter: LogsFilterSelection
    @State private var selectedRowID: String?
    @State private var isInspectorPresented: Bool
    @FocusState private var isSearchFocused: Bool

    init(configuration: VisualUITestConfiguration) {
        self.configuration = configuration
        let snapshot = LogsVisualFixtureFactory.snapshot(configuration: configuration)
        _filter = State(initialValue: snapshot.filter)
        _selectedRowID = State(initialValue: Self.initialSelection(
            configuration: configuration,
            snapshot: snapshot
        ))
        _isInspectorPresented = State(initialValue: configuration.inspector == .open)
    }

    var body: some View {
        let snapshot = LogsVisualFixtureFactory.snapshot(
            configuration: configuration,
            filter: filter
        )
        LogsWorkspaceView(
            snapshot: snapshot,
            filter: $filter,
            selectedRowID: $selectedRowID,
            isInspectorPresented: $isInspectorPresented,
            isExporting: false,
            isSearchFocused: $isSearchFocused,
            onTogglePause: {},
            onRetry: {},
            onClear: {},
            onCopy: { _ in },
            onExport: {},
            onCancelExport: {}
        )
        .environment(\.velaAccessibilityOverrides, accessibilityOverrides)
        .navigationTitle(localized(english: "Logs", chinese: "日志"))
        .overlay(alignment: .topLeading) {
            VisualReadyMarker(fixtureID: configuration.fixtureID)
            if accessibilityOverrides.reduceMotion == true {
                VisualSurfaceMarker(
                    identifier: "logs.accessibility.reduceMotion",
                    label: "Logs Reduce Motion"
                )
            }
            if accessibilityOverrides.increasedContrast == true {
                VisualSurfaceMarker(
                    identifier: "logs.accessibility.increasedContrast",
                    label: "Logs Increase Contrast"
                )
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .velaFocusSearch)) { _ in
            isSearchFocused = true
        }
    }

    private var accessibilityOverrides: VelaAccessibilityOverrides {
        VelaAccessibilityOverrides(
            reduceMotion: launchFlag("-VelaLogsReduceMotion"),
            increasedContrast: launchFlag("-VelaLogsIncreaseContrast")
        )
    }

    private func launchFlag(_ key: String) -> Bool? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.lastIndex(of: key) else { return nil }
        let valueIndex = arguments.index(after: index)
        guard valueIndex < arguments.endIndex else { return nil }
        return switch arguments[valueIndex].lowercased() {
        case "yes", "true", "1": true
        case "no", "false", "0": false
        default: nil
        }
    }

    private static func initialSelection(
        configuration: VisualUITestConfiguration,
        snapshot: LogsPresentationSnapshot
    ) -> String? {
        guard configuration.inspector == .open else { return nil }
        if configuration.state == .permissionRequired {
            return snapshot.rows.first { $0.level == .error }?.id
        }
        return snapshot.rows.last?.id
    }

    private func localized(english: String, chinese: String) -> String {
        configuration.localeIdentifier == .simplifiedChinese ? chinese : english
    }
}
#endif
