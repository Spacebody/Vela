import Foundation
import VelaIPC

public struct PrivilegedDirectories: Sendable {
    public static let trustedAncestorURL = URL(
        fileURLWithPath: "/Library/Application Support",
        isDirectory: true
    )

    public let fileSystem: POSIXRootFileSystem

    public init(fileSystem: POSIXRootFileSystem) {
        self.fileSystem = fileSystem
    }

    public static func live() throws -> PrivilegedDirectories {
        let relativeRoot = try SafeRelativePath(
            "\(VelaIPCConstants.mainBundleIdentifier)/Privileged"
        )
        return PrivilegedDirectories(
            fileSystem: try POSIXRootFileSystem.bootstrap(
                trustedAncestorURL: trustedAncestorURL,
                relativeRoot: relativeRoot,
                policy: .rootWheel
            )
        )
    }

    public func stagingRoot(ownerUID: UInt32, transactionID: UUID) throws
        -> SafeRelativePath
    {
        try SafeRelativePath(
            "users/\(ownerUID)/staging/\(transactionID.uuidString.lowercased())"
        )
    }

    public func stagingRootURL(ownerUID: UInt32, transactionID: UUID) throws -> URL {
        url(for: try stagingRoot(ownerUID: ownerUID, transactionID: transactionID))
    }

    public func runtimeStateRoot(
        ownerUID: UInt32,
        transactionID: UUID
    ) throws -> SafeRelativePath {
        try stagingRoot(ownerUID: ownerUID, transactionID: transactionID)
            .appending("runtime-state")
    }

    public func runtimeStateRootURL(ownerUID: UInt32, transactionID: UUID) throws -> URL {
        url(for: try runtimeStateRoot(ownerUID: ownerUID, transactionID: transactionID))
    }

    public func sanitizedConfigurationPath(
        ownerUID: UInt32,
        transactionID: UUID
    ) throws -> SafeRelativePath {
        try runtimeStateRoot(ownerUID: ownerUID, transactionID: transactionID)
            .appending("config.sanitized.yaml")
    }

    public func sanitizedConfigurationURL(
        ownerUID: UInt32,
        transactionID: UUID
    ) throws -> URL {
        url(for: try sanitizedConfigurationPath(
            ownerUID: ownerUID,
            transactionID: transactionID
        ))
    }

    public func generationRoot(
        ownerUID: UInt32,
        transactionID: UUID
    ) throws -> SafeRelativePath {
        try SafeRelativePath(
            "users/\(ownerUID)/runtime/generations/"
                + transactionID.uuidString.lowercased()
        )
    }

    public func generationRootURL(
        ownerUID: UInt32,
        transactionID: UUID
    ) throws -> URL {
        url(for: try generationRoot(ownerUID: ownerUID, transactionID: transactionID))
    }

    public func generationSanitizedConfigurationPath(
        ownerUID: UInt32,
        transactionID: UUID
    ) throws -> SafeRelativePath {
        try generationRoot(ownerUID: ownerUID, transactionID: transactionID)
            .appending("config.sanitized.yaml")
    }

    public func generationSanitizedConfigurationURL(
        ownerUID: UInt32,
        transactionID: UUID
    ) throws -> URL {
        url(for: try generationSanitizedConfigurationPath(
            ownerUID: ownerUID,
            transactionID: transactionID
        ))
    }

    public func url(for path: SafeRelativePath) -> URL {
        path.components.reduce(fileSystem.rootURL) {
            $0.appending(path: $1)
        }
    }
}
