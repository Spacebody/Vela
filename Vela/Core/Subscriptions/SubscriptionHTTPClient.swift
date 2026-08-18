import CryptoKit
import Foundation
import OSLog
import Synchronization

nonisolated struct SubscriptionHTTPRequest: Equatable, Sendable {
    var secret: SubscriptionSecretEnvelope
    var etag: String?
    var lastModified: String?
    var knownContentSHA256: String?
    var allowsProxyFallback: Bool

    init(
        secret: SubscriptionSecretEnvelope,
        etag: String? = nil,
        lastModified: String? = nil,
        knownContentSHA256: String? = nil,
        allowsProxyFallback: Bool = false
    ) {
        self.secret = secret
        self.etag = etag
        self.lastModified = lastModified
        self.knownContentSHA256 = knownContentSHA256
        self.allowsProxyFallback = allowsProxyFallback
    }
}

nonisolated enum SubscriptionProxyAttemptPolicy {
    static func modes(
        configured: SubscriptionProxyMode,
        allowsFallback: Bool
    ) -> [SubscriptionProxyMode] {
        guard allowsFallback else { return [configured] }

        var modes = [configured]
        for fallback in [SubscriptionProxyMode.vela, .system] where !modes.contains(fallback) {
            modes.append(fallback)
        }
        return modes
    }

    static func shouldTryNext(after failure: SubscriptionUpdateFailure) -> Bool {
        switch failure {
        case .cancelled, .secretMissing, .invalidURL, .invalidUserAgent,
            .unsupportedScheme, .insecureHTTPNotAllowed, .redirectLimitExceeded,
            .insecureRedirect:
            false
        default:
            true
        }
    }
}

nonisolated enum SubscriptionHTTPStatusPolicy {
    static func failure(
        statusCode: Int,
        retryAfterSeconds: TimeInterval? = nil
    ) -> SubscriptionUpdateFailure? {
        switch statusCode {
        case 200 ... 299, 304:
            nil
        case 401:
            .authenticationFailed
        case 403:
            .accessDenied
        case 404:
            .notFound
        case 408:
            .requestTimedOut
        case 429:
            .rateLimited(retryAfterSeconds: retryAfterSeconds)
        case 500 ... 599:
            .serverError(statusCode: statusCode)
        default:
            .unexpectedHTTPStatus(statusCode)
        }
    }
}

nonisolated struct SubscriptionHTTPMetadata: Equatable, Sendable {
    let statusCode: Int
    let etag: String?
    let lastModified: String?
    let usage: SubscriptionUsage?
    let suggestedUpdateIntervalMinutes: Int?
    let suggestedFileName: String?
    let profileWebPageURL: URL?
    let contentSHA256: String?
    let byteCount: Int64

    init(
        statusCode: Int,
        etag: String?,
        lastModified: String?,
        usage: SubscriptionUsage?,
        suggestedUpdateIntervalMinutes: Int?,
        suggestedFileName: String? = nil,
        profileWebPageURL: URL? = nil,
        contentSHA256: String?,
        byteCount: Int64
    ) {
        self.statusCode = statusCode
        self.etag = etag
        self.lastModified = lastModified
        self.usage = usage
        self.suggestedUpdateIntervalMinutes = suggestedUpdateIntervalMinutes
        self.suggestedFileName = suggestedFileName
        self.profileWebPageURL = profileWebPageURL
        self.contentSHA256 = contentSHA256
        self.byteCount = byteCount
    }
}

nonisolated struct SubscriptionDownload: Equatable, Sendable {
    let yaml: String
    let data: Data
    let metadata: SubscriptionHTTPMetadata
    let conversion: SubscriptionConversionSummary
}

nonisolated enum SubscriptionHTTPOutcome: Equatable, Sendable {
    case notModified(SubscriptionHTTPMetadata)
    case unchanged(SubscriptionHTTPMetadata)
    case downloaded(SubscriptionDownload)
}

nonisolated protocol SubscriptionHTTPFetching: Sendable {
    func fetch(_ request: SubscriptionHTTPRequest) async throws -> SubscriptionHTTPOutcome
}

