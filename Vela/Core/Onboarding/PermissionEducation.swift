import Foundation

nonisolated enum PermissionEducationTopic: String, Codable, CaseIterable, Identifiable, Sendable {
    case tun
    case locationSSID = "location-ssid"
    case launchAtLogin = "launch-at-login"

    var id: String { rawValue }
}

nonisolated enum PermissionEducationStatus: String, Codable, Equatable, Sendable {
    case notRequested = "not-requested"
    case available
    case denied
    case requiresApproval = "requires-approval"
    case enabled
    case unavailable
}

nonisolated struct PermissionEducationModel: Identifiable, Equatable, Sendable {
    var id: PermissionEducationTopic { topic }
    let topic: PermissionEducationTopic
    let title: String
    let why: String
    let dataUsed: String
    let whenUsed: String
    let revocationInstructions: String
    let status: PermissionEducationStatus
    let primaryActionTitle: String
    let helpTopicID: String

    init(
        topic: PermissionEducationTopic,
        title: String,
        why: String,
        dataUsed: String,
        whenUsed: String,
        revocationInstructions: String,
        status: PermissionEducationStatus,
        primaryActionTitle: String,
        helpTopicID: String
    ) {
        self.topic = topic
        self.title = title
        self.why = why
        self.dataUsed = dataUsed
        self.whenUsed = whenUsed
        self.revocationInstructions = revocationInstructions
        self.status = status
        self.primaryActionTitle = primaryActionTitle
        self.helpTopicID = helpTopicID
    }
}

nonisolated extension PermissionEducationModel {
    static func tun(status: PermissionEducationStatus = .notRequested) -> Self {
        Self(
            topic: .tun,
            title: VelaL10n.string("permission.tun.title", defaultValue: "TUN Mode"),
            why: VelaL10n.string("permission.tun.why", defaultValue: "TUN can route apps that do not follow the macOS system proxy."),
            dataUsed: VelaL10n.string("permission.tun.data", defaultValue: "Vela configures a local network interface and routing rules. It does not request your credentials here."),
            whenUsed: VelaL10n.string("permission.tun.when", defaultValue: "Only after you explicitly choose to enable TUN and confirm the system prompt."),
            revocationInstructions: VelaL10n.string("permission.tun.revoke", defaultValue: "Disable TUN in Vela. You can also review privileged components in System Settings."),
            status: status,
            primaryActionTitle: VelaL10n.string("permission.tun.action", defaultValue: "Review TUN Setup"),
            helpTopicID: "system-proxy-vs-tun"
        )
    }

    static func locationSSID(
        status: PermissionEducationStatus = .notRequested
    ) -> Self {
        Self(
            topic: .locationSSID,
            title: VelaL10n.string("permission.ssid.title", defaultValue: "Wi-Fi Network Name"),
            why: VelaL10n.string("permission.ssid.why", defaultValue: "macOS protects the current Wi-Fi name as location-related information."),
            dataUsed: VelaL10n.string("permission.ssid.data", defaultValue: "Only the network name you choose for an SSID automation rule."),
            whenUsed: VelaL10n.string("permission.ssid.when", defaultValue: "Only while creating an SSID-based rule and after you request access."),
            revocationInstructions: VelaL10n.string("permission.ssid.revoke", defaultValue: "Remove the SSID rule, then revoke Location access for Vela in System Settings."),
            status: status,
            primaryActionTitle: VelaL10n.string("permission.ssid.action", defaultValue: "Review SSID Access"),
            helpTopicID: "privacy-and-security"
        )
    }

    static func launchAtLogin(
        status: PermissionEducationStatus = .notRequested
    ) -> Self {
        Self(
            topic: .launchAtLogin,
            title: VelaL10n.string("permission.login.title", defaultValue: "Launch at Login"),
            why: VelaL10n.string("permission.login.why", defaultValue: "Launch at Login can make Vela available after you sign in."),
            dataUsed: VelaL10n.string("permission.login.data", defaultValue: "No personal data. macOS records whether Vela is allowed to launch."),
            whenUsed: VelaL10n.string("permission.login.when", defaultValue: "Only after you turn on Launch at Login in Settings."),
            revocationInstructions: VelaL10n.string("permission.login.revoke", defaultValue: "Turn it off in Vela or in System Settings > General > Login Items."),
            status: status,
            primaryActionTitle: VelaL10n.string("permission.login.action", defaultValue: "Review Login Item"),
            helpTopicID: "getting-started"
        )
    }
}
