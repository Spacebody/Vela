import Foundation

nonisolated struct SubscriptionContentDetector: SubscriptionContentDetecting {
    private let limits: SubscriptionConversionLimits

    init(limits: SubscriptionConversionLimits = SubscriptionConversionLimits()) {
        self.limits = limits
    }

    func detect(_ content: String) -> SubscriptionContentDetection {
        detect(content, depth: 0)
    }

    private func detect(_ rawContent: String, depth: Int) -> SubscriptionContentDetection {
        let withoutBOM = rawContent.hasPrefix("\u{FEFF}") ? String(rawContent.dropFirst()) : rawContent
        let content = withoutBOM.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else {
            return SubscriptionContentDetection(
                format: .unknown,
                confidence: 0,
                decodedContent: nil,
                evidence: ["empty input"]
            )
        }

        if isMihomoYAML(content) {
            return SubscriptionContentDetection(
                format: .mihomoYAML,
                confidence: 1,
                decodedContent: nil,
                evidence: ["valid YAML with proxies or proxy-providers"]
            )
        }
        if isSingBox(content) {
            return SubscriptionContentDetection(
                format: .singBox,
                confidence: 0.98,
                decodedContent: nil,
                evidence: ["JSON object with typed outbounds"]
            )
        }
        if isSurge(content) {
            return SubscriptionContentDetection(
                format: .surge,
                confidence: 0.95,
                decodedContent: nil,
                evidence: ["Surge INI sections"]
            )
        }
        let recognizedSchemes = recognizedProxySchemes(in: content)
        if !recognizedSchemes.isEmpty {
            return SubscriptionContentDetection(
                format: .nodeURIList,
                confidence: 0.92,
                decodedContent: nil,
                evidence: ["proxy URI schemes: \(recognizedSchemes.sorted().joined(separator: ", "))"]
            )
        }
        if depth < limits.maximumBase64RecursionDepth,
            let decoded = SubscriptionBase64Decoder.decodeString(
                content,
                maximumBytes: limits.maximumDecodedBytes
            )
        {
            let nested = detect(decoded, depth: depth + 1)
            if nested.format != .unknown {
                return SubscriptionContentDetection(
                    format: .base64NodeList,
                    confidence: min(0.96, nested.confidence),
                    decodedContent: decoded,
                    evidence: ["Base64 decoded to \(nested.format.rawValue)"] + nested.evidence
                )
            }
        }
        return SubscriptionContentDetection(
            format: .unknown,
            confidence: 0,
            decodedContent: nil,
            evidence: ["no supported subscription structure"]
        )
    }

    private func isMihomoYAML(_ content: String) -> Bool {
        guard let document = try? YAMLDocument(yaml: content) else { return false }
        return document["proxies"] != nil || document["proxy-providers"] != nil
    }

    private func isSingBox(_ content: String) -> Bool {
        guard let data = content.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data),
            let root = object as? [String: Any],
            let outbounds = root["outbounds"] as? [[String: Any]],
            !outbounds.isEmpty
        else { return false }
        return outbounds.contains { outbound in
            guard let type = outbound["type"] as? String else { return false }
            return !type.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func isSurge(_ content: String) -> Bool {
        var sections: Set<String> = []
        for line in content.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("["), trimmed.hasSuffix("]") else { continue }
            sections.insert(String(trimmed.dropFirst().dropLast()).lowercased())
        }
        return sections.contains("proxy")
            || sections.intersection(["general", "proxy group", "rule", "rule provider"]).count >= 2
    }

    private func recognizedProxySchemes(in content: String) -> Set<String> {
        let supported: Set<String> = [
            "ss", "ssr", "vmess", "vless", "trojan", "hysteria", "hysteria2", "hy2",
            "tuic", "wireguard", "wg", "socks", "socks5", "http", "https", "ssh",
        ]
        var result: Set<String> = []
        for rawLine in content.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix(";") else { continue }
            guard let separator = line.range(of: "://") else { continue }
            let scheme = String(line[..<separator.lowerBound]).lowercased()
            guard supported.contains(scheme) else { continue }
            if scheme == "http" || scheme == "https" {
                guard let components = URLComponents(string: line),
                    components.user != nil || components.password != nil
                else { continue }
            }
            result.insert(scheme)
        }
        return result
    }
}
