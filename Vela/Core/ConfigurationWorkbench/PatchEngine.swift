import CryptoKit
import Foundation

nonisolated struct PatchEngineResult: Equatable, Sendable {
    let root: YAMLValue
    let provenance: ConfigurationProvenanceGraph
    let ruleOrigins: [RuleOrigin]
    let diagnostics: [ConfigurationDiagnostic]
}

nonisolated enum PatchEngineError: Error, Equatable, Sendable {
    case rootIsNotMapping
    case layerSchemaUnsupported(layerID: UUID, schemaVersion: Int)
    case immutableLayerSupplied(layerID: UUID, kind: ConfigurationLayerKind)
    case protectedPath(layerID: UUID, operationID: UUID, path: String, reason: String)
    case invalidOperation(layerID: UUID, operationID: UUID, path: String, reason: String)
    case operationConflict(layerID: UUID, firstOperationID: UUID, secondOperationID: UUID, path: String)
    case limitExceeded(layerID: UUID?, operationID: UUID?, reason: String)
    case deterministicEncodingFailed
}

extension PatchEngineError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .rootIsNotMapping:
            "The effective configuration root must be a mapping."
        case let .layerSchemaUnsupported(layerID, schemaVersion):
            "Layer \(layerID) uses unsupported schema \(schemaVersion)."
        case let .immutableLayerSupplied(layerID, kind):
            "Layer \(layerID) has read-only kind \(kind.rawValue)."
        case let .protectedPath(layerID, operationID, path, reason):
            "Layer \(layerID), operation \(operationID), cannot modify \(path): \(reason)"
        case let .invalidOperation(layerID, operationID, path, reason):
            "Layer \(layerID), operation \(operationID), is invalid at \(path): \(reason)"
        case let .operationConflict(layerID, firstOperationID, secondOperationID, path):
            "Layer \(layerID) has conflicting operations \(firstOperationID) and \(secondOperationID) at \(path)."
        case let .limitExceeded(layerID, operationID, reason):
            "Configuration limit exceeded\(layerID.map { " in layer \($0)" } ?? "")\(operationID.map { ", operation \($0)" } ?? ""): \(reason)"
        case .deterministicEncodingFailed:
            "A configuration value could not be deterministically encoded."
        }
    }
}

