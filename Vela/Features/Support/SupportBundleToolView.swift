import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Standalone, user-initiated entry to the existing private `.velasupport`
/// pipeline. This view never uploads and does not run a repair transaction.
struct SupportBundleToolView: View {
  let adapter: SupportDiagnosticsAdapter
  let publicBetaEvidence: PublicBetaEvidenceController?

  @Environment(\.dismiss) private var dismiss
  @State private var stage: SupportBundlePreparationStage?
  @State private var includeRecentLogs = false
  @State private var includeReliabilityEvidence = false
  @State private var preview: SupportBundlePreview?
  @State private var operationTask: Task<Void, Never>?
  @State private var errorMessage: String?
  @AccessibilityFocusState private var isHeadingFocused: Bool

  private let builder = SupportBundleBuilder()

  var body: some View {
    ZStack {
      VelaPageCanvas()

      VStack(spacing: 0) {
        header
          .background(.ultraThinMaterial)

        Divider()

        ScrollView {
          VStack(alignment: .leading, spacing: VelaSpacing.section) {
            privacyBoundary
            includedContent
            preparationPipeline
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
      minHeight: 440,
      idealHeight: 620,
      maxHeight: 720
    )
    .clipped()
    .accessibilityIdentifier("support.bundle.tool")
    .sheet(item: $preview) { preview in
      SupportBundlePreviewView(
        preview: preview,
        cancel: { cancelPreview(preview) },
        save: { save(preview) }
      )
    }
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
    .onAppear { isHeadingFocused = true }
    .onDisappear {
      operationTask?.cancel()
      operationTask = nil
      if let preview { builder.cleanup(preview) }
    }
  }

  private var header: some View {
    HStack(alignment: .top, spacing: VelaSpacing.medium) {
      Image(systemName: "doc.zipper")
        .font(.system(size: 18, weight: .semibold))
        .foregroundStyle(Color.accentColor)
        .frame(width: 40, height: 40)
        .background(
          Color.accentColor.opacity(0.12),
          in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: VelaSpacing.micro) {
        Text(
          VelaL10n.string(
            "support.bundle.tool.title",
            defaultValue: "Export Support Bundle"
          )
        )
        .font(VelaTypography.pageTitle)
        .accessibilityAddTraits(.isHeader)
        .accessibilityFocused($isHeadingFocused)
        Text(
          VelaL10n.string(
            "support.bundle.tool.subtitle",
            defaultValue:
              "Preview a bounded, redacted local archive before choosing where to save it."
          )
        )
        .font(VelaTypography.caption)
        .foregroundStyle(.secondary)
      }
      Spacer()
    }
    .padding(VelaSpacing.large)
  }

  private var privacyBoundary: some View {
    VelaStateBanner(
      kind: .info,
      title: VelaL10n.string(
        "support.bundle.private.title",
        defaultValue: "Private by Design"
      ),
      detail: VelaL10n.string(
        "support.bundle.private.detail",
        defaultValue:
          "Preparation stays on this Mac. Vela removes structured secrets, scans every file again, and blocks unsafe exports. Nothing is uploaded automatically."
      )
    )
  }

  private var includedContent: some View {
    VStack(alignment: .leading, spacing: VelaSpacing.medium) {
      VelaSectionHeader(
        VelaL10n.string(
          "support.bundle.contents.title",
          defaultValue: "Bundle Contents"
        ),
        subtitle: VelaL10n.string(
          "support.bundle.contents.detail",
          defaultValue:
            "The archive is limited to 10 MiB and 100 files. Configuration YAML, subscription URLs, credentials, network destinations, process paths, and Keychain content are always excluded."
        )
      )

      Label(
        VelaL10n.string(
          "support.bundle.contents.defaults",
          defaultValue:
            "Included: version, system summary, diagnostic states, lifecycle summaries, trust status, and stable error codes"
        ),
        systemImage: "checkmark.shield"
      )
      .font(VelaTypography.body)

      Toggle(
        VelaL10n.string(
          "support.export.includeLogs",
          defaultValue: "Include up to 200 recent redacted app log entries"
        ),
        isOn: $includeRecentLogs
      )
      .disabled(adapter.recentRedactedLogs() == nil || isPreparing)

      Toggle(
        VelaL10n.string(
          "support.export.includeReliabilityEvidence",
          defaultValue: "Include the bounded local reliability summary"
        ),
        isOn: $includeReliabilityEvidence
      )
      .disabled(publicBetaEvidence == nil || isPreparing)

      Label(
        VelaL10n.string(
          "support.bundle.contents.optionalNotice",
          defaultValue:
            "Optional logs and crash evidence are off by default and remain subject to the same redaction and blocking scan."
        ),
        systemImage: "hand.raised"
      )
      .font(VelaTypography.caption)
      .foregroundStyle(.secondary)
    }
  }

  private var preparationPipeline: some View {
    VStack(alignment: .leading, spacing: VelaSpacing.medium) {
      VelaSectionHeader(
        VelaL10n.string(
          "support.bundle.pipeline.title",
          defaultValue: "Preparation"
        )
      )

      ViewThatFits(in: .horizontal) {
        HStack(spacing: VelaSpacing.small) {
          ForEach(SupportBundlePreparationStage.allCases, id: \.self) { item in
            Label(stageTitle(item), systemImage: stageIcon(item))
              .font(VelaTypography.caption)
              .foregroundStyle(stageColor(item))
            if item != .ready {
              Image(systemName: "chevron.right")
                .font(VelaTypography.caption)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            }
          }
        }

        VStack(alignment: .leading, spacing: VelaSpacing.xSmall) {
          ForEach(SupportBundlePreparationStage.allCases, id: \.self) { item in
            Label(stageTitle(item), systemImage: stageIcon(item))
              .font(VelaTypography.caption)
              .foregroundStyle(stageColor(item))
          }
        }
      }
      .accessibilityElement(children: .combine)
      .accessibilityLabel(
        stage.map(stageTitle)
          ?? VelaL10n.string(
            "support.bundle.pipeline.notStarted",
            defaultValue: "Preparation has not started"
          )
      )

      Button {
        prepare()
      } label: {
        Label(
          VelaL10n.string(
            "support.export.prepare",
            defaultValue: "Preview Support Bundle"
          ),
          systemImage: "doc.badge.gearshape"
        )
      }
      .buttonStyle(.borderedProminent)
      .disabled(isPreparing)
      .accessibilityIdentifier("support.bundle.prepare")

      if isPreparing {
        Button(
          VelaL10n.string(
            "support.bundle.cancelPreparation",
            defaultValue: "Cancel Preparation"
          ),
          role: .cancel
        ) {
          operationTask?.cancel()
          operationTask = nil
          stage = nil
        }
        .buttonStyle(.bordered)
      }
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

  private var isPreparing: Bool {
    guard let stage else { return false }
    return stage != .ready
  }

  private func stageTitle(_ item: SupportBundlePreparationStage) -> String {
    switch item {
    case .collecting:
      VelaL10n.string("support.bundle.stage.collecting", defaultValue: "Collecting")
    case .redacting:
      VelaL10n.string("support.bundle.stage.redacting", defaultValue: "Redacting")
    case .validating:
      VelaL10n.string("support.bundle.stage.validating", defaultValue: "Validating")
    case .ready:
      VelaL10n.string("support.bundle.stage.ready", defaultValue: "Preview Ready")
    }
  }

  private func stageIcon(_ item: SupportBundlePreparationStage) -> String {
    guard let stage else { return "circle" }
    if item == stage { return stage == .ready ? "checkmark.circle.fill" : "circle.dotted" }
    let stages = SupportBundlePreparationStage.allCases
    guard let current = stages.firstIndex(of: stage), let index = stages.firstIndex(of: item) else {
      return "circle"
    }
    return index < current ? "checkmark.circle.fill" : "circle"
  }

  private func stageColor(_ item: SupportBundlePreparationStage) -> Color {
    guard let stage else { return .secondary }
    let stages = SupportBundlePreparationStage.allCases
    guard let current = stages.firstIndex(of: stage), let index = stages.firstIndex(of: item) else {
      return .secondary
    }
    return index <= current ? .accentColor : .secondary
  }

  private func prepare() {
    operationTask?.cancel()
    stage = .collecting
    let diagnostics = adapter.results(for: .cannotConnect)
    let snapshot = adapter.makeSnapshot(category: .cannotConnect, results: diagnostics)
    let shouldIncludeLogs = includeRecentLogs
    let recentLogs = shouldIncludeLogs ? adapter.recentRedactedLogs() : nil
    let shouldIncludeEvidence = includeReliabilityEvidence && publicBetaEvidence != nil

    operationTask = Task {
      do {
        var reliabilityEvidence: String?
        if shouldIncludeEvidence, let publicBetaEvidence {
          let data = try await publicBetaEvidence.redactedExportData()
          try Task.checkCancellation()
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
        let prepared = try await builder.prepare(
          snapshot: snapshot,
          options: options,
          progress: { nextStage in
            await MainActor.run { stage = nextStage }
          }
        )
        guard !Task.isCancelled else {
          builder.cleanup(prepared)
          return
        }
        preview = prepared
        stage = .ready
        operationTask = nil
      } catch is CancellationError {
        stage = nil
        operationTask = nil
      } catch {
        errorMessage = DiagnosticTextSanitizer.redact(error.localizedDescription)
        stage = nil
        operationTask = nil
      }
    }
  }

  private func cancelPreview(_ preview: SupportBundlePreview) {
    builder.cleanup(preview)
    self.preview = nil
    stage = nil
  }

  private func save(_ preview: SupportBundlePreview) {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "Vela-Support.velasupport"
    panel.allowedContentTypes = [UTType(filenameExtension: "velasupport") ?? .zip]
    panel.canCreateDirectories = true
    guard panel.runModal() == .OK, let destination = panel.url else {
      builder.cleanup(preview)
      self.preview = nil
      stage = nil
      return
    }
    do {
      _ = try builder.save(preview, to: destination)
      builder.cleanup(preview)
      self.preview = nil
      stage = nil
    } catch {
      errorMessage = DiagnosticTextSanitizer.redact(error.localizedDescription)
    }
  }
}
