import Foundation

actor DiagnosticsExportWriter {
    static let shared = DiagnosticsExportWriter()

    func write(_ data: Data, to destination: URL) throws {
        try Task.checkCancellation()
        try data.write(to: destination, options: .atomic)
        try applyPrivatePermissions(to: destination)
    }

    func writeUTF8(_ text: String, to destination: URL) throws {
        try write(Data(text.utf8), to: destination)
    }

    private func applyPrivatePermissions(to destination: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: destination.path
        )
    }
}