nonisolated struct PatchEngine: Sendable {
    let limits: ConfigurationCompilerLimits
    let protectedPathPolicy: ProtectedPathPolicy

    init(
        limits: ConfigurationCompilerLimits = .default,
        protectedPathPolicy: ProtectedPathPolicy = ProtectedPathPolicy()
    ) {
        self.limits = limits
        self.protectedPathPolicy = protectedPathPolicy
    }

    func apply(
        root originalRoot: YAMLValue,
        profileRevisionID: UUID?,
        layers: [ConfigurationLayer],
        context: ConfigurationBackendContext
    ) throws -> PatchEngineResult {
        guard case .mapping = originalRoot else { throw PatchEngineError.rootIsNotMapping }
        try checkCancellation()

        var root = originalRoot
        var diagnostics: [ConfigurationDiagnostic] = []
        var provenance = initialProvenance(
            for: originalRoot,
            profileRevisionID: profileRevisionID,
            context: context
        )
        var ruleOrigins = initialRuleOrigins(for: originalRoot)

        let orderedLayers = layers.filter(\.enabled).sorted { lhs, rhs in
            if lhs.kind.precedence != rhs.kind.precedence {
                return lhs.kind.precedence < rhs.kind.precedence
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }

        for layer in orderedLayers {
            try checkCancellation()
            try validate(layer: layer)
            guard layer.kind.isUserEditable else {
                throw PatchEngineError.immutableLayerSupplied(layerID: layer.id, kind: layer.kind)
            }
            try validateSameLayerConflicts(layer)

            for operation in layer.operations.filter(\.enabled).sorted(by: operationOrder) {
                try checkCancellation()
                try validate(operation: operation, in: layer, context: context)

                let beforeRoot = root
                let beforePathValues = pathValues(
                    below: operation.path,
                    in: beforeRoot
                )
                let beforeRuleValues = rules(in: beforeRoot)
                let operationDiagnostics: [ConfigurationDiagnostic]
                do {
                    operationDiagnostics = try apply(
                        operation,
                        layer: layer,
                        to: &root
                    )
                } catch let error as YAMLDocumentError {
                    throw invalid(operation, layer: layer, reason: error.localizedDescription)
                }
                diagnostics.append(contentsOf: operationDiagnostics)
                guard depth(of: root) <= limits.maximumDepth else {
                    throw PatchEngineError.limitExceeded(
                        layerID: layer.id,
                        operationID: operation.id,
                        reason: "effective configuration exceeds nesting depth \(limits.maximumDepth)"
                    )
                }

                let afterPathValues = pathValues(
                    below: operation.path,
                    in: root
                )
                let claimedPaths = claimedPaths(
                    for: operation,
                    beforeRoot: beforeRoot,
                    afterRoot: root,
                    beforePathValues: beforePathValues,
                    afterPathValues: afterPathValues
                )
                diagnostics.append(contentsOf: try updateProvenance(
                    &provenance,
                    beforeValues: beforePathValues,
                    afterValues: afterPathValues,
                    claimedPaths: claimedPaths,
                    source: .layer(layer, operationID: operation.id),
                    layer: layer,
                    operation: operation
                ))

                if operation.path.rawValue == "/rules" {
                    ruleOrigins = try updatedRuleOrigins(
                        previousValues: beforeRuleValues,
                        previousOrigins: ruleOrigins,
                        finalValues: rules(in: root),
                        operation: operation,
                        layer: layer
                    )
                }
            }
        }

        return PatchEngineResult(
            root: root,
            provenance: provenance,
            ruleOrigins: ruleOrigins,
            diagnostics: diagnostics
        )
    }

    private func validate(layer: ConfigurationLayer) throws {
        guard layer.schemaVersion == ConfigurationLayer.currentSchemaVersion else {
            throw PatchEngineError.layerSchemaUnsupported(
                layerID: layer.id,
                schemaVersion: layer.schemaVersion
            )
        }
        guard layer.operations.count <= limits.maximumOperationsPerLayer else {
            throw PatchEngineError.limitExceeded(
                layerID: layer.id,
                operationID: nil,
                reason: "more than \(limits.maximumOperationsPerLayer) operations"
            )
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(layer), data.count <= limits.maximumLayerBytes else {
            throw PatchEngineError.limitExceeded(
                layerID: layer.id,
                operationID: nil,
                reason: "layer exceeds \(limits.maximumLayerBytes) bytes"
            )
        }
    }

    private func validate(
        operation: ConfigurationOperation,
        in layer: ConfigurationLayer,
        context: ConfigurationBackendContext
    ) throws {
        guard !operation.path.isRoot else {
            throw PatchEngineError.protectedPath(
                layerID: layer.id,
                operationID: operation.id,
                path: operation.path.rawValue,
                reason: "The configuration root is read-only."
            )
        }
        guard operation.path.rawValue.utf8.count <= limits.maximumPointerBytes else {
            throw PatchEngineError.limitExceeded(
                layerID: layer.id,
                operationID: operation.id,
                reason: "pointer exceeds \(limits.maximumPointerBytes) bytes"
            )
        }
        guard operation.path.components.count <= limits.maximumDepth else {
            throw PatchEngineError.limitExceeded(
                layerID: layer.id,
                operationID: operation.id,
                reason: "pointer exceeds nesting depth \(limits.maximumDepth)"
            )
        }

        switch protectedPathPolicy.decision(
            for: operation.path,
            layerKind: layer.kind,
            context: context
        ) {
        case .allowed:
            break
        case let .readOnly(reason), let .forbidden(reason):
            throw PatchEngineError.protectedPath(
                layerID: layer.id,
                operationID: operation.id,
                path: operation.path.rawValue,
                reason: reason
            )
        }

        if let value = operation.value {
            guard depth(of: value) <= limits.maximumDepth else {
                throw PatchEngineError.limitExceeded(
                    layerID: layer.id,
                    operationID: operation.id,
                    reason: "value exceeds nesting depth \(limits.maximumDepth)"
                )
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            guard let data = try? encoder.encode(value), data.count <= limits.maximumValueBytes else {
                throw PatchEngineError.limitExceeded(
                    layerID: layer.id,
                    operationID: operation.id,
                    reason: "value exceeds \(limits.maximumValueBytes) bytes"
                )
            }
        }
    }

    private func validateSameLayerConflicts(_ layer: ConfigurationLayer) throws {
        let operations = layer.operations.filter(\.enabled).sorted(by: operationOrder)
        var directWrites: [YAMLPointer: (UUID, String?)] = [:]
        var removals: [(YAMLPointer, UUID)] = []
        var namedWrites: [String: (UUID, String?)] = [:]

        for operation in operations {
            if let removal = removals.first(where: { $0.0.isAncestor(of: operation.path) }) {
                throw PatchEngineError.operationConflict(
                    layerID: layer.id,
                    firstOperationID: removal.1,
                    secondOperationID: operation.id,
                    path: operation.path.rawValue
                )
            }

            if operation.kind == .remove {
                removals.append((operation.path, operation.id))
            }

            if operation.kind == .set {
                let valueFingerprint = try operation.value.map(fingerprint)
                if let prior = directWrites[operation.path], prior.1 != valueFingerprint {
                    throw PatchEngineError.operationConflict(
                        layerID: layer.id,
                        firstOperationID: prior.0,
                        secondOperationID: operation.id,
                        path: operation.path.rawValue
                    )
                }
                directWrites[operation.path] = (operation.id, valueFingerprint)
            }

            if operation.kind == .upsertNamed {
                let identityKey = operation.identityKey ?? "name"
                let identity = operation.identityValue ?? namedIdentity(
                    in: operation.value,
                    key: identityKey
                )
                if let identity {
                    let key = "\(operation.path.rawValue)\u{0}\(identityKey)\u{0}\(identity)"
                    let valueFingerprint = try operation.value.map(fingerprint)
                    if let prior = namedWrites[key], prior.1 != valueFingerprint {
                        throw PatchEngineError.operationConflict(
                            layerID: layer.id,
                            firstOperationID: prior.0,
                            secondOperationID: operation.id,
                            path: operation.path.rawValue
                        )
                    }
                    namedWrites[key] = (operation.id, valueFingerprint)
                }
            }
        }
    }

    private func apply(
        _ operation: ConfigurationOperation,
        layer: ConfigurationLayer,
        to root: inout YAMLValue
    ) throws -> [ConfigurationDiagnostic] {
        var diagnostics: [ConfigurationDiagnostic] = []
        switch operation.kind {
        case .set:
            guard let value = operation.value else {
                throw invalid(operation, layer: layer, reason: "set requires a value")
            }
            try set(value, at: operation.path, in: &root)

        case .remove:
            if try remove(at: operation.path, in: &root) == nil {
                diagnostics.append(warning(
                    .removeMissingPath,
                    "Removing a missing path has no effect.",
                    operation: operation,
                    layer: layer
                ))
            }

        case .deepMerge:
            guard case let .mapping(incoming)? = operation.value else {
                throw invalid(operation, layer: layer, reason: "deepMerge requires a mapping value")
            }
            let merged: YAMLValue
            if let existing = value(at: operation.path, in: root) {
                if case let .mapping(existingMapping) = existing {
                    merged = .mapping(deepMerge(existingMapping, incoming, diagnostics: &diagnostics, operation: operation, layer: layer))
                } else {
                    diagnostics.append(warning(
                        .typeMismatch,
                        "deepMerge replaced a non-mapping target with a mapping.",
                        operation: operation,
                        layer: layer
                    ))
                    merged = .mapping(incoming)
                }
            } else {
                merged = .mapping(incoming)
            }
            try set(merged, at: operation.path, in: &root)

        case .prependUnique, .appendUnique:
            guard case let .sequence(incoming)? = operation.value else {
                throw invalid(operation, layer: layer, reason: "unique sequence operations require a sequence value")
            }
            let existing: [YAMLValue]
            if let target = value(at: operation.path, in: root) {
                guard case let .sequence(values) = target else {
                    throw invalid(operation, layer: layer, reason: "target is not a sequence")
                }
                existing = values
            } else {
                existing = []
            }
            var fingerprints = Set(try existing.map(fingerprint))
            var unique: [YAMLValue] = []
            for value in incoming {
                let valueFingerprint = try fingerprint(value)
                if fingerprints.insert(valueFingerprint).inserted {
                    unique.append(value)
                } else {
                    diagnostics.append(warning(
                        .duplicateValueIgnored,
                        "A duplicate sequence value was ignored.",
                        operation: operation,
                        layer: layer
                    ))
                }
            }
            let output = operation.kind == .prependUnique
                ? unique + existing
                : existing + unique
            try set(.sequence(output), at: operation.path, in: &root)

        case .upsertNamed:
            guard case let .mapping(item)? = operation.value else {
                throw invalid(operation, layer: layer, reason: "upsertNamed requires a mapping value")
            }
            let identityKey = operation.identityKey ?? "name"
            guard let identity = operation.identityValue ?? namedIdentity(in: operation.value, key: identityKey),
                item[identityKey] == .string(identity)
            else {
                throw invalid(operation, layer: layer, reason: "named value must contain a string identity")
            }
            var items: [YAMLValue]
            if let target = value(at: operation.path, in: root) {
                guard case let .sequence(values) = target else {
                    throw invalid(operation, layer: layer, reason: "named target is not a sequence")
                }
                items = values
            } else {
                items = []
            }
            let indexes = matchingIndexes(identity: identity, key: identityKey, items: items)
            guard indexes.count <= 1 else {
                throw invalid(operation, layer: layer, reason: "named target contains duplicate identities")
            }
            if let index = indexes.first {
                switch operation.duplicatePolicy {
                case .replace:
                    items[index] = .mapping(item)
                case .deepMerge:
                    guard case let .mapping(existing) = items[index] else {
                        throw invalid(operation, layer: layer, reason: "named target item is not a mapping")
                    }
                    items[index] = .mapping(deepMerge(existing, item, diagnostics: &diagnostics, operation: operation, layer: layer))
                case .error:
                    throw invalid(operation, layer: layer, reason: "named identity already exists")
                }
            } else if operation.insertionPosition == .beginning {
                items.insert(.mapping(item), at: 0)
            } else {
                items.append(.mapping(item))
            }
            try set(.sequence(items), at: operation.path, in: &root)

        case .removeNamed:
            let identityKey = operation.identityKey ?? "name"
            guard let identity = operation.identityValue else {
                throw invalid(operation, layer: layer, reason: "removeNamed requires identityValue")
            }
            guard let target = value(at: operation.path, in: root) else {
                diagnostics.append(warning(
                    .removeMissingPath,
                    "Removing a missing named target has no effect.",
                    operation: operation,
                    layer: layer
                ))
                return diagnostics
            }
            guard case var .sequence(items) = target else {
                throw invalid(operation, layer: layer, reason: "named target is not a sequence")
            }
            let indexes = matchingIndexes(identity: identity, key: identityKey, items: items)
            guard indexes.count <= 1 else {
                throw invalid(operation, layer: layer, reason: "named target contains duplicate identities")
            }
            if let index = indexes.first {
                items.remove(at: index)
                try set(.sequence(items), at: operation.path, in: &root)
            } else {
                diagnostics.append(warning(
                    .removeMissingPath,
                    "The named identity does not exist.",
                    operation: operation,
                    layer: layer
                ))
            }
        }
        return diagnostics
    }

    private func deepMerge(
        _ base: OrderedYAMLMapping,
        _ incoming: OrderedYAMLMapping,
        diagnostics: inout [ConfigurationDiagnostic],
        operation: ConfigurationOperation,
        layer: ConfigurationLayer
    ) -> OrderedYAMLMapping {
        var result = base
        for (key, value) in incoming {
            if case let .mapping(baseChild)? = base[key], case let .mapping(incomingChild) = value {
                result[key] = .mapping(deepMerge(
                    baseChild,
                    incomingChild,
                    diagnostics: &diagnostics,
                    operation: operation,
                    layer: layer
                ))
            } else {
                if let existing = base[key], kind(of: existing) != kind(of: value) {
                    diagnostics.append(warning(
                        .typeMismatch,
                        "deepMerge replaced a value with a different YAML type.",
                        operation: operation,
                        layer: layer
                    ))
                }
                result[key] = value
            }
        }
        return result
    }

    private func value(at pointer: YAMLPointer, in root: YAMLValue) -> YAMLValue? {
        var current = root
        for component in pointer.components {
            guard case let .mapping(mapping) = current, let next = mapping[component] else {
                return nil
            }
            current = next
        }
        return current
    }

    private func set(_ value: YAMLValue, at pointer: YAMLPointer, in root: inout YAMLValue) throws {
        root = try setting(value, in: root, components: ArraySlice(pointer.components), traversed: [])
    }

    private func setting(
        _ value: YAMLValue,
        in current: YAMLValue,
        components: ArraySlice<String>,
        traversed: [String]
    ) throws -> YAMLValue {
        guard let component = components.first else { return value }
        guard case var .mapping(mapping) = current else {
            throw YAMLDocumentError.pathComponentIsNotMapping(path: traversed.joined(separator: "."))
        }
        let remaining = components.dropFirst()
        if remaining.isEmpty {
            mapping[component] = value
        } else {
            let child = mapping[component] ?? .mapping(OrderedYAMLMapping())
            mapping[component] = try setting(
                value,
                in: child,
                components: remaining,
                traversed: traversed + [component]
            )
        }
        return .mapping(mapping)
    }

    @discardableResult
    private func remove(at pointer: YAMLPointer, in root: inout YAMLValue) throws -> YAMLValue? {
        let result = try removing(from: root, components: ArraySlice(pointer.components), traversed: [])
        root = result.value
        return result.removed
    }

    private func removing(
        from current: YAMLValue,
        components: ArraySlice<String>,
        traversed: [String]
    ) throws -> (value: YAMLValue, removed: YAMLValue?) {
        guard let component = components.first else { return (current, nil) }
        guard case var .mapping(mapping) = current else {
            throw YAMLDocumentError.pathComponentIsNotMapping(path: traversed.joined(separator: "."))
        }
        let remaining = components.dropFirst()
        if remaining.isEmpty {
            let removed = mapping.removeValue(forKey: component)
            return (.mapping(mapping), removed)
        }
        guard let child = mapping[component] else { return (.mapping(mapping), nil) }
        let result = try removing(
            from: child,
            components: remaining,
            traversed: traversed + [component]
        )
        mapping[component] = result.value
        return (.mapping(mapping), result.removed)
    }

    private func initialProvenance(
        for root: YAMLValue,
        profileRevisionID: UUID?,
        context: ConfigurationBackendContext
    ) -> ConfigurationProvenanceGraph {
        var graph = ConfigurationProvenanceGraph(paths: [:])
        recordUpstream(
            root,
            at: .root,
            profileRevisionID: profileRevisionID,
            context: context,
            into: &graph
        )
        return graph
    }

    private func recordUpstream(
        _ value: YAMLValue,
        at pointer: YAMLPointer,
        profileRevisionID: UUID?,
        context: ConfigurationBackendContext,
        into graph: inout ConfigurationProvenanceGraph
    ) {
        if !pointer.isRoot {
            let isProtected: Bool
            switch protectedPathPolicy.decision(
                for: pointer,
                layerKind: .global,
                context: context
            ) {
            case .allowed: isProtected = false
            case .readOnly, .forbidden: isProtected = true
            }
            graph.paths[pointer.rawValue] = ConfigPathProvenance(
                path: pointer,
                effectiveSource: .upstream(profileRevisionID: profileRevisionID, path: pointer),
                contributors: [],
                conflicts: [],
                isProtected: isProtected,
                isRedacted: containsSensitiveValue(value, at: pointer)
            )
        }
        guard case let .mapping(mapping) = value else { return }
        for (key, child) in mapping {
            recordUpstream(
                child,
                at: YAMLPointer(components: pointer.components + [key]),
                profileRevisionID: profileRevisionID,
                context: context,
                into: &graph
            )
        }
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

    private func claimedPaths(
        for operation: ConfigurationOperation,
        beforeRoot: YAMLValue,
        afterRoot: YAMLValue,
        beforePathValues: [YAMLPointer: YAMLValue],
        afterPathValues: [YAMLPointer: YAMLValue]
    ) -> Set<YAMLPointer> {
        var claimed = Set(afterPathValues.keys).subtracting(beforePathValues.keys)
        let before = value(at: operation.path, in: beforeRoot)
        let after = value(at: operation.path, in: afterRoot)

        switch operation.kind {
        case .set:
            claimed.formUnion(afterPathValues.keys.filter {
                $0 == operation.path || operation.path.isAncestor(of: $0)
            })
        case .deepMerge:
            if let incoming = operation.value {
                var incomingValues: [YAMLPointer: YAMLValue] = [:]
                recordPathValues(incoming, at: operation.path, into: &incomingValues)
                claimed.formUnion(incomingValues.keys)
            }
        case .upsertNamed:
            if after != nil { claimed.insert(operation.path) }
        case .prependUnique, .appendUnique, .removeNamed:
            if before != after, after != nil { claimed.insert(operation.path) }
        case .remove:
            break
        }
        return claimed
    }

    private func updateProvenance(
        _ provenance: inout ConfigurationProvenanceGraph,
        beforeValues: [YAMLPointer: YAMLValue],
        afterValues: [YAMLPointer: YAMLValue],
        claimedPaths: Set<YAMLPointer>,
        source: SourceReference,
        layer: ConfigurationLayer,
        operation: ConfigurationOperation
    ) throws -> [ConfigurationDiagnostic] {
        var diagnostics: [ConfigurationDiagnostic] = []

        for rawPath in Array(provenance.paths.keys) {
            guard let pointer = try? YAMLPointer(rawPath),
                pointer == operation.path || operation.path.isAncestor(of: pointer)
            else {
                continue
            }
            if afterValues[pointer] == nil {
                provenance.paths.removeValue(forKey: rawPath)
            }
        }

        for pointer in claimedPaths.sorted() {
            guard let after = afterValues[pointer] else { continue }
            let previous = provenance.paths[pointer.rawValue]
            let before = beforeValues[pointer]
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
                if before != after,
                    sourcesAreCrossLayer(previous.effectiveSource, source)
                {
                    let conflict = ConfigurationConflict(
                        path: pointer,
                        previousSource: previous.effectiveSource,
                        overridingSource: source,
                        message: "A later configuration layer overrides an earlier value."
                    )
                    conflicts.append(conflict)
                    diagnostics.append(ConfigurationDiagnostic(
                        severity: .warning,
                        code: .crossLayerOverride,
                        message: conflict.message,
                        path: pointer,
                        layerID: layer.id,
                        operationID: operation.id
                    ))
                }
            }

            provenance.paths[pointer.rawValue] = ConfigPathProvenance(
                path: pointer,
                effectiveSource: source,
                contributors: contributors,
                conflicts: conflicts,
                isProtected: previous?.isProtected ?? false,
                isRedacted: containsSensitiveValue(after, at: pointer)
            )
        }
        return diagnostics
    }

    private func sourcesAreCrossLayer(
        _ previous: SourceReference,
        _ current: SourceReference
    ) -> Bool {
        if previous.kind == .layer,
            current.kind == .layer,
            previous.layerID == current.layerID
        {
            return false
        }
        return previous != current
    }

    private func contributionFingerprint(
        _ value: YAMLValue,
        at pointer: YAMLPointer
    ) throws -> String {
        if containsSensitiveValue(value, at: pointer) {
            return "redacted"
        }
        return try fingerprint(value)
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

    private func initialRuleOrigins(for root: YAMLValue) -> [RuleOrigin] {
        rules(in: root).indices.map { .upstream(originalIndex: $0) }
    }

    private func rules(in root: YAMLValue) -> [YAMLValue] {
        guard let pointer = try? YAMLPointer("/rules"),
            case let .sequence(values)? = value(at: pointer, in: root)
        else {
            return []
        }
        return values
    }

    private func updatedRuleOrigins(
        previousValues: [YAMLValue],
        previousOrigins: [RuleOrigin],
        finalValues: [YAMLValue],
        operation: ConfigurationOperation,
        layer: ConfigurationLayer
    ) throws -> [RuleOrigin] {
        if operation.kind == .remove { return [] }
        if operation.kind == .set {
            return try finalValues.enumerated().map { index, value in
                try ruleOrigin(
                    layer: layer,
                    operation: operation,
                    ordinal: index,
                    value: value
                )
            }
        }

        var previousByFingerprint: [String: [(YAMLValue, RuleOrigin)]] = [:]
        for (index, value) in previousValues.enumerated() {
            let origin = previousOrigins.indices.contains(index)
                ? previousOrigins[index]
                : .upstream(originalIndex: index)
            previousByFingerprint[try fingerprint(value), default: []]
                .append((value, origin))
        }

        var result: [RuleOrigin] = []
        result.reserveCapacity(finalValues.count)
        for (index, value) in finalValues.enumerated() {
            try checkCancellation()
            let valueFingerprint = try fingerprint(value)
            if var candidates = previousByFingerprint[valueFingerprint],
                let match = candidates.firstIndex(where: { $0.0 == value })
            {
                result.append(candidates.remove(at: match).1)
                previousByFingerprint[valueFingerprint] = candidates
            } else {
                result.append(try ruleOrigin(
                    layer: layer,
                    operation: operation,
                    ordinal: index,
                    value: value
                ))
            }
        }
        return result
    }

    private func ruleOrigin(
        layer: ConfigurationLayer,
        operation: ConfigurationOperation,
        ordinal: Int,
        value: YAMLValue
    ) throws -> RuleOrigin {
        let seed = Data(
            "\(layer.id.uuidString)|\(operation.id.uuidString)|\(ordinal)|\(try fingerprint(value))".utf8
        )
        let ruleID = deterministicUUID(from: SHA256.hash(data: seed))
        switch layer.kind {
        case .global: return .global(ruleID: ruleID)
        case .profile: return .profile(ruleID: ruleID)
        case .scene: return .scene(ruleID: ruleID)
        case .runtimeForced, .privilegedSanitizer:
            throw PatchEngineError.immutableLayerSupplied(
                layerID: layer.id,
                kind: layer.kind
            )
        }
    }

    private func deterministicUUID(
        from digest: SHA256.Digest
    ) -> UUID {
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    private func fingerprint(_ value: YAMLValue) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else {
            throw PatchEngineError.deterministicEncodingFailed
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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

    private func namedIdentity(in value: YAMLValue?, key: String) -> String? {
        guard case let .mapping(mapping)? = value, case let .string(identity)? = mapping[key] else {
            return nil
        }
        return identity
    }

    private func matchingIndexes(
        identity: String,
        key: String,
        items: [YAMLValue]
    ) -> [Int] {
        items.indices.filter { index in
            guard case let .mapping(mapping) = items[index] else { return false }
            return mapping[key] == .string(identity)
        }
    }

    private func kind(of value: YAMLValue) -> Int {
        switch value {
        case .null: 0
        case .bool: 1
        case .integer: 2
        case .floatingPoint: 3
        case .string: 4
        case .sequence: 5
        case .mapping: 6
        }
    }

    private func invalid(
        _ operation: ConfigurationOperation,
        layer: ConfigurationLayer,
        reason: String
    ) -> PatchEngineError {
        .invalidOperation(
            layerID: layer.id,
            operationID: operation.id,
            path: operation.path.rawValue,
            reason: reason
        )
    }

    private func warning(
        _ code: ConfigurationDiagnosticCode,
        _ message: String,
        operation: ConfigurationOperation,
        layer: ConfigurationLayer
    ) -> ConfigurationDiagnostic {
        ConfigurationDiagnostic(
            severity: .warning,
            code: code,
            message: message,
            path: operation.path,
            layerID: layer.id,
            operationID: operation.id
        )
    }

    private func operationOrder(
        _ lhs: ConfigurationOperation,
        _ rhs: ConfigurationOperation
    ) -> Bool {
        if lhs.order != rhs.order { return lhs.order < rhs.order }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private func checkCancellation() throws {
        if Task.isCancelled { throw CancellationError() }
    }
}
