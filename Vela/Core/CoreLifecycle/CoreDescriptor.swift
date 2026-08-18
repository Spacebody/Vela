import Foundation
import VelaIPC

nonisolated enum CoreDescriptorSource: String, Codable, Sendable {
    case factory
    case user
}

nonisolated struct CoreDescriptor: Equatable, Sendable, Identifiable {
    var id: CoreID { coreID }

    let coreID: CoreID
    let source: CoreDescriptorSource
    let bundleURL: URL
    let executableURL: URL
    let upstreamVersion: String
    let packageRevision: Int?

    init(
        coreID: CoreID,
        source: CoreDescriptorSource,
        bundleURL: URL,
        executableURL: URL,
        upstreamVersion: String,
        packageRevision: Int?
    ) {
        self.coreID = coreID
        self.source = source
        self.bundleURL = bundleURL.standardizedFileURL
        self.executableURL = executableURL.standardizedFileURL
        self.upstreamVersion = upstreamVersion
        self.packageRevision = packageRevision
    }

    static func factory(
        from descriptor: MihomoCoreDescriptor,
        appBundleURL: URL
    ) throws -> CoreDescriptor {
        try descriptor.validate()
        let coreID = try CoreID.factory(version: descriptor.version)
        return CoreDescriptor(
            coreID: coreID,
            source: .factory,
            bundleURL: appBundleURL,
            executableURL: appBundleURL.appending(path: descriptor.bundleRelativePath),
            upstreamVersion: descriptor.version,
            packageRevision: nil
        )
    }

    static func installed(
        record: InstalledCoreRecord,
        directories: CoreDirectories
    ) -> CoreDescriptor {
        let bundleURL = directories.bundleURL(for: record.coreID)
        return CoreDescriptor(
            coreID: record.coreID,
            source: .user,
            bundleURL: bundleURL,
            executableURL: bundleURL.appending(path: CoreFileRole.executable.requiredRelativePath),
            upstreamVersion: record.upstreamVersion,
            packageRevision: record.packageRevision
        )
    }
}

nonisolated struct CoreStoreSnapshot: Equatable, Sendable {
    let state: CoreStoreState
    let activeDescriptor: CoreDescriptor
    let previousKnownGoodDescriptor: CoreDescriptor?
    let pinnedDescriptor: CoreDescriptor?

    func descriptor(for coreID: CoreID) -> CoreDescriptor? {
        if activeDescriptor.coreID == coreID { return activeDescriptor }
        if previousKnownGoodDescriptor?.coreID == coreID { return previousKnownGoodDescriptor }
        if pinnedDescriptor?.coreID == coreID { return pinnedDescriptor }
        return nil
    }
}
