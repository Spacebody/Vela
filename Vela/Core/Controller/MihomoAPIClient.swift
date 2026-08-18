import Foundation
import OSLog

nonisolated protocol URLSessionProviding: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: URLSessionProviding {}

protocol MihomoAPIProviding: Sendable {
    func version() async throws -> MihomoVersion
    func configs() async throws -> MihomoConfigs
    func patchConfigs(_ patch: MihomoConfigPatch) async throws
    func reloadConfiguration(at configurationURL: URL, force: Bool) async throws
    func proxies() async throws -> MihomoProxiesResponse
    func proxy(named name: String) async throws -> MihomoProxy
    func proxyProviders() async throws -> MihomoProxyProvidersResponse
    func proxyProvider(named name: String) async throws -> MihomoProxyProvider
    func updateProxyProvider(named name: String) async throws
    func healthCheckProxyProvider(named name: String) async throws
    func proxyProviderProxy(provider: String, name: String) async throws -> MihomoProxy
    func proxyProviderProxyDelay(
        provider: String,
        name: String,
        url: String,
        timeoutMilliseconds: Int,
        expectedStatus: String?
    ) async throws -> MihomoProxyDelayResponse
    func ruleProviders() async throws -> MihomoRuleProvidersResponse
    func updateRuleProvider(named name: String) async throws
    func connections() async throws -> ConnectionsSnapshot
    func closeConnection(id: String) async throws
    func closeAllConnections() async throws
    func rules() async throws -> MihomoRulesResponse
    func setRulesDisabled(_ disabledByIndex: [Int: Bool]) async throws
    func updateGeoDatabases() async throws
    func selectProxy(group: String, proxy: String) async throws
    func proxyDelay(
        name: String,
        url: String,
        timeoutMilliseconds: Int,
        expectedStatus: String?
    ) async throws -> MihomoProxyDelayResponse
}

extension MihomoAPIProviding {
    func reloadConfiguration(at configurationURL: URL, force: Bool) async throws {
        throw unsupportedAPI("Configuration reloads")
    }

    func proxyProviders() async throws -> MihomoProxyProvidersResponse {
        .empty
    }

    func proxyProvider(named name: String) async throws -> MihomoProxyProvider {
        let response = try await proxyProviders()
        guard let provider = response.providers[name] else {
            throw MihomoAPIError.httpStatus(
                code: 404,
                body: #"{"message":"Resource not found"}"#
            )
        }
        return provider
    }

    func updateProxyProvider(named name: String) async throws {
        throw MihomoAPIError.httpStatus(
            code: 501,
            body: "Proxy provider updates are not implemented by this provider."
        )
    }

    func healthCheckProxyProvider(named name: String) async throws {
        throw MihomoAPIError.httpStatus(
            code: 501,
            body: "Proxy provider health checks are not implemented by this provider."
        )
    }

    func proxyProviderProxy(provider: String, name: String) async throws -> MihomoProxy {
        let response = try await proxyProvider(named: provider)
        guard let proxy = response.proxies.first(where: { $0.name == name }) else {
            throw MihomoAPIError.httpStatus(
                code: 404,
                body: #"{"message":"Resource not found"}"#
            )
        }
        return proxy
    }

    func proxyProviderProxyDelay(
        provider: String,
        name: String,
        url: String,
        timeoutMilliseconds: Int,
        expectedStatus: String?
    ) async throws -> MihomoProxyDelayResponse {
        throw MihomoAPIError.httpStatus(
            code: 501,
            body: "Proxy provider delay testing is not implemented by this provider."
        )
    }

    func ruleProviders() async throws -> MihomoRuleProvidersResponse {
        throw unsupportedAPI("Rule provider reads")
    }

    func updateRuleProvider(named name: String) async throws {
        throw unsupportedAPI("Rule provider updates")
    }

    func connections() async throws -> ConnectionsSnapshot {
        throw unsupportedAPI("Connection snapshots")
    }

    func closeConnection(id: String) async throws {
        throw unsupportedAPI("Closing a connection")
    }

    func closeAllConnections() async throws {
        throw unsupportedAPI("Closing all connections")
    }

    func rules() async throws -> MihomoRulesResponse {
        throw unsupportedAPI("Rule reads")
    }

    func setRulesDisabled(_ disabledByIndex: [Int: Bool]) async throws {
        throw unsupportedAPI("Temporary rule changes")
    }

    func updateGeoDatabases() async throws {
        throw unsupportedAPI("Geo database updates")
    }

