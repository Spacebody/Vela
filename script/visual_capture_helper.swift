import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

private enum HelperError: LocalizedError {
    case invalidArguments(String)
    case accessibilityUnavailable
    case processUnavailable(pid_t)
    case elementUnavailable(String)
    case actionFailed(String, AXError)
    case windowUnavailable(pid_t, String?)
    case invalidGeometry(String)

    var errorDescription: String? {
        switch self {
        case let .invalidArguments(message): message
        case .accessibilityUnavailable:
            "Accessibility access is unavailable for the visual capture helper."
        case let .processUnavailable(pid):
            "Process \(pid) is unavailable."
        case let .elementUnavailable(identifier):
            "Accessibility element is unavailable: \(identifier)"
        case let .actionFailed(action, error):
            "Accessibility action \(action) failed with AXError \(error.rawValue)."
        case let .windowUnavailable(pid, title):
            "No on-screen layer-zero window for PID \(pid)"
                + (title.map { " with title \($0)" } ?? "")
        case let .invalidGeometry(context):
            "Invalid accessibility geometry: \(context)"
        }
    }
}

private struct WindowRecord {
    let identifier: CGWindowID
    let bounds: CGRect
    let layer: Int
    let title: String

    var json: [String: Any] {
        [
            "id": Int(identifier),
            "x": bounds.origin.x,
            "y": bounds.origin.y,
            "width": bounds.width,
            "height": bounds.height,
            "layer": layer,
            "title": title,
        ]
    }
}

private func parsePID(_ value: String) throws -> pid_t {
    guard let raw = Int32(value), raw > 1 else {
        throw HelperError.invalidArguments("PID must be an integer greater than 1.")
    }
    guard kill(raw, 0) == 0 || errno == EPERM else {
        throw HelperError.processUnavailable(raw)
    }
    return raw
}

private func parseTimeout(_ value: String) throws -> TimeInterval {
    guard let timeout = TimeInterval(value), timeout > 0, timeout <= 60 else {
        throw HelperError.invalidArguments("Timeout must be greater than 0 and at most 60 seconds.")
    }
    return timeout
}

private func copyAttribute(
    _ element: AXUIElement,
    _ attribute: CFString
) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
        return nil
    }
    return value
}

private func stringAttribute(
    _ element: AXUIElement,
    _ attribute: CFString
) -> String {
    copyAttribute(element, attribute) as? String ?? ""
}

private func elementAttribute(
    _ element: AXUIElement,
    _ attribute: CFString
) -> AXUIElement? {
    guard let value = copyAttribute(element, attribute),
        CFGetTypeID(value) == AXUIElementGetTypeID()
    else {
        return nil
    }
    return unsafeBitCast(value, to: AXUIElement.self)
}

private func children(of element: AXUIElement) -> [AXUIElement] {
    copyAttribute(element, kAXChildrenAttribute as CFString) as? [AXUIElement] ?? []
}

private func supportsAction(
    _ element: AXUIElement,
    action: CFString
) -> Bool {
    var names: CFArray?
    guard AXUIElementCopyActionNames(element, &names) == .success,
        let actions = names as? [String]
    else {
        return false
    }
    return actions.contains(action as String)
}

private func findElement(
    in root: AXUIElement,
    matching predicate: (AXUIElement) -> Bool,
    maximumNodes: Int = 20_000
) -> AXUIElement? {
    var stack = [root]
    var visited = 0
    while let element = stack.popLast(), visited < maximumNodes {
        visited += 1
        if predicate(element) {
            return element
        }
        stack.append(contentsOf: children(of: element).reversed())
    }
    return nil
}

private func element(
    pid: pid_t,
    identifier: String,
    requiringAction action: CFString? = nil
) throws -> AXUIElement {
    let application = AXUIElementCreateApplication(pid)
    guard let match = findElement(in: application, matching: { candidate in
        guard stringAttribute(candidate, kAXIdentifierAttribute as CFString) == identifier
        else {
            return false
        }
        guard let action else { return true }
        return supportsAction(candidate, action: action)
    }) else {
        throw HelperError.elementUnavailable(identifier)
    }
    return match
}

