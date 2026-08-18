import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct GuidedSupportView: View {
  let adapter: SupportDiagnosticsAdapter
  let publicBetaEvidence: PublicBetaEvidenceController?
  let openHelpTopic: (String) -> Void
  @Environment(\.dismiss) private var dismiss
  @Environment(\.layoutDirection) private var layoutDirection
  @State private var category: SupportIssueCategory = .cannotConnect
  @State private var phase: GuidedSupportPhase = .chooseCategory
  @State private var activity: SupportActivity?
  @State private var results: [SupportCheckResult] = []
  @State private var errorMessage: String?
  @State private var includeRecentLogs = false
  @State private var includeReliabilityEvidence = false
  @State private var preview: SupportBundlePreview?
  @State private var pendingRepair: SupportRepairActionID?
  @State private var operationTask: Task<Void, Never>?
  @State private var exportTask: Task<Void, Never>?
  @AccessibilityFocusState private var isResultsHeadingFocused: Bool

  private let builder = SupportBundleBuilder()

  init(
    adapter: SupportDiagnosticsAdapter,
    publicBetaEvidence: PublicBetaEvidenceController? = nil,
    openHelpTopic: @escaping (String) -> Void
  ) {
    self.adapter = adapter
    self.publicBetaEvidence = publicBetaEvidence
    self.openHelpTopic = openHelpTopic
  }

  var body: some View {
    ZStack {
      VelaPageCanvas()

      VStack(spacing: 0) {
        header
          .background(.ultraThinMaterial)

        Divider()

        ScrollView {
          VStack(alignment: .leading, spacing: VelaSpacing.section) {
            categorySection
            if !results.isEmpty {
              resultsSection
              repairSection
              exportSection
            }
          }
          .padding(VelaSpacing.large)
          .frame(maxWidth: 760, alignment: .leading)
          .frame(maxWidth: .infinity)
          .velaPanelSurface()
          .padding(VelaSpacing.standard)
        }
        .scrollIndicators(.automatic)

        Divider()

        footer
          .background(.ultraThinMaterial)
      }
    }
    .frame(
      minWidth: 640,
      idealWidth: 720,
      maxWidth: 860,
      minHeight: results.isEmpty ? 340 : 440,
      idealHeight: results.isEmpty ? 380 : 620,
      maxHeight: results.isEmpty ? 480 : 720
    )
    .clipped()
    .accessibilityIdentifier("support.guided")
    .alert(
      VelaL10n.string(
        "error.support.export.title",
        defaultValue: "Support Export Failed",
        table: "Errors"
      ),
      isPresented: Binding(
        get: { errorMessage != nil },
        set: { if !$0 { errorMessage = nil } }
      )
    ) {
      Button(VelaL10n.string("common.ok", defaultValue: "OK")) {
        errorMessage = nil
      }
    } message: {
      Text(errorMessage ?? "")
    }
    .sheet(item: $preview) { preview in
      SupportBundlePreviewView(
        preview: preview,
        cancel: { cancel(preview) },
        save: { save(preview) }
      )
    }
    .confirmationDialog(
      VelaL10n.string(
        "support.repair.confirm.title",
        defaultValue: "Apply This Repair?"
      ),
      isPresented: Binding(
        get: { pendingRepair != nil },
        set: {
          if !$0 {
            pendingRepair = nil
            if phase == .confirmingRepair { phase = .results }
          }
        }
      ),
      titleVisibility: .visible
    ) {
      if let pendingRepair {
        Button(
          VelaL10n.string(
            "support.repair.\(pendingRepair.rawValue)",
            defaultValue: pendingRepair.defaultTitle
          )
        ) {
          let action = pendingRepair
          self.pendingRepair = nil
          performConfirmed(action)
        }
        Button(VelaL10n.string("common.cancel", defaultValue: "Cancel"), role: .cancel) {
          self.pendingRepair = nil
          phase = .results
        }
      }
    } message: {
      Text(
        VelaL10n.string(
          "support.repair.confirm.detail",
          defaultValue:
            "Vela will run only the selected allowlisted action, then repeat the related local checks."
        )
      )
    }
    .onChange(of: category) {
      resetForCategoryChange()
    }
    .onDisappear {
      operationTask?.cancel()
      operationTask = nil
      exportTask?.cancel()
      exportTask = nil
      activity = nil
      if let preview { builder.cleanup(preview) }
    }
  }

  private var header: some View {
    HStack(alignment: .center, spacing: VelaSpacing.medium) {
      Image(systemName: "lifepreserver.fill")
        .font(.system(size: 18, weight: .semibold))
        .foregroundStyle(Color.accentColor)
        .frame(width: 40, height: 40)
        .background(
          Color.accentColor.opacity(0.12),
          in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: VelaSpacing.micro) {
        Text(VelaL10n.string("support.guided.title", defaultValue: "Guided Support"))
          .font(VelaTypography.pageTitle)
        Text(
          VelaL10n.string(
            "support.guided.subtitle",
            defaultValue:
              "Run local diagnostics, choose an allowlisted repair, and export only after preview."
          )
        )
        .font(VelaTypography.caption)
        .foregroundStyle(.secondary)
        if let activity {
          HStack(spacing: VelaSpacing.xSmall) {
            ProgressView()
              .controlSize(.small)
              .accessibilityHidden(true)
            Text(activity.localizedStatus)
              .font(VelaTypography.caption)
              .foregroundStyle(.secondary)
          }
          .accessibilityElement(children: .ignore)
          .accessibilityLabel(activity.localizedStatus)
        }
      }
      Spacer()
      Button {
        openHelpTopic(category.helpTopicRawValue)
      } label: {
        Label(
          VelaL10n.string("common.learnMore", defaultValue: "Learn More"),
          systemImage: "questionmark.circle"
        )
      }
      .buttonStyle(.bordered)
    }
    .padding(.horizontal, VelaSpacing.large)
    .padding(.vertical, VelaSpacing.standard)
  }

  private var categorySection: some View {
    VStack(alignment: .leading, spacing: VelaSpacing.medium) {
      VelaSectionHeader(
        VelaL10n.string("support.category.title", defaultValue: "What needs attention?")
      )
      Picker(
        VelaL10n.string("support.category.picker", defaultValue: "Issue category"),
        selection: $category
      ) {
        ForEach(SupportIssueCategory.allCases) { item in
          Text(
            VelaL10n.string(
              item.localizationKey,
              defaultValue: item.defaultTitle
            )
          )
          .tag(item)
        }
      }
      .pickerStyle(.menu)
      .disabled(isBusy)
      .accessibilityIdentifier("support.category")

      Button {
        runDiagnostics()
      } label: {
        Label(
          diagnosticsButtonTitle,
          systemImage: "checkmark.shield"
        )
      }
      .buttonStyle(.borderedProminent)
      .disabled(isBusy)
      .keyboardShortcut(.defaultAction)
      .accessibilityIdentifier("support.runDiagnostics")
    }
  }

  private var resultsSection: some View {
    VStack(alignment: .leading, spacing: VelaSpacing.medium) {
      if phase == .resolved {
        VelaStateBanner(
          kind: .info,
          title: VelaL10n.string(
            "support.verify.resolved.title",
            defaultValue: "Verification Passed"
          ),
          detail: VelaL10n.string(
            "support.verify.resolved.detail",
            defaultValue: "The repeated local checks no longer report a failure."
          )
        )
      } else if phase == .unresolved {
        VelaStateBanner(
          kind: .warning,
          title: VelaL10n.string(
            "support.verify.unresolved.title",
            defaultValue: "More Attention Is Needed"
          ),
          detail: VelaL10n.string(
            "support.verify.unresolved.detail",
            defaultValue:
              "The repeated checks still report a failure. Review the evidence or preview a private support bundle."
          )
        )
      }
      VelaSectionHeader(
        VelaL10n.string("support.results.title", defaultValue: "Diagnostic Results"),
        subtitle: VelaL10n.string(
          "support.results.subtitle",
          defaultValue: "These checks run locally and do not upload data."
        )
      )
      .accessibilityFocused($isResultsHeadingFocused)
      VStack(spacing: 0) {
        ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
          SupportCheckResultRow(result: result)
          if index < results.count - 1 { Divider() }
        }
      }
      .velaPanelSurface()
    }
  }

  private var repairSection: some View {
    VStack(alignment: .leading, spacing: VelaSpacing.medium) {
      VelaSectionHeader(
        VelaL10n.string("support.repairs.title", defaultValue: "Safe Repairs"),
        subtitle: VelaL10n.string(
          "support.repairs.subtitle",
          defaultValue:
            "Only actions already implemented by Vela are available. Nothing runs without your selection."
        )
      )
      FlowLayout(
        spacing: VelaSpacing.small,
        layoutDirection: layoutDirection
      ) {
        ForEach(SupportRepairActionID.allowed(for: category)) { action in
          Button(
            VelaL10n.string(
              "support.repair.\(action.rawValue)",
              defaultValue: action.defaultTitle
            )
          ) {
            requestRepair(action)
          }
          .buttonStyle(.bordered)
          .disabled(isBusy)
        }
      }
    }
  }

  private var exportSection: some View {
    VStack(alignment: .leading, spacing: VelaSpacing.medium) {
      VelaSectionHeader(
        VelaL10n.string("support.export.section", defaultValue: "Support Bundle"),
        subtitle: VelaL10n.string(
          "support.export.description",
          defaultValue:
            "The default bundle contains only versions, system summary, diagnostic states, lifecycle summaries, and stable error codes."
        )
      )
      Toggle(
        VelaL10n.string(
          "support.export.includeLogs",
          defaultValue: "Include up to 200 recent redacted app log entries"
        ),
        isOn: $includeRecentLogs
      )
      .disabled(adapter.recentRedactedLogs() == nil || isBusy)
      Toggle(
        VelaL10n.string(
          "support.export.includeReliabilityEvidence",
          defaultValue: "Include the bounded local reliability summary"
        ),
        isOn: $includeReliabilityEvidence
      )
      .disabled(publicBetaEvidence == nil || isBusy)
      VelaStateBanner(
        kind: .warning,
        title: VelaL10n.string(
          "support.export.review.title",
          defaultValue: "Review Before Sharing"
        ),
        detail: VelaL10n.string(
          "support.export.review.detail",
          defaultValue:
            "Vela scans again before export and blocks high-risk content. The bundle is saved locally and is never uploaded automatically."
        )
      )
      Button {
        prepareBundle()
      } label: {
        Label(
          phase == .readyToExport
            ? VelaL10n.string("support.export.ready", defaultValue: "Bundle Ready")
            : VelaL10n.string("support.export.prepare", defaultValue: "Preview Support Bundle"),
          systemImage: "doc.zipper"
        )
      }
      .buttonStyle(.borderedProminent)
      .disabled(isBusy)
      .accessibilityIdentifier("support.previewBundle")
    }
  }

  private var footer: some View {
    HStack {
      Text(
        VelaL10n.string(
          "support.footer.noUpload",
          defaultValue: "No remote AI · No arbitrary shell · No automatic upload"
        )
      )
      .font(VelaTypography.caption)
      .foregroundStyle(.secondary)
      Spacer()
      Button(VelaL10n.string("common.done", defaultValue: "Done")) {
        dismiss()
      }
      .buttonStyle(.borderedProminent)
      .keyboardShortcut(.cancelAction)
    }
    .padding(.horizontal, VelaSpacing.large)
    .padding(.vertical, VelaSpacing.medium)
  }

  private var isBusy: Bool {
    activity != nil
  }

  private var diagnosticsButtonTitle: String {
    if activity == .runningDiagnostics {
      return VelaL10n.string(
        "support.diagnostics.running",
        defaultValue: "Running Diagnostics"
      )
    }
    return VelaL10n.string(
      "support.diagnostics.run",
      defaultValue: "Run Diagnostics"
    )
  }

  private func runDiagnostics() {
    operationTask?.cancel()
    activity = .runningDiagnostics
    phase = .runningDiagnostics
    let selectedCategory = category
    operationTask = Task {
      let newResults = await adapter.run(for: selectedCategory)
      guard !Task.isCancelled else { return }
      results = newResults
      activity = nil
      phase = .results
      operationTask = nil
      isResultsHeadingFocused = true
    }
  }

  private func requestRepair(_ action: SupportRepairActionID) {
    guard SupportRepairActionID.allowed(for: category).contains(action) else { return }
    pendingRepair = action
    phase = .confirmingRepair
  }

  private func performConfirmed(_ action: SupportRepairActionID) {
    guard SupportRepairActionID.allowed(for: category).contains(action) else { return }
    operationTask?.cancel()
    activity = .repairing
    phase = .repairing
    let selectedCategory = category
    operationTask = Task {
      await adapter.repair(action)
      guard !Task.isCancelled else { return }
      activity = .verifyingRepair
      phase = .verifying
      results = await adapter.run(for: selectedCategory)
      guard !Task.isCancelled else { return }
      activity = nil
      phase = results.contains(where: { $0.status == .failed }) ? .unresolved : .resolved
      operationTask = nil
      isResultsHeadingFocused = true
    }
  }

  private func prepareBundle() {
    exportTask?.cancel()
    activity = .preparingBundle
    phase = .verifying
    let snapshot = adapter.makeSnapshot(category: category, results: results)
    let shouldIncludeLogs = includeRecentLogs
    let recentLogs = shouldIncludeLogs ? adapter.recentRedactedLogs() : nil
    let shouldIncludeEvidence = includeReliabilityEvidence && publicBetaEvidence != nil
    exportTask = Task {
      do {
        var reliabilityEvidence: String?
        if shouldIncludeEvidence, let publicBetaEvidence {
          let data = try await publicBetaEvidence.redactedExportData()
          guard let decoded = String(data: data, encoding: .utf8) else {
            throw SupportBundleError.invalidUTF8
          }
          reliabilityEvidence = decoded
        }
        let options = SupportBundleOptions(
          includeRecentAppLogs: shouldIncludeLogs,
          includeCrashSummary: false,
          includeReliabilityEvidence: shouldIncludeEvidence,
          recentAppLogs: recentLogs,
          crashSummary: nil,
          reliabilityEvidence: reliabilityEvidence
        )
        let prepared = try await builder.prepare(snapshot: snapshot, options: options)
        guard !Task.isCancelled else {
          builder.cleanup(prepared)
          return
        }
        preview = prepared
        activity = nil
        phase = .readyToExport
        exportTask = nil
      } catch is CancellationError {
        activity = nil
        phase = .results
        exportTask = nil
      } catch {
        errorMessage = DiagnosticTextSanitizer.redact(error.localizedDescription)
        activity = nil
        phase = .results
        exportTask = nil
      }
    }
  }

  private func resetForCategoryChange() {
    operationTask?.cancel()
    operationTask = nil
    exportTask?.cancel()
    exportTask = nil
    activity = nil
    results.removeAll()
    phase = .chooseCategory
    if let preview {
      builder.cleanup(preview)
      self.preview = nil
    }
  }

  private func cancel(_ preview: SupportBundlePreview) {
    builder.cleanup(preview)
    self.preview = nil
    phase = .results
  }

  private func save(_ preview: SupportBundlePreview) {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "Vela-Support.velasupport"
    panel.allowedContentTypes = [UTType(filenameExtension: "velasupport") ?? .zip]
    panel.canCreateDirectories = true
    guard panel.runModal() == .OK, let destination = panel.url else {
      builder.cleanup(preview)
      self.preview = nil
      phase = .results
      return
    }
    do {
      _ = try builder.save(preview, to: destination)
      builder.cleanup(preview)
      self.preview = nil
      phase = .results
    } catch {
      errorMessage = DiagnosticTextSanitizer.redact(error.localizedDescription)
    }
  }
}

