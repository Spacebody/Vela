import SwiftUI

struct VelaTrafficSparkline: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.velaAccessibilityOverrides) private var accessibilityOverrides

    /// A visual trend is presentation evidence, not an unbounded telemetry store.
    /// Keeping the newest two minutes at a one-second presentation cadence avoids
    /// rebuilding arbitrarily large Canvas paths while retaining useful context.
    nonisolated static let maximumPointCount = 120

    let download: [Double]
    let upload: [Double]
    let downloadSummary: String
    let uploadSummary: String
    var height: CGFloat = 52

    var body: some View {
        Canvas { context, size in
            draw(
                series: Self.bounded(download),
                color: .blue,
                in: size,
                context: &context
            )
            draw(
                series: Self.bounded(upload),
                color: .green,
                in: size,
                context: &context
            )
        }
        .frame(minHeight: height, maxHeight: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(VelaL10n.string("legacy.trafficTrend", defaultValue: "Traffic trend"))
        .accessibilityValue(VelaL10n.string("legacy.downloadUploadObjectFormat", defaultValue: "Download %@. Upload %@.", arguments: downloadSummary, uploadSummary))
        .animation(usesReducedMotion ? nil : .easeOut(duration: VelaMotion.fastSeconds), value: download)
        .animation(usesReducedMotion ? nil : .easeOut(duration: VelaMotion.fastSeconds), value: upload)
    }

    nonisolated static func bounded(_ samples: [Double]) -> [Double] {
        Array(samples.suffix(maximumPointCount))
    }

    private var usesReducedMotion: Bool {
        accessibilityOverrides.reduceMotion ?? reduceMotion
    }

    private func draw(
        series: [Double],
        color: Color,
        in size: CGSize,
        context: inout GraphicsContext
    ) {
        guard series.count > 1 else { return }
        let maximum = max(download.max() ?? 0, upload.max() ?? 0, 1)
        let step = size.width / CGFloat(series.count - 1)
        var path = Path()

        for (index, rawValue) in series.enumerated() {
            let value = min(max(rawValue, 0), maximum)
            let point = CGPoint(
                x: CGFloat(index) * step,
                y: size.height - (CGFloat(value / maximum) * max(size.height - 2, 1)) - 1
            )
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }

        context.stroke(path, with: .color(color), lineWidth: 1.5)
    }
}