actor SubscriptionHTTPClient: SubscriptionHTTPFetching {
    static let defaultMaximumBodyBytes = 20 * 1_024 * 1_024

    private let baseConfiguration: URLSessionConfiguration
    private let maximumBodyBytes: Int
    private let maximumRedirects: Int
    private let conversionService: any SubscriptionConverting
    private let logger = Logger(subsystem: "com.vela.app", category: "subscription")

    init(
        configuration: URLSessionConfiguration = .velaSubscriptionEphemeral,
        maximumBodyBytes: Int = defaultMaximumBodyBytes,
        maximumRedirects: Int = 10,
        conversionService: any SubscriptionConverting = SubscriptionConversionService()
    ) {
        self.baseConfiguration = configuration
        self.maximumBodyBytes = maximumBodyBytes
        self.maximumRedirects = maximumRedirects
        self.conversionService = conversionService
    }

    func fetch(_ request: SubscriptionHTTPRequest) async throws -> SubscriptionHTTPOutcome {
        let proxyModes = SubscriptionProxyAttemptPolicy.modes(
            configured: request.secret.proxyMode,
            allowsFallback: request.allowsProxyFallback
        )
        var lastFailure: SubscriptionUpdateFailure?
        for (index, proxyMode) in proxyModes.enumerated() {
            do {
                return try await fetch(request, proxyMode: proxyMode)
            } catch let failure as SubscriptionUpdateFailure {
                lastFailure = failure
                guard SubscriptionProxyAttemptPolicy.shouldTryNext(after: failure),
                    index < proxyModes.count - 1
                else {
                    throw failure
                }
            }
        }
        throw lastFailure ?? SubscriptionUpdateFailure.transportFailed
    }

    private func fetch(
        _ request: SubscriptionHTTPRequest,
        proxyMode: SubscriptionProxyMode
    ) async throws -> SubscriptionHTTPOutcome {
        try Task.checkCancellation()
        var secret = request.secret
        let normalized = try SubscriptionURLNormalizer.normalizeWithAuthentication(
            secret.url.absoluteString
        )
        secret.url = normalized.url
        if secret.authentication == .none, let embedded = normalized.embeddedAuthentication {
            secret.authentication = embedded
        }
        try SubscriptionURLPolicy.validate(
            secret.url,
            allowInsecureHTTP: secret.allowInsecureHTTP
        )

        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "1.0"
        let userAgent = try secret.userAgentPreset.resolvedValue(
            appVersion: appVersion,
            customValue: secret.userAgent
        )
        guard SubscriptionHeaderPolicy.isValidUserAgent(userAgent) else {
            throw SubscriptionUpdateFailure.invalidUserAgent
        }

        let maskedURL = SubscriptionURLNormalizer.maskedDescription(of: secret.url)
        logger.info("[Subscription] Request started: \(maskedURL, privacy: .public)")
        var urlRequest = URLRequest(url: secret.url)
        urlRequest.httpMethod = "GET"
        urlRequest.cachePolicy = .reloadIgnoringLocalCacheData
        urlRequest.timeoutInterval = min(max(secret.requestTimeout, 5), 120)
        urlRequest.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let etag = request.etag, !etag.isEmpty {
            urlRequest.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        if let lastModified = request.lastModified, !lastModified.isEmpty {
            urlRequest.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
        }
        apply(secret.authentication, to: &urlRequest)

        let redirectDelegate = SubscriptionRedirectDelegate(
            initialURL: secret.url,
            allowInsecureHTTP: secret.allowInsecureHTTP,
            allowInvalidCertificates: secret.allowInvalidCertificates,
            maximumRedirects: maximumRedirects
        )
        guard let configuration = baseConfiguration.copy() as? URLSessionConfiguration else {
            throw SubscriptionUpdateFailure.invalidURL
        }
        configureProxy(proxyMode, for: configuration)
        configuration.timeoutIntervalForRequest = urlRequest.timeoutInterval
        configuration.timeoutIntervalForResource = max(urlRequest.timeoutInterval, 30)
        let session = URLSession(
            configuration: configuration,
            delegate: redirectDelegate,
            delegateQueue: nil
        )
        defer { session.invalidateAndCancel() }

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: urlRequest)
        } catch is CancellationError {
            throw SubscriptionUpdateFailure.cancelled
        } catch let error as URLError where error.code == .cancelled && Task.isCancelled {
            throw SubscriptionUpdateFailure.cancelled
        } catch let error as URLError where error.code == .timedOut {
            throw SubscriptionUpdateFailure.requestTimedOut
        } catch {
            if let redirectFailure = redirectDelegate.failure {
                throw redirectFailure
            }
            throw SubscriptionUpdateFailure.transportFailed
        }

        if let redirectFailure = redirectDelegate.failure {
            throw redirectFailure
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SubscriptionUpdateFailure.transportFailed
        }
        logger.info("[Subscription] Response status: \(httpResponse.statusCode)")

        let responseMetadata = makeMetadata(
            response: httpResponse,
            contentSHA256: request.knownContentSHA256,
            byteCount: 0
        )
        if httpResponse.statusCode == 304 {
            return .notModified(responseMetadata)
        }
        try validateStatus(httpResponse)

        if httpResponse.expectedContentLength > Int64(maximumBodyBytes) {
            throw SubscriptionUpdateFailure.responseTooLarge(
                expected: httpResponse.expectedContentLength,
                limit: Int64(maximumBodyBytes)
            )
        }

        var body = Data()
        body.reserveCapacity(
            min(
                maximumBodyBytes,
                max(Int(httpResponse.expectedContentLength), 0)
            )
        )
        do {
            for try await byte in bytes {
                try Task.checkCancellation()
                guard body.count < maximumBodyBytes else {
                    throw SubscriptionUpdateFailure.responseTooLarge(
                        expected: Int64(body.count + 1),
                        limit: Int64(maximumBodyBytes)
                    )
                }
                body.append(byte)
            }
        } catch let error as SubscriptionUpdateFailure {
            throw error
        } catch is CancellationError {
            throw SubscriptionUpdateFailure.cancelled
        } catch let error as URLError where error.code == .cancelled && Task.isCancelled {
            throw SubscriptionUpdateFailure.cancelled
        } catch let error as URLError where error.code == .timedOut {
            throw SubscriptionUpdateFailure.requestTimedOut
        } catch {
            throw SubscriptionUpdateFailure.transportFailed
        }

        let content = try decodeSubscriptionBody(body)
        let converted: ConvertedSubscription
        do {
            converted = try await conversionService.convertToMihomoYAML(
                content: content,
                sourceURL: httpResponse.url,
                options: request.secret.conversionPreferences.options
            )
        } catch let error as SubscriptionConversionError {
            throw mapConversionFailure(error)
        }
        let convertedData = Data(converted.yaml.utf8)
        let validated = try SubscriptionContentValidator.validate(
            convertedData,
            contentType: "application/yaml",
            maximumBodyBytes: maximumBodyBytes
        )
        logger.info("[Subscription] YAML validation passed")
        let sha = SHA256.hash(data: validated.data)
            .map { String(format: "%02x", $0) }
            .joined()
        let metadata = makeMetadata(
            response: httpResponse,
            contentSHA256: sha,
            byteCount: Int64(validated.data.count)
        )
        if let knownSHA = request.knownContentSHA256,
            knownSHA.caseInsensitiveCompare(sha) == .orderedSame
        {
            return .unchanged(metadata)
        }
        return .downloaded(
            SubscriptionDownload(
                yaml: validated.yaml,
                data: validated.data,
                metadata: metadata,
                conversion: SubscriptionConversionSummary(converted)
            )
        )
    }

    private func decodeSubscriptionBody(_ body: Data) throws -> String {
        guard !body.isEmpty else { throw SubscriptionUpdateFailure.emptyResponse }
        guard !body.contains(0), let content = String(data: body, encoding: .utf8) else {
            throw SubscriptionUpdateFailure.invalidEncoding
        }
        let prefix = content
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if prefix.hasPrefix("<!doctype html")
            || prefix.hasPrefix("<html")
            || prefix.hasPrefix("<head")
            || prefix.hasPrefix("<body")
        {
            throw SubscriptionUpdateFailure.htmlResponse
        }
        return content
    }

    private func mapConversionFailure(
        _ error: SubscriptionConversionError
    ) -> SubscriptionUpdateFailure {
        switch error {
        case .cancelled:
            .cancelled
        case let .contentTooLarge(limit):
            .responseTooLarge(expected: Int64(maximumBodyBytes + 1), limit: Int64(limit))
        case .decodedContentInvalidUTF8:
            .invalidEncoding
        case .conversionProducedInvalidYAML:
            .yamlParsingFailed
        case .unsupportedFormat, .base64DecodeFailed, .noSupportedNodes,
             .malformedURI, .invalidSurgeConfiguration, .invalidSingBoxConfiguration,
             .tooManyNodes, .lineTooLong:
            .unsupportedFormat
        }
    }

    private func configureProxy(
        _ proxyMode: SubscriptionProxyMode,
        for configuration: URLSessionConfiguration
    ) {
        switch proxyMode {
        case .direct:
            configuration.connectionProxyDictionary = [:]
        case .system:
            configuration.connectionProxyDictionary = nil
        case .vela:
            configuration.connectionProxyDictionary = [
                "HTTPEnable": 1,
                "HTTPProxy": "127.0.0.1",
                "HTTPPort": 7_890,
                "HTTPSEnable": 1,
                "HTTPSProxy": "127.0.0.1",
                "HTTPSPort": 7_890,
            ]
        }
    }

    private func apply(
        _ authentication: SubscriptionAuthentication,
        to request: inout URLRequest
    ) {
        switch authentication {
        case .none:
            break
        case let .bearer(token):
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        case let .basic(username, password):
            let credentials = Data("\(username):\(password)".utf8).base64EncodedString()
            request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        }
    }

    private func validateStatus(_ response: HTTPURLResponse) throws {
        if let failure = SubscriptionHTTPStatusPolicy.failure(
            statusCode: response.statusCode,
            retryAfterSeconds: SubscriptionHeaderParser.retryAfterSeconds(
                response.value(forHTTPHeaderField: "Retry-After")
            )
        ) {
            throw failure
        }
    }

    private func makeMetadata(
        response: HTTPURLResponse,
        contentSHA256: String?,
        byteCount: Int64
    ) -> SubscriptionHTTPMetadata {
        SubscriptionHTTPMetadata(
            statusCode: response.statusCode,
            etag: response.value(forHTTPHeaderField: "ETag"),
            lastModified: response.value(forHTTPHeaderField: "Last-Modified"),
            usage: SubscriptionHeaderParser.usage(
                subscriptionHeaderValue(
                    response,
                    exactName: "Subscription-Userinfo",
                    suffix: "subscription-userinfo"
                )
            ),
            suggestedUpdateIntervalMinutes: SubscriptionHeaderParser.updateIntervalMinutes(
                response.value(forHTTPHeaderField: "Profile-Update-Interval")
            ),
            suggestedFileName: SubscriptionContentDispositionParser.suggestedFileName(
                response.value(forHTTPHeaderField: "Content-Disposition")
            ) ?? response.url?.lastPathComponent.nonEmpty,
            profileWebPageURL: SubscriptionHeaderParser.profileWebPageURL(
                response.value(forHTTPHeaderField: "Profile-Web-Page-URL")
            ),
            contentSHA256: contentSHA256,
            byteCount: byteCount
        )
    }

    private func subscriptionHeaderValue(
        _ response: HTTPURLResponse,
        exactName: String,
        suffix: String
    ) -> String? {
        if let exact = response.value(forHTTPHeaderField: exactName), !exact.isEmpty {
            return exact
        }
        let normalizedSuffix = suffix.lowercased()
        return response.allHeaderFields.first { key, value in
            let normalizedName = String(describing: key).lowercased()
            guard normalizedName.hasSuffix(normalizedSuffix),
                !String(describing: value).isEmpty
            else { return false }
            let prefix = normalizedName.dropLast(normalizedSuffix.count)
            return prefix.isEmpty || prefix.hasSuffix("-")
        }.map { String(describing: $0.value) }
    }
}

