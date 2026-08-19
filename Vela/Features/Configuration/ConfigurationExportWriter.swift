import Foundation

actor ConfigurationExportWriter {
  static let shared = ConfigurationExportWriter()

  func write(_ yaml: String, to destination: URL) throws {
    try Task.checkCancellation()
    try Data(yaml.utf8).write(to: destination, options: .atomic)
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: 0o600)],
      ofItemAtPath: destination.path
    )
  }
}
