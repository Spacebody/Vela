import Testing
@testable import Vela

@Suite("Proxy country flag resolution")
struct ProxyCountryFlagResolverTests {
    @Test("Common city names resolve to their country flags")
    func commonCityNames() {
        #expect(ProxyCountryFlagResolver.flag(for: "东京-高峰专线 01") == "🇯🇵")
        #expect(ProxyCountryFlagResolver.flag(for: "Los Angeles · US") == "🇺🇸")
        #expect(ProxyCountryFlagResolver.flag(for: "Frankfurt Premium") == "🇩🇪")
        #expect(ProxyCountryFlagResolver.flag(for: "新加坡-标准节点") == "🇸🇬")
    }

    @Test("ISO region codes resolve without a hand-maintained country list")
    func isoRegionCodes() {
        #expect(ProxyCountryFlagResolver.flag(for: "Node-JP-01") == "🇯🇵")
        #expect(ProxyCountryFlagResolver.flag(for: "Premium DE 02") == "🇩🇪")
        #expect(ProxyCountryFlagResolver.flag(for: "AU-Sydney-Edge") == "🇦🇺")
    }

    @Test("Embedded flags remain authoritative")
    func embeddedFlag() {
        #expect(ProxyCountryFlagResolver.flag(for: "🇹🇼 Taipei · TW") == "🇹🇼")
    }

    @Test("Non-geographic selectors do not invent a flag")
    func unknownSelector() {
        #expect(ProxyCountryFlagResolver.flag(for: "Auto Select") == nil)
        #expect(ProxyCountryFlagResolver.flag(for: "DIRECT") == nil)
    }
}
