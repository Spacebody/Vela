import AppKit
import SwiftUI

nonisolated struct VelaWindowGeometry: Equatable, Sendable {
    let frameSize: CGSize
    let contentLayoutSize: CGSize

    var accessibilityLabel: String {
        "Vela main window geometry; frame \(dimension(frameSize.width))x\(dimension(frameSize.height)); "
            + "content \(dimension(contentLayoutSize.width))x\(dimension(contentLayoutSize.height))"
    }

    private func dimension(_ value: CGFloat) -> String {
        String(format: "%.1f", value)
    }
}

nonisolated struct VelaWindowTestRequest: Equatable, Sendable {
    // Keep window-policy controls distinct from the visual-fixture launch
    // namespace reserved for deterministic screenshot fixtures.
    static let modeKey = "-VelaMainWindowPolicyTest"
    static let requestedContentSizeKey = "-VelaRequestedContentSize"
    static let sceneIdentifierKey = "-VelaPolicySceneIdentifier"

    let requestedContentSize: CGSize?
    let sceneIdentifier: String

    static func resolve(
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) throws -> VelaWindowTestRequest? {
        guard arguments.contains(modeKey) else { return nil }
        guard value(after: modeKey, in: arguments)?.caseInsensitiveCompare("YES")
            == .orderedSame
        else {
            throw VelaWindowTestRequestError.invalidMode
        }
        let sceneIdentifier = value(after: sceneIdentifierKey, in: arguments)
            ?? "<missing>"
        guard sceneIdentifier.hasPrefix("main-window-policy-test-"),
            sceneIdentifier.count <= 96,
            sceneIdentifier.unicodeScalars.allSatisfy({ scalar in
                CharacterSet.alphanumerics.contains(scalar)
                    || scalar.value == 45 || scalar.value == 46
            })
        else {
            throw VelaWindowTestRequestError.invalidSceneIdentifier(
                sceneIdentifier
            )
        }
        guard let rawSize = value(after: requestedContentSizeKey, in: arguments) else {
            return VelaWindowTestRequest(
                requestedContentSize: nil,
                sceneIdentifier: sceneIdentifier
            )
        }
        let components = rawSize.split(separator: "x", omittingEmptySubsequences: false)
        guard components.count == 2,
            let width = Double(components[0]),
            let height = Double(components[1]),
            width.isFinite,
            height.isFinite,
            (200 ... 4_000).contains(width),
            (200 ... 4_000).contains(height)
        else {
            throw VelaWindowTestRequestError.invalidContentSize(rawSize)
        }
        return VelaWindowTestRequest(
            requestedContentSize: CGSize(width: width, height: height),
            sceneIdentifier: sceneIdentifier
        )
    }

    private static func value(after key: String, in arguments: [String]) -> String? {
        guard let keyIndex = arguments.lastIndex(of: key) else { return nil }
        let valueIndex = arguments.index(after: keyIndex)
        guard valueIndex < arguments.endIndex else { return nil }
        let value = arguments[valueIndex]
        return value.hasPrefix("-") ? nil : value
    }
}

nonisolated enum VelaWindowTestRequestError: Error, Equatable, Sendable {
    case invalidMode
    case invalidContentSize(String)
    case invalidSceneIdentifier(String)
}

/// Debug measurement/accessor bridge used by isolated visual and window-policy
/// tests. Production sizing is owned entirely by the SwiftUI Scene policy.
struct VelaWindowConfigurationView: NSViewRepresentable {
    let targetFrameSize: CGSize?
    let testRequest: VelaWindowTestRequest?
    @Binding var chromeSize: CGSize
    @Binding var geometry: VelaWindowGeometry?

    func makeNSView(context: Context) -> WindowConfigurationNSView {
        let view = WindowConfigurationNSView()
        view.update(
            targetFrameSize: targetFrameSize,
            testRequest: testRequest,
            reportChromeSize: reportChromeSize,
            reportGeometry: reportGeometry
        )
        return view
    }

    func updateNSView(_ nsView: WindowConfigurationNSView, context: Context) {
        nsView.update(
            targetFrameSize: targetFrameSize,
            testRequest: testRequest,
            reportChromeSize: reportChromeSize,
            reportGeometry: reportGeometry
        )
    }

    private func reportChromeSize(_ measuredSize: CGSize) {
        guard targetFrameSize != nil else { return }
        chromeSize = measuredSize
    }

