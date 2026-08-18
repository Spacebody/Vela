import Foundation

nonisolated enum MihomoChildEnvironment {
    static func sanitized(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        let clashKeys = environment.keys.filter { $0.hasPrefix("CLASH_") }
        guard !clashKeys.isEmpty else { return environment }

        var sanitized = environment
        for key in clashKeys {
            sanitized.removeValue(forKey: key)
        }
        return sanitized
    }
}
