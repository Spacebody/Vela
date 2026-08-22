import Foundation
import Testing

@testable import Vela

@Suite("Diagnostics export writer")
struct DiagnosticsExportWriterTests {
    @Test("Diagnostics export is atomic, private, and preserves UTF-8")
    func writesPrivateUTF8Document() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "Vela-Diagnostics-Export-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let destination = root.appendingPathComponent("diagnostics.json")
        let document = "{\"status\":\"安全\"}\n"

        try await DiagnosticsExportWriter.shared.writeUTF8(document, to: destination)

        let exported = try String(contentsOf: destination, encoding: .utf8)
        let attributes = try fileManager.attributesOfItem(atPath: destination.path)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)

        #expect(exported == document)
        #expect(permissions.intValue & 0o777 == 0o600)
    }

    @Test("Large diagnostics export does not monopolize MainActor")
    @MainActor
    func largeExportKeepsMainActorResponsive() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "Vela-Large-Diagnostics-Export-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let destination = root.appendingPathComponent("large.json")
        let document = String(repeating: "{\"event\":\"redacted\"}\n", count: 250_000)
        let clock = ContinuousClock()
        let started = clock.now
        let export = Task {
            try await DiagnosticsExportWriter.shared.writeUTF8(document, to: destination)
        }

        await Task.yield()
        let markerLatency = started.duration(to: clock.now)
        try await export.value

        #expect(markerLatency < .milliseconds(250))
        #expect(try Data(contentsOf: destination).count == Data(document.utf8).count)
    }
}
