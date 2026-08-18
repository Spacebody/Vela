import Foundation

nonisolated struct SurgeSubscriptionParser: SubscriptionContentParser {
    let supportedFormat: SubscriptionContentFormat = .surge

    func canParse(
        _: String,
        detection: SubscriptionContentDetection
    ) -> Bool {
        detection.format == .surge
    }

    func parse(
        _ content: String,
        context: SubscriptionParsingContext
    ) async throws -> SubscriptionConversionResult {
        var section = ""
        var proxyLines: [(name: String, value: String, line: Int)] = []
        var proxyGroupCount = 0
        var ruleCount = 0
        var ignoredSections = Set<String>()

        for (lineIndex, rawLine) in content.split(
            omittingEmptySubsequences: false,
            whereSeparator: \.isNewline
        ).enumerated() {
            try Task.checkCancellation()
            guard rawLine.utf8.count <= context.options.limits.maximumLineLength else {
                throw SubscriptionConversionError.lineTooLong(
                    limit: context.options.limits.maximumLineLength
                )
            }
            let line = stripComment(String(rawLine))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                section = String(line.dropFirst().dropLast()).lowercased()
                continue
            }
            switch section {
            case "proxy":
                guard let assignment = splitAssignment(line) else { continue }
                proxyLines.append((assignment.key, assignment.value, lineIndex))
            case "proxy group":
                if splitAssignment(line) != nil { proxyGroupCount += 1 }
            case "rule", "rule provider":
                ruleCount += 1
            case "mitm", "script", "url rewrite", "header rewrite":
                ignoredSections.insert(section)
            default:
                break
            }
        }

        guard !proxyLines.isEmpty else {
            throw SubscriptionConversionError.invalidSurgeConfiguration(
                "The [Proxy] section does not contain proxy entries."
            )
        }

        var nodes: [SubscriptionProxyNode] = []
        var warnings = ignoredSections.sorted().map {
            ConversionWarning.unsupportedField(
                format: "Surge",
                field: "[\(displayName(for: $0))]"
            )
        }
        if proxyGroupCount > 0 {
            warnings.append(
                .unsupportedField(format: "Surge", field: "[Proxy Group]")
            )
        }
        if ruleCount > 0 {
            warnings.append(.unsupportedField(format: "Surge", field: "[Rule]"))
        }
        var rejected: [RejectedSubscriptionItem] = []

        for (index, entry) in proxyLines.enumerated() {
            try Task.checkCancellation()
            do {
                if let node = try parseProxy(
                    name: entry.name,
                    definition: entry.value,
                    index: index,
                    options: context.options
                ) {
                    nodes.append(node)
                    warnings.append(contentsOf: node.warnings)
                }
            } catch let error as SubscriptionConversionError {
                let reason = error.errorDescription ?? "The Surge proxy is invalid."
                let warning = ConversionWarning.invalidNode(index: index, reason: reason)
                warnings.append(warning)
                rejected.append(
                    RejectedSubscriptionItem(
                        index: index,
                        safeDescription: "Surge proxy on line \(entry.line + 1)",
                        reason: reason
                    )
                )
                if !context.options.continueOnInvalidNode { throw error }
            }
            guard nodes.count <= context.options.limits.maximumNodeCount else {
                throw SubscriptionConversionError.tooManyNodes(
                    limit: context.options.limits.maximumNodeCount
                )
            }
        }

        guard !nodes.isEmpty else { throw SubscriptionConversionError.noSupportedNodes }
        return SubscriptionConversionResult(
            format: .surge,
            nodes: nodes,
            warnings: warnings,
            rejectedItems: rejected,
            metadata: SubscriptionConversionMetadata(
                sourceDescription: "Local Surge conversion",
                importedProxyGroups: proxyGroupCount,
                importedRules: ruleCount
            )
        )
    }

    private func parseProxy(
        name rawName: String,
        definition: String,
        index: Int,
        options: SubscriptionConversionOptions
    ) throws -> SubscriptionProxyNode? {
        let fields = splitCommaSeparated(definition)
        guard let type = fields.first?.lowercased(), !type.isEmpty else {
            throw invalid(index, "The proxy type is missing.")
        }
        if ["direct", "reject", "reject-tinygif"].contains(type) { return nil }
        guard fields.count >= 3 else {
            throw invalid(index, "The server or port is missing.")
        }
        let server = unquote(fields[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !server.isEmpty else { throw invalid(index, "The server is missing.") }
        guard let port = Int(unquote(fields[2])), (1 ... 65_535).contains(port) else {
            throw invalid(index, "The port is invalid.")
        }
        let parameters = parameterMap(Array(fields.dropFirst(3)))
        let name = ProxyURIParsingSupport.name(
            fragment: unquote(rawName),
            fallback: "Surge \(index + 1)",
            maximumLength: options.limits.maximumNodeNameLength
        )
        let source = ProxyURIParsingSupport.source(format: .surge, index: index, scheme: type)
        let udp = bool(parameters["udp-relay"] ?? parameters["udp"])
        let tfo = bool(parameters["tfo"])
        let tls = makeTLS(type: type, parameters: parameters)
        let transport = makeTransport(parameters: parameters)

        switch type {
        case "ss":
            let cipher = parameters["encrypt-method"] ?? parameters["method"]
            let password = parameters["password"]
            guard let cipher, !cipher.isEmpty, let password, !password.isEmpty else {
                throw invalid(index, "Shadowsocks requires encrypt-method and password.")
            }
            return SubscriptionProxyNode(
                name: name,
                server: server,
                port: port,
                protocolType: .shadowsocks,
                authentication: .password(password),
                udp: udp,
                tfo: tfo,
                protocolOptions: .shadowsocks(
                    ShadowsocksOptions(
                        cipher: cipher,
                        password: password,
                        plugin: parameters["plugin"],
                        pluginOptions: [:]
                    )
                ),
                source: source
            )
        case "vmess":
            guard let uuid = parameters["username"] ?? parameters["uuid"], !uuid.isEmpty else {
                throw invalid(index, "VMess requires username/UUID.")
            }
            return SubscriptionProxyNode(
                name: name,
                server: server,
                port: port,
                protocolType: .vmess,
                authentication: .uuid(uuid),
                transport: transport,
                tls: tls,
                udp: udp,
                tfo: tfo,
                protocolOptions: .vmess(
                    VMessOptions(
                        uuid: uuid,
                        alterID: Int(parameters["alter-id"] ?? "0") ?? 0,
                        cipher: parameters["cipher"] ?? "auto",
                        packetEncoding: parameters["packet-encoding"]
                    )
                ),
                source: source
            )
        case "trojan":
            guard let password = parameters["password"], !password.isEmpty else {
                throw invalid(index, "Trojan requires a password.")
            }
            return SubscriptionProxyNode(
                name: name,
                server: server,
                port: port,
                protocolType: .trojan,
                authentication: .password(password),
                transport: transport,
                tls: tls ?? ProxyTLSOptions(enabled: true),
                udp: udp,
                tfo: tfo,
                protocolOptions: .trojan(TrojanOptions(password: password)),
                source: source
            )
        case "http", "https":
            let username = parameters["username"]
            let password = parameters["password"]
            return SubscriptionProxyNode(
                name: name,
                server: server,
                port: port,
                protocolType: .http,
                authentication: authentication(username: username, password: password),
                tls: type == "https" ? (tls ?? ProxyTLSOptions(enabled: true)) : tls,
                tfo: tfo,
                protocolOptions: .http(
                    HTTPProxyOptions(username: username, password: password)
                ),
                source: source
            )
        case "socks5", "socks5-tls":
            let username = parameters["username"]
            let password = parameters["password"]
            return SubscriptionProxyNode(
                name: name,
                server: server,
                port: port,
                protocolType: .socks5,
                authentication: authentication(username: username, password: password),
                tls: type == "socks5-tls" ? (tls ?? ProxyTLSOptions(enabled: true)) : tls,
                udp: udp,
                tfo: tfo,
                protocolOptions: .socks5(
                    SOCKS5Options(username: username, password: password)
                ),
                source: source
            )
        case "wireguard":
            return SubscriptionProxyNode(
                name: name,
                server: server,
                port: port,
                protocolType: .wireGuard,
                authentication: .none,
                udp: true,
                protocolOptions: .wireGuard(
                    WireGuardOptions(
                        privateKey: parameters["private-key"],
                        publicKey: parameters["public-key"],
                        presharedKey: parameters["pre-shared-key"] ?? parameters["preshared-key"],
                        ip: parameters["self-ip"],
                        ipv6: parameters["self-ip-v6"],
                        mtu: parameters["mtu"].flatMap(Int.init)
                    )
                ),
                source: source,
                warnings: [.unsupportedField(format: "Surge", field: "wireguard peers")]
            )
        case "snell":
            throw invalid(index, "Snell is not supported by Mihomo and was not imported.")
        default:
            throw invalid(index, "Protocol '\(type)' is not supported.")
        }
    }

    private func makeTLS(type: String, parameters: [String: String]) -> ProxyTLSOptions? {
        let enabled = type == "https" || type == "socks5-tls" || type == "trojan"
            || bool(parameters["tls"]) == true
        let serverName = parameters["sni"] ?? parameters["server-name"]
        let skipVerify = bool(parameters["skip-cert-verify"])
        let alpn = parameters["alpn"].map(splitList)
        guard enabled || serverName != nil || skipVerify != nil || alpn != nil else { return nil }
        return ProxyTLSOptions(
            enabled: enabled,
            serverName: serverName,
            skipCertificateVerification: skipVerify,
            alpn: alpn,
            clientFingerprint: parameters["client-fingerprint"]
        )
    }

    private func makeTransport(parameters: [String: String]) -> ProxyTransport? {
        if bool(parameters["ws"]) == true || parameters["network"]?.lowercased() == "ws" {
            var headers: [String: String] = [:]
            if let host = parameters["ws-headers"] ?? parameters["ws-host"] {
                headers["Host"] = host.replacingOccurrences(of: "Host:", with: "")
                    .trimmingCharacters(in: .whitespaces)
            }
            return .ws(
                WebSocketOptions(
                    path: parameters["ws-path"] ?? parameters["path"],
                    headers: headers,
                    maximumEarlyData: nil,
                    earlyDataHeaderName: nil
                )
            )
        }
        if parameters["network"]?.lowercased() == "grpc" {
            return .grpc(GRPCOptions(serviceName: parameters["grpc-service-name"]))
        }
        return nil
    }

    private func parameterMap(_ fields: [String]) -> [String: String] {
        var result: [String: String] = [:]
        for field in fields {
            guard let assignment = splitAssignment(field) else { continue }
            result[assignment.key.lowercased()] = unquote(assignment.value)
        }
        return result
    }

    private func splitAssignment(_ value: String) -> (key: String, value: String)? {
        guard let index = firstUnquoted(value, character: "=") else { return nil }
        let key = value[..<index].trimmingCharacters(in: .whitespacesAndNewlines)
        let remainder = value[value.index(after: index)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        return (key, remainder)
    }

    private func splitCommaSeparated(_ value: String) -> [String] {
        split(value, separator: ",")
    }

    private func splitList(_ value: String) -> [String] {
        split(value, separator: "|").map(unquote).filter { !$0.isEmpty }
    }

    private func split(_ value: String, separator: Character) -> [String] {
        var result: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        for character in value {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\" {
                current.append(character)
                escaped = true
            } else if character == "\"" || character == "'" {
                if quote == character { quote = nil }
                else if quote == nil { quote = character }
                current.append(character)
            } else if character == separator, quote == nil {
                result.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current = ""
            } else {
                current.append(character)
            }
        }
        result.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
        return result
    }

    private func stripComment(_ value: String) -> String {
        var quote: Character?
        var escaped = false
        for index in value.indices {
            let character = value[index]
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" || character == "'" {
                if quote == character { quote = nil }
                else if quote == nil { quote = character }
            } else if (character == ";" || character == "#"), quote == nil {
                return String(value[..<index])
            }
        }
        return value
    }

    private func firstUnquoted(_ value: String, character target: Character) -> String.Index? {
        var quote: Character?
        var escaped = false
        for index in value.indices {
            let character = value[index]
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" || character == "'" {
                if quote == character { quote = nil }
                else if quote == nil { quote = character }
            } else if character == target, quote == nil {
                return index
            }
        }
        return nil
    }

    private func unquote(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2,
            let first = trimmed.first,
            first == trimmed.last,
            first == "\"" || first == "'"
        else { return trimmed }
        return String(trimmed.dropFirst().dropLast())
            .replacingOccurrences(of: "\\\(first)", with: String(first))
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    private func bool(_ value: String?) -> Bool? {
        guard let value else { return nil }
        return switch value.lowercased() {
        case "true", "yes", "1", "on": true
        case "false", "no", "0", "off": false
        default: nil
        }
    }

    private func displayName(for section: String) -> String {
        switch section {
        case "mitm": "MITM"
        case "script": "Script"
        case "url rewrite": "URL Rewrite"
        case "header rewrite": "Header Rewrite"
        default: section
        }
    }

    private func authentication(username: String?, password: String?) -> ProxyAuthentication {
        if let username, let password { return .usernamePassword(username: username, password: password) }
        if let password { return .password(password) }
        return .none
    }

    private func invalid(_ index: Int, _ reason: String) -> SubscriptionConversionError {
        .malformedURI(index: index, reason: reason)
    }
}
