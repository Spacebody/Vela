import Foundation
import Testing

@testable import Vela

@Suite("Logs presentation")
struct LogsPresentationTests {
    @Test("Mihomo log levels come from explicit markers instead of the output channel")
    func mihomoLogLevelClassificationUsesExplicitMarkers() {
        #expect(LogLevel(
            processMessage: "time=now level=error msg=failed",
            channel: .stderr
        ) == .error)
        #expect(LogLevel(
            processMessage: "time=now level=info msg=ready",
            channel: .stderr
        ) == .info)
        #expect(LogLevel(
            processMessage: "startup detail without a level marker",
            channel: .stderr
        ) == .unknown)
    }

    @Test("Large snapshots remain usable at one thousand and ten thousand events")
    func largeSnapshotsRemainUsable() {
        let entries = makeEntries(count: 10_000)

        let oneThousandStart = ContinuousClock.now
        let oneThousand = makeSnapshot(entries: Array(entries.prefix(1_000)))
        let oneThousandElapsed = ContinuousClock.now - oneThousandStart

        let tenThousandStart = ContinuousClock.now
        let tenThousand = makeSnapshot(entries: entries)
        let tenThousandElapsed = ContinuousClock.now - tenThousandStart

        #expect(oneThousand.totalCount == 1_000)
        #expect(oneThousand.visibleRows.count == 500)
        #expect(oneThousandElapsed < .milliseconds(250))
        #expect(tenThousand.totalCount == 10_000)
        #expect(tenThousand.visibleRows.count == 5_000)
        #expect(tenThousandElapsed < .seconds(1))
    }

    @Test("High frequency batches stay within an interactive presentation budget")
    func highFrequencyBatchesRemainInteractive() {
        let allEntries = makeEntries(count: 2_000)
        var accumulated: [LogEntry] = []
        accumulated.reserveCapacity(allEntries.count)

        let start = ContinuousClock.now
        for batchStart in stride(from: 0, to: allEntries.count, by: 20) {
            let batchEnd = min(batchStart + 20, allEntries.count)
            accumulated.append(contentsOf: allEntries[batchStart ..< batchEnd])
            _ = makeSnapshot(entries: accumulated)
        }
        let elapsed = ContinuousClock.now - start

        #expect(accumulated.count == LogBuffer.maximumCapacity)
        #expect(elapsed < .seconds(2))
    }

    @Test("The log buffer redacts secrets, preserves source identity, and clears the session")
    func logBufferStorageContract() async throws {
        let secret = "controller-token-123"
        let buffer = LogBuffer(
            capacity: 4,
            sessionID: UUID(uuidString: "A2C5E51A-6804-403F-B96D-994BBCDF01E1")!
        )
        await buffer.append(LogEntry(
            timestamp: Date(timeIntervalSince1970: 1_780_000_000),
            level: .warning,
            source: .controller,
            message: "request failed token=\(secret)",
            category: "controller.request"
        ))

        let stored = try #require(await buffer.entries().first)
        let firstSessionID = try #require(stored.eventIdentity?.sessionID)
        #expect(stored.source == .controller)
        #expect(stored.redactionState == .verifiedRedacted)
        #expect(!stored.message.contains(secret))

        await buffer.clear()
        #expect(await buffer.entries().isEmpty)

        await buffer.append(LogEntry(
            timestamp: Date(timeIntervalSince1970: 1_780_000_001),
            level: .info,
            source: .application,
            message: "ready",
            category: "application.lifecycle"
        ))
        let next = try #require(await buffer.entries().first)
        #expect(next.source == .application)
        #expect(next.eventIdentity?.sequence == 1)
        #expect(next.eventIdentity?.sessionID != firstSessionID)
    }

    @Test("JSONL export keeps source metadata and applies defense-in-depth redaction")
    func jsonlExportContract() async throws {
        let secret = "export-token-456"
        let sessionID = UUID(uuidString: "E50B665D-7F28-4663-B842-7A15D0B6EA4E")!
        let entry = LogEntry(
            timestamp: Date(timeIntervalSince1970: 1_780_000_000),
            level: .error,
            source: .controller,
            message: "download failed token=\(secret)",
            eventIdentity: LogEventIdentity(
                sessionID: sessionID,
                source: .controller,
                sequence: 7
            ),
            category: "subscription.download",
            eventCode: "subscription.failed"
        )
        let snapshot = LogsPresentationSnapshot(
            entries: [entry],
            filter: LogsFilterSelection(),
            controllerState: .connected,
            isRuntimeRunning: true
        )
        let destination = FileManager.default.temporaryDirectory
            .appending(path: "VelaLogsPresentationTests-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: destination) }

        try await LogJSONLExportWriter().write(
            snapshot: snapshot,
            to: destination,
            exportedAt: Date(timeIntervalSince1970: 1_780_000_100)
        )

        let lines = try String(contentsOf: destination, encoding: .utf8)
            .split(separator: "\n")
        #expect(lines.count == 2)
        let metadata = try #require(
            JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any]
        )
        let event = try #require(
            JSONSerialization.jsonObject(with: Data(lines[1].utf8)) as? [String: Any]
        )
        #expect(metadata["recordType"] as? String == "metadata")
        #expect(metadata["totalCount"] as? Int == 1)
        #expect(event["recordType"] as? String == "event")
        #expect(event["source"] as? String == LogSource.controller.rawValue)
        #expect(event["redactionState"] as? String == LogRedactionState.verifiedRedacted.rawValue)
        #expect(!(event["message"] as? String ?? "").contains(secret))
    }

    @Test("Responsive metrics preserve the message column and fold the inspector")
    func responsiveMetricsMatchWindowClasses() {
        let constrained = LogsLayoutMetrics.resolve(contentWidth: 1_119)
        let wide = LogsLayoutMetrics.resolve(contentWidth: 1_120)

        #expect(constrained.usesOverlayInspector)
        #expect(constrained.timeColumnWidth == 92)
        #expect(!wide.usesOverlayInspector)
        #expect(wide.inspectorWidth == 300)
        #expect(wide.timeColumnWidth == 120)
        #expect(wide.sourceColumnWidth == 140)
        #expect(wide.levelColumnWidth == 100)
    }

    private func makeSnapshot(entries: [LogEntry]) -> LogsPresentationSnapshot {
        LogsPresentationSnapshot(
            entries: entries,
            filter: LogsFilterSelection(query: "timeout"),
            controllerState: .connected,
            isRuntimeRunning: true
        )
    }

    private func makeEntries(count: Int) -> [LogEntry] {
        let sessionID = UUID(uuidString: "7F909C20-98AD-46E0-92DD-D19017783FE7")!
        let start = Date(timeIntervalSince1970: 1_780_000_000)
        return (0 ..< count).map { index in
            LogEntry(
                id: UUID(),
                timestamp: start.addingTimeInterval(Double(index) / 100),
                level: index.isMultiple(of: 11) ? .error : .info,
                source: index.isMultiple(of: 3) ? .application : .controller,
                message: index.isMultiple(of: 2)
                    ? "Request timeout while connecting to the controller"
                    : "Controller connection is healthy",
                eventIdentity: LogEventIdentity(
                    sessionID: sessionID,
                    source: index.isMultiple(of: 3) ? .application : .controller,
                    sequence: UInt64(index + 1)
                ),
                category: "performance.fixture",
                eventCode: "performance.event",
                redactionState: .verifiedRedacted
            )
        }
    }
}
