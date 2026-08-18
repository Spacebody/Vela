import Foundation

extension SystemProxyStatus {
    var displayTitle: String {
        switch (aggregate, recovery) {
        case (.unavailable, _):
            "Unavailable"
        case (.disabled, .none):
            "Off"
        case (.applied, .managed):
            "On · Managed by Vela"
        case (.applied, .none), (.externallyConfigured, .none):
            "On · External"
        case (.disabled, .managed), (.disabled, .recoveryRequired):
            "Off · Recovery pending"
        case (.partiallyApplied, _), (.externallyConfigured, .managed),
            (.externallyConfigured, .recoveryRequired), (.applied, .recoveryRequired):
            "Partial · Needs attention"
        }
    }

    var displayDetail: String? {
        switch recovery {
        case .none:
            switch aggregate {
            case .externallyConfigured:
                return configuredServiceSummary(
                    prefix: "External proxy settings detected on"
                )
            case .applied:
                return "These settings match Vela's port, but Vela does not own their recovery data."
            case .partiallyApplied:
                return configuredServiceSummary(prefix: "Proxy settings differ across")
            case .unavailable, .disabled:
                return nil
            }
        case let .managed(serviceNames):
            guard aggregate != .applied else {
                return "HTTP, HTTPS, and SOCKS are verified on \(serviceList(serviceNames))."
            }
            return "Vela has recovery data for \(serviceList(serviceNames))."
        case let .recoveryRequired(serviceNames):
            return "Restore or review \(serviceList(serviceNames)) before stopping Mihomo."
        }
    }

    private func configuredServiceSummary(prefix: String) -> String? {
        let names = services.filter { service in
            service.endpoints.contains(where: \.isEnabled)
                || service.automatic.isEnabled
        }.map(\.name)
        guard !names.isEmpty else { return nil }
        return "\(prefix) \(serviceList(names))."
    }

    private func serviceList(_ names: [String]) -> String {
        let uniqueNames = Array(Set(names)).sorted()
        if uniqueNames.count <= 3 {
            return uniqueNames.joined(separator: ", ")
        }
        return uniqueNames.prefix(3).joined(separator: ", ")
            + " and \(uniqueNames.count - 3) more"
    }
}
