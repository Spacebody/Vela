import AppKit
import SwiftUI
import Testing
@testable import Vela

@MainActor
struct VelaCodeEditorAppearanceTests {
    @Test
    func lightSwiftUIColorSchemeKeepsLoadedYAMLVisibleInDarkMode() throws {
        let source = """
        mode: rule
        proxies:
          - name: Example
        """
        let host = NSHostingView(
            rootView: VelaCodeEditor(text: .constant(source))
                .environment(\.colorScheme, .light)
                .frame(width: 640, height: 420)
        )
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = NSRect(x: 0, y: 0, width: 640, height: 420)

        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        host.layoutSubtreeIfNeeded()

        let textView = try #require(findTextView(in: host))
        #expect(textView.string == source)
        #expect(textView.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua)
    }

    private func findTextView(in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView {
            return textView
        }
        return view.subviews.lazy.compactMap(findTextView(in:)).first
    }
}
