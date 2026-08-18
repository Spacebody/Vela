import Foundation

nonisolated enum SceneStoreError: Error, Equatable, Sendable {
    case storagePreparationFailed(path: String, reason: String)
    case documentReadFailed(path: String, reason: String)
    case documentTooLarge(actual: Int, maximum: Int)
    case documentDecodeFailed(path: String, reason: String)
    case unsupportedSchemaVersion(Int)
    case tooManyScenes(Int)
    case duplicateSceneID(UUID)
    case invalidScene(sceneID: UUID, error: SceneValidationError)
    case activeSceneNotFound(UUID)
    case invalidActiveSceneReference(UUID)
    case invalidEvaluationSummary
    case documentEncodeFailed(reason: String)
    case documentWriteFailed(path: String, reason: String)
    case sceneNotFound(UUID)
}

extension SceneStoreError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .storagePreparationFailed:
            "Vela could not prepare private storage for Scenes."
        case .documentReadFailed:
            "Vela could not read the saved Scenes."
        case .documentTooLarge:
            "The saved Scene document is larger than Vela supports."
        case .documentDecodeFailed:
            "The saved Scene document is damaged or uses an invalid format."
        case .unsupportedSchemaVersion:
            "The saved Scene document uses an unsupported data version."
        case .tooManyScenes:
            "The Scene limit has been reached. Remove a Scene before adding another."
        case .duplicateSceneID:
            "Two saved Scenes have the same identifier."
        case let .invalidScene(_, error):
            error.localizedDescription
        case .activeSceneNotFound:
            "The selected Scene no longer exists."
        case .invalidActiveSceneReference:
            "The saved active Scene reference is invalid."
        case .invalidEvaluationSummary:
            "The saved automatic Scene evaluation summary is invalid."
        case .documentEncodeFailed:
            "Vela could not prepare the Scene changes for saving."
        case .documentWriteFailed:
            "Vela could not save the Scene changes."
        case .sceneNotFound:
            "The requested Scene could not be found."
        }
    }
}

