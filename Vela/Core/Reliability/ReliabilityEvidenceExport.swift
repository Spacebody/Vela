import Foundation

nonisolated struct ReliabilityKindCount: Codable, Equatable, Sendable {
    let kind: ReliabilityEventKind
    let count: Int
}

nonisolated struct ReliabilityResultCount: Codable, Equatable, Sendable {
    let resultCode: ReliabilityResultCode
    let count: Int
}

nonisolated struct ReliabilityDurationBucketCount: Codable, Equatable, Sendable {
    let durationBucket: ReliabilityDurationBucket
    let count: Int
}

nonisolated struct ReliabilityRollbackCount: Codable, Equatable, Sendable {
    let rollbackOutcome: ReliabilityRollbackOutcome
    let count: Int
}

nonisolated struct ReliabilityResourcePeaks: Codable, Equatable, Sendable {
    let residentMemoryMiB: Int?
    let openFileDescriptorCount: Int?
    let threadCount: Int?
    let activeTaskCount: Int?
    let socketCount: Int?
}

nonisolated struct ReliabilityPerformanceSummary: Codable, Equatable, Sendable {
    let kind: ReliabilityEventKind
    let sampleCount: Int
    let minimumDurationMilliseconds: Int
    let maximumDurationMilliseconds: Int
    let averageDurationMilliseconds: Int
}

nonisolated struct ReliabilityFailureExport: Codable, Equatable, Sendable {
    let occurredAt: Date
    let identity: ReliabilityBuildIdentity
    let kind: ReliabilityEventKind
    let phase: ReliabilityEventPhase
    let resultCode: ReliabilityResultCode
    let durationBucket: ReliabilityDurationBucket?
    let rollbackOutcome: ReliabilityRollbackOutcome?
    let crashSignatureSHA256: ReliabilitySHA256?
}

nonisolated struct ReliabilityEvidenceAggregate: Codable, Equatable, Sendable {
    let totalEventCount: Int
    let failureEventCount: Int
    let kindCounts: [ReliabilityKindCount]
    let resultCounts: [ReliabilityResultCount]
    let durationBucketCounts: [ReliabilityDurationBucketCount]
    let rollbackCounts: [ReliabilityRollbackCount]
    let resourcePeaks: ReliabilityResourcePeaks
}

/// A minimized DTO suitable for canonical JSON followed by the V0.7 redactor.
nonisolated struct ReliabilityEvidenceExport: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let generatedAt: Date
    let observedBuilds: [ReliabilityBuildIdentity]
    let aggregate: ReliabilityEvidenceAggregate
    let performanceSummaries: [ReliabilityPerformanceSummary]
    let recentFailures: [ReliabilityFailureExport]

    func canonicalJSONData() throws -> Data {
        try ReliabilityEvidenceCoding.encoder().encode(self)
    }

    func canonicalJSONString() throws -> String {
        String(decoding: try canonicalJSONData(), as: UTF8.self)
    }
}