private func enclosingWindow(of element: AXUIElement) -> AXUIElement? {
    if let window = elementAttribute(element, kAXWindowAttribute as CFString) {
        return window
    }

    var current: AXUIElement? = element
    var visited = 0
    while let candidate = current, visited < 64 {
        visited += 1
        if stringAttribute(candidate, kAXRoleAttribute as CFString)
            == kAXWindowRole as String
        {
            return candidate
        }
        current = elementAttribute(candidate, kAXParentAttribute as CFString)
    }
    return nil
}

private func pointAttribute(
    _ element: AXUIElement,
    attribute: CFString
) -> CGPoint? {
    guard let raw = copyAttribute(element, attribute),
        CFGetTypeID(raw) == AXValueGetTypeID()
    else {
        return nil
    }
    let value = unsafeBitCast(raw, to: AXValue.self)
    var result = CGPoint.zero
    guard AXValueGetType(value) == .cgPoint,
        AXValueGetValue(value, .cgPoint, &result)
    else {
        return nil
    }
    return result
}

private func sizeAttribute(
    _ element: AXUIElement,
    attribute: CFString
) -> CGSize? {
    guard let raw = copyAttribute(element, attribute),
        CFGetTypeID(raw) == AXValueGetTypeID()
    else {
        return nil
    }
    let value = unsafeBitCast(raw, to: AXValue.self)
    var result = CGSize.zero
    guard AXValueGetType(value) == .cgSize,
        AXValueGetValue(value, .cgSize, &result)
    else {
        return nil
    }
    return result
}

private func frame(of element: AXUIElement) throws -> CGRect {
    guard let origin = pointAttribute(
        element,
        attribute: kAXPositionAttribute as CFString
    ), let size = sizeAttribute(
        element,
        attribute: kAXSizeAttribute as CFString
    ), origin.x.isFinite, origin.y.isFinite, size.width.isFinite,
        size.height.isFinite, size.width > 0, size.height > 0
    else {
        throw HelperError.invalidGeometry(
            stringAttribute(element, kAXIdentifierAttribute as CFString)
        )
    }
    return CGRect(origin: origin, size: size)
}

private func windows(pid: pid_t) -> [WindowRecord] {
    let raw = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements],
        kCGNullWindowID
    ) as? [[String: Any]] ?? []
    return raw.compactMap { item in
        guard let owner = item[kCGWindowOwnerPID as String] as? NSNumber,
            owner.int32Value == pid,
            let number = item[kCGWindowNumber as String] as? NSNumber,
            let boundsValue = item[kCGWindowBounds as String] as? NSDictionary,
            let bounds = CGRect(dictionaryRepresentation: boundsValue),
            bounds.width.isFinite, bounds.height.isFinite,
            bounds.width > 0, bounds.height > 0
        else {
            return nil
        }
        let layer = (item[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
        let title = item[kCGWindowName as String] as? String ?? ""
        return WindowRecord(
            identifier: CGWindowID(number.uint32Value),
            bounds: bounds,
            layer: layer,
            title: title
        )
    }
}

private func layerZeroWindow(
    pid: pid_t,
    title: String?
) throws -> WindowRecord {
    let matches = windows(pid: pid).filter { record in
        guard record.layer == 0 else { return false }
        guard let title else { return true }
        return record.title == title
    }
    guard let selected = matches.max(by: {
        $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height
    }) else {
        throw HelperError.windowUnavailable(pid, title)
    }
    return selected
}

private func waitForIdentifier(
    pid: pid_t,
    identifier: String,
    timeout: TimeInterval,
    requiringAction action: CFString? = nil
) throws -> AXUIElement {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if let match = try? element(
            pid: pid,
            identifier: identifier,
            requiringAction: action
        ) {
            return match
        }
        Thread.sleep(forTimeInterval: 0.05)
    } while Date() < deadline
    throw HelperError.elementUnavailable(identifier)
}