    func proxy(named name: String) async throws -> MihomoProxy {
        let response = try await proxies()
        guard let proxy = response.proxies[name] else {
            throw MihomoAPIError.httpStatus(
                code: 404,
                body: #"{"message":"Resource not found"}"#
            )
        }
        return proxy
    }

    func selectProxy(group: String, proxy: String) async throws {
        throw MihomoAPIError.httpStatus(
            code: 501,
            body: "Proxy selection is not implemented by this provider."
        )
    }

    func proxyDelay(
        name: String,
        url: String,
        timeoutMilliseconds: Int,
        expectedStatus: String?
    ) async throws -> MihomoProxyDelayResponse {
        throw MihomoAPIError.httpStatus(
            code: 501,
            body: "Proxy delay testing is not implemented by this provider."
        )
    }

    private func unsupportedAPI(_ operation: String) -> MihomoAPIError {
        MihomoAPIError.httpStatus(
            code: 501,
            body: "\(operation) are not implemented by this provider."
        )
    }
}

nonisolated struct MihomoRetryPolicy: Equatable, Sendable {
    let maximumRetryCount: Int
    let retryDelay: Duration
    let maximumRetryDelay: Duration

    init(
        maximumRetryCount: Int = 2,
        retryDelay: Duration = .milliseconds(100),
        maximumRetryDelay: Duration = .seconds(2)
    ) {
        self.maximumRetryCount = max(0, maximumRetryCount)
        self.retryDelay = max(.zero, retryDelay)
        self.maximumRetryDelay = max(self.retryDelay, maximumRetryDelay)
    }

    func delay(forRetry retryNumber: Int) -> Duration {
        guard retryDelay > .zero else { return .zero }

        var delay = retryDelay
        for _ in 1..<max(1, retryNumber) {
            delay = min(delay * 2, maximumRetryDelay)
        }
        return delay
    }
}

