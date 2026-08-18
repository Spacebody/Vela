import Foundation
import Testing
@testable import Vela

@MainActor
@Suite("Sleep and wake observer", .timeLimit(.minutes(1)))
struct SleepWakeObserverTests {
    @Test("Workspace notifications publish once and stop removes active subscriptions")
    func notificationLifecycle() async {
        let center = NotificationCenter()
        let willSleep = Notification.Name("VelaTests.willSleep")
        let didWake = Notification.Name("VelaTests.didWake")
        let observer = SleepWakeObserver(
            notificationCenter: center,
            willSleepNotification: willSleep,
            didWakeNotification: didWake
        )
        let events = await observer.events()
        var eventIterator = events.makeAsyncIterator()

        await observer.start()
        await observer.start()
        center.post(name: willSleep, object: nil)
        center.post(name: didWake, object: nil)

        #expect(await eventIterator.next() == .willSleep)
        #expect(await eventIterator.next() == .didWake)

        await observer.stop()
        center.post(name: didWake, object: nil)

        await observer.start()
        center.post(name: willSleep, object: nil)
        // If stop left a live subscription, the prior didWake notification is
        // buffered and this exact ordered assertion fails before the restart
        // event is consumed.
        #expect(await eventIterator.next() == .willSleep)

        await observer.stop()
    }
}