private func activate(pid: pid_t) throws {
    guard let application = NSRunningApplication(processIdentifier: pid),
        !application.isTerminated
    else {
        throw HelperError.processUnavailable(pid)
    }
    if application.activate(options: [.activateAllWindows]) {
        return
    }

    // Repeated direct launches can temporarily leave LaunchServices unable to
    // activate a newly registered app even though its exact PID and AX tree are
    // already valid. Keep the fallback PID-scoped and use the public AX
    // frontmost attribute instead of posting a global application switch.
    let accessibilityApplication = AXUIElementCreateApplication(pid)
    let result = AXUIElementSetAttributeValue(
        accessibilityApplication,
        kAXFrontmostAttribute as CFString,
        kCFBooleanTrue
    )
    guard result == .success else {
        throw HelperError.actionFailed("activate", result)
    }
}

private func press(_ element: AXUIElement, context: String) throws {
    let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
    guard result == .success else {
        throw HelperError.actionFailed(context, result)
    }
}

private func click(_ element: AXUIElement, context: String) throws {
    let bounds = try frame(of: element)
    let center = CGPoint(x: bounds.midX, y: bounds.midY)
    guard let move = CGEvent(
        mouseEventSource: nil,
        mouseType: .mouseMoved,
        mouseCursorPosition: center,
        mouseButton: .left
    ), let down = CGEvent(
        mouseEventSource: nil,
        mouseType: .leftMouseDown,
        mouseCursorPosition: center,
        mouseButton: .left
    ), let up = CGEvent(
        mouseEventSource: nil,
        mouseType: .leftMouseUp,
        mouseCursorPosition: center,
        mouseButton: .left
    ) else {
        throw HelperError.invalidGeometry(context)
    }
    move.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.05)
    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)
}

private func openSettings(pid: pid_t) throws {
    try activate(pid: pid)
    let application = AXUIElementCreateApplication(pid)
    let settingsTitles = Set(["Settings…", "Settings...", "设置…", "设置..."])
    let menuRoot = elementAttribute(
        application,
        kAXMenuBarAttribute as CFString
    )
    if let menuRoot {
        if let applicationMenu = findElement(in: menuRoot, matching: { candidate in
            stringAttribute(candidate, kAXRoleAttribute as CFString)
                == kAXMenuBarItemRole as String
                && stringAttribute(candidate, kAXTitleAttribute as CFString) == "Vela"
                && supportsAction(candidate, action: kAXPressAction as CFString)
        }, maximumNodes: 200) {
            try press(applicationMenu, context: "Vela application menu")
            Thread.sleep(forTimeInterval: 0.08)
        }
        if let menuItem = findElement(in: menuRoot, matching: { candidate in
            stringAttribute(candidate, kAXRoleAttribute as CFString)
                == kAXMenuItemRole as String
                && settingsTitles.contains(
                    stringAttribute(candidate, kAXTitleAttribute as CFString)
                )
                && supportsAction(candidate, action: kAXPressAction as CFString)
        }, maximumNodes: 2_000) {
            try press(menuItem, context: "Settings menu item")
            return
        }
    }

    // ANSI key code 43 is comma on the supported macOS capture host.
    guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 43, keyDown: true),
        let up = CGEvent(keyboardEventSource: nil, virtualKey: 43, keyDown: false)
    else {
        throw HelperError.actionFailed("Command+,", .failure)
    }
    down.flags = .maskCommand
    up.flags = .maskCommand
    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)
}

private func roleElement(
    pid: pid_t,
    role: CFString,
    timeout: TimeInterval
) throws -> AXUIElement {
    let application = AXUIElementCreateApplication(pid)
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if let match = findElement(in: application, matching: { candidate in
            stringAttribute(candidate, kAXRoleAttribute as CFString) == role as String
                && (try? frame(of: candidate)) != nil
        }) {
            return match
        }
        Thread.sleep(forTimeInterval: 0.05)
    } while Date() < deadline
    throw HelperError.elementUnavailable(role as String)
}

private func menuItemTitles(in menu: AXUIElement) -> Set<String> {
    var titles = Set<String>()
    var stack = children(of: menu)
    while let candidate = stack.popLast() {
        if stringAttribute(candidate, kAXRoleAttribute as CFString)
            == kAXMenuItemRole as String
        {
            let title = stringAttribute(candidate, kAXTitleAttribute as CFString)
            if !title.isEmpty { titles.insert(title) }
        }
        stack.append(contentsOf: children(of: candidate))
    }
    return titles
}

