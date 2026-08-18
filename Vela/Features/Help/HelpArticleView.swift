import SwiftUI

struct HelpArticleView: View {
  let article: HelpArticle
  let relatedArticles: [HelpArticleSummary]
  let strings: HelpUIStrings
  let showsLocaleFallback: Bool
  let navigate: (HelpTopicID) -> Void

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: VelaSpacing.standard) {
        if showsLocaleFallback {
          Label(strings.fallbackNotice, systemImage: "globe")
            .font(VelaTypography.caption)
            .foregroundStyle(.secondary)
            .padding(VelaSpacing.medium)
            .frame(maxWidth: .infinity, alignment: .leading)
            .velaPanelSurface()
        }

        ForEach(Array(article.blocks.enumerated()), id: \.offset) { _, block in
          HelpMarkdownBlockView(block: block)
        }

        if !relatedArticles.isEmpty {
          Divider()
            .padding(.top, VelaSpacing.small)
          Text(strings.relatedTopics)
            .font(VelaTypography.sectionTitle)
          VStack(alignment: .leading, spacing: VelaSpacing.small) {
            ForEach(relatedArticles) { related in
              Button(related.title) {
                navigate(related.id)
              }
              .buttonStyle(.link)
            }
          }
        }
      }
      .frame(maxWidth: 760, alignment: .leading)
      .padding(VelaSpacing.large)
      .frame(maxWidth: .infinity, alignment: .topLeading)
    }
    .textSelection(.enabled)
    .accessibilityIdentifier("help.article.\(article.summary.id.rawValue)")
  }
}

private struct HelpMarkdownBlockView: View {
  let block: HelpMarkdownBlock

  @ViewBuilder
  var body: some View {
    switch block {
    case .heading(let level, let content):
      Text(content.attributedString)
        .font(headingFont(level))
        .padding(.top, level == 1 ? 0 : VelaSpacing.small)
        .accessibilityAddTraits(.isHeader)
    case .paragraph(let content):
      Text(content.attributedString)
        .font(VelaTypography.body)
        .lineSpacing(3)
    case .unorderedList(let items):
      VStack(alignment: .leading, spacing: VelaSpacing.small) {
        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
          HStack(alignment: .firstTextBaseline, spacing: VelaSpacing.small) {
            Text(verbatim: "•")
            Text(item.attributedString)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .accessibilityElement(children: .combine)
        }
      }
      .font(VelaTypography.body)
    case .orderedList(let start, let items):
      VStack(alignment: .leading, spacing: VelaSpacing.small) {
        ForEach(Array(items.enumerated()), id: \.offset) { offset, item in
          HStack(alignment: .firstTextBaseline, spacing: VelaSpacing.small) {
            Text(verbatim: "\(start + offset).")
              .foregroundStyle(.secondary)
              .frame(minWidth: 22, alignment: .trailing)
            Text(item.attributedString)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .accessibilityElement(children: .combine)
        }
      }
      .font(VelaTypography.body)
    case .callout(let content):
      HStack(alignment: .top, spacing: VelaSpacing.small) {
        Image(systemName: "info.circle")
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
        Text(content.attributedString)
          .font(VelaTypography.body)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(VelaSpacing.medium)
      .velaPanelSurface()
    case .code(let language, let text):
      VStack(alignment: .leading, spacing: VelaSpacing.xSmall) {
        if let language {
          Text(language.uppercased())
            .font(VelaTypography.caption.weight(.medium))
            .foregroundStyle(.secondary)
        }
        ScrollView(.horizontal) {
          Text(verbatim: text)
            .font(VelaTypography.code)
            .fixedSize(horizontal: true, vertical: false)
            .padding(VelaSpacing.medium)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
          VelaAppearance.secondarySurface,
          in: RoundedRectangle(
            cornerRadius: VelaRadius.small,
            style: .continuous
          ))
      }
    }
  }

  private func headingFont(_ level: Int) -> Font {
    switch level {
    case 1: VelaTypography.pageTitle
    case 2: .title3.weight(.semibold)
    default: VelaTypography.sectionTitle
    }
  }
}

extension HelpInlineContent {
  fileprivate var attributedString: AttributedString {
    var result = AttributedString()
    for fragment in fragments {
      var part: AttributedString
      switch fragment {
      case .text(let value):
        part = AttributedString(value)
      case .emphasis(let value):
        part = AttributedString(value)
        part.inlinePresentationIntent = .emphasized
      case .strong(let value):
        part = AttributedString(value)
        part.inlinePresentationIntent = .stronglyEmphasized
      case .code(let value):
        part = AttributedString(value)
        part.inlinePresentationIntent = .code
      case .link(let label, let destination):
        part = AttributedString(label)
        switch destination {
        case .topic(let topicID):
          part.link = URL(string: "help:\(topicID.rawValue)")
        case .external(let url):
          part.link = url
        }
      }
      result.append(part)
    }
    return result
  }
}
