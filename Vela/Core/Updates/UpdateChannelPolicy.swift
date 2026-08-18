import Foundation

nonisolated enum UpdateChannelTransition: Equatable, Sendable {
    case applied(ReleaseChannel)
    case blockedToAvoidDowngrade(
        currentChannel: ReleaseChannel,
        requestedChannel: ReleaseChannel,
        currentBuild: Int,
        latestStableBuild: Int?
    )

    var effectiveChannel: ReleaseChannel {
        switch self {
        case let .applied(channel):
            channel
        case let .blockedToAvoidDowngrade(currentChannel, _, _, _):
            currentChannel
        }
    }

    var wasApplied: Bool {
        if case .applied = self { true } else { false }
    }
}
nonisolated enum UpdateChannelPolicy {
    static func allowedChannels(for channel: ReleaseChannel) -> Set<String> {
        channel.allowedSparkleChannels
    }

    /// Moving from Beta back to Stable is delayed until a strictly newer
    /// Stable build exists. This prevents a channel preference change from
    /// asking Sparkle to install an older or same-build binary.
    static func transition(
        from current: ReleaseChannel,
        to requested: ReleaseChannel,
        currentBuild: Int,
        latestStableBuild: Int?
    ) -> UpdateChannelTransition {
        guard current != requested else { return .applied(current) }
        guard current == .beta, requested == .stable else {
            return .applied(requested)
        }
        guard let latestStableBuild, latestStableBuild > currentBuild else {
            return .blockedToAvoidDowngrade(
                currentChannel: current,
                requestedChannel: requested,
                currentBuild: currentBuild,
                latestStableBuild: latestStableBuild
            )
        }
        return .applied(requested)
    }
}
