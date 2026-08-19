import Foundation

actor SettingsTransferFileCoordinator {
  static let shared = SettingsTransferFileCoordinator()

  func export(
    _ document: SettingsTransferDocument,
    to destination: URL
  ) throws {
    try Task.checkCancellation()
    let data = try SettingsTransferCodec.encode(document)
    try Task.checkCancellation()
    try data.write(to: destination, options: .atomic)
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: 0o600)],
      ofItemAtPath: destination.path
    )
  }

  func importDocument(from source: URL) throws -> SettingsTransferDocument {
    try Task.checkCancellation()
    let data = try Data(contentsOf: source, options: [.mappedIfSafe])
    try Task.checkCancellation()
    return try SettingsTransferCodec.decode(data)
  }
}
