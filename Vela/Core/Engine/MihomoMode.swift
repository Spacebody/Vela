nonisolated enum MihomoMode: String, CaseIterable, Codable, Equatable, Sendable {
    case rule
    case global
    case direct

    var displayName: String {
        switch self {
        case .rule: VelaL10n.string("mode.rule", defaultValue: "Rule")
        case .global: VelaL10n.string("mode.global", defaultValue: "Global")
        case .direct: VelaL10n.string("mode.direct", defaultValue: "Direct")
        }
    }
}
