import Foundation
import Synchronization
import Testing
@testable import Vela

@Suite("Remote profile URL draft policy", .serialized)
struct RemoteProfileURLDraftPolicyTests {
    @Test("An unchanged normalized URL does not request a replacement")
    func unchangedURLDoesNotRequestReplacement() throws {
        let currentURL = try #require(URL(string: "https://example.com/subscription?token=value"))
        let draft = try SubscriptionURLNormalizer.normalizeWithAuthentication(
            "HTTPS://example.com/subscription?token=value"
        )

        let replacement = RemoteProfileURLDraftPolicy.replacement(
            currentURL: currentURL,
            normalizedDraft: draft
        )

        #expect(replacement == nil)
    }

    @Test("A changed URL requests replacement with the normalized value")
    func changedURLRequestsReplacement() throws {
        let currentURL = try #require(URL(string: "https://example.com/old"))
        let draft = try SubscriptionURLNormalizer.normalizeWithAuthentication(
            "example.com/new?token=updated"
        )

        let replacement = try #require(
            RemoteProfileURLDraftPolicy.replacement(
                currentURL: currentURL,
                normalizedDraft: draft
            )
        )

        #expect(replacement.url.absoluteString == "https://example.com/new?token=updated")
        #expect(replacement.embeddedAuthentication == nil)
    }

    @Test("Embedded credentials on the same URL remain an explicit edit")
    func embeddedCredentialsRemainExplicitEdit() throws {
        let currentURL = try #require(URL(string: "https://example.com/subscription"))
        let draft = try SubscriptionURLNormalizer.normalizeWithAuthentication(
            "https://user:pass@example.com/subscription"
        )

        let replacement = try #require(
            RemoteProfileURLDraftPolicy.replacement(
                currentURL: currentURL,
                normalizedDraft: draft
            )
        )

        #expect(replacement.url == currentURL)
        #expect(replacement.embeddedAuthentication == .basic(username: "user", password: "pass"))
    }

    @Test("A provider URL with query parameters appended to its path is repaired")
    func dirtyProviderURLIsRepaired() throws {
        let normalized = try SubscriptionURLNormalizer.normalize(
            "https://example.com/subscription&token=abc%20123&type=clash"
        )

        #expect(normalized.path == "/subscription")
        #expect(normalized.query == "token=abc%20123&type=clash")
    }

    @Test("An existing query is never rewritten as a dirty path")
    func existingQueryIsPreserved() throws {
        let normalized = try SubscriptionURLNormalizer.normalize(
            "https://example.com/subscription?token=abc&name=value"
        )

        #expect(normalized.absoluteString == "https://example.com/subscription?token=abc&name=value")
    }

    @Test("Proxy attempts start with the configured route and then use Clash-compatible fallbacks")
    func proxyAttemptOrder() {
        #expect(
            SubscriptionProxyAttemptPolicy.modes(configured: .direct, allowsFallback: true)
                == [.direct, .vela, .system]
        )
        #expect(
            SubscriptionProxyAttemptPolicy.modes(configured: .vela, allowsFallback: true)
                == [.vela, .system]
        )
        #expect(
            SubscriptionProxyAttemptPolicy.modes(configured: .system, allowsFallback: true)
                == [.system, .vela]
        )
        #expect(
            SubscriptionProxyAttemptPolicy.modes(configured: .system, allowsFallback: false)
                == [.system]
        )
    }

    @Test("Route-dependent failures retry while unsafe or cancelled requests stop")
    func proxyRetryClassification() {
        #expect(SubscriptionProxyAttemptPolicy.shouldTryNext(after: .accessDenied))
        #expect(SubscriptionProxyAttemptPolicy.shouldTryNext(after: .authenticationFailed))
        #expect(SubscriptionProxyAttemptPolicy.shouldTryNext(after: .transportFailed))
        #expect(!SubscriptionProxyAttemptPolicy.shouldTryNext(after: .invalidURL))
        #expect(!SubscriptionProxyAttemptPolicy.shouldTryNext(after: .cancelled))
    }

    @Test("HTTP authorization failures distinguish credentials from provider policy")
    func authorizationStatusClassification() {
        #expect(
            SubscriptionHTTPStatusPolicy.failure(statusCode: 401)
                == .authenticationFailed
        )
        #expect(SubscriptionHTTPStatusPolicy.failure(statusCode: 403) == .accessDenied)
        #expect(SubscriptionHTTPStatusPolicy.failure(statusCode: 204) == nil)
    }

    @Test("A provider denial retries through the next subscription route")
    func accessDeniedRetriesThroughNextRoute() async throws {
        let requestCounter = MihomoRequestCounter()
        RemoteProfileMockURLProtocol.setHandler { _ in
            let attempt = requestCounter.increment()
            if attempt == 1 {
                return MihomoMockHTTPResponse(statusCode: 403)
            }
            return MihomoMockHTTPResponse(
                statusCode: 200,
                headers: ["Content-Type": "application/yaml"],
                data: Data(
                    """
                    proxies:
                      - name: Direct
                        type: direct
                    """.utf8
                )
            )
        }
        defer { RemoteProfileMockURLProtocol.reset() }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RemoteProfileMockURLProtocol.self]
        let client = SubscriptionHTTPClient(configuration: configuration)
        let url = try #require(URL(string: "https://example.com/subscription"))
        let outcome = try await client.fetch(
            SubscriptionHTTPRequest(
                secret: SubscriptionSecretEnvelope(url: url),
                allowsProxyFallback: true
            )
        )

        #expect(requestCounter.value() == 2)
        guard case .downloaded = outcome else {
            Issue.record("The fallback route should download the subscription.")
            return
        }
    }

    @Test("Clash Verge compatibility sends the upstream identity without a Vela Accept fingerprint")
    func clashVergeCompatibilityRequestHeaders() async throws {
        RemoteProfileMockURLProtocol.setHandler { request in
            #expect(
                request.value(forHTTPHeaderField: "User-Agent")
                    == ClashVergeSubscriptionCompatibility.userAgent
            )
            #expect(request.value(forHTTPHeaderField: "Accept") == nil)
            return MihomoMockHTTPResponse(
                statusCode: 200,
                headers: ["Content-Type": "text/html; charset=utf-8"],
                data: Data(
                    """
                    proxies:
                      - name: Direct
                        type: direct
                    """.utf8
                )
            )
        }
        defer { RemoteProfileMockURLProtocol.reset() }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RemoteProfileMockURLProtocol.self]
        let client = SubscriptionHTTPClient(configuration: configuration)
        let url = try #require(URL(string: "https://example.com/one-shot.jpg"))
        let outcome = try await client.fetch(
            SubscriptionHTTPRequest(secret: SubscriptionSecretEnvelope(url: url))
        )

        guard case .downloaded = outcome else {
            Issue.record(
                "The Clash Verge-compatible request should accept YAML with a misleading content type."
            )
            return
        }
    }
}

/// Subscription tests intentionally use a URLProtocol class distinct from the
/// Controller API suite. Swift Testing may execute separate serialized suites
/// concurrently, so sharing `MihomoMockURLProtocol` would still let one suite
/// replace another suite's static handler.
nonisolated private final class RemoteProfileMockURLProtocol: URLProtocol,
    @unchecked Sendable
{
    typealias Handler = @Sendable (URLRequest) throws -> MihomoMockHTTPResponse

    private static let handlerStorage = Mutex<Handler?>(nil)

    static func setHandler(_ handler: @escaping Handler) {
        handlerStorage.withLock { $0 = handler }
    }

    static func reset() {
        handlerStorage.withLock { $0 = nil }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handlerStorage.withLock({ $0 }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let stub = try handler(request)
            guard let url = request.url,
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: stub.statusCode,
                    httpVersion: "HTTP/1.1",
                    headerFields: stub.headers
                )
            else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !stub.data.isEmpty {
                client?.urlProtocol(self, didLoad: stub.data)
            }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
