import Foundation
import SwiftUI

nonisolated enum PublicPolicyDocument: String, CaseIterable, Identifiable, Sendable {
  case privacy = "PRIVACY"
  case security = "SECURITY"
  case support = "SUPPORT"
  case accessibility = "ACCESSIBILITY"

  var id: String { rawValue }

  var localizationKey: String { "policy.\(rawValue.lowercased()).title" }

  var defaultTitle: String {
    switch self {
    case .privacy: "Privacy Policy"
    case .security: "Security Policy"
    case .support: "Support Policy"
    case .accessibility: "Accessibility"
    }
  }
}

nonisolated enum BundledPolicyError: LocalizedError, Sendable {
  case resourceUnavailable
  case unsafeResource

  var errorDescription: String? {
    switch self {
    case .resourceUnavailable:
      "The bundled policy document is unavailable."
    case .unsafeResource:
      "The bundled policy document failed its local safety checks."
    }
  }
}

nonisolated enum BundledPolicyLoader {
  static let maximumBytes = 256 * 1_024

  static func load(
    _ document: PublicPolicyDocument,
    locale: VelaSupportedLocale,
    bundle: Bundle = .main
  ) throws -> HelpArticle {
    guard let resources = bundle.resourceURL else {
      throw BundledPolicyError.resourceUnavailable
    }
    let url =
      resources
      .appending(path: "Policies", directoryHint: .isDirectory)
      .appending(path: locale.rawValue, directoryHint: .isDirectory)
      .appending(path: "\(document.rawValue).md")
      .standardizedFileURL
    let values = try url.resourceValues(
      forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
    )
    guard values.isRegularFile == true,
      values.isSymbolicLink != true,
      let size = values.fileSize,
      size > 0,
      size <= maximumBytes
    else {
      throw BundledPolicyError.unsafeResource
    }
    let data = try Data(contentsOf: url, options: [.mappedIfSafe])
    guard data.count == size else { throw BundledPolicyError.unsafeResource }
    let blocks = try HelpMarkdownParser.parse(
      data: data,
      resourcePath: "Policies/\(locale.rawValue)/\(document.rawValue).md"
    )
    guard let topicID = HelpTopicID(rawValue: "privacy-and-security"),
      let categoryID = HelpCategoryID(rawValue: "reference")
    else {
      // These are compile-time stable identifiers. Keep the loader
      // fail-closed if that invariant is ever changed during maintenance.
      throw BundledPolicyError.unsafeResource
    }
    return HelpArticle(
      summary: HelpArticleSummary(
        id: topicID,
        categoryID: categoryID,
        order: 1,
        title: document.defaultTitle,
        keywords: [],
        relatedTopicIDs: [],
        resourcePath: url.lastPathComponent,
        sha256: "bundled"
      ),
      blocks: blocks
    )
  }
}

struct PublicPolicyDocumentView: View {
  private enum Phase {
    case loading
    case loaded(HelpArticle)
    case failed(String)
  }

  let document: PublicPolicyDocument
  @Environment(\.dismiss) private var dismiss
  @State private var phase: Phase = .loading
  @AccessibilityFocusState private var isHeadingFocused: Bool

  var body: some View {
    ZStack {
      VelaPageCanvas()

      VStack(spacing: 0) {
        HStack(spacing: VelaSpacing.medium) {
          Image(systemName: document.systemImage)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(Color.accentColor)
            .frame(width: 40, height: 40)
            .background(
              Color.accentColor.opacity(0.12),
              in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .accessibilityHidden(true)

          Text(
            VelaL10n.string(
              document.localizationKey,
              defaultValue: document.defaultTitle
            )
          )
          .font(VelaTypography.pageTitle)
          .accessibilityAddTraits(.isHeader)
          .accessibilityFocused($isHeadingFocused)

          Spacer()

          Button(VelaL10n.string("common.done", defaultValue: "Done")) {
            dismiss()
          }
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, VelaSpacing.large)
        .padding(.vertical, VelaSpacing.medium)
        .background(.ultraThinMaterial)

        Divider()

        content
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .velaPanelSurface()
          .padding(VelaSpacing.standard)
      }
    }
    .frame(
      minWidth: 640,
      idealWidth: 720,
      maxWidth: 900,
      minHeight: 400,
      idealHeight: 480,
      maxHeight: 680
    )
    .clipped()
    .task(id: document) {
      phase = .loading
      do {
        let locale = VelaSupportedLocale.resolve()
        let article = try await Task.detached {
          try BundledPolicyLoader.load(document, locale: locale)
        }.value
        try Task.checkCancellation()
        phase = .loaded(article)
      } catch is CancellationError {
        return
      } catch {
        phase = .failed(error.localizedDescription)
      }
    }
    .onAppear {
      isHeadingFocused = true
    }
    .accessibilityIdentifier("policy.\(document.rawValue.lowercased())")
  }

  @ViewBuilder
  private var content: some View {
    switch phase {
    case .loading:
      VelaLoadingState(
        title: VelaL10n.string("policy.loading", defaultValue: "Loading Policy")
      )
    case .loaded(let article):
      HelpArticleView(
        article: article,
        relatedArticles: [],
        strings: HelpUIStrings(
          locale: VelaSupportedLocale.resolve() == .simplifiedChinese
            ? .simplifiedChinese
            : .english
        ),
        showsLocaleFallback: false,
        navigate: { _ in }
      )
    case .failed(let message):
      ContentUnavailableView(
        VelaL10n.string("policy.unavailable", defaultValue: "Policy Unavailable"),
        systemImage: "exclamationmark.triangle",
        description: Text(message)
      )
    }
  }
}

private extension PublicPolicyDocument {
  var systemImage: String {
    switch self {
    case .privacy: "hand.raised"
    case .security: "lock.shield"
    case .support: "lifepreserver"
    case .accessibility: "accessibility"
    }
  }
}