actor SceneStore {
    static let privateDirectoryPermissions = 0o700
    static let privateFilePermissions = 0o600
    static let defaultMaximumBytes = 1 * 1_024 * 1_024
    static let maximumSceneCount = 128

    nonisolated let documentURL: URL

    private let directories: ApplicationDirectories
    private let fileSystem: any FileSystemProviding
    private let now: @Sendable () -> Date
    private let maximumBytes: Int

    init(
        directories: ApplicationDirectories,
        fileSystem: any FileSystemProviding = LiveFileSystem(),
        now: @escaping @Sendable () -> Date = { .now },
        maximumBytes: Int = SceneStore.defaultMaximumBytes
    ) {
        self.directories = directories
        self.fileSystem = fileSystem
        self.now = now
        self.maximumBytes = max(1, maximumBytes)
        documentURL = directories.scenesDocument
    }

    func document() throws -> SceneStoreDocument {
        try Task<Never, Never>.checkCancellation()
        return try loadDocument()
    }

    /// Returns Scenes in deterministic UI order: priority, name, then opaque ID.
    func scenes() throws -> [VelaScene] {
        try document().scenes.sorted(by: Self.scenePrecedes)
    }

    @discardableResult
    func upsert(_ scene: VelaScene) throws -> VelaScene {
        try Task<Never, Never>.checkCancellation()
        var document = try loadDocument()

        let validated: VelaScene
        do {
            validated = try scene.validated()
        } catch let error as SceneValidationError {
            throw SceneStoreError.invalidScene(sceneID: scene.id, error: error)
        }

        let timestamp = now()
        var committed = validated
        if let index = document.scenes.firstIndex(where: { $0.id == validated.id }) {
            committed.createdAt = document.scenes[index].createdAt
            committed.updatedAt = max(timestamp, committed.createdAt)
            document.scenes[index] = committed
        } else {
            guard document.scenes.count < Self.maximumSceneCount else {
                throw SceneStoreError.tooManyScenes(document.scenes.count + 1)
            }
            committed.createdAt = timestamp
            committed.updatedAt = timestamp
            document.scenes.append(committed)
        }
        document.lastEvaluation = nil
        document.scenes.sort(by: Self.persistencePrecedes)
        try saveDocument(document)
        return committed
    }

    func remove(id: UUID) throws {
        try Task<Never, Never>.checkCancellation()
        var document = try loadDocument()
        guard let index = document.scenes.firstIndex(where: { $0.id == id }) else {
            throw SceneStoreError.sceneNotFound(id)
        }
        document.scenes.remove(at: index)
        if document.activeSceneID == id {
            document.activeSceneID = nil
            document.manualLockUntil = nil
        }
        // Any catalog mutation makes the prior evaluated count and decision
        // stale, even when the removed Scene was not the selected candidate.
        document.lastEvaluation = nil
        try saveDocument(document)
    }

    func setActiveScene(
        id: UUID?,
        manualLockUntil: Date? = nil,
        lastAutomaticSwitchAt: Date? = nil,
        evaluation: SceneEvaluationSummary? = nil
    ) throws {
        try Task<Never, Never>.checkCancellation()
        var document = try loadDocument()
        if let id, !document.scenes.contains(where: { $0.id == id }) {
            throw SceneStoreError.activeSceneNotFound(id)
        }
        try validate(evaluation: evaluation, scenes: document.scenes)
        document.activeSceneID = id
        document.manualLockUntil = id == nil ? nil : manualLockUntil
        document.lastAutomaticSwitchAt = lastAutomaticSwitchAt
        document.lastEvaluation = evaluation
        try saveDocument(document)
    }

    func setAutomaticScenesEnabled(_ enabled: Bool) throws {
        try Task<Never, Never>.checkCancellation()
        var document = try loadDocument()
        document.automaticScenesEnabled = enabled
        if enabled {
            // "Until disabled" locks are represented by a distant-future date.
            // Enabling Auto is an explicit user override and must release it.
            document.manualLockUntil = nil
        }
        try saveDocument(document)
    }

    func setManualRepairRequired(_ required: Bool, reason: String? = nil) throws {
        try Task<Never, Never>.checkCancellation()
        var document = try loadDocument()
        document.manualRepairRequired = required
        document.manualRepairReasonCode = required
            ? Self.redactedDiagnosticCode(reason)
            : nil
        if required {
            document.automaticScenesEnabled = false
        }
        try saveDocument(document)
    }

    private func prepareStorage() throws {
        do {
            try directories.prepare(fileSystem: fileSystem)
            try fileSystem.setPOSIXPermissions(
                Self.privateDirectoryPermissions,
                at: directories.scenes
            )
        } catch {
            throw SceneStoreError.storagePreparationFailed(
                path: directories.scenes.path,
                reason: String(describing: error)
            )
        }
    }

    private func loadDocument() throws -> SceneStoreDocument {
        try prepareStorage()
        guard fileSystem.fileExists(at: documentURL) else {
            return SceneStoreDocument()
        }

        let data: Data
        do {
            data = try fileSystem.readData(at: documentURL)
        } catch {
            throw SceneStoreError.documentReadFailed(
                path: documentURL.path,
                reason: String(describing: error)
            )
        }
        guard data.count <= maximumBytes else {
            throw SceneStoreError.documentTooLarge(actual: data.count, maximum: maximumBytes)
        }

        let document: SceneStoreDocument
        do {
            document = try Self.decoder().decode(SceneStoreDocument.self, from: data)
        } catch {
            throw SceneStoreError.documentDecodeFailed(
                path: documentURL.path,
                reason: String(describing: error)
            )
        }
        return try validated(document)
    }

    private func saveDocument(_ document: SceneStoreDocument) throws {
        let validatedDocument = try validated(document)
        let data: Data
        do {
            data = try Self.encoder().encode(validatedDocument)
        } catch {
            throw SceneStoreError.documentEncodeFailed(reason: String(describing: error))
        }
        guard data.count <= maximumBytes else {
            throw SceneStoreError.documentTooLarge(actual: data.count, maximum: maximumBytes)
        }

        try prepareStorage()
        try Task<Never, Never>.checkCancellation()
        do {
            try fileSystem.writeDataAtomically(data, to: documentURL)
            try fileSystem.setPOSIXPermissions(Self.privateFilePermissions, at: documentURL)
        } catch {
            throw SceneStoreError.documentWriteFailed(
                path: documentURL.path,
                reason: String(describing: error)
            )
        }
    }

    private func validated(_ document: SceneStoreDocument) throws -> SceneStoreDocument {
        guard document.schemaVersion == SceneStoreDocument.currentSchemaVersion else {
            throw SceneStoreError.unsupportedSchemaVersion(document.schemaVersion)
        }
        guard document.scenes.count <= Self.maximumSceneCount else {
            throw SceneStoreError.tooManyScenes(document.scenes.count)
        }

        var result = document
        var identifiers: Set<UUID> = []
        result.scenes = try document.scenes.map { scene in
            guard identifiers.insert(scene.id).inserted else {
                throw SceneStoreError.duplicateSceneID(scene.id)
            }
            do {
                return try scene.validated()
            } catch let error as SceneValidationError {
                throw SceneStoreError.invalidScene(sceneID: scene.id, error: error)
            }
        }
        if let activeSceneID = result.activeSceneID,
            !identifiers.contains(activeSceneID)
        {
            throw SceneStoreError.invalidActiveSceneReference(activeSceneID)
        }
        try validate(evaluation: result.lastEvaluation, scenes: result.scenes)
        result.scenes.sort(by: Self.persistencePrecedes)
        result.manualRepairReasonCode = result.manualRepairRequired
            ? Self.redactedDiagnosticCode(result.manualRepairReasonCode)
            : nil
        return result
    }

    private func validate(
        evaluation: SceneEvaluationSummary?,
        scenes: [VelaScene]
    ) throws {
        guard let evaluation else { return }
        let sceneIDs = Set(scenes.map(\.id))
        let allReferencedIDs = [
            evaluation.selectedSceneID,
            evaluation.recommendedSceneID,
        ].compactMap { $0 } + evaluation.matchingSceneIDs
        guard allReferencedIDs.allSatisfy(sceneIDs.contains),
            evaluation.evaluatedSceneCount >= 0,
            evaluation.evaluatedSceneCount <= scenes.count,
            Set(evaluation.matchingSceneIDs).count == evaluation.matchingSceneIDs.count
        else {
            throw SceneStoreError.invalidEvaluationSummary
        }
    }

    private nonisolated static func persistencePrecedes(
        _ lhs: VelaScene,
        _ rhs: VelaScene
    ) -> Bool {
        lhs.id.uuidString < rhs.id.uuidString
    }

    private nonisolated static func scenePrecedes(_ lhs: VelaScene, _ rhs: VelaScene) -> Bool {
        if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
        let nameComparison = lhs.name.localizedStandardCompare(rhs.name)
        if nameComparison != .orderedSame { return nameComparison == .orderedAscending }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private nonisolated static func redactedDiagnosticCode(_ reason: String?) -> String {
        guard let reason else { return "scene.repairRequired" }
        let candidate = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty, candidate.count <= 96,
            candidate.unicodeScalars.allSatisfy({ scalar in
                CharacterSet.alphanumerics.contains(scalar)
                    || scalar == "."
                    || scalar == "_"
                    || scalar == "-"
            })
        else {
            return "scene.repairRequired"
        }
        return candidate
    }

    private nonisolated static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private nonisolated static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
