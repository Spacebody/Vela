import CryptoKit
import Darwin
import Foundation
import Synchronization
import VelaIPC

nonisolated struct CoreHTTPResponse: Sendable {
    let statusCode: Int
    let expectedContentLength: Int64
    let etag: String?
    let finalURL: URL
    let chunks: AsyncThrowingStream<Data, any Error>
}

nonisolated protocol CoreHTTPStreaming: Sendable {
    func stream(for request: URLRequest) async throws -> CoreHTTPResponse
}

nonisolated struct EphemeralCoreHTTPTransport: CoreHTTPStreaming, Sendable {
    let requestTimeout: TimeInterval
    let resourceTimeout: TimeInterval
    let maximumRedirects: Int
    let allowsExpensiveNetworkAccess: Bool
    let allowsConstrainedNetworkAccess: Bool

    init(
        requestTimeout: TimeInterval = 30,
        resourceTimeout: TimeInterval = 180,
        maximumRedirects: Int = 5,
        allowsExpensiveNetworkAccess: Bool = true,
        allowsConstrainedNetworkAccess: Bool = true
    ) {
        self.requestTimeout = requestTimeout
        self.resourceTimeout = resourceTimeout
        self.maximumRedirects = maximumRedirects
        self.allowsExpensiveNetworkAccess = allowsExpensiveNetworkAccess
        self.allowsConstrainedNetworkAccess = allowsConstrainedNetworkAccess
    }

    func stream(for request: URLRequest) async throws -> CoreHTTPResponse {
        guard let initialURL = request.url else { throw CoreDownloadError.invalidURL }
        try CoreCatalogURLPolicy.validate(initialURL)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.httpMaximumConnectionsPerHost = 2
        configuration.allowsExpensiveNetworkAccess = allowsExpensiveNetworkAccess
        configuration.allowsConstrainedNetworkAccess = allowsConstrainedNetworkAccess

        let redirectDelegate = CoreRedirectDelegate(
            initialURL: initialURL,
            maximumRedirects: maximumRedirects
        )
        let session = URLSession(
            configuration: configuration,
            delegate: redirectDelegate,
            delegateQueue: nil
        )
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch is CancellationError {
            session.invalidateAndCancel()
            throw CoreDownloadError.cancelled
        } catch let error as URLError where error.code == .cancelled && Task.isCancelled {
            session.invalidateAndCancel()
            throw CoreDownloadError.cancelled
        } catch let error as URLError where error.code == .timedOut {
            session.invalidateAndCancel()
            throw CoreDownloadError.timedOut
        } catch {
            session.invalidateAndCancel()
            if let failure = redirectDelegate.failure { throw failure }
            throw CoreDownloadError.transportFailed
        }
        if let failure = redirectDelegate.failure {
            session.invalidateAndCancel()
            throw failure
        }
        guard let http = response as? HTTPURLResponse,
            let finalURL = http.url
        else {
            session.invalidateAndCancel()
            throw CoreDownloadError.invalidResponse
        }
        try CoreCatalogURLPolicy.validate(finalURL)

        let stream = AsyncThrowingStream<Data, any Error> { continuation in
            let producer = Task {
                do {
                    var chunk = Data()
                    chunk.reserveCapacity(64 * 1_024)
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        chunk.append(byte)
                        if chunk.count == 64 * 1_024 {
                            continuation.yield(chunk)
                            chunk.removeAll(keepingCapacity: true)
                        }
                    }
                    if !chunk.isEmpty { continuation.yield(chunk) }
                    continuation.finish()
                    session.finishTasksAndInvalidate()
                } catch is CancellationError {
                    continuation.finish(throwing: CoreDownloadError.cancelled)
                    session.invalidateAndCancel()
                } catch {
                    continuation.finish(throwing: CoreDownloadError.transportFailed)
                    session.invalidateAndCancel()
                }
            }
            continuation.onTermination = { @Sendable _ in
                producer.cancel()
                session.invalidateAndCancel()
            }
        }
        return CoreHTTPResponse(
            statusCode: http.statusCode,
            expectedContentLength: http.expectedContentLength,
            etag: http.value(forHTTPHeaderField: "ETag"),
            finalURL: finalURL,
            chunks: stream
        )
    }
}

nonisolated struct CoreCatalogDownload: Sendable {
    let catalogBytes: Data
    let envelopeBytes: Data
    let etag: String?
}

