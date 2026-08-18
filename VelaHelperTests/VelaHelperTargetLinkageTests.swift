import Testing
import VelaIPC
@testable import VelaPrivilegedCore

@Suite("VelaHelper target linkage")
struct VelaHelperTargetLinkageTests {
    @Test("uses the fixed privileged service identifiers")
    func usesFixedServiceIdentifiers() {
        #expect(VelaIPCConstants.mainBundleIdentifier == "dev.yilin.Vela")
        #expect(VelaIPCConstants.helperIdentifier == "dev.yilin.Vela.Helper")
        #expect(VelaIPCConstants.machServiceName == "dev.yilin.Vela.Helper")
    }
}
