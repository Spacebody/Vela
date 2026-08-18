import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct LogsView: View {
    let engineStore: EngineStore

    @State private var filter = LogsFilterSelection()
    @State private var pauseSnapshot: LogsPauseSnapshot?
    @State private var selectedRowID: String?
    @State private var isInspectorPresented = false
    @State private var showsClearConfirmation = false
    @State private var exportTask: Task<Void, Never>?
    @State private var exportErrorMessage = ""
    @State private var showsExportError = false
    @FocusState private var isSearchFocused: Bool

    private var presentedEntries: [LogEntry] {
        pauseSnapshot?.entries ?? engineStore.logEntries
    }

    private var newCount: Int {
        pauseSnapshot?.newEntryCount(in: engineStore.logEntries) ?? 0
    }

    private var snapshot: LogsPresentationSnapshot {
        LogsPresentationSnapshot(
            entries: presentedEntries,
            filter: filter,
            controllerState: engineStore.controllerState,
            isRuntimeRunning: engineStore.isRunning,
            isPaused: pauseSnapshot != nil,
            newCount: newCount
        )
    }

    var body: some View {
        LogsWorkspaceView(
            snapshot: snapshot,
            filter: $filter,
            selectedRowID: $selectedRowID,
            isInspectorPresented: $isInspectorPresented,
            isExporting: exportTask != nil,
            isSearchFocused: $isSearchFocused,
            onTogglePause: togglePause,
            onRetry: { Task { await engineStore.refreshHealth() } },
            onClear: { showsClearConfirmation = true },
            onCopy: copy,
            onExport: export,
            onCancelExport: { exportTask?.cancel() }
        )
        .navigationTitle(VelaL10n.string("legacy.logs", defaultValue: "Logs"))
        .confirmationDialog(
            VelaL10n.string("legacy.clearAllLogsQuestion", defaultValue: "Clear all logs?"),
            isPresented: $showsClearConfirmation,
            titleVisibility: .visible
        ) {
            Button(VelaL10n.string("legacy.clearLogs", defaultValue: "Clear Logs"), role: .destructive) {
                pauseSnapshot = nil
                selectedRowID = nil
                Task { await engineStore.clearLogs() }
            }
            Button(VelaL10n.string("legacy.cancel", defaultValue: "Cancel"), role: .cancel) {}
        } message: {
            Text(VelaL10n.string(
                "legacy.thisRemovesTheInMemoryLogBufferThisActionCannotBeUndone",
                defaultValue: "This removes the in-memory log buffer. This action cannot be undone."
            ))
        }
        .alert(
            VelaL10n.string("legacy.couldnTExportLogs", defaultValue: "Couldn’t Export Logs"),
            isPresented: $showsExportError
        ) {
            Button(VelaL10n.string("legacy.ok", defaultValue: "OK"), role: .cancel) {}
        } message: {
            Text(exportErrorMessage)
        }
        .onChange(of: filter) { _, _ in
            clearInvalidSelection()
        }
        .onChange(of: snapshot.rows.first?.id) { _, _ in
            clearInvalidSelection()
        }
        .onReceive(NotificationCenter.default.publisher(for: .velaFocusSearch)) { _ in
            isSearchFocused = true
        }
        .onDisappear {
            exportTask?.cancel()
            exportTask = nil
        }
    }

    private func togglePause() {
        if pauseSnapshot == nil {
            pauseSnapshot = LogsPauseSnapshot(entries: engineStore.logEntries)
        } else {
            pauseSnapshot = nil
            let liveSnapshot = LogsPresentationSnapshot(
                entries: engineStore.logEntries,
                filter: filter,
                controllerState: engineStore.controllerState,
                isRuntimeRunning: engineStore.isRunning,
                isPaused: false,
                newCount: 0
            )
            selectedRowID = liveSnapshot.visibleRows.last?.id
        }
    }

    private func clearInvalidSelection() {
        guard let selectedRowID,
              !snapshot.visibleRows.contains(where: { $0.id == selectedRowID })
        else { return }
        self.selectedRowID = nil
    }

    private func copy(_ rows: [LogPresentationRow]) {
        let text = rows.map(\.copyableText).joined(separator: "\n")
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func export() {
        let snapshot = snapshot
        guard !snapshot.visibleRows.isEmpty else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Vela-Logs-Redacted.jsonl"
        panel.allowedContentTypes = [UTType(filenameExtension: "jsonl") ?? .json]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        let writer = LogJSONLExportWriter()
        exportTask = Task {
            defer { exportTask = nil }
            do {
                try await writer.write(snapshot: snapshot, to: destination)
            } catch is CancellationError {
                return
            } catch {
                exportErrorMessage = SensitiveTextRedactor(context: .error)
                    .redact(error.localizedDescription)
                showsExportError = true
            }
        }
    }
}

struct LogsWorkspaceView: View {
    @Environment(\.locale) private var locale
    let snapshot: LogsPresentationSnapshot
    @Binding var filter: LogsFilterSelection
    @Binding var selectedRowID: String?
    @Binding var isInspectorPresented: Bool
    let isExporting: Bool
    var isSearchFocused: FocusState<Bool>.Binding
    let onTogglePause: () -> Void
    let onRetry: () -> Void
    let onClear: () -> Void
    let onCopy: ([LogPresentationRow]) -> Void
    let onExport: () -> Void
    let onCancelExport: () -> Void

    @State private var density: LogsRowDensity = .comfortable
    @State private var showsMilliseconds = false
    @State private var autoScrollEnabled = true
    @State private var isNearBottom = true
    @State private var hoveredRowID: String?
    @State private var showsMoreActions = false
    @FocusState private var isListFocused: Bool

    var body: some View {
        GeometryReader { geometry in
            let metrics = LogsLayoutMetrics.resolve(contentWidth: geometry.size.width)
            workspace(metrics: metrics, size: geometry.size)
        }
        .velaPageRoot()
    }

    private func workspace(metrics: LogsLayoutMetrics, size: CGSize) -> some View {
        ZStack {
            VelaPageCanvas()

            VStack(alignment: .leading, spacing: VelaSpacing.medium) {
                pageHeader

                HStack(alignment: .top, spacing: VelaSpacing.medium) {
                    VStack(spacing: VelaSpacing.medium) {
                        summaryBar
                            .velaPanelSurface(radius: 16)

                        phaseBanner

                        filterBar(metrics: metrics)
                            .velaPanelSurface(radius: 16)

                        tableRegion(metrics: metrics)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .velaPanelSurface()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if isInspectorPresented, !metrics.usesOverlayInspector {
                        inspector
                            .frame(width: metrics.inspectorWidth)
                            .frame(maxHeight: .infinity, alignment: .topLeading)
                            .velaPanelSurface()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(VelaSpacing.standard)

            if isInspectorPresented, metrics.usesOverlayInspector {
                Color.black.opacity(0.08)
                    .contentShape(Rectangle())
                    .onTapGesture { isInspectorPresented = false }
                    .accessibilityHidden(true)

                inspector
                    .frame(width: metrics.inspectorWidth)
                    .frame(maxHeight: max(size.height - 104, 420), alignment: .topLeading)
                    .velaPanelSurface(emphasized: true)
                    .shadow(color: .black.opacity(0.16), radius: 24, y: 10)
                    .padding(.top, 88)
                    .padding(.trailing, VelaSpacing.standard)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
    }

    private var pageHeader: some View {
        HStack(alignment: .center, spacing: VelaSpacing.medium) {
            VStack(alignment: .leading, spacing: VelaSpacing.micro) {
                Text(VelaL10n.string("legacy.logs", defaultValue: "Logs"))
                    .font(VelaTypography.mainPageTitle)
                Text(locale.language.languageCode?.identifier == "zh"
                    ? "检查本地脱敏的运行时与应用事件。"
                    : "Inspect local, redacted runtime and application events.")
                .font(VelaTypography.pageSubtitle)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: VelaSpacing.large)

            Button {
                isInspectorPresented.toggle()
            } label: {
                Label(
                    isInspectorPresented
                        ? VelaL10n.string("logs.inspector.hide", defaultValue: "Hide Inspector")
                        : VelaL10n.string("logs.inspector.show", defaultValue: "Show Inspector"),
                    systemImage: "sidebar.trailing"
                )
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier(
                isInspectorPresented ? "logs.inspector.hide" : "logs.inspector.show"
            )
        }
    }

    private var summaryBar: some View {
        HStack(spacing: VelaSpacing.medium) {
            VelaStatusPill(status: phaseStatus, label: phaseLabel)
                .accessibilityIdentifier("logs.status")

            if let lastEventAt = snapshot.lastEventAt {
                Text(VelaL10n.string(
                    "logs.summary.lastEvent",
                    defaultValue: "Last event %@",
                    arguments: lastEventAt.formatted(date: .omitted, time: .standard)
                ))
                .font(VelaTypography.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }

            Text("·")
                .foregroundStyle(.tertiary)

            Text(VelaL10n.string(
                "logs.summary.total",
                defaultValue: "%lld events",
                arguments: snapshot.visibleRows.count
            ))
            .font(VelaTypography.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("logs.summary.count")

            Spacer(minLength: VelaSpacing.small)

            if snapshot.discardedCountLowerBound > 0 {
                Label(
                    VelaL10n.string(
                        "logs.summary.discarded",
                        defaultValue: "%lld older events discarded",
                        arguments: snapshot.discardedCountLowerBound
                    ),
                    systemImage: "exclamationmark.triangle"
                )
                .font(VelaTypography.caption)
                .foregroundStyle(.orange)
                .accessibilityIdentifier("logs.buffer.truncated")
            }

            Button(action: onTogglePause) {
                Label(
                    isPaused
                        ? VelaL10n.string("logs.action.resume", defaultValue: "Resume")
                        : VelaL10n.string("legacy.pause", defaultValue: "Pause"),
                    systemImage: isPaused ? "play.fill" : "pause.fill"
                )
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier(isPaused ? "logs.resume" : "logs.pause")
        }
        .padding(.horizontal, VelaSpacing.standard)
        .padding(.vertical, VelaSpacing.small)
    }

    @ViewBuilder
    private var phaseBanner: some View {
        switch snapshot.phase {
        case .loading:
            stateBanner(
                kind: .info,
                identifier: "logs.state.loading",
                title: VelaL10n.string("logs.state.loading.title", defaultValue: "Preparing Log Stream"),
                detail: VelaL10n.string("logs.state.loading.detail", defaultValue: "The table will remain in place while sources are prepared.")
            )
        case .reconnecting:
            stateBanner(
                kind: .recovery,
                identifier: "logs.state.reconnecting",
                title: VelaL10n.string("logs.state.reconnecting.title", defaultValue: "Reconnecting Log Sources"),
                detail: VelaL10n.string("logs.state.reconnecting.detail", defaultValue: "Buffered events remain available while the Controller reconnects.")
            )
        case let .paused(newCount):
            stateBanner(
                kind: .stale,
                identifier: "logs.state.paused",
                title: VelaL10n.string("logs.state.paused.title", defaultValue: "Live View Paused"),
                detail: VelaL10n.string(
                    "logs.state.paused.detail",
                    defaultValue: "%lld new events are buffered. Resume to catch up.",
                    arguments: newCount
                )
            )
        case .stale:
            stateBanner(
                kind: .stale,
                identifier: "logs.state.stale",
                title: VelaL10n.string("logs.state.stale.title", defaultValue: "Log Snapshot Is Stale"),
                detail: VelaL10n.string("logs.state.stale.detail", defaultValue: "Showing the last buffered events. New events are not arriving.")
            )
        case let .failureWithBuffer(message):
            stateBanner(
                kind: .warning,
                identifier: "logs.state.failureWithBuffer",
                title: VelaL10n.string("logs.state.failureWithBuffer.title", defaultValue: "Live Collection Interrupted"),
                detail: SensitiveTextRedactor(context: .error).redact(message),
                showsRetry: true
            )
        case .fullFailure:
            // The full-height empty state below is the single canonical error and retry surface.
            EmptyView()
        case .live, .empty:
            EmptyView()
        }
    }

    private func stateBanner(
        kind: VelaStateBannerKind,
        identifier: String,
        title: String,
        detail: String,
        showsRetry: Bool = false
    ) -> some View {
        VelaStateBanner(kind: kind, title: title, detail: detail) {
            if showsRetry {
                Button(VelaL10n.string("logs.action.retrySource", defaultValue: "Retry Source")) {
                    onRetry()
                }
                .accessibilityIdentifier("logs.retrySource")
            }
        }
        .padding(.horizontal, VelaSpacing.standard)
        .padding(.bottom, VelaSpacing.small)
        .accessibilityIdentifier(identifier)
    }

    private func filterBar(metrics: LogsLayoutMetrics) -> some View {
        HStack(spacing: VelaSpacing.small) {
            TextField(
                VelaL10n.string("legacy.searchLogMessages", defaultValue: "Search log messages"),
                text: $filter.query
            )
            .textFieldStyle(.roundedBorder)
            .focused(isSearchFocused)
            .frame(minWidth: metrics.searchMinimumWidth, maxWidth: metrics.searchMaximumWidth)
            .accessibilityIdentifier("logs.search")

            filterMenu(
                title: VelaL10n.string("logs.filter.levels", defaultValue: "Levels"),
                identifier: "levels",
                systemImage: "line.3.horizontal.decrease.circle",
                values: LogLevel.allCases,
                selection: $filter.levels,
                label: { $0.displayName }
            )
            filterMenu(
                title: VelaL10n.string("logs.filter.sources", defaultValue: "Sources"),
                identifier: "sources",
                systemImage: "square.stack.3d.up",
                values: LogSource.allCases,
                selection: $filter.sources,
                label: { $0.displayName }
            )

            Spacer(minLength: VelaSpacing.small)

            Button {
                showsMoreActions.toggle()
            } label: {
                Label(VelaL10n.string("legacy.more", defaultValue: "More"), systemImage: "ellipsis")
            }
            .buttonStyle(.borderless)
            .fixedSize()
            .accessibilityIdentifier("logs.more")
            .popover(isPresented: $showsMoreActions, arrowEdge: .bottom) {
                moreActionsPopover
            }
        }
        .controlSize(.regular)
        .padding(.horizontal, VelaSpacing.standard)
        .padding(.vertical, VelaSpacing.small)
    }

    private var moreActionsPopover: some View {
        VStack(alignment: .leading, spacing: VelaSpacing.small) {
            Button {
                onCopy(selectedRow.map { [$0] } ?? snapshot.visibleRows)
                showsMoreActions = false
            } label: {
                Label(
                    VelaL10n.string("legacy.copyRedactedLogs", defaultValue: "Copy Visible"),
                    systemImage: "doc.on.doc"
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(snapshot.visibleRows.isEmpty)
            .accessibilityIdentifier("logs.copyRedacted")

            Button {
                if isExporting { onCancelExport() }
                else { onExport() }
                showsMoreActions = false
            } label: {
                Label(
                    isExporting
                        ? VelaL10n.string("logs.action.cancelExport", defaultValue: "Cancel Export")
                        : VelaL10n.string("legacy.exportRedacted", defaultValue: "Export Redacted"),
                    systemImage: isExporting ? "xmark.circle" : "square.and.arrow.up"
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(snapshot.visibleRows.isEmpty && !isExporting)
            .accessibilityIdentifier(isExporting ? "logs.cancelExport" : "logs.exportRedacted")

            Button(role: .destructive) {
                onClear()
                showsMoreActions = false
            } label: {
                Label(
                    VelaL10n.string("legacy.clearLogs", defaultValue: "Clear Logs"),
                    systemImage: "trash"
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(snapshot.totalCount == 0)
            .accessibilityIdentifier("logs.clear")

            Divider()

            Picker(VelaL10n.string("logs.menu.density", defaultValue: "Density"), selection: $density) {
                ForEach(LogsRowDensity.allCases) { density in
                    Text(density.displayName).tag(density)
                }
            }
            .pickerStyle(.menu)

            Toggle(
                VelaL10n.string("logs.menu.autoScroll", defaultValue: "Auto Scroll"),
                isOn: $autoScrollEnabled
            )
            Toggle(
                VelaL10n.string("logs.menu.milliseconds", defaultValue: "Milliseconds"),
                isOn: $showsMilliseconds
            )
        }
        .controlSize(.regular)
        .padding(VelaSpacing.standard)
        .frame(width: 250)
    }

    private func filterMenu<Value: Hashable & CaseIterable>(
        title: String,
        identifier: String,
        systemImage: String,
        values: Value.AllCases,
        selection: Binding<Set<Value>>,
        label: @escaping (Value) -> String
    ) -> some View where Value.AllCases: RandomAccessCollection {
        Menu {
            ForEach(Array(values), id: \.self) { value in
                Toggle(label(value), isOn: Binding(
                    get: { selection.wrappedValue.contains(value) },
                    set: { enabled in
                        if enabled { selection.wrappedValue.insert(value) }
                        else { selection.wrappedValue.remove(value) }
                    }
                ))
            }
            Divider()
            Button(VelaL10n.string("legacy.selectAll", defaultValue: "Select All")) {
                selection.wrappedValue = Set(values)
            }
            Button(VelaL10n.string("legacy.selectNone", defaultValue: "Select None")) {
                selection.wrappedValue.removeAll()
            }
        } label: {
            Label(title, systemImage: systemImage)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityIdentifier("logs.filter.\(identifier)")
    }

    private func tableRegion(metrics: LogsLayoutMetrics) -> some View {
        VStack(spacing: 0) {
            tableHeader(metrics: metrics)
            Divider().opacity(0.45)

            ZStack {
                logList(metrics: metrics)
                    .opacity(snapshot.visibleRows.isEmpty ? 0.16 : 1)

                if snapshot.visibleRows.isEmpty {
                    emptyState
                        .padding(VelaSpacing.large)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider().opacity(0.45)
            tableFooter
        }
    }

    private func tableHeader(metrics: LogsLayoutMetrics) -> some View {
        HStack(spacing: VelaSpacing.standard) {
            columnHeader(VelaL10n.string("legacy.time", defaultValue: "Time"), width: metrics.timeColumnWidth)
            columnHeader(VelaL10n.string("legacy.source", defaultValue: "Source"), width: metrics.sourceColumnWidth)
            columnHeader(VelaL10n.string("legacy.level", defaultValue: "Level"), width: metrics.levelColumnWidth)
            Text(VelaL10n.string("legacy.message", defaultValue: "Message"))
                .font(VelaTypography.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, VelaSpacing.standard)
        .frame(height: 38)
        .background(Color.white.opacity(0.035))
    }

    private func columnHeader(_ title: String, width: CGFloat) -> some View {
        Text(title)
            .font(VelaTypography.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(width: width, alignment: .leading)
    }

    private func logList(metrics: LogsLayoutMetrics) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(snapshot.visibleRows) { row in
                        logRow(row, metrics: metrics)
                            .id(row.id)
                    }
                }
            }
            .scrollIndicators(.visible)
            .velaContainsNestedScrolling()
            .accessibilityIdentifier("logs.table")
            .focused($isListFocused)
            .onMoveCommand(perform: moveSelection)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height
                    >= geometry.contentSize.height - 48
            } action: { _, nearBottom in
                isNearBottom = nearBottom
            }
            .onChange(of: snapshot.visibleRows.last?.id) { _, lastID in
                guard autoScrollEnabled, isNearBottom, !isPaused, let lastID else { return }
                proxy.scrollTo(lastID, anchor: .bottom)
            }
            .onAppear {
                guard autoScrollEnabled, let lastID = snapshot.visibleRows.last?.id else { return }
                proxy.scrollTo(lastID, anchor: .bottom)
            }
        }
    }

    private func logRow(_ row: LogPresentationRow, metrics: LogsLayoutMetrics) -> some View {
        let isSelected = selectedRowID == row.id
        let isHovered = hoveredRowID == row.id

        return HStack(spacing: VelaSpacing.standard) {
            Text(timeText(row.timestamp, milliseconds: showsMilliseconds))
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: metrics.timeColumnWidth, alignment: .leading)

            Text(row.source.compactDisplayName)
                .font(VelaTypography.table)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: metrics.sourceColumnWidth, alignment: .leading)

            levelBadge(row.level)
                .frame(width: metrics.levelColumnWidth, alignment: .leading)

            messageCell(row)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, VelaSpacing.standard)
        .frame(height: density.rowHeight)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
            } else if isHovered {
                Color.primary.opacity(0.035)
            }
        }
        .overlay(alignment: .bottom) {
            Divider()
                .opacity(0.28)
                .padding(.leading, VelaSpacing.standard)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            selectedRowID = row.id
            isListFocused = true
        }
        .onHover { isHovering in
            hoveredRowID = isHovering ? row.id : nil
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(rowAccessibilityLabel(row))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("logs.row.\(row.id)")
        .contextMenu {
            Button(VelaL10n.string("legacy.copyEntry", defaultValue: "Copy Entry")) {
                onCopy([row])
            }
        }
    }

    private func levelBadge(_ level: LogLevel) -> some View {
        Text(level.displayName)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(level.badgeColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(level.badgeColor.opacity(0.11), in: Capsule())
            .fixedSize()
    }

    private var tableFooter: some View {
        HStack {
            Spacer()
            Text(VelaL10n.string(
                "logs.footer.count",
                defaultValue: "%lld events · %@",
                arguments: snapshot.visibleRows.count,
                phaseLabel
            ))
            .font(VelaTypography.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(height: 32)
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        guard !snapshot.visibleRows.isEmpty else { return }
        let currentIndex = selectedRowID.flatMap { id in
            snapshot.visibleRows.firstIndex { $0.id == id }
        }
        switch direction {
        case .down:
            let next = min((currentIndex ?? -1) + 1, snapshot.visibleRows.count - 1)
            selectedRowID = snapshot.visibleRows[next].id
        case .up:
            let next = max((currentIndex ?? snapshot.visibleRows.count) - 1, 0)
            selectedRowID = snapshot.visibleRows[next].id
        default:
            break
        }
    }

    private func timeText(_ date: Date, milliseconds: Bool) -> String {
        if milliseconds {
            return date.formatted(
                .dateTime.hour().minute().second().secondFraction(.fractional(3))
            )
        }
        return date.formatted(date: .omitted, time: .standard)
    }

    private func messageCell(_ row: LogPresentationRow) -> some View {
        Text(row.message)
            .font(.system(size: 13, weight: .regular, design: .monospaced))
            .lineLimit(1)
            .truncationMode(.tail)
            .help(row.message)
    }

    private func rowAccessibilityLabel(_ row: LogPresentationRow) -> String {
        [
            timeText(row.timestamp, milliseconds: true),
            row.level.displayName,
            row.source.displayName,
            row.eventCode,
            row.message,
        ]
        .compactMap { $0 }
        .joined(separator: ", ")
    }

    @ViewBuilder
    private var emptyState: some View {
        if snapshot.hasFilteredEmptyState {
            VelaEmptyState(
                title: VelaL10n.string("logs.empty.filtered.title", defaultValue: "No matching logs"),
                description: VelaL10n.string("logs.empty.filtered.description", defaultValue: "Adjust the level, source, or search filters."),
                systemImage: "line.3.horizontal.decrease.circle"
            ) {
                Button(VelaL10n.string("logs.action.clearFilters", defaultValue: "Clear Filters")) {
                    filter = LogsFilterSelection()
                }
                .accessibilityIdentifier("logs.clearFilters")
            }
            .accessibilityIdentifier("logs.empty.filtered")
        } else if case .fullFailure = snapshot.phase {
            VelaEmptyState(
                title: VelaL10n.string("logs.state.failure.title", defaultValue: "Logs Unavailable"),
                description: VelaL10n.string("logs.empty.failure.detail", defaultValue: "Retry the source or open Diagnostics for guided recovery."),
                systemImage: "exclamationmark.triangle"
            ) {
                Button(VelaL10n.string("logs.action.retrySource", defaultValue: "Retry Source"), action: onRetry)
                    .accessibilityIdentifier("logs.empty.retrySource")
            }
            .accessibilityIdentifier("logs.empty.failure")
        } else {
            VelaEmptyState(
                title: VelaL10n.string("logs.empty.none.title", defaultValue: "No logs yet"),
                description: VelaL10n.string("logs.empty.none.description", defaultValue: "Logs appear here when Mihomo or Vela emits an event."),
                systemImage: "text.alignleft"
            )
            .accessibilityIdentifier("logs.empty.session")
        }
    }

    private var inspector: some View {
        VStack(spacing: 0) {
            HStack {
                Text(VelaL10n.string("logs.inspector.title", defaultValue: "Event Details"))
                    .font(VelaTypography.sectionTitle)
                Spacer()
                Button {
                    isInspectorPresented = false
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(VelaL10n.string("logs.inspector.hide", defaultValue: "Hide Inspector"))
                .accessibilityIdentifier("logs.inspector.hide")
            }
            .padding(VelaSpacing.standard)

            Divider().opacity(0.45)

            if let row = selectedRow {
                ScrollView {
                    VStack(alignment: .leading, spacing: VelaSpacing.section) {
                        inspectorSection(VelaL10n.string("logs.inspector.event", defaultValue: "Event")) {
                            inspectorValue(VelaL10n.string("legacy.time", defaultValue: "Time"), row.timestamp.formatted(.iso8601))
                            inspectorValue(VelaL10n.string("legacy.source", defaultValue: "Source"), row.source.displayName)
                            HStack {
                                Text(VelaL10n.string("legacy.level", defaultValue: "Level"))
                                    .font(VelaTypography.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                levelBadge(row.level)
                            }
                            inspectorValue(
                                VelaL10n.string("logs.inspector.subsystem", defaultValue: "Subsystem"),
                                "—"
                            )
                            inspectorValue(VelaL10n.string("logs.column.category", defaultValue: "Category"), row.category)
                            inspectorValue(
                                VelaL10n.string("logs.inspector.eventCode", defaultValue: "Event Code"),
                                row.eventCode ?? "—"
                            )
                        }

                        inspectorSection(VelaL10n.string("logs.inspector.fullMessage", defaultValue: "Message")) {
                            Text(row.message)
                                .font(VelaTypography.code)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(VelaSpacing.medium)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
                        }

                        inspectorSection(VelaL10n.string("logs.inspector.metadata", defaultValue: "Metadata")) {
                            inspectorValue(VelaL10n.string("logs.inspector.pid", defaultValue: "PID"), "—")
                            inspectorValue(VelaL10n.string("logs.inspector.thread", defaultValue: "Thread"), "—")
                            inspectorValue(VelaL10n.string("logs.inspector.file", defaultValue: "File"), "—")
                            inspectorValue(VelaL10n.string("logs.inspector.function", defaultValue: "Function"), "—")
                            inspectorValue(
                                VelaL10n.string("logs.inspector.sequence", defaultValue: "Sequence"),
                                row.sequence.map(String.init) ?? "—"
                            )
                        }

                        Button {
                            onCopy([row])
                        } label: {
                            Label(VelaL10n.string("legacy.copyEntry", defaultValue: "Copy Entry"), systemImage: "doc.on.doc")
                        }
                        .accessibilityIdentifier("logs.inspector.copy")
                    }
                    .padding(VelaSpacing.standard)
                }
                .velaContainsNestedScrolling()
                .accessibilityIdentifier("logs.inspector")
            } else {
                VelaEmptyState(
                    title: VelaL10n.string("logs.inspector.noSelection.title", defaultValue: "No Event Selected"),
                    description: VelaL10n.string("logs.inspector.noSelection.detail", defaultValue: "Select a log row to inspect its redacted event metadata."),
                    systemImage: "sidebar.trailing"
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(VelaSpacing.large)
                .accessibilityIdentifier("logs.inspector.empty")
            }
        }
    }

    private func inspectorSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: VelaSpacing.small) {
            Text(title)
                .font(VelaTypography.sectionTitle)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func inspectorValue(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: VelaSpacing.small) {
            Text(label)
                .font(VelaTypography.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: VelaSpacing.medium)
            Text(value)
                .font(VelaTypography.caption.monospaced())
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, VelaSpacing.micro)
    }

    private var selectedRow: LogPresentationRow? {
        guard let selectedRowID else { return nil }
        return snapshot.visibleRows.first { $0.id == selectedRowID }
    }

    private var isPaused: Bool {
        if case .paused = snapshot.phase { return true }
        return false
    }

    private var phaseStatus: VelaSemanticStatus {
        switch snapshot.phase {
        case .live: .success
        case .loading, .reconnecting: .info
        case .paused, .stale: .stale
        case .failureWithBuffer: .warning
        case .fullFailure: .error
        case .empty: .neutral
        }
    }

    private var phaseLabel: String {
        switch snapshot.phase {
        case .live:
            VelaL10n.string("logs.status.live", defaultValue: "Live")
        case .loading:
            VelaL10n.string("logs.status.loading", defaultValue: "Loading")
        case .reconnecting:
            VelaL10n.string("logs.status.reconnecting", defaultValue: "Reconnecting")
        case .paused:
            VelaL10n.string("logs.status.paused", defaultValue: "Paused")
        case .stale:
            VelaL10n.string("logs.status.stale", defaultValue: "Stale")
        case .failureWithBuffer:
            VelaL10n.string("logs.status.interrupted", defaultValue: "Interrupted")
        case .fullFailure:
            VelaL10n.string("logs.status.unavailable", defaultValue: "Unavailable")
        case .empty:
            VelaL10n.string("logs.status.waiting", defaultValue: "Waiting")
        }
    }
}

nonisolated enum LogsRowDensity: String, CaseIterable, Identifiable, Sendable {
    case comfortable
    case compact

    var id: String { rawValue }

    var rowHeight: CGFloat {
        switch self {
        case .comfortable: 38
        case .compact: 30
        }
    }

    var displayName: String {
        switch self {
        case .comfortable:
            VelaL10n.string("logs.density.comfortable", defaultValue: "Comfortable")
        case .compact:
            VelaL10n.string("logs.density.compact", defaultValue: "Compact")
        }
    }
}

extension LogLevel {
    var displayName: String {
        switch self {
        case .debug: VelaL10n.string("logs.level.debug", defaultValue: "Debug")
        case .info: VelaL10n.string("logs.level.info", defaultValue: "Info")
        case .warning: VelaL10n.string("logs.level.warning", defaultValue: "Warning")
        case .error: VelaL10n.string("logs.level.error", defaultValue: "Error")
        case .silent: VelaL10n.string("logs.level.silent", defaultValue: "Silent")
        case .unknown: VelaL10n.string("logs.level.unknown", defaultValue: "Unknown")
        }
    }

    var color: Color {
        switch self {
        case .debug, .silent, .unknown: .secondary
        case .info: .primary
        case .warning: .orange
        case .error: .red
        }
    }

    var badgeColor: Color {
        switch self {
        case .debug: .purple
        case .info: .blue
        case .warning: .orange
        case .error: .red
        case .silent, .unknown: .secondary
        }
    }
}

extension LogSource {
    var displayName: String {
        switch self {
        case .mihomoStdout: VelaL10n.string("logs.source.mihomoStdout", defaultValue: "Mihomo stdout")
        case .mihomoStderr: VelaL10n.string("logs.source.mihomoStderr", defaultValue: "Mihomo stderr")
        case .controller: VelaL10n.string("logs.source.controller", defaultValue: "Controller")
        case .application: VelaL10n.string("logs.source.application", defaultValue: "Vela")
        }
    }

    var compactDisplayName: String {
        switch self {
        case .mihomoStdout, .mihomoStderr: "Mihomo"
        case .controller: VelaL10n.string("logs.source.controller", defaultValue: "Controller")
        case .application: "Vela"
        }
    }
}
