import Foundation
import VelaIPC

nonisolated struct ConfigurationBackendContext: Equatable, Sendable {
    let backend: EngineBackendKind
    let managedPortKeys: Set<String>

    init(
        backend: EngineBackendKind = .userProcess,
        managedPortKeys: Set<String> = [
            "port", "socks-port", "redir-port", "tproxy-port", "mixed-port",
        ]
    ) {
        self.backend = backend
        self.managedPortKeys = managedPortKeys
    }
}

nonisolated enum ProtectedPathDecision: Equatable, Sendable {
    case allowed
    case readOnly(reason: String)
    case forbidden(reason: String)
}

nonisolated struct ProtectedPathPolicy: Sendable {
    private static let controllerKeys: Set<String> = [
        "external-controller",
        "external-controller-tls",
        "external-controller-unix",
        "external-controller-pipe",
        "external-controller-cors",
        "external-ui",
        "external-ui-url",
        "secret",
        "authentication",
    ]

    private static let listenerKeys: Set<String> = [
        "listeners",
        "inbounds",
        "ss-config",
        "vmess-config",
        "tuic-server",
        "hysteria2-server",
    ]

    private static let rootPrivilegeKeys: Set<String> = [
        "routing-mark",
        "iptables",
        "interface-name",
    ]

    func decision(
        for pointer: YAMLPointer,
        layerKind: ConfigurationLayerKind,
        context: ConfigurationBackendContext
    ) -> ProtectedPathDecision {
        guard layerKind.isUserEditable else {
            return .readOnly(reason: "Runtime-forced and privileged sanitizer layers are read-only.")
        }
        guard let first = pointer.components.first else {
            return .forbidden(reason: "The configuration root cannot be replaced or removed.")
        }

        let key = first.lowercased()
        if Self.controllerKeys.contains(key)
            || key.hasPrefix("external-controller")
            || key.hasPrefix("external-ui")
        {
            return .forbidden(reason: "Vela owns Controller endpoints, authentication, and UI exposure.")
        }
        if context.managedPortKeys.contains(key) {
            return .forbidden(reason: "Vela owns runtime listener ports.")
        }
        if key == "allow-lan" || key == "bind-address" {
            return .forbidden(reason: "Network exposure settings are managed by Vela.")
        }
        if Self.listenerKeys.contains(key) {
            return .forbidden(reason: "Generic layers cannot create server listeners or inbound services.")
        }
        if Self.rootPrivilegeKeys.contains(key) {
            return .forbidden(reason: "Generic layers cannot change root networking or interface settings.")
        }
        if key == "tun" {
            return .forbidden(reason: "TUN safety settings must use the typed privileged settings model.")
        }
        if key.hasPrefix("vela-") || key == "profile" && pointer.components.dropFirst().contains("store-selected") {
            return .forbidden(reason: "App and Helper internal runtime paths are not editable configuration.")
        }
        return .allowed
    }

    func isSensitive(_ pointer: YAMLPointer) -> Bool {
        let normalized = pointer.components.map { component in
            component.lowercased().filter { $0.isLetter || $0.isNumber }
        }
        if normalized.contains(where: { key in
            key == "password"
                || key == "passwd"
                || key == "privatekey"
                || key == "authentication"
                || key == "uuid"
                || key.hasSuffix("uuid")
                || key.hasSuffix("token")
                || key.hasSuffix("secret")
        }) {
            return true
        }

        guard let final = normalized.last else { return false }
        if final == "url",
            normalized.dropLast().contains(where: {
                $0.contains("subscription") || $0.contains("provider")
            })
        {
            return true
        }
        return pointer.components.contains { component in
            let key = component.lowercased().filter { $0.isLetter || $0.isNumber }
            return key.contains("subscription") && key.contains("url")
        }
    }
}