nonisolated enum ReliabilityEvidenceExportBuilder {
    static let maximumFailureExportCount = 50

    static func make(
        events: [ReliabilityEvidence],
        generatedAt: Date,
        maximumRecentFailures: Int
    ) -> ReliabilityEvidenceExport {
        let failureLimit = min(max(0, maximumRecentFailures), maximumFailureExportCount)
        let failures = events
            .filter { $0.resultCode.isFailure }
            .sorted(by: newestFirst)
            .prefix(failureLimit)
            .map {
                ReliabilityFailureExport(
                    occurredAt: $0.occurredAt,
                    identity: $0.identity,
                    kind: $0.kind,
                    phase: $0.phase,
                    resultCode: $0.resultCode,
                    durationBucket: $0.durationBucket,
                    rollbackOutcome: $0.rollbackOutcome,
                    crashSignatureSHA256: $0.crashSignatureSHA256
                )
            }

        return ReliabilityEvidenceExport(
            schemaVersion: ReliabilityEvidenceExport.currentSchemaVersion,
            generatedAt: generatedAt,
            observedBuilds: observedBuilds(events),
            aggregate: aggregate(events),
            performanceSummaries: performanceSummaries(events),
            recentFailures: Array(failures)
        )
    }

    static func aggregate(_ events: [ReliabilityEvidence]) -> ReliabilityEvidenceAggregate {
        ReliabilityEvidenceAggregate(
            totalEventCount: events.count,
            failureEventCount: events.count(where: { $0.resultCode.isFailure }),
            kindCounts: counts(events.map(\.kind)).map {
                ReliabilityKindCount(kind: $0.key, count: $0.value)
            },
            resultCounts: counts(events.map(\.resultCode)).map {
                ReliabilityResultCount(resultCode: $0.key, count: $0.value)
            },
            durationBucketCounts: counts(events.compactMap(\.durationBucket)).map {
                ReliabilityDurationBucketCount(durationBucket: $0.key, count: $0.value)
            },
            rollbackCounts: counts(events.compactMap(\.rollbackOutcome)).map {
                ReliabilityRollbackCount(rollbackOutcome: $0.key, count: $0.value)
            },
            resourcePeaks: resourcePeaks(events)
        )
    }

    private static func observedBuilds(
        _ events: [ReliabilityEvidence]
    ) -> [ReliabilityBuildIdentity] {
        Array(Set(events.map(\.identity))).sorted {
            if $0.build != $1.build { return $0.build < $1.build }
            if $0.version.rawValue != $1.version.rawValue {
                return $0.version.rawValue < $1.version.rawValue
            }
            return $0.channel.rawValue < $1.channel.rawValue
        }
    }

    private static func performanceSummaries(
        _ events: [ReliabilityEvidence]
    ) -> [ReliabilityPerformanceSummary] {
        let grouped = Dictionary(grouping: events.compactMap { event in
            event.durationMilliseconds.map { (event.kind, $0) }
        }, by: \.0)
        return grouped.keys.sorted(by: { $0.rawValue < $1.rawValue }).compactMap { kind in
            let samples = grouped[kind, default: []].map(\.1)
            guard let minimum = samples.min(), let maximum = samples.max() else { return nil }
            let total = samples.reduce(into: Int64(0)) { $0 += Int64($1) }
            return ReliabilityPerformanceSummary(
                kind: kind,
                sampleCount: samples.count,
                minimumDurationMilliseconds: minimum,
                maximumDurationMilliseconds: maximum,
                averageDurationMilliseconds: Int(total / Int64(samples.count))
            )
        }
    }

    private static func resourcePeaks(
        _ events: [ReliabilityEvidence]
    ) -> ReliabilityResourcePeaks {
        let summaries = events.compactMap(\.resourceSummary)
        return ReliabilityResourcePeaks(
            residentMemoryMiB: summaries.compactMap(\.residentMemoryMiB).max(),
            openFileDescriptorCount: summaries.compactMap(\.openFileDescriptorCount).max(),
            threadCount: summaries.compactMap(\.threadCount).max(),
            activeTaskCount: summaries.compactMap(\.activeTaskCount).max(),
            socketCount: summaries.compactMap(\.socketCount).max()
        )
    }

    private static func counts<Value>(
        _ values: [Value]
    ) -> [(key: Value, value: Int)] where Value: Hashable & RawRepresentable,
        Value.RawValue == String {
        var result: [Value: Int] = [:]
        for value in values { result[value, default: 0] += 1 }
        return result.sorted { $0.key.rawValue < $1.key.rawValue }
    }

    private static func newestFirst(
        _ lhs: ReliabilityEvidence,
        _ rhs: ReliabilityEvidence
    ) -> Bool {
        if lhs.occurredAt != rhs.occurredAt { return lhs.occurredAt > rhs.occurredAt }
        return lhs.id.uuidString > rhs.id.uuidString
    }
}