private enum SupportActivity: Equatable, Sendable {
  case runningDiagnostics
  case repairing
  case verifyingRepair
  case preparingBundle

  var localizedStatus: String {
    switch self {
    case .runningDiagnostics:
      VelaL10n.string(
        "support.activity.diagnostics",
        defaultValue: "Running diagnostics"
      )
    case .repairing:
      VelaL10n.string(
        "support.activity.repairing",
        defaultValue: "Applying the selected repair"
      )
    case .verifyingRepair:
      VelaL10n.string(
        "support.activity.verifying",
        defaultValue: "Verifying the repair"
      )
    case .preparingBundle:
      VelaL10n.string(
        "support.activity.preparingBundle",
        defaultValue: "Preparing the support bundle"
      )
    }
  }
}

private struct SupportCheckResultRow: View {
  let result: SupportCheckResult

  var body: some View {
    HStack(alignment: .top, spacing: VelaSpacing.medium) {
      VelaStatusPill(status: semanticStatus, label: statusLabel)
      VStack(alignment: .leading, spacing: VelaSpacing.micro) {
        Text(result.title)
          .font(VelaTypography.sectionTitle)
        Text(result.detail)
          .font(VelaTypography.body)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        if let stableCode = result.stableCode {
          Text(stableCode)
            .font(VelaTypography.code)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
      }
      Spacer(minLength: 0)
    }
    .padding(VelaSpacing.medium)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      VelaL10n.string(
        "support.result.accessibility.format",
        defaultValue: "%@, %@",
        arguments: result.title,
        statusLabel
      )
    )
    .accessibilityValue(result.detail)
  }