nonisolated struct MihomoAPIClient: MihomoAPIProviding, Sendable {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.jerry.Vela",
        category: "ControllerAPI"
    )
    private static let pathSegmentAllowedCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )
    private static let delayRequestTimeoutMargin: TimeInterval = 1
    static let geoUpdateRequestTimeout: TimeInterval = 10 * 60

    private let baseURL: URL
    private let secret: String
    private let session: any URLSessionProviding
    private let retryPolicy: MihomoRetryPolicy
    private let requestTimeout: TimeInterval

    init(
        baseURL: URL,
        secret: String,
        session: any URLSessionProviding = URLSession.shared,
        retryPolicy: MihomoRetryPolicy = MihomoRetryPolicy(),
        requestTimeout: TimeInterval = 10
    ) {
        self.baseURL = baseURL
        self.secret = secret
        self.session = session
        self.retryPolicy = retryPolicy
        self.requestTimeout = requestTimeout
    }

    func version() async throws -> MihomoVersion {
        try await decodedRequest(pathSegments: ["version"], method: "GET")
    }

    func configs() async throws -> MihomoConfigs {
        try await decodedRequest(pathSegments: ["configs"], method: "GET")
    }

    func patchConfigs(_ patch: MihomoConfigPatch) async throws {
        let body: Data
        do {
            body = try JSONEncoder().encode(patch)
        } catch {
            throw MihomoAPIError.encodingFailed(message: String(describing: error))
        }

        var request = try makeRequest(pathSegments: ["configs"], method: "PATCH")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        _ = try await perform(
            request,
            endpoint: "/configs",
            allowsRetry: false
        )
    }

    func reloadConfiguration(at configurationURL: URL, force: Bool = false) async throws {
        let standardizedURL = configurationURL.standardizedFileURL
        guard standardizedURL.isFileURL, standardizedURL.path.hasPrefix("/") else {
            throw MihomoRequestValidationError.invalidConfigurationPath(configurationURL)
        }

        let body: Data
        do {
            body = try JSONEncoder().encode(
                MihomoConfigurationReloadRequest(path: standardizedURL.path)
            )
        } catch {
            throw MihomoAPIError.encodingFailed(message: String(describing: error))
        }

        var request = try makeRequest(
            pathSegments: ["configs"],
            method: "PUT",
            queryItems: [
                URLQueryItem(name: "force", value: force ? "true" : "false"),
            ]
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        _ = try await perform(
            request,
            endpoint: "/configs",
            allowsRetry: false
        )
    }

    func proxies() async throws -> MihomoProxiesResponse {
        try await decodedRequest(pathSegments: ["proxies"], method: "GET")
    }

    func proxy(named name: String) async throws -> MihomoProxy {
        try await decodedRequest(
            pathSegments: ["proxies", name],
            method: "GET"
        )
    }

    func proxyProviders() async throws -> MihomoProxyProvidersResponse {
        try await decodedRequest(
            pathSegments: ["providers", "proxies"],
            method: "GET"
        )
    }

    func proxyProvider(named name: String) async throws -> MihomoProxyProvider {
        try await decodedRequest(
            pathSegments: ["providers", "proxies", name],
            method: "GET"
        )
    }

    func updateProxyProvider(named name: String) async throws {
        let pathSegments = ["providers", "proxies", name]
        _ = try await perform(
            makeRequest(pathSegments: pathSegments, method: "PUT"),
            endpoint: endpointDescription(pathSegments),
            allowsRetry: false
        )
    }

    func healthCheckProxyProvider(named name: String) async throws {
        let pathSegments = ["providers", "proxies", name, "healthcheck"]
        _ = try await perform(
            makeRequest(pathSegments: pathSegments, method: "GET"),
            endpoint: endpointDescription(pathSegments),
            allowsRetry: false
        )
    }

    func proxyProviderProxy(provider: String, name: String) async throws -> MihomoProxy {
        try await decodedRequest(
            pathSegments: ["providers", "proxies", provider, name],
            method: "GET"
        )
    }

    func proxyProviderProxyDelay(
        provider: String,
        name: String,
        url: String,
        timeoutMilliseconds: Int,
        expectedStatus: String?
    ) async throws -> MihomoProxyDelayResponse {
        let pathSegments = ["providers", "proxies", provider, name, "healthcheck"]
        let request = try makeDelayRequest(
            pathSegments: pathSegments,
            url: url,
            timeoutMilliseconds: timeoutMilliseconds,
            expectedStatus: expectedStatus
        )
        return try await decodedResponse(
            for: request,
            endpoint: endpointDescription(pathSegments),
            allowsRetry: false
        )
    }

    func ruleProviders() async throws -> MihomoRuleProvidersResponse {
        try await decodedRequest(
            pathSegments: ["providers", "rules"],
            method: "GET"
        )
    }

    func updateRuleProvider(named name: String) async throws {
        let pathSegments = ["providers", "rules", name]
        _ = try await perform(
            makeRequest(pathSegments: pathSegments, method: "PUT"),
            endpoint: endpointDescription(pathSegments),
            allowsRetry: false
        )
    }

    func connections() async throws -> ConnectionsSnapshot {
        try await decodedRequest(pathSegments: ["connections"], method: "GET")
    }

    func closeConnection(id: String) async throws {
        let pathSegments = ["connections", id]
        _ = try await perform(
            makeRequest(pathSegments: pathSegments, method: "DELETE"),
            endpoint: endpointDescription(pathSegments),
            allowsRetry: false
        )
    }

    func closeAllConnections() async throws {
        _ = try await perform(
            makeRequest(pathSegments: ["connections"], method: "DELETE"),
            endpoint: "/connections",
            allowsRetry: false
        )
    }

    func rules() async throws -> MihomoRulesResponse {
        try await decodedRequest(pathSegments: ["rules"], method: "GET")
    }

    func setRulesDisabled(_ disabledByIndex: [Int: Bool]) async throws {
        let body: Data
        do {
            let payload = Dictionary(
                uniqueKeysWithValues: disabledByIndex.map { index, disabled in
                    (String(index), disabled)
                }
            )
            body = try JSONEncoder().encode(payload)
        } catch {
            throw MihomoAPIError.encodingFailed(message: String(describing: error))
        }

        var request = try makeRequest(
            pathSegments: ["rules", "disable"],
            method: "PATCH"
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        _ = try await perform(
            request,
            endpoint: "/rules/disable",
            allowsRetry: false
        )
    }

    func updateGeoDatabases() async throws {
        let request = try makeRequest(
            pathSegments: ["configs", "geo"],
            method: "POST",
            timeoutInterval: Self.geoUpdateRequestTimeout
        )
        _ = try await perform(
            request,
            endpoint: "/configs/geo",
            allowsRetry: false
        )
    }

    func selectProxy(group: String, proxy: String) async throws {
        let body: Data
        do {
            body = try JSONEncoder().encode(MihomoProxySelection(name: proxy))
        } catch {
            throw MihomoAPIError.encodingFailed(message: String(describing: error))
        }

        let pathSegments = ["proxies", group]
        var request = try makeRequest(pathSegments: pathSegments, method: "PUT")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        _ = try await perform(
            request,
            endpoint: endpointDescription(pathSegments),
            allowsRetry: false
        )
    }

    func proxyDelay(
        name: String,
        url: String,
        timeoutMilliseconds: Int,
        expectedStatus: String?
    ) async throws -> MihomoProxyDelayResponse {
        let pathSegments = ["proxies", name, "delay"]
        let request = try makeDelayRequest(
            pathSegments: pathSegments,
            url: url,
            timeoutMilliseconds: timeoutMilliseconds,
            expectedStatus: expectedStatus
        )
        return try await decodedResponse(
            for: request,
            endpoint: endpointDescription(pathSegments),
            allowsRetry: false
        )
    }

    private func makeDelayRequest(
        pathSegments: [String],
        url: String,
        timeoutMilliseconds: Int,
        expectedStatus: String?
    ) throws -> URLRequest {
        guard (1...Int(Int16.max)).contains(timeoutMilliseconds) else {
            throw MihomoRequestValidationError.invalidDelayTimeout(
                milliseconds: timeoutMilliseconds
            )
        }

        var queryItems = [
            URLQueryItem(name: "url", value: url),
            URLQueryItem(name: "timeout", value: String(timeoutMilliseconds)),
        ]
        if let expectedStatus {
            queryItems.append(URLQueryItem(name: "expected", value: expectedStatus))
        }

        return try makeRequest(
            pathSegments: pathSegments,
            method: "GET",
            queryItems: queryItems,
            timeoutInterval: TimeInterval(timeoutMilliseconds) / 1_000
                + Self.delayRequestTimeoutMargin
        )
    }

    private func decodedRequest<Response: Decodable & Sendable>(
        pathSegments: [String],
        method: String,
        allowsRetry: Bool = true
    ) async throws -> Response {
        let endpoint = endpointDescription(pathSegments)
        return try await decodedResponse(
            for: makeRequest(pathSegments: pathSegments, method: method),
            endpoint: endpoint,
            allowsRetry: allowsRetry
        )
    }

    private func decodedResponse<Response: Decodable & Sendable>(
        for request: URLRequest,
        endpoint: String,
        allowsRetry: Bool
    ) async throws -> Response {
        let (data, _) = try await perform(
            request,
            endpoint: endpoint,
            allowsRetry: allowsRetry
        )

        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw MihomoAPIError.decodingFailed(
                endpoint: endpoint,
                message: String(describing: error)
            )
        }
    }

    private func makeRequest(
        pathSegments: [String],
        method: String,
        queryItems: [URLQueryItem] = [],
        timeoutInterval: TimeInterval? = nil
    ) throws -> URLRequest {
        guard var components = URLComponents(
            url: baseURL,
            resolvingAgainstBaseURL: false
        ) else {
            throw MihomoRequestValidationError.invalidBaseURL(baseURL)
        }

        let encodedSegments = try pathSegments.map { segment in
            guard let encoded = segment.addingPercentEncoding(
                withAllowedCharacters: Self.pathSegmentAllowedCharacters
            ) else {
                throw MihomoRequestValidationError.invalidPathSegment(segment)
            }
            return encoded
        }

        var basePath = components.percentEncodedPath
        while basePath.hasSuffix("/") {
            basePath.removeLast()
        }
        components.percentEncodedPath = basePath + "/" + encodedSegments.joined(separator: "/")
        components.query = nil
        components.fragment = nil
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }

        guard let url = components.url else {
            throw MihomoRequestValidationError.invalidBaseURL(baseURL)
        }

        var request = URLRequest(
            url: url,
            timeoutInterval: timeoutInterval ?? requestTimeout
        )
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !secret.isEmpty {
            request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func endpointDescription(_ pathSegments: [String]) -> String {
        "/" + pathSegments.joined(separator: "/")
    }

    private func perform(
        _ request: URLRequest,
        endpoint: String,
        allowsRetry: Bool = true
    ) async throws -> (Data, HTTPURLResponse) {
        var retryCount = 0

        while true {
            do {
                try Task.checkCancellation()
                let (data, response) = try await session.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw MihomoAPIError.invalidResponse(endpoint: endpoint)
                }

                if (200..<300).contains(httpResponse.statusCode) {
                    return (data, httpResponse)
                }

                let error: MihomoAPIError
                if httpResponse.statusCode == 401 {
                    error = .unauthorized(body: responseBody(from: data))
                } else {
                    error = .httpStatus(
                        code: httpResponse.statusCode,
                        body: responseBody(from: data)
                    )
                }

                if allowsRetry,
                    (500..<600).contains(httpResponse.statusCode),
                    retryCount < retryPolicy.maximumRetryCount
                {
                    retryCount += 1
                    try await waitBeforeRetry(retryNumber: retryCount)
                    continue
                }

                throw error
            } catch let error as MihomoAPIError {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError {
                if error.code == .cancelled || Task.isCancelled {
                    throw CancellationError()
                }

                if allowsRetry,
                    isTransient(error.code),
                    retryCount < retryPolicy.maximumRetryCount
                {
                    retryCount += 1
                    try await waitBeforeRetry(retryNumber: retryCount)
                    continue
                }

                throw MihomoAPIError.transport(
                    code: error.code,
                    message: error.localizedDescription
                )
            } catch {
                if Task.isCancelled {
                    throw CancellationError()
                }
                throw MihomoAPIError.transport(
                    code: .unknown,
                    message: error.localizedDescription
                )
            }
        }
    }

    private func waitBeforeRetry(retryNumber: Int) async throws {
        let delay = retryPolicy.delay(forRetry: retryNumber)
        Self.logger.info(
            "Retrying controller request (attempt \(retryNumber, privacy: .public) of \(retryPolicy.maximumRetryCount, privacy: .public))"
        )
        if delay == .zero {
            await Task.yield()
        } else {
            try await Task.sleep(for: delay)
        }
    }

    private func isTransient(_ code: URLError.Code) -> Bool {
        switch code {
        case .timedOut,
            .cannotFindHost,
            .cannotConnectToHost,
            .networkConnectionLost,
            .dnsLookupFailed,
            .notConnectedToInternet,
            .internationalRoamingOff,
            .callIsActive,
            .dataNotAllowed,
            .resourceUnavailable,
            .backgroundSessionWasDisconnected,
            .cannotLoadFromNetwork:
            true
        default:
            false
        }
    }

    private func responseBody(from data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        return String(decoding: data.prefix(4_096), as: UTF8.self)
    }
}

nonisolated private struct MihomoProxySelection: Encodable, Sendable {
    let name: String
}

nonisolated private struct MihomoConfigurationReloadRequest: Encodable, Sendable {
    let path: String
}

nonisolated enum MihomoRequestValidationError: Error, Equatable, Sendable {
    case invalidBaseURL(URL)
    case invalidPathSegment(String)
    case invalidDelayTimeout(milliseconds: Int)
    case invalidConfigurationPath(URL)
}

extension MihomoRequestValidationError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .invalidBaseURL(url):
            "Could not construct a Mihomo endpoint URL from \(url.absoluteString)."
        case let .invalidPathSegment(segment):
            "Could not encode Mihomo path segment \(segment.debugDescription)."
        case let .invalidDelayTimeout(milliseconds):
            "Mihomo delay timeout must be between 1 and \(Int(Int16.max)) ms; got \(milliseconds) ms."
        case let .invalidConfigurationPath(url):
            "Mihomo configuration reload requires an absolute file URL, not \(url.absoluteString)."
        }
    }
}