private func extrasMenuBar(pid: pid_t) -> AXUIElement? {
    let application = AXUIElementCreateApplication(pid)
    guard let raw = copyAttribute(
        application,
        kAXExtrasMenuBarAttribute as CFString
    ), CFGetTypeID(raw) == AXUIElementGetTypeID()
    else {
        return nil
    }
    return unsafeBitCast(raw, to: AXUIElement.self)
}

private func waitForMenuBarItem(
    pid: pid_t,
    timeout: TimeInterval
) throws -> AXUIElement {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if let extras = extrasMenuBar(pid: pid) {
            let identifierMatch = findElement(in: extras, matching: { candidate in
                stringAttribute(candidate, kAXIdentifierAttribute as CFString)
                    == "menubar.open"
                    && supportsAction(candidate, action: kAXPressAction as CFString)
            })
            if let identifierMatch {
                return identifierMatch
            }
            let roleMatch = findElement(in: extras, matching: { candidate in
                stringAttribute(candidate, kAXRoleAttribute as CFString)
                    == kAXMenuBarItemRole as String
                    && supportsAction(candidate, action: kAXPressAction as CFString)
            })
            if let roleMatch {
                return roleMatch
            }
        }
        Thread.sleep(forTimeInterval: 0.05)
    } while Date() < deadline
    throw HelperError.elementUnavailable("Vela extras-menu-bar item")
}

private func matchingWindow(
    pid: pid_t,
    frame target: CGRect
) -> WindowRecord? {
    windows(pid: pid).min(by: { lhs, rhs in
        geometryDistance(lhs.bounds, target) < geometryDistance(rhs.bounds, target)
    }).flatMap { candidate in
        geometryDistance(candidate.bounds, target) <= 8 ? candidate : nil
    }
}

private func geometryDistance(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
    abs(lhs.minX - rhs.minX) + abs(lhs.minY - rhs.minY)
        + abs(lhs.width - rhs.width) + abs(lhs.height - rhs.height)
}

private func rectJSON(_ rect: CGRect, window: WindowRecord? = nil) -> [String: Any] {
    var value: [String: Any] = [
        "x": rect.origin.x,
        "y": rect.origin.y,
        "width": rect.width,
        "height": rect.height,
    ]
    if let window {
        value["id"] = Int(window.identifier)
        value["layer"] = window.layer
        value["title"] = window.title
        value["windowBounds"] = [
            "x": window.bounds.origin.x,
            "y": window.bounds.origin.y,
            "width": window.bounds.width,
            "height": window.bounds.height,
        ]
    }
    return value
}

private func printJSON(_ value: [String: Any]) throws {
    let data = try JSONSerialization.data(
        withJSONObject: value,
        options: [.sortedKeys, .withoutEscapingSlashes]
    )
    guard let line = String(data: data, encoding: .utf8) else {
        throw HelperError.invalidArguments("Could not encode helper JSON output.")
    }
    print(line)
}

private func usage() -> String {
    "Usage: visual_capture_helper trusted | activate PID | window PID [TITLE] | "
        + "window-id PID IDENTIFIER | "
        + "wait-id PID IDENTIFIER TIMEOUT | press-id PID IDENTIFIER | "
        + "click-id PID IDENTIFIER | open-settings PID | sheet PID [TIMEOUT] | "
        + "menu PID [TIMEOUT]"
}