extension URLSessionConfiguration {
    nonisolated static var velaSubscriptionEphemeral: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        configuration.httpMaximumConnectionsPerHost = 2
        return configuration
    }
}

nonisolated private final class SubscriptionRedirectDelegate: NSObject,
    URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable
{
    private struct State: Sendable {
        var redirectCount = 0
        var visitedURLs: Set<String>
        var failure: SubscriptionUpdateFailure?
    }

    private let allowInsecureHTTP: Bool
    private let allowInvalidCertificates: Bool
    private let maximumRedirects: Int
    private let state: Mutex<State>

    init(
        initialURL: URL,
        allowInsecureHTTP: Bool,
        allowInvalidCertificates: Bool,
        maximumRedirects: Int
    ) {
        self.allowInsecureHTTP = allowInsecureHTTP
        self.allowInvalidCertificates = allowInvalidCertificates
        self.maximumRedirects = maximumRedirects
        state = Mutex(State(visitedURLs: [initialURL.absoluteString]))
    }

    func urlSession(
        _: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (
            URLSession.AuthChallengeDisposition,
            URLCredential?
        ) -> Void
    ) {
        guard allowInvalidCertificates,
            challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
            let trust = challenge.protectionSpace.serverTrust
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    var failure: SubscriptionUpdateFailure? {
        state.withLock { $0.failure }
    }

    func urlSession(
        _: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard let oldURL = task.currentRequest?.url, let newURL = request.url else {
            reject(.invalidURL, completionHandler: completionHandler)
            return
        }

        let failure = state.withLock { state -> SubscriptionUpdateFailure? in
            state.redirectCount += 1
            guard state.redirectCount <= maximumRedirects else {
                return .redirectLimitExceeded
            }
            guard !state.visitedURLs.contains(newURL.absoluteString) else {
                return .redirectLimitExceeded
            }
            do {
                try SubscriptionURLPolicy.validateRedirect(
                    from: oldURL,
                    to: newURL,
                    allowInsecureHTTP: allowInsecureHTTP
                )
            } catch let error as SubscriptionUpdateFailure {
                return error
            } catch {
                return .invalidURL
            }
            state.visitedURLs.insert(newURL.absoluteString)
            return nil
        }
        if let failure {
            reject(failure, completionHandler: completionHandler)
            return
        }

        completionHandler(
            SubscriptionRedirectPolicy.sanitize(request, from: oldURL, to: newURL)
        )
    }

    private func reject(
        _ failure: SubscriptionUpdateFailure,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        state.withLock { $0.failure = failure }
        completionHandler(nil)
    }
}

nonisolated enum SubscriptionRedirectPolicy {
    static func sanitize(_ request: URLRequest, from source: URL, to destination: URL) -> URLRequest {
        var redirected = request
        let crossesAuthority = source.host?.lowercased() != destination.host?.lowercased()
            || source.port != destination.port
        if crossesAuthority {
            redirected.setValue(nil, forHTTPHeaderField: "Authorization")
            redirected.setValue(nil, forHTTPHeaderField: "Proxy-Authorization")
            redirected.setValue(nil, forHTTPHeaderField: "Cookie")
        }
        return redirected
    }
}

nonisolated enum SubscriptionURLPolicy {
    static func validate(_ url: URL, allowInsecureHTTP: Bool) throws {
        guard let scheme = url.scheme?.lowercased() else {
            throw SubscriptionUpdateFailure.invalidURL
        }
        switch scheme {
        case "https" where url.host != nil:
            return
        case "http" where url.host == nil:
            throw SubscriptionUpdateFailure.invalidURL
        case "https":
            throw SubscriptionUpdateFailure.invalidURL
        case "http" where allowInsecureHTTP:
            return
        case "http":
            throw SubscriptionUpdateFailure.insecureHTTPNotAllowed
        default:
            throw SubscriptionUpdateFailure.unsupportedScheme
        }
    }

    static func validateRedirect(
        from source: URL,
        to destination: URL,
        allowInsecureHTTP: Bool
    ) throws {
        try validate(destination, allowInsecureHTTP: allowInsecureHTTP)
        let sourceScheme = source.scheme?.lowercased()
        let destinationScheme = destination.scheme?.lowercased()
        if sourceScheme == "https", destinationScheme == "http" {
            throw SubscriptionUpdateFailure.insecureRedirect
        }
    }
}

nonisolated enum SubscriptionHeaderPolicy {
    static func isValidUserAgent(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= 256
            && !value.contains("\r")
            && !value.contains("\n")
    }
}

nonisolated enum SubscriptionContentValidator {
    struct ValidatedContent: Equatable, Sendable {
        let yaml: String
        let data: Data
    }

    static func validate(
        _ input: Data,
        contentType: String?,
        maximumBodyBytes: Int = SubscriptionHTTPClient.defaultMaximumBodyBytes
    ) throws -> ValidatedContent {
        guard !input.isEmpty else {
            throw SubscriptionUpdateFailure.emptyResponse
        }
        guard input.count <= maximumBodyBytes else {
            throw SubscriptionUpdateFailure.responseTooLarge(
                expected: Int64(input.count),
                limit: Int64(maximumBodyBytes)
            )
        }

        var data = input
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            data.removeFirst(3)
        }
        guard !data.isEmpty else {
            throw SubscriptionUpdateFailure.emptyResponse
        }
        guard !data.contains(0) else {
            throw SubscriptionUpdateFailure.invalidEncoding
        }
        guard let yaml = String(data: data, encoding: .utf8) else {
            throw SubscriptionUpdateFailure.invalidEncoding
        }

        let trimmedText = yaml.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = trimmedText.lowercased()
        if prefix.hasPrefix("<!doctype html")
            || prefix.hasPrefix("<html")
            || prefix.hasPrefix("<head")
            || prefix.hasPrefix("<body")
        {
            throw SubscriptionUpdateFailure.htmlResponse
        }
        if looksLikeUnsupportedSubscription(trimmedText, data: data, contentType: contentType) {
            throw SubscriptionUpdateFailure.unsupportedFormat
        }
        let normalized = try SubscriptionPayloadNormalizer.normalize(
            text: yaml,
            maximumOutputBytes: maximumBodyBytes
        )
        return ValidatedContent(yaml: normalized.yaml, data: normalized.data)
    }

    private static func looksLikeUnsupportedSubscription(
        _ trimmedText: String,
        data: Data,
        contentType: String?
    ) -> Bool {
        let proxySchemes = [
            "ss://", "ssr://", "vmess://", "vless://", "trojan://",
            "hysteria2://", "hy2://",
        ]
        let lowercaseText = trimmedText.lowercased()
        if proxySchemes.contains(where: lowercaseText.hasPrefix) {
            return true
        }

        let mediaType = contentType?
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if mediaType == "application/json"
            || lowercaseText.hasPrefix("{")
            || lowercaseText.hasPrefix("[")
        {
            if (try? JSONSerialization.jsonObject(with: data)) != nil {
                return true
            }
        }

        let compact = trimmedText.filter { !$0.isWhitespace }
        guard compact.count >= 16,
            let decoded = Data(base64Encoded: compact),
            let decodedText = String(data: decoded, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
        else {
            return false
        }
        return proxySchemes.contains(where: decodedText.hasPrefix)
    }
}

nonisolated enum SubscriptionHeaderParser {
    static func usage(_ value: String?) -> SubscriptionUsage? {
        guard let value else { return nil }
        var fields: [String: Int64] = [:]
        for component in value.split(separator: ";") {
            let pair = component.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard pair.count == 2, let parsed = parseInt64(pair[1]) else { continue }
            fields[pair[0].lowercased()] = parsed
        }
        let usage = SubscriptionUsage(
            upload: nonnegative(fields["upload"]),
            download: nonnegative(fields["download"]),
            total: nonnegative(fields["total"]),
            expireUnixSeconds: positive(fields["expire"])
        )
        guard usage.upload != nil || usage.download != nil || usage.total != nil
            || usage.expireUnixSeconds != nil
        else {
            return nil
        }
        return usage
    }

    static func updateIntervalMinutes(_ value: String?) -> Int? {
        guard let value, let parsed = parseInt64(value), parsed > 0,
            let hours = Int(exactly: parsed)
        else {
            return nil
        }
        let conversion = hours.multipliedReportingOverflow(by: 60)
        return conversion.overflow ? nil : conversion.partialValue
    }

    static func profileWebPageURL(_ value: String?) -> URL? {
        guard let value,
            let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
            let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https"
        else { return nil }
        return url
    }

    private static func nonnegative(_ value: Int64?) -> Int64? {
        guard let value, value >= 0 else { return nil }
        return value
    }

    private static func positive(_ value: Int64?) -> Int64? {
        guard let value, value > 0 else { return nil }
        return value
    }

    static func retryAfterSeconds(
        _ value: String?,
        now: Date = .now
    ) -> TimeInterval? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let parsed = Double(trimmed), parsed.isFinite, parsed >= 0 {
            return parsed
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss 'GMT'"
        guard let date = formatter.date(from: trimmed) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }

    private static func parseInt64(_ value: String) -> Int64? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let integer = Int64(trimmed) {
            return integer
        }
        guard let number = Double(trimmed), number.isFinite,
            number.rounded(.towardZero) == number,
            number >= Double(Int64.min), number <= Double(Int64.max)
        else {
            return nil
        }
        return Int64(number)
    }
}

