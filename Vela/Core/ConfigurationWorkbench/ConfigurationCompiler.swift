import CryptoKit
import Foundation
import VelaIPC

nonisolated struct RuntimeForcedConfigurationValue: Equatable, Sendable {
    let path: YAMLPointer
    let value: YAMLValue
    let reasonCode: String

    init(path: YAMLPointer, value: YAMLValue, reasonCode: String) {
        self.path = path
        self.value = value
        self.reasonCode = reasonCode
    }
}

nonisolated struct ConfigurationCompilationContext: Equatable, Sendable {
    var profileID: UUID?
    var profileRevisionID: UUID?
    var layers: [ConfigurationLayer]
    var backend: ConfigurationBackendContext
    var runtimeForcedValues: [RuntimeForcedConfigurationValue]
    var generationID: UUID?

    init(
        profileID: UUID? = nil,
        profileRevisionID: UUID? = nil,
        layers: [ConfigurationLayer] = [],
        backend: ConfigurationBackendContext = ConfigurationBackendContext(),
        runtimeForcedValues: [RuntimeForcedConfigurationValue] = [],
        generationID: UUID? = nil
    ) {
        self.profileID = profileID
        self.profileRevisionID = profileRevisionID
        self.layers = layers
        self.backend = backend
        self.runtimeForcedValues = runtimeForcedValues
        self.generationID = generationID
    }
}

nonisolated struct CompiledConfiguration: Equatable, Sendable {
    let yaml: Data
    let sha256: String
    let semanticRoot: YAMLValue
    let provenance: ConfigurationProvenanceGraph
    let ruleIndexMap: EffectiveRuleIndexMap
    let diagnostics: [ConfigurationDiagnostic]
    let configurationGenerationID: UUID
}

nonisolated enum ConfigurationCompilerError: Error, Equatable, Sendable {
    case sourceIsNotUTF8
    case invalidYAML(YAMLDocumentError)
    case patch(PatchEngineError)
    case invalidRuntimeForcedPath(String)
    case ruleOriginMismatch(expected: Int, actual: Int)
    case outputLimitExceeded(maximumBytes: Int, actualBytes: Int)
    case deterministicEncodingFailed
}

extension ConfigurationCompilerError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .sourceIsNotUTF8:
            "The source configuration is not valid UTF-8."
        case let .invalidYAML(error):
            error.localizedDescription
        case let .patch(error):
            error.localizedDescription
        case let .invalidRuntimeForcedPath(path):
            "Runtime-forced configuration path is invalid: \(path)"
        case let .ruleOriginMismatch(expected, actual):
            "The rule source map has \(actual) origins for \(expected) effective rules."
        case let .outputLimitExceeded(maximumBytes, actualBytes):
            "Compiled configuration is \(actualBytes) bytes; the limit is \(maximumBytes) bytes."
        case .deterministicEncodingFailed:
            "The compiled configuration could not be deterministically encoded."
        }
    }
}

