import Foundation

enum ConfigurationTestSupport {
    static func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VelaTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    static func removeTemporaryDirectory(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }

    @discardableResult
    static func write(
        _ contents: String,
        named name: String,
        in directory: URL
    ) throws -> URL {
        let file = directory.appendingPathComponent(name, isDirectory: false)
        guard let data = contents.data(using: .utf8) else {
            throw ConfigurationTestSupportError.couldNotEncodeUTF8
        }
        try data.write(to: file, options: .atomic)
        return file
    }
}

enum ConfigurationTestSupportError: Error {
    case couldNotEncodeUTF8
}
