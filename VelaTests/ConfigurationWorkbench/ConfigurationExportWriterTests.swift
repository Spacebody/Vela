import Foundation
import Testing

@testable import Vela

@Suite("Configuration export writer")
struct ConfigurationExportWriterTests {
  @Test("Configuration export is atomic, private, and preserves UTF-8")
  func writesPrivateUTF8Document() async throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(
      "Vela-Configuration-Export-\(UUID().uuidString)",
      isDirectory: true
    )
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: root) }

    let destination = root.appendingPathComponent("config.yaml")
    let yaml = "mode: rule\n备注: 安全导出\n"

    try await ConfigurationExportWriter.shared.write(yaml, to: destination)

    let exported = try String(contentsOf: destination, encoding: .utf8)
    let attributes = try fileManager.attributesOfItem(atPath: destination.path)
    let permissions = try #require(attributes[.posixPermissions] as? NSNumber)

    #expect(exported == yaml)
    #expect(permissions.intValue & 0o777 == 0o600)
  }

  @Test("Large configuration export does not monopolize MainActor")
  @MainActor
  func largeExportKeepsMainActorResponsive() async throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(
      "Vela-Large-Configuration-Export-\(UUID().uuidString)",
      isDirectory: true
    )
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: root) }

    let destination = root.appendingPathComponent("large.yaml")
    let yaml = String(repeating: "DOMAIN-SUFFIX,example.com,DIRECT\n", count: 250_000)
    let clock = ContinuousClock()
    let started = clock.now
    let export = Task {
      try await ConfigurationExportWriter.shared.write(yaml, to: destination)
    }

    await Task.yield()
    let markerLatency = started.duration(to: clock.now)
    try await export.value

    #expect(markerLatency < .milliseconds(250))
    #expect(try Data(contentsOf: destination).count == Data(yaml.utf8).count)
  }
}