nonisolated enum SubscriptionURLRedactor {
    static func redact(_ url: URL, hideHost: Bool = false) -> String {
        guard let scheme = url.scheme?.lowercased() else { return "•••" }
        let host = hideHost ? "•••" : (url.host ?? "•••")
        let components = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        guard let last = components.last, isSafeDisplayComponent(last) else {
            return "\(scheme)://\(host)/•••"
        }
        return "\(scheme)://\(host)/•••/\(last)"
    }

    private static func isSafeDisplayComponent(_ component: String) -> Bool {
        guard component.utf8.count <= 40 else { return false }
        let lower = component.lowercased()
        let safeNames = ["subscription", "sub", "clash", "config", "profile", "download"]
        return safeNames.contains(lower)
            || lower.hasSuffix(".yaml")
            || lower.hasSuffix(".yml")
    }
}

nonisolated enum SubscriptionUpdateFailure: Error, Equatable, Sendable {
    case secretMissing
    case invalidURL
    case invalidUserAgent
    case unsupportedScheme
    case insecureHTTPNotAllowed
    case requestTimedOut
    case redirectLimitExceeded
    case insecureRedirect
    case authenticationFailed
    case accessDenied
    case notFound
    case rateLimited(retryAfterSeconds: TimeInterval?)
    case serverError(statusCode: Int)
    case unexpectedHTTPStatus(Int)
    case responseTooLarge(expected: Int64, limit: Int64)
    case emptyResponse
    case invalidEncoding
    case htmlResponse
    case unsupportedFormat
    case missingProxySection
    case yamlParsingFailed
    case runtimeBuildFailed
    case configurationValidationFailed
    case hotReloadFailed
    case controllerDidNotRecover
    case healthVerificationFailed
    case rollbackFailed
    case profileMutationRecoveryFailed
    case profileDeletionCleanupFailed
    case transportFailed
    case cancelled
}

