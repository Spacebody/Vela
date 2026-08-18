import AppKit
import Foundation
import OSLog

nonisolated enum SleepWakeEvent: Equatable, Sendable {
    case willSleep
    case didWake
}

/// NotificationCenter's Objective-C observer token is thread-safe to retain
/// and pass back only to the center that created it, but is not annotated
/// Sendable. This wrapper keeps that narrow ownership contract explicit and
/// lets the observer unregister tokens from its nonisolated deinitializer.
private nonisolated final class SleepWakeNotificationToken: @unchecked Sendable {
    let value: any NSObjectProtocol

    init(_ value: any NSObjectProtocol) {
        self.value = value
    }
}

nonisolated protocol SleepWakeObserving: Sendable {
    @MainActor
    func start() async
    @MainActor
    func events() async -> AsyncStream<SleepWakeEvent>
    @MainActor
    func stop() async
}

@MainActor
final class SleepWakeObserver: SleepWakeObserving {
    private nonisolated static let logger = Logger(
        subsystem: "dev.yilin.Vela",
        category: "SleepWake"
    )

    private let notificationCenter: NotificationCenter
    private let willSleepNotification: Notification.Name
    private let didWakeNotification: Notification.Name
    private var notificationTokens: [SleepWakeNotificationToken] = []
    private var continuations: [
        UUID: AsyncStream<SleepWakeEvent>.Continuation
    ] = [:]

    init(
        notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        willSleepNotification: Notification.Name = NSWorkspace.willSleepNotification,
        didWakeNotification: Notification.Name = NSWorkspace.didWakeNotification
    ) {
        self.notificationCenter = notificationCenter
        self.willSleepNotification = willSleepNotification
        self.didWakeNotification = didWakeNotification
    }

    func start() async {
        guard notificationTokens.isEmpty else { return }

        let willSleepToken = notificationCenter.addObserver(
            forName: willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.emit(.willSleep)
            }
        }
        let didWakeToken = notificationCenter.addObserver(
            forName: didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.emit(.didWake)
            }
        }

        notificationTokens = [
            SleepWakeNotificationToken(willSleepToken),
            SleepWakeNotificationToken(didWakeToken),
        ]
    }

    func events() async -> AsyncStream<SleepWakeEvent> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(8)) { continuation in
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    self?.removeContinuation(id: id)
                }
            }
        }
    }

    func stop() async {
        let activeTokens = notificationTokens
        notificationTokens.removeAll()
        for token in activeTokens {
            notificationCenter.removeObserver(token.value)
        }
    }

    deinit {
        for token in notificationTokens {
            notificationCenter.removeObserver(token.value)
        }
        continuations.values.forEach { $0.finish() }
    }

    private func emit(_ event: SleepWakeEvent) {
        switch event {
        case .willSleep:
            Self.logger.info("System will sleep")
        case .didWake:
            Self.logger.info("System did wake")
        }

        for continuation in continuations.values {
            continuation.yield(event)
        }
    }

    private func removeContinuation(id: UUID) {
        continuations.removeValue(forKey: id)
    }
}
