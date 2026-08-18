import Foundation
import Testing
@testable import VelaPrivilegedCore

@Suite("Owned TUN route probing")
struct PrivilegedRouteProbeTests {
    @Test("Probe selection skips an address covered by route exclusions")
    func selectionSkipsExcludedAddress() throws {
        let selected = try #require(PrivilegedRouteProbeSelector.select(excluding: [
            "1.1.1.0/24",
            "2001:db8::/32",
        ]))

        #expect(selected == "8.8.8.8")
        #expect(!PrivilegedRouteProbeSelector.contains(
            address: selected,
            cidr: "1.1.1.0/24"
        ))
    }

    @Test("A configuration excluding every safe probe fails closed")
    func selectionFailsWhenAllCandidatesAreExcluded() {
        #expect(PrivilegedRouteProbeSelector.select(excluding: ["0.0.0.0/0"]) == nil)
    }

    @Test("No route while offline is clean after the owned interface disappeared")
    func noRouteIsClean() async {
        let verifier = PrivilegedRouteCleanupVerifier(
            prober: RouteProberFake(result: .noRoute)
        )

        #expect(await verifier.waitForRemoval(
            address: "1.1.1.1",
            interface: "utun42",
            timeout: .zero
        ))
    }

    @Test("A route on another interface is clean after the owned interface disappeared")
    func otherInterfaceIsClean() async {
        let verifier = PrivilegedRouteCleanupVerifier(
            prober: RouteProberFake(result: .otherInterface)
        )

        #expect(await verifier.waitForRemoval(
            address: "1.1.1.1",
            interface: "utun42",
            timeout: .zero
        ))
    }

    @Test("A residual route to the owned interface fails closed")
    func residualOwnedRouteIsNotClean() async {
        let verifier = PrivilegedRouteCleanupVerifier(
            prober: RouteProberFake(result: .usesOwnedInterface)
        )

        #expect(!(await verifier.waitForRemoval(
            address: "1.1.1.1",
            interface: "utun42",
            timeout: .zero
        )))
    }

    @Test("A timed out or malformed route probe remains fail closed")
    func unavailableProbeIsNotClean() async {
        let verifier = PrivilegedRouteCleanupVerifier(
            prober: RouteProberFake(result: .unavailable)
        )

        #expect(!(await verifier.waitForRemoval(
            address: "1.1.1.1",
            interface: "utun42",
            timeout: .zero
        )))
    }

    @Test("Only an ASCII utun name with at least one digit is accepted")
    func ownedInterfaceValidationIsStrict() {
        #expect(PrivilegedTunInterfaceValidator.isValid("utun0"))
        #expect(PrivilegedTunInterfaceValidator.isValid("utun42"))
        #expect(!PrivilegedTunInterfaceValidator.isValid("utun"))
        #expect(!PrivilegedTunInterfaceValidator.isValid("utun-1"))
        #expect(!PrivilegedTunInterfaceValidator.isValid("utun١"))
        #expect(!PrivilegedTunInterfaceValidator.isValid("utun123456789012"))
    }

    @Test("Crash recovery accepts the preserved baseline when no new utun remains")
    func baselineCleanupAcceptsNoAdditions() async {
        let verifier = PrivilegedTunBaselineCleanupVerifier(
            interfaceLister: TunInterfaceListerFake(interfaces: ["utun2"])
        )

        #expect(await verifier.waitForNoAdditions(
            since: ["utun2"],
            timeout: .zero
        ))
    }

    @Test("Crash recovery fails closed while a post-launch utun remains")
    func baselineCleanupRejectsResidualAddition() async {
        let verifier = PrivilegedTunBaselineCleanupVerifier(
            interfaceLister: TunInterfaceListerFake(
                interfaces: ["utun2", "utun9"]
            )
        )

        #expect(!(await verifier.waitForNoAdditions(
            since: ["utun2"],
            timeout: .zero
        )))
    }

    @Test("Crash recovery fails closed when interface inspection is unavailable")
    func baselineCleanupRejectsUnavailableInspection() async {
        let verifier = PrivilegedTunBaselineCleanupVerifier(
            interfaceLister: TunInterfaceListerFake(interfaces: nil)
        )

        #expect(!(await verifier.waitForNoAdditions(
            since: [],
            timeout: .zero
        )))
    }
}

private struct RouteProberFake: PrivilegedRouteProbing {
    let result: PrivilegedRouteProbeResult

    func probe(
        address _: String,
        ownedInterface _: String
    ) async -> PrivilegedRouteProbeResult {
        result
    }
}

private struct TunInterfaceListerFake: PrivilegedTunInterfaceListing {
    let interfaces: Set<String>?

    func currentInterfaces() -> Set<String>? {
        interfaces
    }
}
