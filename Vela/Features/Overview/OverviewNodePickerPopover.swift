import SwiftUI

struct OverviewNodePickerPopover: View {
    @Environment(\.locale) private var locale
    @State private var searchText = ""

    let groupName: String
    let candidates: [OverviewProxyNodeSnapshot]
    let isRefreshing: Bool
    let onSelect: (OverviewProxyNodeSnapshot) -> Void

    private var strings: OverviewStrings { OverviewStrings(locale: locale) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(groupName)
                        .font(.system(size: 16, weight: .semibold))
                    Text(strings.availableNodeCount(candidates.count))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(OverviewDesignTokens.ColorToken.accent)
            }

            TextField(strings.searchNodes, text: $searchText)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("overview.nodePicker.search")

            Divider()

            if sections.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 24, weight: .regular))
                    Text(strings.noMatchingNodes)
                        .font(.system(size: 14, weight: .medium))
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12, pinnedViews: [.sectionHeaders]) {
                        ForEach(sections) { section in
                            Section {
                                VStack(spacing: 4) {
                                    ForEach(section.candidates) { candidate in
                                        nodeRow(candidate)
                                    }
                                }
                            } header: {
                                sectionHeader(section)
                            }
                        }
                    }
                    .padding(.horizontal, 2)
                    .padding(.bottom, 4)
                }
                .scrollIndicators(.visible)
            }
        }
        .padding(14)
        .frame(width: 380, height: 430)
        .accessibilityIdentifier("overview.nodePicker")
    }

    private var filteredCandidates: [OverviewProxyNodeSnapshot] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return candidates }
        return candidates.filter { candidate in
            candidate.name.localizedCaseInsensitiveContains(query)
                || candidate.selectionName.localizedCaseInsensitiveContains(query)
        }
    }

    private var sections: [NodeSection] {
        var sectionOrder: [String] = []
        var grouped: [String: [OverviewProxyNodeSnapshot]] = [:]

        for candidate in filteredCandidates {
            let key = candidate.regionCode ?? NodeSection.otherKey
            if grouped[key] == nil {
                sectionOrder.append(key)
            }
            grouped[key, default: []].append(candidate)
        }

        return sectionOrder.map { key in
            NodeSection(
                id: key,
                regionCode: key == NodeSection.otherKey ? nil : key,
                candidates: grouped[key, default: []]
            )
        }
    }

    private func sectionHeader(_ section: NodeSection) -> some View {
        HStack(spacing: 7) {
            if let flag = section.candidates.first.flatMap({
                ProxyCountryFlagResolver.flag(for: $0.selectionName)
            }) {
                Text(flag)
            }

            Text(sectionTitle(section))
                .font(.system(size: 12, weight: .semibold))

            Spacer()

            Text(String(section.candidates.count))
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.regularMaterial)
    }

    private func nodeRow(_ candidate: OverviewProxyNodeSnapshot) -> some View {
        Button {
            onSelect(candidate)
        } label: {
            HStack(spacing: 10) {
                if let flag = ProxyCountryFlagResolver.flag(for: candidate.selectionName) {
                    Text(flag)
                        .font(.system(size: 16))
                        .frame(width: 22)
                } else {
                    Image(systemName: "network")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 22)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(displayTitle(candidate))
                        .font(.system(size: 14, weight: candidate.isSelected ? .semibold : .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if let latency = candidate.latency {
                        Text(latency)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 10)

                if candidate.isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(OverviewDesignTokens.ColorToken.accent)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 44)
            .background(
                candidate.isSelected
                    ? OverviewDesignTokens.ColorToken.accent.opacity(0.11)
                    : Color.clear,
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(candidate.isSelected || isRefreshing)
        .accessibilityIdentifier("overview.nodeOption.\(candidate.id)")
        .accessibilityLabel(candidate.name)
    }

    private func sectionTitle(_ section: NodeSection) -> String {
        guard let regionCode = section.regionCode else { return strings.otherNodes }
        return locale.localizedString(forRegionCode: regionCode) ?? regionCode
    }

    private func displayTitle(_ candidate: OverviewProxyNodeSnapshot) -> String {
        guard let flag = ProxyCountryFlagResolver.flag(for: candidate.selectionName),
            candidate.name.hasPrefix(flag)
        else { return candidate.name }

        return candidate.name
            .dropFirst(flag.count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct NodeSection: Identifiable {
    static let otherKey = "__other__"

    let id: String
    let regionCode: String?
    let candidates: [OverviewProxyNodeSnapshot]
}
