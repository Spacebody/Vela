import Foundation

nonisolated enum ClashVergeSubscriptionCompatibility {
    static let version = "2.5.2"
    static let userAgent = "clash-verge/v\(version)"
}

nonisolated enum SubscriptionUserAgent: String, Codable, CaseIterable, Identifiable, Sendable {
    case vela
    case clashVerge
    case mihomo
    case clashMetaForAndroid
    case custom

    var id: Self { self }

    func resolvedValue(appVersion: String, customValue: String?) throws -> String {
        let normalizedVersion = appVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        let version = normalizedVersion.isEmpty ? "1.0" : normalizedVersion
        let value = switch self {
        case .vela:
            "Vela/\(version)"
        case .clashVerge:
            ClashVergeSubscriptionCompatibility.userAgent
        case .mihomo:
            "mihomo"
        case .clashMetaForAndroid:
            "ClashMetaForAndroid"
        case .custom:
            customValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        guard SubscriptionHeaderPolicy.isValidUserAgent(value) else {
            throw SubscriptionUpdateFailure.invalidUserAgent
        }
        return value
    }
}

nonisolated enum SubscriptionProxyMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case direct
    case vela
    case system

    var id: Self { self }
}

nonisolated struct NormalizedSubscriptionURL: Equatable, Sendable {
    let url: URL
    let embeddedAuthentication: SubscriptionAuthentication?
}

nonisolated enum SubscriptionURLNormalizer {
    static func normalize(_ rawValue: String) throws -> URL {
        try normalizeWithAuthentication(rawValue).url
    }

    static func normalizeWithAuthentication(_ rawValue: String) throws
        -> NormalizedSubscriptionURL
    {
        var candidate = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { throw SubscriptionUpdateFailure.invalidURL }
        if candidate.hasPrefix("//") {
            candidate = "https:" + candidate
        } else if !candidate.contains("://"), !candidate.contains(where: { $0.isWhitespace }) {
            candidate = "https://" + candidate
        }

        guard var components = URLComponents(string: candidate),
            let scheme = components.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            components.host?.isEmpty == false
        else {
            throw SubscriptionUpdateFailure.invalidURL
        }
        components.scheme = scheme

        // Some subscription providers issue URLs with query parameters appended
        // to the path using `&` instead of starting a query with `?`. Match Clash
        // Verge Rev's compatibility repair while leaving already valid queries alone.
        if components.percentEncodedQuery == nil,
            let separator = components.percentEncodedPath.firstIndex(of: "&")
        {
            let path = components.percentEncodedPath[..<separator]
            let query = components.percentEncodedPath[components.percentEncodedPath.index(after: separator)...]
            components.percentEncodedPath = String(path)
            components.percentEncodedQuery = query.isEmpty ? nil : String(query)
        }

        let username = components.user?.removingPercentEncoding ?? components.user
        let password = components.password?.removingPercentEncoding ?? components.password
        let embeddedAuthentication: SubscriptionAuthentication?
        if let username, !username.isEmpty {
            embeddedAuthentication = .basic(username: username, password: password ?? "")
        } else {
            embeddedAuthentication = nil
        }
        components.user = nil
        components.password = nil
        components.fragment = nil

        guard let url = components.url else { throw SubscriptionUpdateFailure.invalidURL }
        return NormalizedSubscriptionURL(
            url: url,
            embeddedAuthentication: embeddedAuthentication
        )
    }

    static func maskedDescription(of url: URL) -> String {
        SubscriptionURLRedactor.redact(url)
    }
}

nonisolated enum SubscriptionContentDispositionParser {
    static func suggestedFileName(_ value: String?) -> String? {
        guard let value else { return nil }
        let parameters = value.split(separator: ";").dropFirst()
        var fallback: String?
        for parameter in parameters {
            let pair = parameter.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { continue }
            let key = pair[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let raw = pair[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if key == "filename*" {
                let encoded = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                let payload = encoded.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
                let candidate = payload.count == 3 ? String(payload[2]) : encoded
                if let decoded = candidate.removingPercentEncoding,
                    let safe = safeDisplayName(decoded)
                {
                    return safe
                }
            } else if key == "filename" {
                fallback = safeDisplayName(
                    raw.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                )
            }
        }
        return fallback
    }

    private static func safeDisplayName(_ value: String) -> String? {
        let leaf = (value as NSString).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !leaf.isEmpty, leaf != ".", leaf != "..", leaf.utf8.count <= 255 else {
            return nil
        }
        return leaf
    }
}