  private var semanticStatus: VelaSemanticStatus {
    switch result.status {
    case .healthy: .success
    case .warning: .warning
    case .failed: .error
    case .unavailable: .neutral
    }
  }

  private var statusLabel: String {
    switch result.status {
    case .healthy: VelaL10n.string("status.healthy", defaultValue: "Healthy")
    case .warning: VelaL10n.string("status.warning", defaultValue: "Warning")
    case .failed: VelaL10n.string("status.failed", defaultValue: "Failed")
    case .unavailable: VelaL10n.string("status.unavailable", defaultValue: "Unavailable")
    }
  }
}

private struct FlowLayout: Layout {
  let spacing: CGFloat
  let layoutDirection: LayoutDirection

  func sizeThatFits(
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache _: inout ()
  ) -> CGSize {
    layout(proposal: proposal, subviews: subviews).size
  }

  func placeSubviews(
    in bounds: CGRect,
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache _: inout ()
  ) {
    let result = layout(proposal: proposal, subviews: subviews)
    for (index, point) in result.points.enumerated() {
      subviews[index].place(
        at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y),
        proposal: .unspecified
      )
    }
  }

  private func layout(proposal: ProposedViewSize, subviews: Subviews) -> (
    size: CGSize, points: [CGPoint]
  ) {
    let width = proposal.width ?? 640
    let result = SupportFlowLayoutGeometry.layout(
      sizes: subviews.map { $0.sizeThatFits(.unspecified) },
      width: width,
      spacing: spacing,
      layoutDirection: layoutDirection
    )
    return (result.size, result.points)
  }
}

