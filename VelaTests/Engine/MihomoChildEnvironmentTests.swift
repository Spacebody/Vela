import Testing
@testable import Vela

struct MihomoChildEnvironmentTests {
    @Test
    func removesEveryClashVariableAndPreservesUnrelatedValues() {
        let environment = [
            "PATH": "/usr/bin",
            "HOME": "/tmp/home",
            "CLASH_HOME_DIR": "/tmp/hostile-home",
            "CLASH_CONFIG_FILE": "/tmp/hostile.yaml",
            "CLASH_CONFIG_STRING": "injected",
            "CLASH_OVERRIDE_EXTERNAL_CONTROLLER": "0.0.0.0:9999",
            "CLASH_POST_UP": "unexpected",
            "CLASH_FUTURE_OPTION": "must also be removed",
        ]

        let sanitized = MihomoChildEnvironment.sanitized(environment)

        #expect(sanitized["PATH"] == "/usr/bin")
        #expect(sanitized["HOME"] == "/tmp/home")
        #expect(sanitized.keys.allSatisfy { !$0.hasPrefix("CLASH_") })
    }
}