private func run(_ arguments: [String]) throws {
    guard let command = arguments.first else {
        throw HelperError.invalidArguments(usage())
    }
    if command == "trusted" {
        guard arguments.count == 1 else {
            throw HelperError.invalidArguments(usage())
        }
        guard AXIsProcessTrusted() else {
            throw HelperError.accessibilityUnavailable
        }
        print("trusted")
        return
    }
    guard AXIsProcessTrusted() else {
        throw HelperError.accessibilityUnavailable
    }

    switch command {
    case "activate":
        guard arguments.count == 2 else { throw HelperError.invalidArguments(usage()) }
        try activate(pid: parsePID(arguments[1]))
    case "window":
        guard arguments.count == 2 || arguments.count == 3 else {
            throw HelperError.invalidArguments(usage())
        }
        let record = try layerZeroWindow(
            pid: parsePID(arguments[1]),
            title: arguments.count == 3 ? arguments[2] : nil
        )
        try printJSON(record.json)
    case "window-id":
        guard arguments.count == 3 else {
            throw HelperError.invalidArguments(usage())
        }
        let pid = try parsePID(arguments[1])
        let identifier = arguments[2]
        let marker = try element(pid: pid, identifier: identifier)
        guard let window = enclosingWindow(of: marker) else {
            throw HelperError.elementUnavailable("window containing \(identifier)")
        }
        let bounds = try frame(of: window)
        guard let record = matchingWindow(pid: pid, frame: bounds), record.layer == 0 else {
            throw HelperError.windowUnavailable(pid, nil)
        }
        try printJSON(record.json)
    case "wait-id":
        guard arguments.count == 4 else { throw HelperError.invalidArguments(usage()) }
        _ = try waitForIdentifier(
            pid: parsePID(arguments[1]),
            identifier: arguments[2],
            timeout: parseTimeout(arguments[3])
        )
    case "press-id":
        guard arguments.count == 3 else { throw HelperError.invalidArguments(usage()) }
        let pid = try parsePID(arguments[1])
        try press(
            try element(
                pid: pid,
                identifier: arguments[2],
                requiringAction: kAXPressAction as CFString
            ),
            context: arguments[2]
        )
    case "click-id":
        guard arguments.count == 3 else { throw HelperError.invalidArguments(usage()) }
        let pid = try parsePID(arguments[1])
        try click(try element(pid: pid, identifier: arguments[2]), context: arguments[2])
    case "open-settings":
        guard arguments.count == 2 else { throw HelperError.invalidArguments(usage()) }
        try openSettings(pid: parsePID(arguments[1]))
    case "sheet":
        guard arguments.count == 2 || arguments.count == 3 else {
            throw HelperError.invalidArguments(usage())
        }
        let pid = try parsePID(arguments[1])
        let timeout = try parseTimeout(arguments.count == 3 ? arguments[2] : "5")
        let sheet = try roleElement(pid: pid, role: kAXSheetRole as CFString, timeout: timeout)
        let bounds = try frame(of: sheet)
        try printJSON(rectJSON(bounds, window: matchingWindow(pid: pid, frame: bounds)))
    case "menu":
        guard arguments.count == 2 || arguments.count == 3 else {
            throw HelperError.invalidArguments(usage())
        }
        let pid = try parsePID(arguments[1])
        let timeout = try parseTimeout(arguments.count == 3 ? arguments[2] : "5")
        try activate(pid: pid)
        let item = try waitForMenuBarItem(pid: pid, timeout: timeout)
        let pressDeadline = Date().addingTimeInterval(timeout)
        var pressResult = AXUIElementPerformAction(
            item,
            kAXPressAction as CFString
        )
        while pressResult == .cannotComplete, Date() < pressDeadline {
            Thread.sleep(forTimeInterval: 0.08)
            pressResult = AXUIElementPerformAction(
                item,
                kAXPressAction as CFString
            )
        }
        guard pressResult == .success else {
            throw HelperError.actionFailed("menubar.open", pressResult)
        }
        let deadline = Date().addingTimeInterval(timeout)
        let application = AXUIElementCreateApplication(pid)
        var selected: AXUIElement?
        repeat {
            if let menu = findElement(in: application, matching: { candidate in
                stringAttribute(candidate, kAXRoleAttribute as CFString)
                    == kAXMenuRole as String
                    && (try? frame(of: candidate)) != nil
            }) {
                let titles = menuItemTitles(in: menu)
                let hasSettings = titles.contains("Settings") || titles.contains("设置")
                if hasSettings && titles.contains("TUN") {
                    selected = menu
                    break
                }
            }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < deadline
        guard let selected else {
            throw HelperError.elementUnavailable("visible Vela AXMenu with Settings and TUN")
        }
        let bounds = try frame(of: selected)
        var value = rectJSON(bounds, window: matchingWindow(pid: pid, frame: bounds))
        value["menuItemTitles"] = menuItemTitles(in: selected).sorted()
        try printJSON(value)
    default:
        throw HelperError.invalidArguments(usage())
    }
}

do {
    try run(Array(CommandLine.arguments.dropFirst()))
} catch {
    let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    FileHandle.standardError.write(Data(("error: \(message)\n").utf8))
    exit(2)
}
