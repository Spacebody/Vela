import Foundation
import SystemConfiguration

nonisolated enum SystemProxyPropertyList {
    struct ManagedFieldRestore: Sendable {
        let configuration: Data
        let restoredKeyCount: Int
        let conflictedKeyCount: Int
    }

    static func emptyConfiguration() throws -> Data {
        try encode([:])
    }

    static func applying(
        target: SystemProxyTarget,
        to configuration: Data
    ) throws -> Data {
        var dictionary = try decode(configuration)

        setEndpoint(
            in: &dictionary,
            enabledKey: kSCPropNetProxiesHTTPEnable as String,
            hostKey: kSCPropNetProxiesHTTPProxy as String,
            portKey: kSCPropNetProxiesHTTPPort as String,
            target: target
        )
        setEndpoint(
            in: &dictionary,
            enabledKey: kSCPropNetProxiesHTTPSEnable as String,
            hostKey: kSCPropNetProxiesHTTPSProxy as String,
            portKey: kSCPropNetProxiesHTTPSPort as String,
            target: target
        )
        setEndpoint(
            in: &dictionary,
            enabledKey: kSCPropNetProxiesSOCKSEnable as String,
            hostKey: kSCPropNetProxiesSOCKSProxy as String,
            portKey: kSCPropNetProxiesSOCKSPort as String,
            target: target
        )
        dictionary.removeValue(forKey: kSCPropNetProxiesHTTPUser as String)
        dictionary.removeValue(forKey: kSCPropNetProxiesHTTPSUser as String)
        dictionary.removeValue(forKey: kSCPropNetProxiesSOCKSUser as String)

        return try encode(dictionary)
    }

    static func endpoints(in configuration: Data) throws -> [SystemProxyEndpointState] {
        let dictionary = try decode(configuration)
        return [
            endpoint(
                kind: .http,
                dictionary: dictionary,
                enabledKey: kSCPropNetProxiesHTTPEnable as String,
                hostKey: kSCPropNetProxiesHTTPProxy as String,
                portKey: kSCPropNetProxiesHTTPPort as String
            ),
            endpoint(
                kind: .https,
                dictionary: dictionary,
                enabledKey: kSCPropNetProxiesHTTPSEnable as String,
                hostKey: kSCPropNetProxiesHTTPSProxy as String,
                portKey: kSCPropNetProxiesHTTPSPort as String
            ),
            endpoint(
                kind: .socks,
                dictionary: dictionary,
                enabledKey: kSCPropNetProxiesSOCKSEnable as String,
                hostKey: kSCPropNetProxiesSOCKSProxy as String,
                portKey: kSCPropNetProxiesSOCKSPort as String
            )
        ]
    }

    static func automaticConfiguration(
        in configuration: Data
    ) throws -> SystemProxyAutomaticConfigurationState {
        let dictionary = try decode(configuration)
        return SystemProxyAutomaticConfigurationState(
            isAutoConfigurationEnabled: boolean(
                dictionary[kSCPropNetProxiesProxyAutoConfigEnable as String]
            ),
            autoConfigurationURL: dictionary[
                kSCPropNetProxiesProxyAutoConfigURLString as String
            ] as? String,
            isAutoDiscoveryEnabled: boolean(
                dictionary[kSCPropNetProxiesProxyAutoDiscoveryEnable as String]
            )
        )
    }

    static func configurationsEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard
            let left = try? decode(lhs),
            let right = try? decode(rhs)
        else {
            return false
        }
        return NSDictionary(dictionary: left).isEqual(to: right)
    }

    static func managedFieldsEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard
            let left = try? decode(lhs),
            let right = try? decode(rhs)
        else {
            return false
        }

        return managedKeys.allSatisfy { key in
            propertyListValuesEqual(left[key], right[key])
        }
    }

    static func restoringManagedFields(
        from original: Data,
        in actual: Data
    ) throws -> Data {
        let originalDictionary = try decode(original)
        var restoredDictionary = try decode(actual)

        for key in managedKeys {
            if let originalValue = originalDictionary[key] {
                restoredDictionary[key] = originalValue
            } else {
                restoredDictionary.removeValue(forKey: key)
            }
        }
        return try encode(restoredDictionary)
    }

    static func restoringManagedFieldsCAS(
        original: Data,
        managed: Data,
        actual: Data
    ) throws -> ManagedFieldRestore {
        let originalDictionary = try decode(original)
        let managedDictionary = try decode(managed)
        var restoredDictionary = try decode(actual)
        var restoredKeyCount = 0
        var conflictedKeyCount = 0

        for key in managedKeys {
            let actualValue = restoredDictionary[key]
            let originalValue = originalDictionary[key]
            let managedValue = managedDictionary[key]

            if propertyListValuesEqual(actualValue, originalValue) {
                continue
            }
            if propertyListValuesEqual(actualValue, managedValue) {
                if let originalValue {
                    restoredDictionary[key] = originalValue
                } else {
                    restoredDictionary.removeValue(forKey: key)
                }
                restoredKeyCount += 1
            } else {
                // This key no longer contains either Vela's value or the
                // baseline. Preserve the external owner's value.
                conflictedKeyCount += 1
            }
        }

        return ManagedFieldRestore(
            configuration: try encode(restoredDictionary),
            restoredKeyCount: restoredKeyCount,
            conflictedKeyCount: conflictedKeyCount
        )
    }

    static func decode(_ data: Data) throws -> [String: Any] {
        var format = PropertyListSerialization.PropertyListFormat.binary
        let propertyList = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: &format
        )
        guard let dictionary = propertyList as? [String: Any] else {
            throw SystemProxyPropertyListError.rootIsNotDictionary
        }
        return dictionary
    }

    static func encode(_ dictionary: [String: Any]) throws -> Data {
        guard PropertyListSerialization.propertyList(dictionary, isValidFor: .binary) else {
            throw SystemProxyPropertyListError.invalidPropertyList
        }
        return try PropertyListSerialization.data(
            fromPropertyList: dictionary,
            format: .binary,
            options: 0
        )
    }

    private static func setEndpoint(
        in dictionary: inout [String: Any],
        enabledKey: String,
        hostKey: String,
        portKey: String,
        target: SystemProxyTarget
    ) {
        dictionary[enabledKey] = 1
        dictionary[hostKey] = target.host
        dictionary[portKey] = target.port
    }

    private static func endpoint(
        kind: SystemProxyEndpointKind,
        dictionary: [String: Any],
        enabledKey: String,
        hostKey: String,
        portKey: String
    ) -> SystemProxyEndpointState {
        let enabled = (dictionary[enabledKey] as? NSNumber)?.boolValue ?? false
        let host = dictionary[hostKey] as? String
        let port = (dictionary[portKey] as? NSNumber)?.intValue
        return SystemProxyEndpointState(
            kind: kind,
            isEnabled: enabled,
            host: host,
            port: port
        )
    }

    private static var managedKeys: [String] {
        [
            kSCPropNetProxiesHTTPEnable as String,
            kSCPropNetProxiesHTTPProxy as String,
            kSCPropNetProxiesHTTPPort as String,
            kSCPropNetProxiesHTTPSEnable as String,
            kSCPropNetProxiesHTTPSProxy as String,
            kSCPropNetProxiesHTTPSPort as String,
            kSCPropNetProxiesSOCKSEnable as String,
            kSCPropNetProxiesSOCKSProxy as String,
            kSCPropNetProxiesSOCKSPort as String,
            kSCPropNetProxiesHTTPUser as String,
            kSCPropNetProxiesHTTPSUser as String,
            kSCPropNetProxiesSOCKSUser as String
        ]
    }

    private static func boolean(_ value: Any?) -> Bool {
        (value as? NSNumber)?.boolValue ?? false
    }

    private static func propertyListValuesEqual(_ lhs: Any?, _ rhs: Any?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            true
        case let (left as NSObject, right as NSObject):
            left.isEqual(right)
        default:
            false
        }
    }
}

nonisolated enum SystemProxyPropertyListError: Error, Equatable, Sendable {
    case rootIsNotDictionary
    case invalidPropertyList
}

extension SystemProxyPropertyListError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .rootIsNotDictionary:
            "The system proxy configuration is not a property-list dictionary."
        case .invalidPropertyList:
            "The system proxy configuration contains unsupported property-list values."
        }
    }
}