nonisolated enum CoreCatalogDownloadOutcome: Sendable {
    case notModified(envelopeBytes: Data, etag: String?)
    case downloaded(CoreCatalogDownload)
}

nonisolated struct CoreCatalogDownloader: Sendable {
    private let transport: any CoreHTTPStreaming

    init(transport: any CoreHTTPStreaming = EphemeralCoreHTTPTransport()) {
        self.transport = transport
    }

    /// Downloads the signature envelope first so callers never parse an
    /// unauthenticated catalog. A 304 requires the caller's last verified raw bytes.
    func download(
        catalogURL: URL,
        signatureEnvelopeURL: URL,
        etag: String? = nil
    ) async throws -> CoreCatalogDownloadOutcome {
        try CoreCatalogURLPolicy.validate(catalogURL)
        try CoreCatalogURLPolicy.validate(signatureEnvelopeURL)
        guard catalogURL.host?.lowercased() == signatureEnvelopeURL.host?.lowercased() else {
            throw CoreDownloadError.catalogHostMismatch
        }

        let envelope = try await boundedData(
            from: signatureEnvelopeURL,
            maximumBytes: CoreCatalogDecoder.maximumEnvelopeBytes,
            etag: nil,
            allowNotModified: false
        )
        let catalog = try await boundedData(
            from: catalogURL,
            maximumBytes: CoreCatalogDecoder.maximumCatalogBytes,
            etag: etag,
            allowNotModified: true
        )
        if catalog.statusCode == 304 {
            return .notModified(
                envelopeBytes: envelope.data,
                etag: catalog.etag ?? etag
            )
        }
        return .downloaded(
            CoreCatalogDownload(
                catalogBytes: catalog.data,
                envelopeBytes: envelope.data,
                etag: catalog.etag
            )
        )
    }

    private func boundedData(
        from url: URL,
        maximumBytes: Int,
        etag: String?,
        allowNotModified: Bool
    ) async throws -> (data: Data, statusCode: Int, etag: String?) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let etag, !etag.isEmpty { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        let response = try await transport.stream(for: request)
        if response.statusCode == 304, allowNotModified {
            return (Data(), response.statusCode, response.etag)
        }
        guard (200 ... 299).contains(response.statusCode) else {
            throw CoreDownloadError.httpStatus(response.statusCode)
        }
        if response.expectedContentLength > Int64(maximumBytes) {
            throw CoreDownloadError.responseTooLarge
        }
        var data = Data()
        data.reserveCapacity(min(maximumBytes, max(Int(response.expectedContentLength), 0)))
        do {
            for try await chunk in response.chunks {
                try Task.checkCancellation()
                guard chunk.count <= maximumBytes - data.count else {
                    throw CoreDownloadError.responseTooLarge
                }
                data.append(chunk)
            }
        } catch is CancellationError {
            throw CoreDownloadError.cancelled
        }
        guard !data.isEmpty else { throw CoreDownloadError.emptyResponse }
        return (data, response.statusCode, response.etag)
    }
}

nonisolated struct CoreDownloadedFile: Equatable, Sendable {
    let role: CoreFileRole
    let temporaryURL: URL
    let byteCount: UInt64
    let sha256: String
}

nonisolated struct CoreDownloadWorkspace: Equatable, Sendable {
    let directory: URL

    fileprivate init(directory: URL) {
        self.directory = directory
    }
}