nonisolated enum MihomoAPIError: Error, Equatable, Sendable {
    case invalidResponse(endpoint: String)
    case unauthorized(body: String?)
    case httpStatus(code: Int, body: String?)
    case transport(code: URLError.Code, message: String)
    case decodingFailed(endpoint: String, message: String)
    case encodingFailed(message: String)
}

extension MihomoAPIError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .invalidResponse(endpoint):
            "Mihomo returned a non-HTTP response for \(endpoint)."
        case let .unauthorized(body):
            "Mihomo rejected the Controller secret.\(bodySuffix(body))"
        case let .httpStatus(code, body):
            "Mihomo returned HTTP \(code).\(bodySuffix(body))"
        case let .transport(code, message):
            "Mihomo Controller transport failed (\(code.rawValue)): \(message)"
        case let .decodingFailed(endpoint, message):
            "Could not decode the Mihomo response for \(endpoint): \(message)"
        case let .encodingFailed(message):
            "Could not encode the Mihomo request: \(message)"
        }
    }

    private func bodySuffix(_: String?) -> String {
        // Controller error bodies may contain upstream URLs, local paths, rule
        // payloads, or other user configuration. Keep the typed body in memory
        // for protocol tests, but never surface it through LocalizedError/UI.
        ""
    }
}
