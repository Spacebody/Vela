import Foundation
import Testing
@testable import Vela

@Suite("Application composition", .serialized)
@MainActor
struct AppEnvironmentCompositionTests {
    @Test("Isolated production composition builds and tears down")
    func isolatedCompositionBuildsAndTearsDown() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "VelaAppEnvironmentCompositionTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        defer { try? fileManager.removeItem(at: root) }

        let environment = try AppEnvironment.live(
            launchConfiguration: .startupSmoke(root: root),
            directories: ApplicationDirectories(root: root)
        )

        #expect(environment.engineStore.state == .stopped)
        #expect(await environment.engineStore.prepareForTermination())
    }
}
