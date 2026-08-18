#if DEBUG
import SwiftUI

struct VelaVisualSystemPreviewCatalog: View {
    @State private var codeSample = """
        dns:
          enable: true
          enhanced-mode: fake-ip
        """

    private let metricColumns = [
        GridItem(.adaptive(minimum: 260), spacing: VelaSpacing.medium),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: VelaSpacing.large) {
                Text(VelaL10n.string("legacy.velaVisualSystem", defaultValue: "Vela Visual System"))
                    .font(VelaTypography.pageTitle)

                catalogSection("State Matrix") {
                    LazyVGrid(
                        columns: metricColumns,
                        alignment: .leading,
                        spacing: VelaSpacing.small
                    ) {
                        ForEach(VelaPreviewScenario.allCases, id: \.self) { scenario in
                            let fixture = VelaPreviewFixtures.fixture(for: scenario)
                            VelaStatusPill(
                                status: fixture.status,
                                label: fixture.title,
                                detail: fixture.detail
                            )
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }

                catalogSection("Status Pills") {
                    LazyVGrid(columns: metricColumns, alignment: .leading, spacing: VelaSpacing.small) {
                        ForEach(VelaPreviewFixtures.statusPills) { fixture in
                            VelaStatusPill(
                                status: fixture.status,
                                label: fixture.label,
                                detail: fixture.detail
                            )
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }

                catalogSection("Metric Cards") {
                    LazyVGrid(columns: metricColumns, spacing: VelaSpacing.medium) {
                        ForEach(VelaPreviewFixtures.metricCards) { fixture in
                            VelaMetricCard(
                                title: fixture.title,
                                value: fixture.value,
                                secondaryText: fixture.secondaryText,
                                status: fixture.status,
                                statusLabel: fixture.statusLabel,
                                density: fixture.density
                            ) {
                                if let actionTitle = fixture.actionTitle {
                                    Button(actionTitle) {}
                                        .buttonStyle(.borderless)
                                        .controlSize(.small)
                                }
                            }
                        }
                    }
                }

                catalogSection("State Banners") {
                    VStack(spacing: VelaSpacing.small) {
                        ForEach(VelaPreviewFixtures.stateBanners) { fixture in
                            VelaStateBanner(
                                kind: fixture.kind,
                                title: fixture.title,
                                detail: fixture.detail
                            ) {
                                Button(fixture.primaryActionTitle) {}
                                    .buttonStyle(.bordered)
                                if let secondaryActionTitle = fixture.secondaryActionTitle {
                                    Button(secondaryActionTitle) {}
                                        .buttonStyle(.borderless)
                                }
                            }
                        }
                    }
                }

                catalogSection("Empty States") {
                    LazyVGrid(columns: metricColumns, spacing: VelaSpacing.medium) {
                        ForEach(VelaPreviewFixtures.emptyStates) { fixture in
                            VelaEmptyState(
                                title: fixture.title,
                                description: fixture.description,
                                systemImage: fixture.systemImage
                            ) {
                                if let actionTitle = fixture.actionTitle {
                                    Button(actionTitle) {}
                                }
                            }
                            .background(VelaAppearance.controlBackground, in: RoundedRectangle(
                                cornerRadius: VelaRadius.panel,
                                style: .continuous
                            ))
                        }
                    }
                }

                catalogSection("Inspector Section") {
                    VelaInspectorSection(
                        title: "Connection Details",
                        subtitle: "Current confirmed values",
                        help: "Inspector values update with the selected row.",
                        showsDivider: false
                    ) {
                        Grid(alignment: .leading, horizontalSpacing: VelaSpacing.medium) {
                            ForEach(VelaPreviewFixtures.inspectorValues) { fixture in
                                GridRow {
                                    Text(fixture.label)
                                        .foregroundStyle(.secondary)
                                    Text(fixture.value)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                        .font(VelaTypography.body)
                    }
                    .padding(.horizontal, VelaSpacing.standard)
                    .background(VelaAppearance.controlBackground, in: RoundedRectangle(
                        cornerRadius: VelaRadius.panel,
                        style: .continuous
                    ))
                }

                catalogSection("Section, Loading, and Latency") {
                    VStack(alignment: .leading, spacing: VelaSpacing.medium) {
                        VelaSectionHeader(
                            "Proxy Health",
                            subtitle: "Compact desktop hierarchy"
                        ) {
                            Button(VelaL10n.string("legacy.refresh", defaultValue: "Refresh")) {}
                        }
                        VelaLoadingState(
                            title: "Testing visible proxies",
                            detail: "Three requests are still in flight",
                            compact: true
                        )
                        HStack(spacing: VelaSpacing.small) {
                            VelaLatencyBadge(state: .good, milliseconds: 82)
                            VelaLatencyBadge(state: .medium, milliseconds: 241)
                            VelaLatencyBadge(state: .failed)
                        }
                    }
                }

                catalogSection("Traffic Sparkline") {
                    VelaTrafficSparkline(
                        download: VelaPreviewFixtures.environment.chartSamples,
                        upload: VelaPreviewFixtures.environment.chartSamples.map { $0 * 0.45 },
                        downloadSummary: "12.3 MB/s",
                        uploadSummary: "3.2 MB/s"
                    )
                    .padding(VelaSpacing.standard)
                    .velaPanelSurface()
                }

                catalogSection("Sensitive Value") {
                    VelaSensitiveText(value: "https://token@example.invalid/subscription")
                }

                catalogSection("Code Editor") {
                    VelaCodeEditor(text: $codeSample)
                        .frame(height: 180)
                        .velaPanelSurface()
                }

                catalogSection("Result Summary") {
                    VelaResultSummary(
                        title: "Provider Update",
                        items: [
                            VelaResultItem(id: "a", title: "Primary", detail: "24 nodes", status: .success),
                            VelaResultItem(id: "b", title: "Fallback", detail: "Timed out", status: .error),
                        ],
                        retryFailed: {}
                    )
                }
            }
            .padding(VelaSpacing.large)
        }
        .frame(minWidth: 760, minHeight: 900)
    }

    private func catalogSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: VelaSpacing.medium) {
            Text(title)
                .font(VelaTypography.sectionTitle)
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview("Visual System · Light") {
    VelaVisualSystemPreviewCatalog()
        .preferredColorScheme(.light)
}

#Preview("Visual System · Dark") {
    VelaVisualSystemPreviewCatalog()
        .preferredColorScheme(.dark)
}

#Preview("Visual System · Increased Contrast") {
    VelaVisualSystemPreviewCatalog()
        .preferredColorScheme(.light)
        .environment(
            \.velaAccessibilityOverrides,
            VelaAccessibilityOverrides(reduceMotion: nil, increasedContrast: true)
        )
}

#Preview("Visual System · Reduce Motion") {
    VelaVisualSystemPreviewCatalog()
        .preferredColorScheme(.dark)
        .environment(
            \.velaAccessibilityOverrides,
            VelaAccessibilityOverrides(reduceMotion: true, increasedContrast: nil)
        )
}
#endif
