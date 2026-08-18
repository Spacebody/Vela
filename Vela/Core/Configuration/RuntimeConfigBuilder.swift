import Foundation

nonisolated struct RuntimeConfigParameters: Equatable, Sendable {
    let externalController: String
    let secret: String
    let mixedPort: UInt16
    let ipv6: Bool?

    init(
        externalController: String,
        secret: String,
        mixedPort: UInt16,
        ipv6: Bool? = nil
    ) {
        self.externalController = externalController
        self.secret = secret
        self.mixedPort = mixedPort
        self.ipv6 = ipv6
    }

    func replacingIPv6(with enabled: Bool) -> Self {
        Self(
            externalController: externalController,
            secret: secret,
            mixedPort: mixedPort,
            ipv6: enabled
        )
    }
}

nonisolated struct RuntimeConfigBuilder: Sendable {
    private let compiler: ConfigurationCompiler

    init(compiler: ConfigurationCompiler = ConfigurationCompiler()) {
        self.compiler = compiler
    }

    func build(
        from originalYAML: String,
        parameters: RuntimeConfigParameters,
        context: ConfigurationCompilationContext = ConfigurationCompilationContext()
    ) throws -> String {
        try validate(parameters)

        do {
            var compilationContext = context
            compilationContext.runtimeForcedValues.removeAll {
                ["/external-controller", "/mixed-port", "/secret"]
                    .contains($0.path.rawValue)
                    || (parameters.ipv6 != nil && $0.path.rawValue == "/ipv6")
            }
            compilationContext.runtimeForcedValues.append(contentsOf: [
                RuntimeForcedConfigurationValue(
                    path: try YAMLPointer("/external-controller"),
                    value: .string(parameters.externalController),
                    reasonCode: "managedController"
                ),
                RuntimeForcedConfigurationValue(
                    path: try YAMLPointer("/mixed-port"),
                    value: .integer(Int(parameters.mixedPort)),
                    reasonCode: "managedMixedPort"
                ),
                RuntimeForcedConfigurationValue(
                    path: try YAMLPointer("/secret"),
                    value: .string(parameters.secret),
                    reasonCode: "managedControllerSecret"
                ),
            ])
            if let ipv6 = parameters.ipv6 {
                compilationContext.runtimeForcedValues.append(
                    RuntimeForcedConfigurationValue(
                        path: try YAMLPointer("/ipv6"),
                        value: .bool(ipv6),
                        reasonCode: "managedIPv6Preference"
                    )
                )
            }
            let compiled = try compiler.compile(
                upstreamYAML: originalYAML,
                context: compilationContext
            )
            guard let yaml = String(data: compiled.yaml, encoding: .utf8) else {
                throw RuntimeConfigBuilderError.runtimeConfigurationEncodingFailed
            }
            return yaml
        } catch let error as ConfigurationCompilerError {
            switch error {
            case .sourceIsNotUTF8:
                throw RuntimeConfigBuilderError.sourceIsNotUTF8
            case let .invalidYAML(yamlError):
                throw RuntimeConfigBuilderError.invalidYAML(yamlError)
            default:
                throw RuntimeConfigBuilderError.configurationCompilationFailed(
                    reason: error.localizedDescription
                )
            }
        }
    }

    func compile(
        from originalData: Data,
        parameters: RuntimeConfigParameters,
        context: ConfigurationCompilationContext = ConfigurationCompilationContext()
    ) throws -> CompiledConfiguration {
        try validate(parameters)
        var compilationContext = context
        compilationContext.runtimeForcedValues.removeAll {
            ["/external-controller", "/mixed-port", "/secret"]
                .contains($0.path.rawValue)
                || (parameters.ipv6 != nil && $0.path.rawValue == "/ipv6")
        }
        compilationContext.runtimeForcedValues.append(contentsOf: [
            RuntimeForcedConfigurationValue(
                path: try YAMLPointer("/external-controller"),
                value: .string(parameters.externalController),
                reasonCode: "managedController"
            ),
            RuntimeForcedConfigurationValue(
                path: try YAMLPointer("/mixed-port"),
                value: .integer(Int(parameters.mixedPort)),
                reasonCode: "managedMixedPort"
            ),
            RuntimeForcedConfigurationValue(
                path: try YAMLPointer("/secret"),
                value: .string(parameters.secret),
                reasonCode: "managedControllerSecret"
            ),
        ])
        if let ipv6 = parameters.ipv6 {
            compilationContext.runtimeForcedValues.append(
                RuntimeForcedConfigurationValue(
                    path: try YAMLPointer("/ipv6"),
                    value: .bool(ipv6),
                    reasonCode: "managedIPv6Preference"
                )
            )
        }
        do {
            return try compiler.compile(
                upstreamYAML: originalData,
                context: compilationContext
            )
        } catch let error as ConfigurationCompilerError {
            switch error {
            case .sourceIsNotUTF8:
                throw RuntimeConfigBuilderError.sourceIsNotUTF8
            case let .invalidYAML(yamlError):
                throw RuntimeConfigBuilderError.invalidYAML(yamlError)
            default:
                throw RuntimeConfigBuilderError.configurationCompilationFailed(
                    reason: error.localizedDescription
                )
            }
        }
    }

    func build(
        from originalData: Data,
        parameters: RuntimeConfigParameters,
        context: ConfigurationCompilationContext = ConfigurationCompilationContext()
    ) throws -> Data {
        guard let originalYAML = String(data: originalData, encoding: .utf8) else {
            throw RuntimeConfigBuilderError.sourceIsNotUTF8
        }

        let runtimeYAML = try build(
            from: originalYAML,
            parameters: parameters,
            context: context
        )
        guard let data = runtimeYAML.data(using: .utf8) else {
            throw RuntimeConfigBuilderError.runtimeConfigurationEncodingFailed
        }
        return data
    }

    @discardableResult
    func writeRuntimeConfiguration(
        from source: URL,
        to destination: URL,
        parameters: RuntimeConfigParameters,
        context: ConfigurationCompilationContext = ConfigurationCompilationContext(),
        fileSystem: any FileSystemProviding = LiveFileSystem()
    ) throws -> URL {
        let originalData: Data
        do {
            originalData = try fileSystem.readData(at: source)
        } catch {
            throw RuntimeConfigBuilderError.sourceReadFailed(
                path: source.path,
                reason: String(describing: error)
            )
        }

        let runtimeData = try build(
            from: originalData,
            parameters: parameters,
            context: context
        )

        do {
            try fileSystem.createDirectory(at: destination.deletingLastPathComponent())
            try fileSystem.setPOSIXPermissions(
                0o700,
                at: destination.deletingLastPathComponent()
            )
            try fileSystem.writeDataAtomically(runtimeData, to: destination)
            try fileSystem.setPOSIXPermissions(0o600, at: destination)
        } catch {
            throw RuntimeConfigBuilderError.runtimeConfigurationWriteFailed(
                path: destination.path,
                reason: String(describing: error)
            )
        }

        return destination
    }

    private func validate(_ parameters: RuntimeConfigParameters) throws {
        if parameters.externalController.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw RuntimeConfigBuilderError.externalControllerIsEmpty
        }
        if parameters.secret.isEmpty {
            throw RuntimeConfigBuilderError.secretIsEmpty
        }
        if parameters.mixedPort == 0 {
            throw RuntimeConfigBuilderError.mixedPortIsZero
        }
    }
}

