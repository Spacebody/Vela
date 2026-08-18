import AppKit
import SwiftUI

struct VelaSensitiveText: View {
    let value: String
    var redactedValue = "••••••••"
    var autoHideSeconds: Double = 15
    var allowsCopy = true

    @State private var isRevealed = false

    var body: some View {
        HStack(spacing: VelaSpacing.xSmall) {
            Text(isRevealed ? value : redactedValue)
                .font(VelaTypography.code)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)

            Button(isRevealed ? VelaL10n.string("legacy.hide", defaultValue: "Hide") : VelaL10n.string("legacy.reveal", defaultValue: "Reveal"), systemImage: isRevealed ? "eye.slash" : "eye") {
                isRevealed.toggle()
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)

            if allowsCopy, isRevealed {
                Button(VelaL10n.string("legacy.copy", defaultValue: "Copy"), systemImage: "doc.on.doc") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(value, forType: .string)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityValue(isRevealed ? VelaL10n.string("legacy.revealed", defaultValue: "Revealed") : VelaL10n.string("legacy.hidden", defaultValue: "Hidden"))
        .task(id: isRevealed) {
            guard isRevealed, autoHideSeconds > 0 else { return }
            try? await Task.sleep(for: .seconds(autoHideSeconds))
            guard !Task.isCancelled else { return }
            isRevealed = false
        }
    }
}
