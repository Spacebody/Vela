import AppKit

/// Presentation adapter for resolving process paths to macOS application icons.
///
/// Keeping filesystem and workspace queries outside the SwiftUI view prevents
/// rendering code from owning infrastructure work. The main-actor cache also
/// ensures repeated rows do not perform repeated synchronous lookups.
@MainActor
enum ConnectionApplicationIconProvider {
    private static let cache = NSCache<NSString, NSImage>()
    private static var missingPaths = Set<String>()

    static func icon(for rawPath: String?) -> NSImage? {
        guard let rawPath else { return nil }
        let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, path.hasPrefix("/"), !missingPaths.contains(path) else {
            return nil
        }
        if let cached = cache.object(forKey: path as NSString) {
            return cached
        }
        guard FileManager.default.fileExists(atPath: path) else {
            missingPaths.insert(path)
            return nil
        }
        let icon = NSWorkspace.shared.icon(forFile: path)
        cache.setObject(icon, forKey: path as NSString)
        return icon
    }
}
