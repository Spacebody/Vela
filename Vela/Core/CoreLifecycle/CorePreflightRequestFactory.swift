import Darwin
import Foundation

nonisolated enum CoreLifecycleSecurityPolicy {
    #if DEBUG
    static let team: CodeSignatureTeamPolicy = .developmentAllowsAdHoc
    #else
    static let team: CodeSignatureTeamPolicy = .distribution
    #endif
}

actor CorePreflightRequestFactory {
    private let workspaceURL: URL
    private let applicationBundleURL: URL
    private let compatibilityEnvironment: CoreCompatibilityEnvironment
    private let fileManager: FileManager

    init(
        workspaceURL: URL,
        applicationBundleURL: URL = Bundle.main.bundleURL,
        compatibilityEnvironment: CoreCompatibilityEnvironment,
        fileManager: FileManager = .default
    ) throws {
        self.workspaceURL = workspaceURL.standardizedFileURL
        self.applicationBundleURL = applicationBundleURL.standardizedFileURL
        self.compatibilityEnvironment = compatibilityEnvironment
        self.fileManager = fileManager
        try Self.preparePrivateDirectory(self.workspaceURL, fileManager: fileManager)
    }

    deinit {
        try? FileManager.default.removeItem(at: workspaceURL)
    }

    func request(
        descriptor: CoreDescriptor,
        catalogEntry: CoreCatalogEntry
    ) throws -> InstalledCorePreflightRequest {
        let controllerPort = try Self.availableLoopbackPort()
        var mixedPort = try Self.availableLoopbackPort()
        while mixedPort == controllerPort {
            mixedPort = try Self.availableLoopbackPort()
        }
        let secret = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let configurationURL = workspaceURL.appending(path: "smoke.yaml")
        let yaml = """
        mixed-port: \(mixedPort)
        allow-lan: false
        bind-address: 127.0.0.1
        mode: rule
        log-level: silent
        ipv6: false
        external-controller: 127.0.0.1:\(controllerPort)
        secret: \(secret)
        proxies: []
        proxy-groups: []
        rules: []
        """
        try Data(yaml.utf8).write(to: configurationURL, options: [.atomic])
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: configurationURL.path
        )
        guard let endpoint = URL(string: "http://127.0.0.1:\(controllerPort)") else {
            throw CorePreflightRequestFactoryError.invalidControllerEndpoint
        }
        return InstalledCorePreflightRequest(
            descriptor: descriptor,
            catalogEntry: catalogEntry,
            applicationBundleURL: applicationBundleURL,
            signatureTeamPolicy: CoreLifecycleSecurityPolicy.team,
            compatibilityEnvironment: compatibilityEnvironment,
            configurationURL: configurationURL,
            temporaryHomeURL: workspaceURL,
            controllerEndpoint: endpoint,
            controllerSecret: secret
        )
    }

    nonisolated private static func preparePrivateDirectory(
        _ url: URL,
        fileManager: FileManager
    ) throws {
        var metadata = stat()
        let status = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.lstat(path, &metadata)
        }
        if status == 0 {
            guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
                metadata.st_uid == getuid(),
                metadata.st_mode & 0o022 == 0
            else {
                throw CorePreflightRequestFactoryError.unsafeWorkspace
            }
        } else {
            guard errno == ENOENT else {
                throw CorePreflightRequestFactoryError.unsafeWorkspace
            }
            try fileManager.createDirectory(
                at: url,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
        }
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: url.path
        )
    }

    nonisolated private static func availableLoopbackPort() throws -> UInt16 {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw CorePreflightRequestFactoryError.portAllocationFailed
        }
        defer { Darwin.close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }
        guard bound == 0 else {
            throw CorePreflightRequestFactoryError.portAllocationFailed
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(descriptor, $0, &length)
            }
        }
        guard named == 0, address.sin_port != 0 else {
            throw CorePreflightRequestFactoryError.portAllocationFailed
        }
        return UInt16(bigEndian: address.sin_port)
    }
}

nonisolated enum CorePreflightRequestFactoryError: Error, Equatable, Sendable {
    case unsafeWorkspace
    case portAllocationFailed
    case invalidControllerEndpoint
}