nonisolated struct CoreFileDownloader: Sendable {
    private let transport: any CoreHTTPStreaming

    init(transport: any CoreHTTPStreaming = EphemeralCoreHTTPTransport()) {
        self.transport = transport
    }

    @concurrent
    func createWorkspace(in trustedStagingDirectory: URL) async throws -> CoreDownloadWorkspace {
        try validateTrustedDirectory(trustedStagingDirectory)
        let directory = trustedStagingDirectory.appending(
            path: "download-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
            try validateTrustedDirectory(directory)
            return CoreDownloadWorkspace(directory: directory)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    @concurrent
    func removeWorkspace(_ workspace: CoreDownloadWorkspace) async {
        try? FileManager.default.removeItem(at: workspace.directory)
    }

    @concurrent
    func download(
        _ descriptor: CoreFileDescriptor,
        into trustedTemporaryDirectory: URL
    ) async throws -> CoreDownloadedFile {
        try descriptor.validate()
        try validateTrustedDirectory(trustedTemporaryDirectory)
        let fileManager = FileManager.default
        var request = URLRequest(url: descriptor.url)
        request.httpMethod = "GET"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        let response = try await transport.stream(for: request)
        guard (200 ... 299).contains(response.statusCode) else {
            throw CoreDownloadError.httpStatus(response.statusCode)
        }
        if response.expectedContentLength >= 0,
            UInt64(response.expectedContentLength) != descriptor.size
        {
            throw CoreDownloadError.sizeMismatch(
                expected: descriptor.size,
                actual: UInt64(response.expectedContentLength)
            )
        }

        let temporaryURL = trustedTemporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .notDirectory)
        guard fileManager.createFile(atPath: temporaryURL.path, contents: nil) else {
            throw CoreDownloadError.temporaryFileFailed
        }
        var keepFile = false
        defer { if !keepFile { try? fileManager.removeItem(at: temporaryURL) } }
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: temporaryURL.path
        )
        let handle = try FileHandle(forWritingTo: temporaryURL)
        defer { try? handle.close() }
        var hash = SHA256()
        var byteCount: UInt64 = 0
        do {
            for try await chunk in response.chunks {
                try Task.checkCancellation()
                guard UInt64(chunk.count) <= descriptor.size - byteCount else {
                    throw CoreDownloadError.responseTooLarge
                }
                try handle.write(contentsOf: chunk)
                hash.update(data: chunk)
                byteCount += UInt64(chunk.count)
            }
        } catch is CancellationError {
            throw CoreDownloadError.cancelled
        }
        try handle.synchronize()
        guard byteCount == descriptor.size else {
            throw CoreDownloadError.sizeMismatch(expected: descriptor.size, actual: byteCount)
        }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == descriptor.sha256 else { throw CoreDownloadError.hashMismatch }
        keepFile = true
        return CoreDownloadedFile(
            role: descriptor.role,
            temporaryURL: temporaryURL,
            byteCount: byteCount,
            sha256: digest
        )
    }

    private func validateTrustedDirectory(_ url: URL) throws {
        var status = stat()
        let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.lstat(path, &status)
        }
        guard result == 0,
            status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
            status.st_uid == getuid(),
            status.st_mode & 0o022 == 0
        else {
            throw CoreDownloadError.unsafeTemporaryDirectory
        }
    }
}

nonisolated private final class CoreRedirectDelegate: NSObject,
    URLSessionTaskDelegate, @unchecked Sendable
{
    private struct State: Sendable {
        var redirectCount = 0
        var visitedURLs: Set<String>
        var failure: CoreDownloadError?
    }

    private let maximumRedirects: Int
    private let state: Mutex<State>

    init(initialURL: URL, maximumRedirects: Int) {
        self.maximumRedirects = max(0, maximumRedirects)
        state = Mutex(State(visitedURLs: [initialURL.absoluteString]))
    }

    var failure: CoreDownloadError? { state.withLock { $0.failure } }

    func urlSession(
        _: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard let destination = request.url else {
            reject(.invalidURL, completionHandler)
            return
        }
        let failure = state.withLock { state -> CoreDownloadError? in
            state.redirectCount += 1
            guard state.redirectCount <= maximumRedirects,
                !state.visitedURLs.contains(destination.absoluteString)
            else { return .redirectLimitExceeded }
            do {
                try CoreCatalogURLPolicy.validate(destination)
            } catch {
                return .insecureRedirect
            }
            state.visitedURLs.insert(destination.absoluteString)
            return nil
        }
        if let failure {
            reject(failure, completionHandler)
            return
        }
        var sanitized = request
        sanitized.setValue(nil, forHTTPHeaderField: "Authorization")
        sanitized.setValue(nil, forHTTPHeaderField: "Proxy-Authorization")
        sanitized.setValue(nil, forHTTPHeaderField: "Cookie")
        completionHandler(sanitized)
    }

    private func reject(
        _ error: CoreDownloadError,
        _ completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        state.withLock { $0.failure = error }
        completionHandler(nil)
    }
}

nonisolated enum CoreDownloadError: Error, Equatable, Sendable {
    case invalidURL
    case invalidResponse
    case catalogHostMismatch
    case transportFailed
    case timedOut
    case cancelled
    case redirectLimitExceeded
    case insecureRedirect
    case httpStatus(Int)
    case responseTooLarge
    case emptyResponse
    case sizeMismatch(expected: UInt64, actual: UInt64)
    case hashMismatch
    case temporaryFileFailed
    case unsafeTemporaryDirectory
}
