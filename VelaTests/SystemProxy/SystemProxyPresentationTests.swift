import XCTest
@testable import Vela

nonisolated final class SystemProxyPresentationTests: XCTestCase {
    func testPACOnlyStateIncludesServiceName() throws {
        let target = SystemProxyTarget(host: "127.0.0.1", port: Int(7_890))
        let disabledHTTP = SystemProxyEndpointState(
            kind: .http,
            isEnabled: false,
            host: nil,
            port: nil
        )
        let status = SystemProxyStatus(
            target: target,
            aggregate: .externallyConfigured,
            services: [
                SystemProxyServiceState(
                    id: "wifi",
                    name: "Wi-Fi",
                    isServiceEnabled: true,
                    http: disabledHTTP,
                    https: SystemProxyEndpointState(
                        kind: .https,
                        isEnabled: false,
                        host: nil,
                        port: nil
                    ),
                    socks: SystemProxyEndpointState(
                        kind: .socks,
                        isEnabled: false,
                        host: nil,
                        port: nil
                    ),
                    automatic: SystemProxyAutomaticConfigurationState(
                        isAutoConfigurationEnabled: true,
                        autoConfigurationURL: "https://example.test/proxy.pac",
                        isAutoDiscoveryEnabled: false
                    ),
                    ownership: .untracked
                )
            ],
            recovery: .none
        )

        XCTAssertEqual(status.displayTitle, "On · External")
        let detail = try XCTUnwrap(status.displayDetail)
        XCTAssertTrue(detail.contains("Wi-Fi"))
    }
}
