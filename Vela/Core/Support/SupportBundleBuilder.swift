import CryptoKit
import Foundation

nonisolated struct SupportBundleBuilder: Sendable {
    static let maximumArchiveBytes = 10 * 1_024 * 1_024
    static let maximumFiles = 100
    static let redactionVersion = 1

    private let baseDirectory: URL
    private let now: @Sendable () -> Date
    private let identifier: @Sendable () -> UUID
    private let redactor = SupportTextRedactor()
    private let scanner = SupportSecretScanner()

    init(
        baseDirectory: URL = FileManager.default.temporaryDirectory
            .appending(path: "VelaSupport", directoryHint: .isDirectory),
        now: @escaping @Sendable () -> Date = { .now },
        identifier: @escaping @Sendable () -> UUID = { UUID() }
    ) {
        self.baseDirectory = baseDirectory.standardizedFileURL
        self.now = now
        self.identifier = identifier
    }

    func prepare(
        snapshot: SupportBundleSnapshot,
        options: SupportBundleOptions = SupportBundleOptions(),
        progress: @escaping @Sendable (SupportBundlePreparationStage) async -> Void = { _ in }
    ) async throws -> SupportBundlePreview {
        let fileManager = FileManager.default
        try Task.checkCancellation()
        await progress(.collecting)
        // Reject oversized optional text before running every redaction regex
        // over it. Besides bounding memory, this keeps a deliberately large
        // support input from monopolizing the export task for minutes.
        var rawOptionalBytes = 0
        for text in [
            options.includeRecentAppLogs ? options.recentAppLogs : nil,
            options.includeCrashSummary ? options.crashSummary : nil,
            options.includeReliabilityEvidence ? options.reliabilityEvidence : nil,
        ].compactMap({ $0 }) {
            let byteCount = text.utf8.count
            guard byteCount <= Self.maximumArchiveBytes else {
                throw SupportBundleError.payloadTooLarge(byteCount)
            }
            rawOptionalBytes += byteCount
        }
        guard rawOptionalBytes <= Self.maximumArchiveBytes else {
            throw SupportBundleError.payloadTooLarge(rawOptionalBytes)
        }
        if (try? fileManager.destinationOfSymbolicLink(atPath: baseDirectory.path)) != nil {
            throw SupportBundleError.unsafeStagingDirectory
        }
        try fileManager.createDirectory(
            at: baseDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        let baseValues = try baseDirectory.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard baseValues.isDirectory == true, baseValues.isSymbolicLink != true else {
            throw SupportBundleError.unsafeStagingDirectory
        }
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: baseDirectory.path
        )
        let operationID = identifier()
        let staging = baseDirectory
            .appending(path: operationID.uuidString, directoryHint: .isDirectory)
            .standardizedFileURL
        guard Self.isStrictlyContained(staging, in: baseDirectory) else {
            throw SupportBundleError.unsafeStagingDirectory
        }

        do {
            try fileManager.createDirectory(
                at: staging,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: 0o700)],
                ofItemAtPath: staging.path
            )
            let values = try staging.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw SupportBundleError.unsafeStagingDirectory
            }

            await progress(.redacting)
            var entries = try payloadEntries(snapshot: snapshot, options: options)
            try Task.checkCancellation()
            guard entries.count + 1 <= Self.maximumFiles else {
                throw SupportBundleError.tooManyFiles(entries.count + 1)
            }
            let payloadBytes = entries.reduce(0) { $0 + $1.data.count }
            guard payloadBytes <= Self.maximumArchiveBytes else {
                throw SupportBundleError.payloadTooLarge(payloadBytes)
            }

            await progress(.validating)
            for entry in entries {
                try Task.checkCancellation()
                try validate(entry)
                try write(entry, to: staging)
            }

            let manifest = SupportBundleManifest(
                schemaVersion: 1,
                createdAt: now(),
                app: snapshot.app,
                redactionVersion: Self.redactionVersion,
                files: entries.map {
                    SupportBundleManifest.FileEntry(
                        path: $0.path,
                        size: $0.data.count,
                        sha256: Self.sha256($0.data)
                    )
                }
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let manifestData = try encoder.encode(manifest) + Data([0x0a])
            let manifestEntry = SupportZipEntry(path: "manifest.json", data: manifestData)
            try validate(manifestEntry)
            try write(manifestEntry, to: staging)
            entries.append(manifestEntry)

            try Task.checkCancellation()
            let archiveData = try SupportZipArchive.encode(entries)
            guard archiveData.count <= Self.maximumArchiveBytes else {
                throw SupportBundleError.archiveTooLarge(archiveData.count)
            }
            let archiveURL = staging.appending(path: "Vela-Support.velasupport")
            try archiveData.write(to: archiveURL, options: [.atomic])
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: archiveURL.path
            )
            try Task.checkCancellation()
            let preview = SupportBundlePreview(
                id: operationID,
                stagingDirectory: staging,
                archiveURL: archiveURL,
                manifest: manifest,
                archiveByteCount: archiveData.count,
                includedOptionalLogs: options.includeRecentAppLogs && options.recentAppLogs != nil,
                includedCrashSummary: options.includeCrashSummary && options.crashSummary != nil,
                includedReliabilityEvidence: options.includeReliabilityEvidence
                    && options.reliabilityEvidence != nil
            )
            await progress(.ready)
            return preview
        } catch is CancellationError {
            try? fileManager.removeItem(at: staging)
            throw CancellationError()
        } catch let error as SupportBundleError {
            try? fileManager.removeItem(at: staging)
            throw error
        } catch {
            try? fileManager.removeItem(at: staging)
            throw SupportBundleError.couldNotCreateBundle(
                DiagnosticTextSanitizer.redact(error.localizedDescription)
            )
        }
    }

    func save(_ preview: SupportBundlePreview, to requestedURL: URL) throws -> URL {
        let fileManager = FileManager.default
        let archive = preview.archiveURL.standardizedFileURL
        guard Self.isStrictlyContained(archive, in: preview.stagingDirectory.standardizedFileURL),
            fileManager.fileExists(atPath: archive.path),
            (try archive.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])).isRegularFile == true,
            (try archive.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])).isSymbolicLink != true
        else {
            throw SupportBundleError.archiveUnavailable
        }

        var destination = requestedURL.standardizedFileURL
        if destination.pathExtension.lowercased() != "velasupport" {
            destination.appendPathExtension("velasupport")
        }
        if (try? destination.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            throw SupportBundleError.destinationIsDirectory
        }
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: archive, to: destination)
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: destination.path
        )
        return destination
    }

    func cleanup(_ preview: SupportBundlePreview) {
        let fileManager = FileManager.default
        let staging = preview.stagingDirectory.standardizedFileURL
        guard Self.isStrictlyContained(staging, in: baseDirectory) else { return }
        try? fileManager.removeItem(at: staging)
    }

    private func payloadEntries(
        snapshot: SupportBundleSnapshot,
        options: SupportBundleOptions
    ) throws -> [SupportZipEntry] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

        let safeDiagnostics = snapshot.diagnostics.map {
            SupportCheckResult(
                id: Self.stableIdentifier($0.id),
                title: redactor.redact($0.title),
                detail: redactor.redact($0.detail),
                status: $0.status,
                stableCode: $0.stableCode.map(Self.stableIdentifier)
            )
        }
        let system = SupportBundleSystemSummary(
            macOSVersion: redactor.redact(snapshot.system.macOSVersion),
            architecture: Self.stableIdentifier(snapshot.system.architecture),
            locale: Self.stableIdentifier(snapshot.system.locale)
        )
        let lifecycle = SupportLifecyclePayload(
            appUpdateSummary: snapshot.appUpdateSummary.map(redactor.redact),
            coreUpdateSummary: snapshot.coreUpdateSummary.map(redactor.redact),
            stableErrorCodes: snapshot.stableErrorCodes.map(Self.stableIdentifier)
        )
        var entries = [
            SupportZipEntry(path: "system.json", data: try encoded(system, encoder: encoder)),
            SupportZipEntry(
                path: "diagnostics.json",
                data: try encoded(
                    SupportDiagnosticsPayload(
                        issueCategory: snapshot.issueCategory,
                        checks: safeDiagnostics
                    ),
                    encoder: encoder
                )
            ),
            SupportZipEntry(path: "lifecycle.json", data: try encoded(lifecycle, encoder: encoder)),
        ]
        if options.includeRecentAppLogs, let logs = options.recentAppLogs {
            entries.append(
                SupportZipEntry(
                    path: "optional/recent-app.log",
                    data: Data((redactor.redact(logs) + "\n").utf8)
                )
            )
        }
        if options.includeCrashSummary, let crash = options.crashSummary {
            entries.append(
                SupportZipEntry(
                    path: "optional/crash-summary.txt",
                    data: Data((redactor.redact(crash) + "\n").utf8)
                )
            )
        }
        if options.includeReliabilityEvidence, let evidence = options.reliabilityEvidence {
            entries.append(
                SupportZipEntry(
                    path: "optional/reliability-evidence.json",
                    data: Data((redactor.redact(evidence) + "\n").utf8)
                )
            )
        }
        return entries
    }

    private func encoded<T: Encodable>(_ value: T, encoder: JSONEncoder) throws -> Data {
        try encoder.encode(value) + Data([0x0a])
    }

    private func validate(_ entry: SupportZipEntry) throws {
        try SupportZipArchive.validate(path: entry.path)
        let findings = try scanner.scan(entry.data)
        guard findings.isEmpty else {
            throw SupportBundleError.sensitiveDataDetected(
                Array(Set(findings.map(\.kind))).sorted { $0.rawValue < $1.rawValue }
            )
        }
    }

    private func write(_ entry: SupportZipEntry, to staging: URL) throws {
        let fileManager = FileManager.default
        let destination = staging.appending(path: entry.path).standardizedFileURL
        guard Self.isStrictlyContained(destination, in: staging) else {
            throw SupportBundleError.invalidRelativePath(entry.path)
        }
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        try entry.data.write(to: destination, options: [.atomic])
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: destination.path
        )
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func stableIdentifier(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-+")
        return value.unicodeScalars.allSatisfy(allowed.contains) ? value : "redacted"
    }

    private static func isStrictlyContained(_ child: URL, in parent: URL) -> Bool {
        let childComponents = child.standardizedFileURL.pathComponents
        let parentComponents = parent.standardizedFileURL.pathComponents
        return childComponents.count > parentComponents.count
            && childComponents.prefix(parentComponents.count).elementsEqual(parentComponents)
    }
}

private nonisolated struct SupportDiagnosticsPayload: Codable, Sendable {
    let issueCategory: SupportIssueCategory
    let checks: [SupportCheckResult]
}

private nonisolated struct SupportLifecyclePayload: Codable, Sendable {
    let appUpdateSummary: String?
    let coreUpdateSummary: String?
    let stableErrorCodes: [String]
}
