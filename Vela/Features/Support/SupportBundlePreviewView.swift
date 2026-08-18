import SwiftUI

struct SupportBundlePreviewView: View {
  let preview: SupportBundlePreview
  let cancel: () -> Void
  let save: () -> Void

  @AccessibilityFocusState private var isHeadingFocused: Bool

  var body: some View {
    ZStack {
      VelaPageCanvas()

      VStack(spacing: 0) {
        HStack(alignment: .center, spacing: VelaSpacing.medium) {
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
                "support.preview.title",
                defaultValue: "Preview Support Bundle"
              )
            )
            .font(VelaTypography.pageTitle)
            .accessibilityAddTraits(.isHeader)
            .accessibilityFocused($isHeadingFocused)
            Text(
              ByteCountFormatter.string(
                fromByteCount: Int64(preview.archiveByteCount),
                countStyle: .file
              )
            )
            .font(VelaTypography.caption)
            .foregroundStyle(.secondary)
          }
          Spacer()
        }
        .padding(.horizontal, VelaSpacing.large)
        .padding(.vertical, VelaSpacing.medium)
        .background(.ultraThinMaterial)

        Divider()

        List {
          Section(
            VelaL10n.string(
              "support.preview.files",
              defaultValue: "Included Files"
            )
          ) {
            ForEach(preview.manifest.files, id: \.path) { file in
              VStack(alignment: .leading, spacing: VelaSpacing.micro) {
                HStack {
                  Text(file.path)
                    .font(VelaTypography.body)
                  Spacer()
                  Text(
                    ByteCountFormatter.string(
                      fromByteCount: Int64(file.size),
                      countStyle: .file
                    )
                  )
                  .font(VelaTypography.caption)
                  .foregroundStyle(.secondary)
                }
                Text(file.sha256)
                  .font(VelaTypography.code)
                  .foregroundStyle(.secondary)
                  .textSelection(.enabled)
              }
              .padding(.vertical, VelaSpacing.xSmall)
              .accessibilityElement(children: .combine)
            }
          }

          Section(
            VelaL10n.string(
              "support.preview.privacy",
              defaultValue: "Privacy"
            )
          ) {
            Label(
              VelaL10n.string(
                "support.preview.redacted",
                defaultValue: "Structured redaction and a second sensitive-data scan passed."
              ),
              systemImage: "checkmark.shield.fill"
            )
            Label(
              VelaL10n.string(
                "support.preview.noUpload",
                defaultValue: "Saving does not upload or open a support site."
              ),
              systemImage: "externaldrive"
            )
            if preview.includedOptionalLogs {
              Label(
                VelaL10n.string(
                  "support.preview.logsIncluded",
                  defaultValue: "Recent redacted app logs are included by your choice."
                ),
                systemImage: "exclamationmark.triangle.fill"
              )
              .foregroundStyle(.orange)
            }
            if preview.includedReliabilityEvidence {
              Label(
                VelaL10n.string(
                  "support.preview.evidenceIncluded",
                  defaultValue: "The bounded local reliability summary is included by your choice."
                ),
                systemImage: "waveform.path.ecg"
              )
            }
          }
        }
        .scrollContentBackground(.hidden)
        .listStyle(.inset)
        .velaPanelSurface()
        .padding(VelaSpacing.standard)

        Divider()

        HStack {
          Button(VelaL10n.string("common.cancel", defaultValue: "Cancel"), action: cancel)
            .buttonStyle(.bordered)
            .keyboardShortcut(.cancelAction)
          Spacer()
          Button(
            VelaL10n.string(
              "support.preview.save",
              defaultValue: "Save Support Bundle…"
            ),
            action: save
          )
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, VelaSpacing.large)
        .padding(.vertical, VelaSpacing.medium)
        .background(.ultraThinMaterial)
      }
    }
    .frame(
      minWidth: 620,
      idealWidth: 720,
      maxWidth: 860,
      minHeight: 420,
      idealHeight: 520,
      maxHeight: 620
    )
    .clipped()
    .accessibilityIdentifier("support.bundle.preview")
    .onAppear {
      isHeadingFocused = true
    }
  }
}
