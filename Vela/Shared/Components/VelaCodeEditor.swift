import AppKit
import SwiftUI

struct VelaCodeEditor: NSViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme

    @Binding var text: String
    var isEditable = true
    var accessibilityLabel = VelaL10n.string(
        "accessibility.configurationEditor",
        defaultValue: "Configuration editor"
    )

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.appearance = appKitAppearance
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.verticalScrollElasticity = .none
        scrollView.horizontalScrollElasticity = .none
        scrollView.usesPredominantAxisScrolling = true

        let textView = NSTextView(frame: .zero)
        textView.appearance = appKitAppearance
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.usesFindPanel = true
        textView.allowsUndo = true
        textView.font = .monospacedSystemFont(ofSize: VelaTypeSize.code, weight: .regular)
        textView.textColor = .labelColor
        textView.backgroundColor = .clear
        textView.textContainerInset = NSSize(width: VelaSpacing.small, height: VelaSpacing.small)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.string = text
        textView.setAccessibilityLabel(localizedAccessibilityLabel)
        scrollView.documentView = textView
        let ruler = VelaLineNumberRulerView(textView: textView, scrollView: scrollView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        context.coordinator.textView = textView
        context.coordinator.ruler = ruler
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        applyAppearance(to: scrollView, textView: textView, ruler: context.coordinator.ruler)
        textView.isEditable = isEditable
        textView.setAccessibilityLabel(localizedAccessibilityLabel)
        if textView.string != text, !context.coordinator.isApplyingEdit {
            textView.string = text
        }
        context.coordinator.ruler?.needsDisplay = true
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        weak var textView: NSTextView?
        fileprivate weak var ruler: VelaLineNumberRulerView?
        var isApplyingEdit = false

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            isApplyingEdit = true
            text.wrappedValue = textView.string
            isApplyingEdit = false
            ruler?.needsDisplay = true
        }
    }

    private var localizedAccessibilityLabel: String {
        VelaL10n.legacy(accessibilityLabel)
    }

    private var appKitAppearance: NSAppearance? {
        NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
    }

    private func applyAppearance(
        to scrollView: NSScrollView,
        textView: NSTextView,
        ruler: NSRulerView?
    ) {
        let appearance = appKitAppearance
        scrollView.appearance = appearance
        textView.appearance = appearance
        ruler?.appearance = appearance
        textView.textColor = .labelColor
    }
}

@MainActor
fileprivate final class VelaLineNumberRulerView: NSRulerView {
    private weak var textView: NSTextView?

    init(textView: NSTextView, scrollView: NSScrollView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 38
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard
            let textView,
            let layoutManager = textView.layoutManager,
            let textContainer = textView.textContainer
        else { return }

        NSColor.controlBackgroundColor.setFill()
        rect.fill()

        let visibleRect = textView.enclosingScrollView?.contentView.bounds ?? textView.visibleRect
        let glyphRange = layoutManager.glyphRange(
            forBoundingRect: visibleRect,
            in: textContainer
        )
        let characterRange = layoutManager.characterRange(
            forGlyphRange: glyphRange,
            actualGlyphRange: nil
        )
        let source = textView.string as NSString
        var characterIndex = characterRange.location
        var lineNumber = 1
        if characterIndex > 0 {
            let prefix = source.substring(to: min(characterIndex, source.length))
            lineNumber += prefix.reduce(into: 0) { count, character in
                if character == "\n" { count += 1 }
            }
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]

        while characterIndex < NSMaxRange(characterRange), characterIndex < source.length {
            let lineRange = source.lineRange(for: NSRange(location: characterIndex, length: 0))
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: lineRange.location)
            var effectiveRange = NSRange()
            let fragment = layoutManager.lineFragmentRect(
                forGlyphAt: glyphIndex,
                effectiveRange: &effectiveRange
            )
            let label = NSString(string: String(lineNumber))
            let labelSize = label.size(withAttributes: attributes)
            let y = fragment.minY + textView.textContainerOrigin.y - visibleRect.minY
            label.draw(
                at: NSPoint(x: ruleThickness - labelSize.width - 7, y: y),
                withAttributes: attributes
            )

            characterIndex = NSMaxRange(lineRange)
            lineNumber += 1
        }

        NSColor.separatorColor.setStroke()
        let divider = NSBezierPath()
        divider.move(to: NSPoint(x: ruleThickness - 0.5, y: rect.minY))
        divider.line(to: NSPoint(x: ruleThickness - 0.5, y: rect.maxY))
        divider.stroke()
    }
}
