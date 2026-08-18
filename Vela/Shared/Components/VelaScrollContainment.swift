import AppKit
import SwiftUI

/// Keeps scroll gestures and scroller-thumb drags inside their owning scroll view.
///
/// SwiftUI does not expose a way to disable AppKit scroll elasticity. The probe
/// deliberately owns no state: it only applies a window-local interaction policy
/// to the native scroll views backing the current SwiftUI hierarchy.
@MainActor
enum VelaScrollContainmentPolicy {
    static func apply(to rootView: NSView) {
        if let scrollView = rootView as? NSScrollView {
            if scrollView.verticalScrollElasticity != .none {
                scrollView.verticalScrollElasticity = .none
            }
            if scrollView.horizontalScrollElasticity != .none {
                scrollView.horizontalScrollElasticity = .none
            }
            if !scrollView.usesPredominantAxisScrolling {
                scrollView.usesPredominantAxisScrolling = true
            }
        }

        for subview in rootView.subviews {
            apply(to: subview)
        }
    }
}

private struct VelaScrollContainmentProbe: NSViewRepresentable {
    func makeNSView(context: Context) -> VelaScrollContainmentProbeView {
        VelaScrollContainmentProbeView()
    }

    func updateNSView(_ nsView: VelaScrollContainmentProbeView, context: Context) {
        nsView.schedulePolicyApplication()
    }
}

@MainActor
private final class VelaScrollContainmentProbeView: NSView {
    private var hasScheduledApplication = false

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        schedulePolicyApplication()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        schedulePolicyApplication()
    }

    override func layout() {
        super.layout()
        schedulePolicyApplication()
    }

    func schedulePolicyApplication() {
        guard !hasScheduledApplication else { return }
        hasScheduledApplication = true

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            hasScheduledApplication = false
            guard let contentView = window?.contentView else { return }
            VelaScrollContainmentPolicy.apply(to: contentView)
        }
    }
}

extension View {
    /// Disables elastic cross-axis drift for every native scroll view in the
    /// containing window while preserving standard scrolling and scrollbars.
    func velaContainsNestedScrolling() -> some View {
        background {
            VelaScrollContainmentProbe()
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}