    private func reportGeometry(_ measuredGeometry: VelaWindowGeometry) {
        guard geometry != measuredGeometry else { return }
        geometry = measuredGeometry
    }
}

final class WindowConfigurationNSView: NSView {
    private var configuredTargetFrameSize: CGSize?
    private var configuredTestRequest: VelaWindowTestRequest?
    private var configuredChromeSizeReporter: (CGSize) -> Void = { _ in }
    private var configuredGeometryReporter: (VelaWindowGeometry) -> Void = { _ in }
    private var lastReportedChromeSize: CGSize?
    private var isConfigurationScheduled = false
    private var didApplyTestRequest = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scheduleConfiguration()
    }

    func update(
        targetFrameSize: CGSize?,
        testRequest: VelaWindowTestRequest?,
        reportChromeSize: @escaping (CGSize) -> Void,
        reportGeometry: @escaping (VelaWindowGeometry) -> Void
    ) {
        configuredTargetFrameSize = targetFrameSize
        if configuredTestRequest != testRequest {
            configuredTestRequest = testRequest
            didApplyTestRequest = false
        }
        configuredChromeSizeReporter = reportChromeSize
        configuredGeometryReporter = reportGeometry
        scheduleConfiguration()
    }

    private func scheduleConfiguration() {
        // `updateNSView` is commonly called before this representable is
        // attached. Do not consume the one-shot schedule until an NSWindow
        // actually exists; `viewDidMoveToWindow` will schedule it reliably.
        guard window != nil else { return }
        guard !isConfigurationScheduled else { return }
        isConfigurationScheduled = true
        Task { @MainActor [weak self] in
            // Never mutate an Auto Layout managed NSWindow from inside
            // NSViewRepresentable.updateNSView or an AppKit resize callback.
            // The visual harness previously proved that doing so can recurse
            // through Update Constraints and terminate the process.
            await Task.yield()
            // The unified toolbar is installed on the following AppKit turns.
            // Measure only after that bounded setup window so the reported
            // content-layout delta includes the real titlebar/toolbar chrome.
            try? await Task.sleep(for: .milliseconds(250))
            guard let self else { return }
            self.isConfigurationScheduled = false
            self.applyConfiguration()
        }
    }

    private func applyConfiguration() {
        guard let window else { return }

        if let requestedContentSize = configuredTestRequest?.requestedContentSize,
            !didApplyTestRequest
        {
            // Explicitly Debug/UI-test-only. NSWindow applies the production
            // SwiftUI content-minimum constraint to this attempted resize.
            didApplyTestRequest = true
            window.setContentSize(requestedContentSize)
        }

        let layoutSize = window.contentLayoutRect.size
        configuredGeometryReporter(
            VelaWindowGeometry(
                frameSize: window.frame.size,
                contentLayoutSize: layoutSize
            )
        )
        guard configuredTargetFrameSize != nil else { return }

        let measuredChromeSize = CGSize(
            width: max(0, window.frame.width - layoutSize.width),
            height: max(0, window.frame.height - layoutSize.height)
        )
        if lastReportedChromeSize.map({ previous in
            abs(previous.width - measuredChromeSize.width) <= 0.5
                && abs(previous.height - measuredChromeSize.height) <= 0.5
        }) != true {
            lastReportedChromeSize = measuredChromeSize
            configuredChromeSizeReporter(measuredChromeSize)
        }

        // A visual fixture is a disposable presentation process. Detach the
        // dedicated test window from autosave. SwiftUI's content-size scene
        // policy owns the exact outer frame after this bridge reports the
        // native toolbar/titlebar delta; direct frame mutation is intentionally
        // avoided because it can recurse through AppKit layout callbacks.
        _ = window.setFrameAutosaveName("")
        let splitViews = splitViews(in: window.contentView)
        for splitView in splitViews {
            // NavigationSplitView owns an AppKit NSSplitView whose separate
            // autosave record can otherwise replay a stale content height and
            // expand the outer window even after NSWindow autosave is detached.
            splitView.autosaveName = nil
        }
    }

    private func splitViews(in root: NSView?) -> [NSSplitView] {
        guard let root else { return [] }
        let nested = root.subviews.flatMap { splitViews(in: $0) }
        if let splitView = root as? NSSplitView {
            return [splitView] + nested
        }
        return nested
    }
}