nonisolated enum SupportFlowLayoutGeometry {
  nonisolated struct Result: Equatable, Sendable {
    let size: CGSize
    let points: [CGPoint]
  }

  static func layout(
    sizes: [CGSize],
    width: CGFloat,
    spacing: CGFloat,
    layoutDirection: LayoutDirection
  ) -> Result {
    var x: CGFloat = layoutDirection == .leftToRight ? 0 : width
    var y: CGFloat = 0
    var rowHeight: CGFloat = 0
    var hasItemInRow = false
    var points: [CGPoint] = []
    for size in sizes {
      let needsNewRow: Bool
      switch layoutDirection {
      case .leftToRight:
        needsNewRow = hasItemInRow && x + size.width > width
      case .rightToLeft:
        needsNewRow = hasItemInRow && x - size.width < 0
      @unknown default:
        needsNewRow = hasItemInRow && x + size.width > width
      }

      if needsNewRow {
        x = layoutDirection == .leftToRight ? 0 : width
        y += rowHeight + spacing
        rowHeight = 0
        hasItemInRow = false
      }

      if layoutDirection == .rightToLeft {
        x = max(0, x - size.width)
      }
      points.append(CGPoint(x: x, y: y))
      if layoutDirection == .leftToRight {
        x += size.width + spacing
      } else {
        x -= spacing
      }
      rowHeight = max(rowHeight, size.height)
      hasItemInRow = true
    }
    return Result(
      size: CGSize(width: width, height: y + rowHeight),
      points: points
    )
  }
}
