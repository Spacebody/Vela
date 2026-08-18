import Foundation
import IOKit
import IOKit.pwr_mgt
import VelaPrivilegedCore

/// Receives system power transitions from the root power domain. A privileged
/// LaunchDaemon must not depend on a per-user AppKit workspace session for
/// lease correctness.
final class VelaHelperPowerObserver: @unchecked Sendable {
    private let coordinator: PrivilegedHelperCoordinator
    private let callbackQueue = DispatchQueue(
        label: "dev.yilin.Vela.Helper.Power",
        qos: .utility
    )
    private var rootPowerPort: io_connect_t = IO_OBJECT_NULL
    private var notificationPort: IONotificationPortRef?
    private var notifier: io_object_t = IO_OBJECT_NULL

    init(coordinator: PrivilegedHelperCoordinator) throws {
        self.coordinator = coordinator

        var registeredNotificationPort: IONotificationPortRef?
        var registeredNotifier: io_object_t = IO_OBJECT_NULL
        let registeredRootPort = IORegisterForSystemPower(
            Unmanaged.passUnretained(self).toOpaque(),
            &registeredNotificationPort,
            velaHelperPowerCallback,
            &registeredNotifier
        )
        guard registeredRootPort != IO_OBJECT_NULL,
            let registeredNotificationPort,
            registeredNotifier != IO_OBJECT_NULL
        else {
            if registeredNotifier != IO_OBJECT_NULL {
                var notifierToRemove = registeredNotifier
                _ = IODeregisterForSystemPower(&notifierToRemove)
            }
            if let registeredNotificationPort {
                IONotificationPortDestroy(registeredNotificationPort)
            }
            if registeredRootPort != IO_OBJECT_NULL {
                IOServiceClose(registeredRootPort)
            }
            throw VelaHelperPowerObserverError.registrationFailed
        }

        rootPowerPort = registeredRootPort
        notificationPort = registeredNotificationPort
        notifier = registeredNotifier
        IONotificationPortSetDispatchQueue(registeredNotificationPort, callbackQueue)
    }

    deinit {
        if let notificationPort {
            IONotificationPortSetDispatchQueue(notificationPort, nil)
        }
        if notifier != IO_OBJECT_NULL {
            var notifierToRemove = notifier
            _ = IODeregisterForSystemPower(&notifierToRemove)
            notifier = IO_OBJECT_NULL
        }
        if let notificationPort {
            IONotificationPortDestroy(notificationPort)
            self.notificationPort = nil
        }
        if rootPowerPort != IO_OBJECT_NULL {
            IOServiceClose(rootPowerPort)
            rootPowerPort = IO_OBJECT_NULL
        }
    }

    fileprivate func handlePowerMessage(
        type: natural_t,
        argument: UnsafeMutableRawPointer?
    ) {
        switch type {
        case VelaSystemPowerMessage.canSystemSleep:
            // Vela never vetoes idle sleep.
            _ = IOAllowPowerChange(rootPowerPort, Int(bitPattern: argument))

        case VelaSystemPowerMessage.systemWillSleep:
            let coordinator = coordinator
            let rootPowerPort = rootPowerPort
            let notificationID = Int(bitPattern: argument)
            Task {
                // Mark the monotonic owner lease asleep before acknowledging
                // the non-abortable transition, closing the expiry race.
                await coordinator.systemWillSleep()
                _ = IOAllowPowerChange(rootPowerPort, notificationID)
            }

        case VelaSystemPowerMessage.systemHasPoweredOn:
            let coordinator = coordinator
            Task { await coordinator.systemDidWake() }

        case VelaSystemPowerMessage.systemWillPowerOn,
            VelaSystemPowerMessage.systemWillNotSleep:
            break

        default:
            break
        }
    }
}

/// Swift does not import IOKit's `iokit_common_msg(...)` structure macros.
/// These are the stable values declared by IOKit/IOMessage.h: the IOKit
/// common-message domain (`err_system(0x38)`) ORed with each documented code.
private enum VelaSystemPowerMessage {
    private static let commonDomain: natural_t = 0xe000_0000

    static let canSystemSleep = commonDomain | 0x270
    static let systemWillSleep = commonDomain | 0x280
    static let systemWillNotSleep = commonDomain | 0x290
    static let systemHasPoweredOn = commonDomain | 0x300
    static let systemWillPowerOn = commonDomain | 0x320
}

private func velaHelperPowerCallback(
    refcon: UnsafeMutableRawPointer?,
    service _: io_service_t,
    messageType: natural_t,
    messageArgument: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let observer = Unmanaged<VelaHelperPowerObserver>
        .fromOpaque(refcon)
        .takeUnretainedValue()
    observer.handlePowerMessage(type: messageType, argument: messageArgument)
}

enum VelaHelperPowerObserverError: Error, Equatable, Sendable {
    case registrationFailed
}