/// Pure, deterministic configuration compilation. Runtime validation remains
/// the responsibility of the existing transaction coordinator and Mihomo `-t`.
nonisolated struct ConfigurationCompiler: Sendable {
    let limits: ConfigurationCompilerLimits
    let protectedPathPolicy: ProtectedPathPolicy

    init(
        limits: ConfigurationCompilerLimits = .default,
        protectedPathPolicy: ProtectedPathPolicy = ProtectedPathPolicy()
    ) {
        self.limits = limits
        self.protectedPathPolicy = protectedPathPolicy
    }

    func compile(
        upstreamYAML: Data,
        context: ConfigurationCompilationContext = ConfigurationCompilationContext()
    ) throws -> CompiledConfiguration {
        guard upstreamYAML.count <= limits.maximumOutputBytes else {
            throw ConfigurationCompilerError.outputLimitExceeded(
                maximumBytes: limits.maximumOutputBytes,
                actualBytes: upstreamYAML.count
            )
        }
        guard let yaml = String(data: upstreamYAML, encoding: .utf8) else {
            throw ConfigurationCompilerError.sourceIsNotUTF8
        }
        return try compile(upstreamYAML: yaml, context: context)
    }

    func compile(
        upstreamYAML: String,
        context: ConfigurationCompilationContext = ConfigurationCompilationContext()
    ) throws -> CompiledConfiguration {
        try checkCancellation()
        let upstreamByteCount = upstreamYAML.lengthOfBytes(using: .utf8)
        guard upstreamByteCount <= limits.maximumOutputBytes else {
            throw ConfigurationCompilerError.outputLimitExceeded(
                maximumBytes: limits.maximumOutputBytes,
                actualBytes: upstreamByteCount
            )
        }
        let upstream: YAMLDocument
        do {
            upstream = try YAMLDocument(yaml: upstreamYAML)
        } catch let error as YAMLDocumentError {
            throw ConfigurationCompilerError.invalidYAML(error)
        }
        try checkCancellation()
        guard depth(of: .mapping(upstream.root)) <= limits.maximumDepth else {
            throw ConfigurationCompilerError.patch(.limitExceeded(
                layerID: nil,
                operationID: nil,
                reason: "upstream configuration exceeds nesting depth \(limits.maximumDepth)"
            ))
        }

        let patchResult: PatchEngineResult
        do {
            patchResult = try PatchEngine(
                limits: limits,
                protectedPathPolicy: protectedPathPolicy
            ).apply(
                root: .mapping(upstream.root),
                profileRevisionID: context.profileRevisionID,
                layers: context.layers,
                context: context.backend
            )
        } catch let error as PatchEngineError {
            throw ConfigurationCompilerError.patch(error)
        }

        try checkCancellation()
        guard case let .mapping(patchedMapping) = patchResult.root else {
            throw ConfigurationCompilerError.patch(.rootIsNotMapping)
        }
        var document = YAMLDocument(root: patchedMapping)
        var provenance = patchResult.provenance
        var diagnostics = patchResult.diagnostics

        let orderedForced = context.runtimeForcedValues.sorted { lhs, rhs in
            if lhs.path != rhs.path { return lhs.path < rhs.path }
            return lhs.reasonCode < rhs.reasonCode
        }
        var forcedPaths = Set<YAMLPointer>()
        for forced in orderedForced {
            try checkCancellation()
            guard forcedPaths.insert(forced.path).inserted else {
                throw ConfigurationCompilerError.invalidRuntimeForcedPath(
                    "duplicate path \(forced.path.rawValue)"
                )
            }
            guard !forced.path.isRoot,
                forced.path.components.count <= limits.maximumDepth,
                forced.path.rawValue.utf8.count <= limits.maximumPointerBytes,
                forced.path.components.first != "rules"
            else {
                throw ConfigurationCompilerError.invalidRuntimeForcedPath(forced.path.rawValue)
            }
            guard depth(of: forced.value) <= limits.maximumDepth,
                let forcedData = try? canonicalData(forced.value),
                forcedData.count <= limits.maximumValueBytes
            else {
                throw ConfigurationCompilerError.invalidRuntimeForcedPath(forced.path.rawValue)
            }

            let beforeRoot = YAMLValue.mapping(document.root)
            let beforeValues = pathValues(below: forced.path, in: beforeRoot)
            do {
                try document.setValue(forced.value, at: forced.path.components)
            } catch let error as YAMLDocumentError {
                throw ConfigurationCompilerError.invalidYAML(error)
            }
            let afterRoot = YAMLValue.mapping(document.root)
            guard depth(of: afterRoot) <= limits.maximumDepth else {
                throw ConfigurationCompilerError.invalidRuntimeForcedPath(forced.path.rawValue)
            }

            let source = SourceReference.runtimeForced(forced.reasonCode)
            let afterValues = pathValues(below: forced.path, in: afterRoot)
            diagnostics.append(contentsOf: try applyRuntimeForcedProvenance(
                to: &provenance,
                beforeValues: beforeValues,
                afterValues: afterValues,
                path: forced.path,
                source: source
            ))
            try checkCancellation()
        }

        try checkCancellation()
        let serialized: String
        do {
            serialized = try document.serialized()
        } catch let error as YAMLDocumentError {
            throw ConfigurationCompilerError.invalidYAML(error)
        }
        try checkCancellation()
        guard let data = serialized.data(using: .utf8) else {
            throw ConfigurationCompilerError.deterministicEncodingFailed
        }
        guard data.count <= limits.maximumOutputBytes else {
            throw ConfigurationCompilerError.outputLimitExceeded(
                maximumBytes: limits.maximumOutputBytes,
                actualBytes: data.count
            )
        }

        let hash = Self.sha256(data)
        try checkCancellation()
        let generationID = context.generationID ?? Self.deterministicUUID(fromSHA256: hash)
        let semanticRoot = YAMLValue.mapping(document.root)
        let ruleIndexMap = try makeRuleIndexMap(
            root: semanticRoot,
            generationID: generationID,
            origins: patchResult.ruleOrigins
        )
        return CompiledConfiguration(
            yaml: data,
            sha256: hash,
            semanticRoot: semanticRoot,
            provenance: provenance,
            ruleIndexMap: ruleIndexMap,
            diagnostics: diagnostics,
            configurationGenerationID: generationID
        )
    }

    /// Async entry for UI/preview callers. The synchronous compiler remains
    /// available to existing non-main actors such as ProfileStore.
    func compileOffMain(
        upstreamYAML: Data,
        context: ConfigurationCompilationContext = ConfigurationCompilationContext()
    ) async throws -> CompiledConfiguration {
        let work = Task.detached(priority: nil) {
            try compile(upstreamYAML: upstreamYAML, context: context)
        }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }

    private func makeRuleIndexMap(
        root: YAMLValue,
        generationID: UUID,
        origins: [RuleOrigin]
    ) throws -> EffectiveRuleIndexMap {
        guard case let .mapping(mapping) = root,
            case let .sequence(rules)? = mapping["rules"]
        else {
            return EffectiveRuleIndexMap(entries: [])
        }
        guard rules.count == origins.count else {
            throw ConfigurationCompilerError.ruleOriginMismatch(
                expected: rules.count,
                actual: origins.count
            )
        }
        var entries: [EffectiveRuleOrigin] = []
        entries.reserveCapacity(rules.count)
        for (index, rule) in rules.enumerated() {
            if index.isMultiple(of: 256) { try checkCancellation() }
            entries.append(EffectiveRuleOrigin(
                runtimeIndex: index,
                ruleFingerprint: try fingerprint(rule),
                origin: origins[index],
                configurationGenerationID: generationID
            ))
        }
        return EffectiveRuleIndexMap(entries: entries)
    }

    private func pathValues(
        below pointer: YAMLPointer,
        in root: YAMLValue
    ) -> [YAMLPointer: YAMLValue] {
        var values: [YAMLPointer: YAMLValue] = [:]
        if let subtree = value(at: pointer, in: root) {
            recordPathValues(subtree, at: pointer, into: &values)
        }
        if pointer.components.count > 1 {
            for count in 1..<pointer.components.count {
                let ancestor = YAMLPointer(
                    components: Array(pointer.components.prefix(count))
                )
                if let value = value(at: ancestor, in: root) {
                    values[ancestor] = value
                }
            }
        }
        return values
    }

    private func value(
        at pointer: YAMLPointer,
        in root: YAMLValue
    ) -> YAMLValue? {
        var current = root
        for component in pointer.components {
            guard case let .mapping(mapping) = current,
                let next = mapping[component]
            else {
                return nil
            }
            current = next
        }
        return current
    }

    private func recordPathValues(
        _ value: YAMLValue,
        at pointer: YAMLPointer,
        into values: inout [YAMLPointer: YAMLValue]
    ) {
        values[pointer] = value
        guard case let .mapping(mapping) = value else { return }
        for (key, child) in mapping {
            recordPathValues(
                child,
                at: YAMLPointer(components: pointer.components + [key]),
                into: &values
            )
        }
    }

    private func applyRuntimeForcedProvenance(
        to provenance: inout ConfigurationProvenanceGraph,
        beforeValues: [YAMLPointer: YAMLValue],
        afterValues: [YAMLPointer: YAMLValue],
        path: YAMLPointer,
        source: SourceReference
    ) throws -> [ConfigurationDiagnostic] {
        var diagnostics: [ConfigurationDiagnostic] = []
        for rawPath in Array(provenance.paths.keys) {
            guard let pointer = try? YAMLPointer(rawPath),
                pointer == path || path.isAncestor(of: pointer)
            else {
                continue
            }
            if afterValues[pointer] == nil {
                provenance.paths.removeValue(forKey: rawPath)
            }
        }

        var claimed = Set(afterValues.keys).subtracting(beforeValues.keys)
        claimed.formUnion(afterValues.keys.filter {
            $0 == path || path.isAncestor(of: $0)
        })
        for pointer in claimed.sorted() {
            guard let after = afterValues[pointer] else { continue }
            let before = beforeValues[pointer]
            let previous = provenance.paths[pointer.rawValue]
            var contributors = previous?.contributors ?? []
            var conflicts = previous?.conflicts ?? []

            if let previous,
                let before,
                previous.effectiveSource != source
            {
                contributors.append(SourceContribution(
                    source: previous.effectiveSource,
                    valueFingerprint: try contributionFingerprint(before, at: pointer)
                ))
                if before != after {
                    let conflict = ConfigurationConflict(
                        path: pointer,
                        previousSource: previous.effectiveSource,
                        overridingSource: source,
                        message: "A runtime-forced value overrides an earlier configuration value."
                    )
                    conflicts.append(conflict)
                    diagnostics.append(ConfigurationDiagnostic(
                        severity: .warning,
                        code: .crossLayerOverride,
                        message: conflict.message,
                        path: pointer,
                        layerID: nil,
                        operationID: nil
                    ))
                }
            }

            provenance.paths[pointer.rawValue] = ConfigPathProvenance(
                path: pointer,
                effectiveSource: source,
                contributors: contributors,
                conflicts: conflicts,
                isProtected: true,
                isRedacted: containsSensitiveValue(after, at: pointer)
            )
        }
        return diagnostics
    }

    private func contributionFingerprint(
        _ value: YAMLValue,
        at pointer: YAMLPointer
    ) throws -> String {
        containsSensitiveValue(value, at: pointer)
            ? "redacted"
            : try fingerprint(value)
    }

    private func containsSensitiveValue(
        _ value: YAMLValue,
        at pointer: YAMLPointer
    ) -> Bool {
        if protectedPathPolicy.isSensitive(pointer) { return true }
        switch value {
        case let .mapping(mapping):
            return mapping.contains { key, child in
                containsSensitiveValue(
                    child,
                    at: YAMLPointer(components: pointer.components + [key])
                )
            }
        case let .sequence(values):
            return values.contains { containsSensitiveValue($0, at: pointer) }
        case .null, .bool, .integer, .floatingPoint, .string:
            return false
        }
    }

    private func canonicalData(_ value: YAMLValue) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private func fingerprint(_ value: YAMLValue) throws -> String {
        do {
            return Self.sha256(try canonicalData(value))
        } catch {
            throw ConfigurationCompilerError.deterministicEncodingFailed
        }
    }

    private func depth(of value: YAMLValue) -> Int {
        switch value {
        case .null, .bool, .integer, .floatingPoint, .string:
            1
        case let .sequence(values):
            1 + (values.map(depth).max() ?? 0)
        case let .mapping(mapping):
            1 + (mapping.map { depth(of: $0.value) }.max() ?? 0)
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func deterministicUUID(fromSHA256 hash: String) -> UUID {
        var bytes = stride(from: 0, to: min(hash.count, 32), by: 2).compactMap { offset -> UInt8? in
            let start = hash.index(hash.startIndex, offsetBy: offset)
            let end = hash.index(start, offsetBy: 2)
            return UInt8(hash[start..<end], radix: 16)
        }
        while bytes.count < 16 { bytes.append(0) }
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    private func checkCancellation() throws {
        if Task.isCancelled { throw CancellationError() }
    }
}
