import Foundation
import Security

nonisolated enum SubscriptionAuthentication: Equatable, Sendable {
    case none
    case bearer(token: String)
    case basic(username: String, password: String)
}

nonisolated extension SubscriptionAuthentication: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case token
        case username
        case password
    }

    private enum Kind: String, Codable {
        case none
        case bearer
        case basic
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .none:
            self = .none
        case .bearer:
            self = .bearer(token: try container.decode(String.self, forKey: .token))
        case .basic:
            self = .basic(
                username: try container.decode(String.self, forKey: .username),
                password: try container.decode(String.self, forKey: .password)
            )
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .none:
            try container.encode(Kind.none, forKey: .kind)
        case let .bearer(token):
            try container.encode(Kind.bearer, forKey: .kind)
            try container.encode(token, forKey: .token)
        case let .basic(username, password):
            try container.encode(Kind.basic, forKey: .kind)
            try container.encode(username, forKey: .username)
            try container.encode(password, forKey: .password)
        }
    }
}

nonisolated struct SubscriptionSecretEnvelope: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    var url: URL
    var authentication: SubscriptionAuthentication
    var userAgent: String?
    var userAgentPreset: SubscriptionUserAgent
    var proxyMode: SubscriptionProxyMode
    var allowInsecureHTTP: Bool
    var allowInvalidCertificates: Bool
    var requestTimeout: TimeInterval
    var conversionPreferences: SubscriptionConversionPreferences

    init(
        schemaVersion: Int = currentSchemaVersion,
        url: URL,
        authentication: SubscriptionAuthentication = .none,
        userAgent: String? = nil,
        userAgentPreset: SubscriptionUserAgent? = nil,
        proxyMode: SubscriptionProxyMode = .direct,
        allowInsecureHTTP: Bool = false,
        allowInvalidCertificates: Bool = false,
        requestTimeout: TimeInterval = 20,
        conversionPreferences: SubscriptionConversionPreferences = SubscriptionConversionPreferences()
    ) {
        self.schemaVersion = schemaVersion
        self.url = url
        self.authentication = authentication
        self.userAgent = userAgent
        self.userAgentPreset = userAgentPreset ?? (userAgent == nil ? .clashVerge : .custom)
        self.proxyMode = proxyMode
        self.allowInsecureHTTP = allowInsecureHTTP
        self.allowInvalidCertificates = allowInvalidCertificates
        self.requestTimeout = requestTimeout
        self.conversionPreferences = conversionPreferences
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case url
        case authentication
        case userAgent
        case userAgentPreset
        case proxyMode
        case allowInsecureHTTP
        case allowInvalidCertificates
        case requestTimeout
        case conversionPreferences
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        url = try container.decode(URL.self, forKey: .url)
        authentication = try container.decode(
            SubscriptionAuthentication.self,
            forKey: .authentication
        )
        userAgent = try container.decodeIfPresent(String.self, forKey: .userAgent)
        userAgentPreset = try container.decodeIfPresent(
            SubscriptionUserAgent.self,
            forKey: .userAgentPreset
        ) ?? (userAgent == nil ? .clashVerge : .custom)
        proxyMode = try container.decodeIfPresent(
            SubscriptionProxyMode.self,
            forKey: .proxyMode
        ) ?? .direct
        allowInsecureHTTP = try container.decodeIfPresent(
            Bool.self,
            forKey: .allowInsecureHTTP
        ) ?? false
        allowInvalidCertificates = try container.decodeIfPresent(
            Bool.self,
            forKey: .allowInvalidCertificates
        ) ?? false
        requestTimeout = try container.decodeIfPresent(
            TimeInterval.self,
            forKey: .requestTimeout
        ) ?? 20
        conversionPreferences = try container.decodeIfPresent(
            SubscriptionConversionPreferences.self,
            forKey: .conversionPreferences
        ) ?? SubscriptionConversionPreferences()
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(url, forKey: .url)
        try container.encode(authentication, forKey: .authentication)
        try container.encodeIfPresent(userAgent, forKey: .userAgent)
        try container.encode(userAgentPreset, forKey: .userAgentPreset)
        try container.encode(proxyMode, forKey: .proxyMode)
        try container.encode(allowInsecureHTTP, forKey: .allowInsecureHTTP)
        try container.encode(allowInvalidCertificates, forKey: .allowInvalidCertificates)
        try container.encode(requestTimeout, forKey: .requestTimeout)
        try container.encode(conversionPreferences, forKey: .conversionPreferences)
    }
}

nonisolated protocol SecureStoreBackend: Sendable {
    func data(service: String, account: String) throws -> Data?
    func setData(_ data: Data, service: String, account: String) throws
    func removeData(service: String, account: String) throws
}

nonisolated struct KeychainSecureStoreBackend: SecureStoreBackend {
    func data(service: String, account: String) throws -> Data? {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw SecureStoreError.invalidResult
            }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw SecureStoreError.keychain(status: status)
        }
    }

    func setData(_ data: Data, service: String, account: String) throws {
        let query = baseQuery(service: service, account: account)
        let update = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)

        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var attributes = query
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(attributes as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw SecureStoreError.keychain(status: addStatus)
            }
        default:
            throw SecureStoreError.keychain(status: updateStatus)
        }
    }

    func removeData(service: String, account: String) throws {
        let status = SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecureStoreError.keychain(status: status)
        }
    }

    private func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

actor SubscriptionSecretStore {
    static let defaultService = "dev.yilin.Vela.subscription"

    private let backend: any SecureStoreBackend
    private let service: String

    init(
        backend: any SecureStoreBackend = KeychainSecureStoreBackend(),
        service: String = defaultService
    ) {
        self.backend = backend
        self.service = service
    }

    func envelope(for profileID: UUID) throws -> SubscriptionSecretEnvelope? {
        guard let data = try backend.data(service: service, account: account(for: profileID)) else {
            return nil
        }

        do {
            let envelope = try JSONDecoder().decode(SubscriptionSecretEnvelope.self, from: data)
            guard envelope.schemaVersion == SubscriptionSecretEnvelope.currentSchemaVersion else {
                throw SecureStoreError.unsupportedSchema(envelope.schemaVersion)
            }
            return envelope
        } catch let error as SecureStoreError {
            throw error
        } catch {
            throw SecureStoreError.decodeFailed
        }
    }

    func save(_ envelope: SubscriptionSecretEnvelope, for profileID: UUID) throws {
        guard envelope.schemaVersion == SubscriptionSecretEnvelope.currentSchemaVersion else {
            throw SecureStoreError.unsupportedSchema(envelope.schemaVersion)
        }

        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            data = try encoder.encode(envelope)
        } catch {
            throw SecureStoreError.encodeFailed
        }

        try backend.setData(data, service: service, account: account(for: profileID))
    }

    func removeEnvelope(for profileID: UUID) throws {
        try backend.removeData(service: service, account: account(for: profileID))
    }

    private func account(for profileID: UUID) -> String {
        profileID.uuidString.lowercased()
    }
}

nonisolated enum SecureStoreError: Error, Equatable, Sendable {
    case keychain(status: OSStatus)
    case invalidResult
    case encodeFailed
    case decodeFailed
    case unsupportedSchema(Int)
}

extension SecureStoreError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .keychain(status):
            "The secure store operation failed (OSStatus \(status))."
        case .invalidResult:
            "The secure store returned an invalid value."
        case .encodeFailed:
            "The subscription credentials could not be encoded."
        case .decodeFailed:
            "The subscription credentials are damaged or unreadable."
        case let .unsupportedSchema(version):
            "The subscription credential schema version \(version) is not supported."
        }
    }
}
