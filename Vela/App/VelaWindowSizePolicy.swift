import CoreGraphics

/// Single source of truth for the primary navigation window.
///
/// The approved 1040x680 and 1280x820 visual sizes are outer window-frame
/// contracts. A live NSWindow measurement on the supported macOS runtime
/// reports a 32-point unified titlebar region, so content sizes are derived
/// explicitly instead of mixing the two coordinate spaces.
nonisolated enum VelaWindowSizePolicy {
    static let mainMinimumReferenceFrameSize = CGSize(width: 1_040, height: 680)
    static let mainDefaultReferenceFrameSize = CGSize(width: 1_280, height: 820)
    static let measuredUnifiedChromeSize = CGSize(width: 0, height: 32)

    static let mainMinimumContentSize = contentSize(
        forReferenceFrameSize: mainMinimumReferenceFrameSize
    )
    static let mainDefaultContentSize = contentSize(
        forReferenceFrameSize: mainDefaultReferenceFrameSize
    )
    static let mainIdealContentSize = mainDefaultContentSize

    static func referenceFrameSize(forContentSize contentSize: CGSize) -> CGSize {
        CGSize(
            width: contentSize.width + measuredUnifiedChromeSize.width,
            height: contentSize.height + measuredUnifiedChromeSize.height
        )
    }

    static func contentSize(forReferenceFrameSize frameSize: CGSize) -> CGSize {
        CGSize(
            width: max(1, frameSize.width - measuredUnifiedChromeSize.width),
            height: max(1, frameSize.height - measuredUnifiedChromeSize.height)
        )
    }
}