nonisolated enum RuntimeConfigBuilderError: Error, Equatable, Sendable {
    case externalControllerIsEmpty
    case secretIsEmpty
    case mixedPortIsZero
    case sourceReadFailed(path: String, reason: String)
    case sourceIsNotUTF8
    case invalidYAML(YAMLDocumentError)
    case runtimeConfigurationEncodingFailed
    case configurationCompilationFailed(reason: String)
    case runtimeConfigurationWriteFailed(path: String, reason: String)
}

extension RuntimeConfigBuilderError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .externalControllerIsEmpty:
            "The External Controller address cannot be empty."
        case .secretIsEmpty:
            "The External Controller secret cannot be empty."
        case .mixedPortIsZero:
            "The mixed port must be greater than zero."
        case let .sourceReadFailed(path, reason):
            "Could not read the source configuration at \(path): \(reason)"
        case .sourceIsNotUTF8:
            "The source configuration is not valid UTF-8."
        case let .invalidYAML(error):
            error.localizedDescription
        case .runtimeConfigurationEncodingFailed:
            "Could not encode the generated runtime configuration as UTF-8."
        case let .configurationCompilationFailed(reason):
            "Could not compile the runtime configuration: \(reason)"
        case let .runtimeConfigurationWriteFailed(path, reason):
            "Could not write the runtime configuration at \(path): \(reason)"
        }
    }
}