extension SubscriptionUpdateFailure: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .secretMissing: "Subscription credentials are missing."
        case .invalidURL: "The subscription URL is invalid."
        case .invalidUserAgent: "The selected subscription User-Agent is invalid."
        case .unsupportedScheme: "The subscription URL scheme is not supported."
        case .insecureHTTPNotAllowed: "This profile does not allow insecure HTTP."
        case .requestTimedOut: "The subscription request timed out."
        case .redirectLimitExceeded: "The subscription redirected too many times."
        case .insecureRedirect: "A secure subscription attempted to redirect to HTTP."
        case .authenticationFailed: "Subscription authentication failed."
        case .accessDenied:
            "The subscription server denied access for the current network route or client policy."
        case .notFound: "The subscription was not found."
        case .rateLimited: "The subscription server is rate limiting requests."
        case let .serverError(statusCode): "The subscription server failed (HTTP \(statusCode))."
        case let .unexpectedHTTPStatus(statusCode): "Unexpected HTTP status \(statusCode)."
        case let .responseTooLarge(_, limit): "The subscription exceeds the \(limit)-byte limit."
        case .emptyResponse: "The subscription response is empty."
        case .invalidEncoding: "The subscription is not valid UTF-8 text."
        case .htmlResponse:
            "The server returned HTML instead of Clash/Mihomo YAML. Confirm the URL is a direct subscription endpoint (use the raw file URL for GitHub), or try the Clash Verge User-Agent."
        case .unsupportedFormat:
            "Vela could not recognize or convert this subscription into a valid Clash/Mihomo configuration. Check the source format and conversion details, then retry."
        case .missingProxySection:
            "The YAML does not contain proxies or proxy-providers. Confirm the provider returned a Clash/Mihomo subscription."
        case .yamlParsingFailed: "The subscription is not a valid YAML mapping."
        case .runtimeBuildFailed: "The runtime configuration could not be built."
        case .configurationValidationFailed: "Mihomo rejected the candidate configuration."
        case .hotReloadFailed: "Mihomo could not apply the candidate configuration."
        case .controllerDidNotRecover: "The Mihomo controller did not recover after reload."
        case .healthVerificationFailed: "The updated engine did not pass its health check."
        case .rollbackFailed: "The previous configuration could not be restored."
        case .profileMutationRecoveryFailed:
            "Vela could not restore a consistent subscription profile state. Retry the profile operation."
        case .profileDeletionCleanupFailed:
            "The subscription profile was deleted, but its private staged files could not be cleaned up."
        case .transportFailed: "The subscription request failed."
        case .cancelled: "The subscription update was cancelled."
        }
    }
}

private extension String {
    nonisolated var nonEmpty: String? { isEmpty ? nil : self }
}
