import Foundation
import Testing
@testable import Vela

@Suite("Mihomo REST API client", .serialized)
nonisolated struct MihomoAPIClientTests {
    @Test("Core activation contract rejects a malformed critical endpoint")
    func coreActivationContractRejectsMalformedRules() async throws {
        MihomoMockURLProtocol.setHandler { request in
            switch request.url?.path {
            case "/version":
                MihomoMockHTTPResponse(
                    statusCode: 200,
                    data: Data(#"{"meta":true,"version":"1.19.28"}"#.utf8)
                )
            case "/configs":
                MihomoMockHTTPResponse(
                    statusCode: 200,
                    data: Data(Self.configsJSON.utf8)
                )
            case "/proxies":
                MihomoMockHTTPResponse(
                    statusCode: 200,
                    data: Data(#"{"proxies":{}}"#.utf8)
                )
            case "/rules":
                MihomoMockHTTPResponse(
                    statusCode: 200,
                    data: Data(#"{"rules":"not-an-array"}"#.utf8)
                )
            default:
                MihomoMockHTTPResponse(statusCode: 404)
            }
        }
        let (client, session) = try makeClient(maximumRetryCount: 0)
        defer {
            session.invalidateAndCancel()
            MihomoMockURLProtocol.reset()
        }

        do {
            try await CoreControllerAPIContractProbe(api: client).run()
            Issue.record("Expected the malformed /rules response to fail the Core contract")
        } catch let error as MihomoAPIError {
            guard case let .decodingFailed(endpoint, _) = error else {
                Issue.record("Unexpected API error: \(error)")
                return
            }
            #expect(endpoint == "/rules")
        }
    }

    @Test("Supported endpoints decode official response shapes and send Bearer auth")
    func successfulEndpoints() async throws {
        let recorder = MihomoRequestRecorder()
        MihomoMockURLProtocol.setHandler { request in
            recorder.record(Self.materializingBody(in: request))
            switch request.url?.path {
            case "/version":
                return MihomoMockHTTPResponse(
                    statusCode: 200,
                    data: Data(#"{"meta":true,"version":"1.19.28"}"#.utf8)
                )
            case "/configs" where request.httpMethod == "GET":
                return MihomoMockHTTPResponse(
                    statusCode: 200,
                    data: Data(Self.configsJSON.utf8)
                )
            case "/configs" where request.httpMethod == "PATCH":
                return MihomoMockHTTPResponse(statusCode: 204)
            case "/proxies":
                return MihomoMockHTTPResponse(
                    statusCode: 200,
                    data: Data(Self.proxiesJSON.utf8)
                )
            default:
                return MihomoMockHTTPResponse(statusCode: 404)
            }
        }
        let (client, session) = try makeClient(maximumRetryCount: 0)
        defer {
            session.invalidateAndCancel()
            MihomoMockURLProtocol.reset()
        }

        let version = try await client.version()
        let configs = try await client.configs()
        try await client.patchConfigs(
            MihomoConfigPatch(mixedPort: 17_891, mode: .global)
        )
        let proxies = try await client.proxies()

        #expect(version == MihomoVersion(meta: true, version: "1.19.28"))
        #expect(configs.mode == .rule)
        #expect(configs.mixedPort == 7_890)
        #expect(configs.allowLan == false)
        #expect(proxies.proxies["GLOBAL"]?.type == "Selector")
        #expect(proxies.proxies["GLOBAL"]?.now == "DIRECT")
        #expect(proxies.proxies["GLOBAL"]?.testURL == "https://example.com/generate_204")
        #expect(proxies.proxies["GLOBAL"]?.expectedStatus == "200/204")
        #expect(proxies.proxies["GLOBAL"]?.fixed == "DIRECT")
        #expect(proxies.proxies["GLOBAL"]?.hidden == false)
        #expect(proxies.proxies["GLOBAL"]?.icon == "https://example.com/icon.png")
        #expect(proxies.proxies["GLOBAL"]?.emptyFallback == "DIRECT")
        #expect(proxies.proxies["DIRECT"]?.type == "Direct")

        let requests = recorder.requests()
        #expect(requests.map { $0.url?.path } == [
            "/version", "/configs", "/configs", "/proxies",
        ])
        #expect(requests.allSatisfy {
            $0.value(forHTTPHeaderField: "Authorization") == "Bearer controller-secret"
        })
        #expect(requests.allSatisfy {
            $0.value(forHTTPHeaderField: "Accept") == "application/json"
        })

        let patchRequest = try #require(requests.first { $0.httpMethod == "PATCH" })
        #expect(patchRequest.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let patchData = try #require(patchRequest.httpBody)
        let patchObject = try #require(
            JSONSerialization.jsonObject(with: patchData) as? [String: Any]
        )
        #expect(patchObject["mode"] as? String == "global")
        #expect(patchObject["mixed-port"] as? Int == 17_891)
        #expect(patchObject["port"] == nil)
    }

    @Test("401 is typed and never retried")
    func unauthorizedIsNotRetried() async throws {
        let counter = MihomoRequestCounter()
        MihomoMockURLProtocol.setHandler { _ in
            _ = counter.increment()
            return MihomoMockHTTPResponse(
                statusCode: 401,
                data: Data(#"{"message":"Unauthorized"}"#.utf8)
            )
        }
        let (client, session) = try makeClient(maximumRetryCount: 3)
        defer {
            session.invalidateAndCancel()
            MihomoMockURLProtocol.reset()
        }

        do {
            _ = try await client.version()
            Issue.record("Expected unauthorized response")
        } catch let error as MihomoAPIError {
            guard case let .unauthorized(body) = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            #expect(body?.contains("Unauthorized") == true)
        }
        #expect(counter.value() == 1)
    }

    @Test("Proxy names are encoded as one RFC3986 path segment")
    func proxyNameUsesOneEncodedPathSegment() async throws {
        let recorder = MihomoRequestRecorder()
        MihomoMockURLProtocol.setHandler { request in
            recorder.record(request)
            return MihomoMockHTTPResponse(
                statusCode: 200,
                data: Data(Self.specialProxyJSON.utf8)
            )
        }
        let (client, session) = try makeClient(maximumRetryCount: 0)
        defer {
            session.invalidateAndCancel()
            MihomoMockURLProtocol.reset()
        }

        let proxy = try await client.proxy(named: Self.specialProxyName)

        #expect(proxy.name == Self.specialProxyName)
        let request = try #require(recorder.requests().first)
        let requestURL = try #require(request.url)
        let components = try #require(
            URLComponents(url: requestURL, resolvingAgainstBaseURL: false)
        )
        #expect(
            components.percentEncodedPath
                == "/proxies/Group%20%2F%20%E4%B8%AD%E6%96%87%3F%23%25"
        )
        #expect(request.httpMethod == "GET")
    }

    @Test("Provider endpoints decode v1.19.28 fixtures and encode every dynamic path segment")
    func providerEndpointContracts() async throws {
        let recorder = MihomoRequestRecorder()
        let providersFixture = try Self.fixtureData(
            named: "providers-proxies-v1.19.28.json"
        )
        MihomoMockURLProtocol.setHandler { request in
            recorder.record(request)
            let path = URLComponents(
                url: request.url ?? URL(fileURLWithPath: "/"),
                resolvingAgainstBaseURL: false
            )?.percentEncodedPath

            if request.httpMethod == "GET", path == "/providers/proxies" {
                return MihomoMockHTTPResponse(statusCode: 200, data: providersFixture)
            }
            if request.httpMethod == "GET", path == Self.encodedProviderPath {
                return MihomoMockHTTPResponse(
                    statusCode: 200,
                    data: Data(Self.specialProviderJSON.utf8)
                )
            }
            if request.httpMethod == "PUT", path == Self.encodedProviderPath {
                return MihomoMockHTTPResponse(statusCode: 204)
            }
            if request.httpMethod == "GET",
                path == Self.encodedProviderPath + "/healthcheck"
            {
                return MihomoMockHTTPResponse(statusCode: 204)
            }
            if request.httpMethod == "GET", path == Self.encodedProviderProxyPath {
                return MihomoMockHTTPResponse(
                    statusCode: 200,
                    data: Data(Self.specialProviderProxyJSON.utf8)
                )
            }
            if request.httpMethod == "GET",
                path == Self.encodedProviderProxyPath + "/healthcheck"
            {
                return MihomoMockHTTPResponse(
                    statusCode: 200,
                    data: Data(#"{"delay":64}"#.utf8)
                )
            }
            return MihomoMockHTTPResponse(statusCode: 404)
        }
        let (client, session) = try makeClient(maximumRetryCount: 3)
        defer {
            session.invalidateAndCancel()
            MihomoMockURLProtocol.reset()
        }
        let testURL = "https://example.com/generate_204?label=中文#fragment"

        let providers = try await client.proxyProviders()
        let provider = try await client.proxyProvider(named: Self.specialProviderName)
        try await client.updateProxyProvider(named: Self.specialProviderName)
        try await client.healthCheckProxyProvider(named: Self.specialProviderName)
        let proxy = try await client.proxyProviderProxy(
            provider: Self.specialProviderName,
            name: Self.specialProviderProxyName
        )
        let delay = try await client.proxyProviderProxyDelay(
            provider: Self.specialProviderName,
            name: Self.specialProviderProxyName,
            url: testURL,
            timeoutMilliseconds: 5_000,
            expectedStatus: "200-299"
        )

        #expect(providers.providers["Provider A"]?.proxies.count == 3)
        #expect(providers.providers["Provider A"]?.subscriptionInfo == MihomoSubscriptionInfo(
            upload: 1,
            download: 2,
            total: 3,
            expire: 4
        ))
        #expect(providers.providers["Partial Provider"]?.name == nil)
        #expect(providers.providers["Partial Provider"]?.type == nil)
        #expect(provider.name == Self.specialProviderName)
        #expect(proxy.name == Self.specialProviderProxyName)
        #expect(delay.delay == 64)

        let requests = recorder.requests()
        #expect(requests.map(\.httpMethod) == ["GET", "GET", "PUT", "GET", "GET", "GET"])
        #expect(requests.compactMap { request in
            URLComponents(url: request.url ?? URL(fileURLWithPath: "/"), resolvingAgainstBaseURL: false)?
                .percentEncodedPath
        } == [
            "/providers/proxies",
            Self.encodedProviderPath,
            Self.encodedProviderPath,
            Self.encodedProviderPath + "/healthcheck",
            Self.encodedProviderProxyPath,
            Self.encodedProviderProxyPath + "/healthcheck",
        ])
        #expect(requests.allSatisfy {
            $0.value(forHTTPHeaderField: "Authorization") == "Bearer controller-secret"
        })

        let delayRequest = try #require(requests.last)
        let delayURL = try #require(delayRequest.url)
        let components = try #require(
            URLComponents(url: delayURL, resolvingAgainstBaseURL: false)
        )
        let query = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
                item.value.map { (item.name, $0) }
            }
        )
        #expect(query == [
            "url": testURL,
            "timeout": "5000",
            "expected": "200-299",
        ])
        #expect(delayRequest.timeoutInterval == 6)
    }

    @Test("Proxy selection safely encodes the group and sends the exact JSON body")
    func selectProxyRequestContract() async throws {
        let recorder = MihomoRequestRecorder()
        MihomoMockURLProtocol.setHandler { request in
            recorder.record(Self.materializingBody(in: request))
            return MihomoMockHTTPResponse(statusCode: 204)
        }
        let (client, session) = try makeClient(maximumRetryCount: 3)
        defer {
            session.invalidateAndCancel()
            MihomoMockURLProtocol.reset()
        }

        try await client.selectProxy(
            group: Self.specialProxyName,
            proxy: "节点 / A?#%"
        )

        let request = try #require(recorder.requests().first)
        let requestURL = try #require(request.url)
        let components = try #require(
            URLComponents(url: requestURL, resolvingAgainstBaseURL: false)
        )
        #expect(
            components.percentEncodedPath
                == "/proxies/Group%20%2F%20%E4%B8%AD%E6%96%87%3F%23%25"
        )
        #expect(request.httpMethod == "PUT")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try #require(request.httpBody)
        let object = try #require(
            JSONSerialization.jsonObject(with: body) as? [String: String]
        )
        #expect(object == ["name": "节点 / A?#%"])
        #expect(recorder.requests().count == 1)
    }

    @Test("Proxy selection is never retried after an ambiguous transport failure")
    func selectProxyTransportFailureIsNotRetried() async throws {
        let counter = MihomoRequestCounter()
        MihomoMockURLProtocol.setHandler { _ in
            _ = counter.increment()
            throw URLError(.networkConnectionLost)
        }
        let (client, session) = try makeClient(maximumRetryCount: 3)
        defer {
            session.invalidateAndCancel()
            MihomoMockURLProtocol.reset()
        }

        do {
            try await client.selectProxy(group: "GLOBAL", proxy: "DIRECT")
            Issue.record("Expected an ambiguous proxy-selection failure")
        } catch let error as MihomoAPIError {
            guard case let .transport(code, _) = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            #expect(code == .networkConnectionLost)
        }

        #expect(counter.value() == 1)
    }

    @Test("Proxy delay encodes path and query, decodes delay, and uses timeout plus margin")
    func proxyDelayRequestContract() async throws {
        let recorder = MihomoRequestRecorder()
        MihomoMockURLProtocol.setHandler { request in
            recorder.record(request)
            return MihomoMockHTTPResponse(
                statusCode: 200,
                data: Data(#"{"delay":87}"#.utf8)
            )
        }
        let (client, session) = try makeClient(maximumRetryCount: 3)
        defer {
            session.invalidateAndCancel()
            MihomoMockURLProtocol.reset()
        }
        let testURL = "https://example.com/generate_204?a=1&label=中文#fragment"

        let result = try await client.proxyDelay(
            name: Self.specialProxyName,
            url: testURL,
            timeoutMilliseconds: 5_000,
            expectedStatus: "200/204"
        )

        #expect(result == MihomoProxyDelayResponse(delay: 87))
        let request = try #require(recorder.requests().first)
        let requestURL = try #require(request.url)
        let components = try #require(
            URLComponents(url: requestURL, resolvingAgainstBaseURL: false)
        )
        #expect(
            components.percentEncodedPath
                == "/proxies/Group%20%2F%20%E4%B8%AD%E6%96%87%3F%23%25/delay"
        )
        let query = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
                item.value.map { (item.name, $0) }
            }
        )
        #expect(query["url"] == testURL)
        #expect(query["timeout"] == "5000")
        #expect(query["expected"] == "200/204")
        #expect(request.timeoutInterval == 6)
        #expect(request.httpMethod == "GET")
    }

    @Test("Proxy delay is not retried even though it uses GET")
    func proxyDelayFailureIsNotRetried() async throws {
        let counter = MihomoRequestCounter()
        MihomoMockURLProtocol.setHandler { _ in
            _ = counter.increment()
            return MihomoMockHTTPResponse(
                statusCode: 503,
                data: Data(#"{"message":"An error occurred in the delay test"}"#.utf8)
            )
        }
        let (client, session) = try makeClient(maximumRetryCount: 3)
        defer {
            session.invalidateAndCancel()
            MihomoMockURLProtocol.reset()
        }

        do {
            _ = try await client.proxyDelay(
                name: "DIRECT",
                url: "https://example.com/generate_204",
                timeoutMilliseconds: 5_000,
                expectedStatus: nil
            )
            Issue.record("Expected proxy-delay failure")
        } catch let error as MihomoAPIError {
            guard case let .httpStatus(code, _) = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            #expect(code == 503)
        }

        #expect(counter.value() == 1)
    }

    @Test("Proxy delay rejects timeout values outside Mihomo's signed 16-bit contract")
    func proxyDelayTimeoutValidation() async throws {
        let counter = MihomoRequestCounter()
        MihomoMockURLProtocol.setHandler { _ in
            _ = counter.increment()
            return MihomoMockHTTPResponse(statusCode: 200)
        }
        let (client, session) = try makeClient(maximumRetryCount: 0)
        defer {
            session.invalidateAndCancel()
            MihomoMockURLProtocol.reset()
        }

        do {
            _ = try await client.proxyDelay(
                name: "DIRECT",
                url: "https://example.com",
                timeoutMilliseconds: 32_768,
                expectedStatus: nil
            )
            Issue.record("Expected timeout validation failure")
        } catch let error as MihomoRequestValidationError {
            #expect(error == .invalidDelayTimeout(milliseconds: 32_768))
        }

        #expect(counter.value() == 0)
    }

    @Test("500 responses use only the configured finite retries")
    func serverErrorRetriesAreFinite() async throws {
        let counter = MihomoRequestCounter()
        MihomoMockURLProtocol.setHandler { _ in
            _ = counter.increment()
            return MihomoMockHTTPResponse(
                statusCode: 500,
                data: Data(#"{"message":"temporary failure"}"#.utf8)
            )
        }
        let (client, session) = try makeClient(maximumRetryCount: 2)
        defer {
            session.invalidateAndCancel()
            MihomoMockURLProtocol.reset()
        }

        do {
            _ = try await client.version()
            Issue.record("Expected server error")
        } catch let error as MihomoAPIError {
            guard case let .httpStatus(code, body) = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            #expect(code == 500)
            #expect(body?.contains("temporary failure") == true)
        }
        #expect(counter.value() == 3)
    }

    @Test("Retry delay backs off exponentially and stays bounded")
    func retryDelayUsesBoundedExponentialBackoff() {
        let policy = MihomoRetryPolicy(
            maximumRetryCount: 6,
            retryDelay: .milliseconds(100),
            maximumRetryDelay: .milliseconds(500)
        )

        #expect((1...6).map(policy.delay(forRetry:)) == [
            .milliseconds(100),
            .milliseconds(200),
            .milliseconds(400),
            .milliseconds(500),
            .milliseconds(500),
            .milliseconds(500),
        ])
        #expect(policy.delay(forRetry: 0) == .milliseconds(100))

        let zeroDelay = MihomoRetryPolicy(
            maximumRetryCount: 1,
            retryDelay: .seconds(-1),
            maximumRetryDelay: .seconds(-2)
        )
        #expect(zeroDelay.retryDelay == .zero)
        #expect(zeroDelay.maximumRetryDelay == .zero)
        #expect(zeroDelay.delay(forRetry: 1) == .zero)
    }

    @Test("Transient transport failures retry and can recover")
    func transientTransportRetries() async throws {
        let counter = MihomoRequestCounter()
        MihomoMockURLProtocol.setHandler { _ in
            let attempt = counter.increment()
            if attempt < 3 {
                throw URLError(.networkConnectionLost)
            }
            return MihomoMockHTTPResponse(
                statusCode: 200,
                data: Data(#"{"meta":true,"version":"1.19.28"}"#.utf8)
            )
        }
        let (client, session) = try makeClient(maximumRetryCount: 2)
        defer {
            session.invalidateAndCancel()
            MihomoMockURLProtocol.reset()
        }

        let version = try await client.version()

        #expect(version.version == "1.19.28")
        #expect(counter.value() == 3)
    }

    @Test("PATCH is not replayed after an ambiguous transport failure")
    func patchTransportFailureIsNotRetried() async throws {
        let counter = MihomoRequestCounter()
        MihomoMockURLProtocol.setHandler { request in
            #expect(request.httpMethod == "PATCH")
            _ = counter.increment()
            throw URLError(.networkConnectionLost)
        }
        let (client, session) = try makeClient(maximumRetryCount: 3)
        defer {
            session.invalidateAndCancel()
            MihomoMockURLProtocol.reset()
        }

        do {
            try await client.patchConfigs(MihomoConfigPatch(mode: .global))
            Issue.record("Expected an ambiguous PATCH transport failure")
        } catch let error as MihomoAPIError {
            guard case let .transport(code, _) = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            #expect(code == .networkConnectionLost)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(counter.value() == 1)
    }

    @Test("Timeout is returned as a typed transport error")
    func timeoutIsTyped() async throws {
        let counter = MihomoRequestCounter()
        MihomoMockURLProtocol.setHandler { _ in
            _ = counter.increment()
            throw URLError(.timedOut)
        }
        let (client, session) = try makeClient(maximumRetryCount: 0)
        defer {
            session.invalidateAndCancel()
            MihomoMockURLProtocol.reset()
        }

        do {
            _ = try await client.version()
            Issue.record("Expected timeout")
        } catch let error as MihomoAPIError {
            guard case let .transport(code, _) = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            #expect(code == .timedOut)
        }
        #expect(counter.value() == 1)
    }

    @Test("Decoding failures are typed and never retried")
    func decodingFailureIsNotRetried() async throws {
        let counter = MihomoRequestCounter()
        MihomoMockURLProtocol.setHandler { _ in
            _ = counter.increment()
            return MihomoMockHTTPResponse(
                statusCode: 200,
                data: Data(#"{"meta":true,"version":19}"#.utf8)
            )
        }
        let (client, session) = try makeClient(maximumRetryCount: 3)
        defer {
            session.invalidateAndCancel()
            MihomoMockURLProtocol.reset()
        }

        do {
            _ = try await client.version()
            Issue.record("Expected decoding failure")
        } catch let error as MihomoAPIError {
            guard case let .decodingFailed(endpoint, _) = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            #expect(endpoint == "/version")
        }
        #expect(counter.value() == 1)
    }

    @Test("Cancelling the caller cancels the in-flight request without retry")
    func cancellation() async throws {
        MihomoHangingURLProtocol.reset()
        let (client, session) = try makeClient(
            maximumRetryCount: 3,
            protocolClass: MihomoHangingURLProtocol.self
        )
        defer {
            session.invalidateAndCancel()
            MihomoHangingURLProtocol.reset()
        }

        let requestTask = Task {
            try await client.version()
        }
        guard await MihomoHangingURLProtocol.waitUntilStarted() else {
            requestTask.cancel()
            _ = try? await requestTask.value
            Issue.record("Timed out waiting for the mock request")
            return
        }
        requestTask.cancel()

        do {
            _ = try await requestTask.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {
            // Native cancellation is preserved for structured-concurrency callers.
        }
        #expect(MihomoHangingURLProtocol.startCount() == 1)
    }

    @Test("Hanging mock request waits have a bounded, one-shot deadline")
    func hangingRequestWaitDeadline() async throws {
        MihomoHangingURLProtocol.reset()
        defer { MihomoHangingURLProtocol.reset() }

        let didStart = await MihomoHangingURLProtocol.waitUntilStarted(
            timeout: .milliseconds(1)
        )
        #expect(!didStart)
        #expect(MihomoHangingURLProtocol.pendingStartWaiterCount() == 0)

        let request = try #require(URL(string: "http://127.0.0.1:9090/version"))
        let lateProtocol = MihomoHangingURLProtocol(
            request: URLRequest(url: request),
            cachedResponse: nil,
            client: nil
        )
        lateProtocol.startLoading()

        #expect(MihomoHangingURLProtocol.startCount() == 1)
        #expect(MihomoHangingURLProtocol.pendingStartWaiterCount() == 0)
    }

    @Test("V0.2 read endpoints decode the supplied Mihomo fixtures")
    func v02ReadEndpointContracts() async throws {
        let recorder = MihomoRequestRecorder()
        let ruleProvidersFixture = try Self.fixtureData(named: "rule-providers-v0.2.json")
        let connectionsFixture = try Self.fixtureData(named: "connections-snapshot-v0.2.json")
        let rulesFixture = try Self.fixtureData(named: "rules-v0.2.json")
        MihomoMockURLProtocol.setHandler { request in
            recorder.record(request)
            switch request.url?.path {
            case "/providers/rules":
                return MihomoMockHTTPResponse(statusCode: 200, data: ruleProvidersFixture)
            case "/connections":
                return MihomoMockHTTPResponse(statusCode: 200, data: connectionsFixture)
            case "/rules":
                return MihomoMockHTTPResponse(statusCode: 200, data: rulesFixture)
            default:
                return MihomoMockHTTPResponse(statusCode: 404)
            }
        }
        let (client, session) = try makeClient(maximumRetryCount: 0)
        defer {
            session.invalidateAndCancel()
            MihomoMockURLProtocol.reset()
        }

        let providers = try await client.ruleProviders()
        let connections = try await client.connections()
        let rules = try await client.rules()

        #expect(providers.providers["private"]?.ruleCount == 42)
        #expect(providers.providers["inline-rules"]?.payload?.count == 2)
        #expect(connections.connections.count == 2)
        #expect(connections.connections[0].metadata.sourcePort == 54_321)
        #expect(connections.connections[1].metadata.sourcePort == 55_001)
        #expect(rules.rules.map(\.index) == [0, 1, 2])
        #expect(rules.rules[2].extra?.hitAt == nil)

        #expect(recorder.requests().map(\.httpMethod) == ["GET", "GET", "GET"])
        #expect(recorder.requests().compactMap { $0.url?.path } == [
            "/providers/rules", "/connections", "/rules",
        ])
    }

    @Test("V0.2 mutations encode paths and bodies exactly and accept 204")
    func v02MutationContracts() async throws {
        let recorder = MihomoRequestRecorder()
        MihomoMockURLProtocol.setHandler { request in
            recorder.record(Self.materializingBody(in: request))
            return MihomoMockHTTPResponse(statusCode: 204)
        }
        let (client, session) = try makeClient(maximumRetryCount: 3)
        defer {
            session.invalidateAndCancel()
            MihomoMockURLProtocol.reset()
        }
        let configurationURL = URL(fileURLWithPath: "/tmp/Vela runtime/active.yaml")

        try await client.updateRuleProvider(named: Self.specialRuleProviderName)
        try await client.closeConnection(id: Self.specialConnectionID)
        try await client.closeAllConnections()
        try await client.setRulesDisabled([18: false, 12: true])
        try await client.reloadConfiguration(at: configurationURL, force: false)
        try await client.updateGeoDatabases()

        let requests = recorder.requests()
        #expect(requests.map(\.httpMethod) == ["PUT", "DELETE", "DELETE", "PATCH", "PUT", "POST"])
        #expect(requests.compactMap { request in
            URLComponents(
                url: request.url ?? URL(fileURLWithPath: "/"),
                resolvingAgainstBaseURL: false
            )?.percentEncodedPath
        } == [
            Self.encodedRuleProviderPath,
            Self.encodedConnectionPath,
            "/connections",
            "/rules/disable",
            "/configs",
            "/configs/geo",
        ])
        #expect(requests.allSatisfy {
            $0.value(forHTTPHeaderField: "Authorization") == "Bearer controller-secret"
        })

        let ruleRequest = requests[3]
        #expect(ruleRequest.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let ruleBody = try #require(ruleRequest.httpBody)
        let ruleObject = try #require(
            JSONSerialization.jsonObject(with: ruleBody) as? [String: Bool]
        )
        #expect(ruleObject == ["12": true, "18": false])

        let reloadRequest = requests[4]
        let reloadURL = try #require(reloadRequest.url)
        let reloadComponents = try #require(
            URLComponents(url: reloadURL, resolvingAgainstBaseURL: false)
        )
        #expect(reloadComponents.queryItems == [URLQueryItem(name: "force", value: "false")])
        #expect(reloadRequest.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let reloadBody = try #require(reloadRequest.httpBody)
        let reloadObject = try #require(
            JSONSerialization.jsonObject(with: reloadBody) as? [String: String]
        )
        #expect(reloadObject == ["path": configurationURL.standardizedFileURL.path])

        #expect(requests[5].timeoutInterval == MihomoAPIClient.geoUpdateRequestTimeout)
        #expect(requests[5].httpBody == nil)
    }

    @Test("Every V0.2 mutation is attempted once after an ambiguous 503")
    func v02MutationsAreNotRetried() async throws {
        let recorder = MihomoRequestRecorder()
        MihomoMockURLProtocol.setHandler { request in
            recorder.record(request)
            return MihomoMockHTTPResponse(
                statusCode: 503,
                data: Data(#"{"message":"ambiguous"}"#.utf8)
            )
        }
        let (client, session) = try makeClient(maximumRetryCount: 3)
        defer {
            session.invalidateAndCancel()
            MihomoMockURLProtocol.reset()
        }

        let operations: [@Sendable () async throws -> Void] = [
            { try await client.updateRuleProvider(named: "rules") },
            { try await client.closeConnection(id: "connection") },
            { try await client.closeAllConnections() },
            { try await client.setRulesDisabled([3: true]) },
            { try await client.reloadConfiguration(
                at: URL(fileURLWithPath: "/tmp/active.yaml"),
                force: false
            ) },
            { try await client.updateGeoDatabases() },
        ]

        for operation in operations {
            do {
                try await operation()
                Issue.record("Expected an HTTP 503 mutation failure")
            } catch let error as MihomoAPIError {
                guard case let .httpStatus(code, _) = error else {
                    Issue.record("Unexpected error: \(error)")
                    continue
                }
                #expect(code == 503)
            }
        }

        #expect(recorder.requests().count == operations.count)
    }

    private func makeClient(
        maximumRetryCount: Int,
        protocolClass: AnyClass = MihomoMockURLProtocol.self
    ) throws -> (MihomoAPIClient, URLSession) {
        guard let baseURL = URL(string: "http://127.0.0.1:9090") else {
            throw MihomoAPIClientTestError.invalidBaseURL
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [protocolClass]
        let session = URLSession(configuration: configuration)
        let client = MihomoAPIClient(
            baseURL: baseURL,
            secret: "controller-secret",
            session: session,
            retryPolicy: MihomoRetryPolicy(
                maximumRetryCount: maximumRetryCount,
                retryDelay: .zero
            ),
            requestTimeout: 1
        )
        return (client, session)
    }

    private static func materializingBody(in request: URLRequest) -> URLRequest {
        guard request.httpBody == nil, let stream = request.httpBodyStream else {
            return request
        }

        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)

        while true {
            let bytesRead = buffer.withUnsafeMutableBufferPointer { pointer in
                guard let baseAddress = pointer.baseAddress else { return 0 }
                return stream.read(baseAddress, maxLength: pointer.count)
            }
            guard bytesRead > 0 else { break }
            data.append(contentsOf: buffer.prefix(bytesRead))
        }

        var materialized = request
        materialized.httpBodyStream = nil
        materialized.httpBody = data
        return materialized
    }

    private static func fixtureData(named name: String) throws -> Data {
        guard let bundledURL = Bundle(for: MihomoMockURLProtocol.self).url(
            forResource: name,
            withExtension: nil
        ) else {
            throw MihomoAPIClientTestError.missingFixture(name)
        }
        return try Data(contentsOf: bundledURL)
    }

    private static let configsJSON = #"""
    {
      "port": 0,
      "socks-port": 0,
      "redir-port": 0,
      "tproxy-port": 0,
      "mixed-port": 7890,
      "allow-lan": false,
      "bind-address": "*",
      "mode": "rule",
      "log-level": "info",
      "ipv6": true,
      "unified-delay": false,
      "tcp-concurrent": true,
      "find-process-mode": "strict",
      "interface-name": "",
      "sniffing": false
    }
    """#

    private static let proxiesJSON = #"""
    {
      "proxies": {
        "GLOBAL": {
          "id": "group-id",
          "name": "GLOBAL",
          "type": "Selector",
          "alive": true,
          "udp": true,
          "now": "DIRECT",
          "all": ["DIRECT"],
          "testUrl": "https://example.com/generate_204",
          "expectedStatus": "200/204",
          "fixed": "DIRECT",
          "hidden": false,
          "icon": "https://example.com/icon.png",
          "emptyFallback": "DIRECT",
          "history": [],
          "extra": {}
        },
        "DIRECT": {
          "id": "direct-id",
          "name": "DIRECT",
          "type": "Direct",
          "alive": true,
          "udp": true,
          "uot": false,
          "xudp": false,
          "tfo": false,
          "mptcp": false,
          "smux": false,
          "interface": "",
          "routing-mark": 0,
          "provider-name": "",
          "dialer-proxy": "",
          "history": [
            {"time": "2026-07-11T07:00:00Z", "delay": 12}
          ],
          "extra": {}
        }
      }
    }
    """#

    private static let specialProxyName = "Group / 中文?#%"

    private static let specialProviderName = "Provider / 中文?#%"
    private static let specialProviderProxyName = "Node / 日本?#%"
    private static let encodedProviderPath =
        "/providers/proxies/Provider%20%2F%20%E4%B8%AD%E6%96%87%3F%23%25"
    private static let encodedProviderProxyPath = encodedProviderPath
        + "/Node%20%2F%20%E6%97%A5%E6%9C%AC%3F%23%25"

    private static let specialRuleProviderName = "Rules / 中文?#%"
    private static let encodedRuleProviderPath =
        "/providers/rules/Rules%20%2F%20%E4%B8%AD%E6%96%87%3F%23%25"
    private static let specialConnectionID = "Connection / 日本?#%"
    private static let encodedConnectionPath =
        "/connections/Connection%20%2F%20%E6%97%A5%E6%9C%AC%3F%23%25"

    private static let specialProviderJSON = #"""
    {
      "name": "Provider / 中文?#%",
      "type": "Proxy",
      "vehicleType": "HTTP",
      "proxies": [
        {"name": "Node / 日本?#%", "type": "Trojan", "alive": true}
      ],
      "testUrl": "https://example.com/generate_204",
      "expectedStatus": "200-299"
    }
    """#

    private static let specialProviderProxyJSON = #"""
    {
      "name": "Node / 日本?#%",
      "type": "Trojan",
      "alive": true,
      "provider-name": "Provider / 中文?#%"
    }
    """#

    private static let specialProxyJSON = #"""
    {
      "name": "Group / 中文?#%",
      "type": "Selector",
      "alive": true,
      "now": "DIRECT",
      "all": ["DIRECT"],
      "history": [],
      "extra": {}
    }
    """#
}

nonisolated private enum MihomoAPIClientTestError: Error {
    case invalidBaseURL
    case missingFixture(String)
}
