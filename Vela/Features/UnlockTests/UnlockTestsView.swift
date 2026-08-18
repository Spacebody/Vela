import Foundation
import Observation
import SwiftUI

nonisolated enum UnlockTestStrings {
    private static var isChinese: Bool {
        Locale.current.language.languageCode?.identifier == "zh"
    }

    static func text(_ english: String, _ chinese: String) -> String {
        isChinese ? chinese : english
    }

    static var title: String { text("Unlock Tests", "解锁测试") }
    static var subtitle: String {
        text(
            "Check public reachability and obvious regional restrictions for common services.",
            "检查常用服务的公开访问能力与明显的地区限制。"
        )
    }
}

nonisolated struct UnlockProbeDefinition: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let category: String
    let systemImage: String
    let url: URL

    static let defaults: [Self] = [
        .init(id: "openai", name: "ChatGPT", category: "AI", systemImage: "sparkles", url: URL(string: "https://chatgpt.com/")!),
        .init(id: "claude", name: "Claude", category: "AI", systemImage: "brain", url: URL(string: "https://claude.ai/")!),
        .init(id: "gemini", name: "Gemini", category: "AI", systemImage: "wand.and.stars", url: URL(string: "https://gemini.google.com/")!),
        .init(id: "netflix", name: "Netflix", category: "Streaming", systemImage: "play.tv", url: URL(string: "https://www.netflix.com/title/80018499")!),
        .init(id: "disney", name: "Disney+", category: "Streaming", systemImage: "sparkles.tv", url: URL(string: "https://www.disneyplus.com/")!),
        .init(id: "youtube", name: "YouTube", category: "Streaming", systemImage: "play.rectangle", url: URL(string: "https://www.youtube.com/premium")!),
        .init(id: "tiktok", name: "TikTok", category: "Social", systemImage: "music.note", url: URL(string: "https://www.tiktok.com/")!),
        .init(id: "google", name: "Google", category: "Web", systemImage: "magnifyingglass", url: URL(string: "https://www.google.com/generate_204")!),
        .init(id: "github", name: "GitHub", category: "Developer", systemImage: "chevron.left.forwardslash.chevron.right", url: URL(string: "https://github.com/")!),
        .init(id: "wikipedia", name: "Wikipedia", category: "Web", systemImage: "books.vertical", url: URL(string: "https://www.wikipedia.org/")!),
    ]
}

nonisolated struct StoredUnlockProbeDefinition: Codable, Equatable, Sendable {
    let id: String
    let name: String
    let category: String
    let url: String

    init(id: String = "custom.\(UUID().uuidString.lowercased())", name: String, category: String, url: URL) {
        self.id = id
        self.name = name
        self.category = category
        self.url = url.absoluteString
    }

    var probeDefinition: UnlockProbeDefinition? {
        guard let parsedURL = URL(string: url),
              ["http", "https"].contains(parsedURL.scheme?.lowercased() ?? "")
        else { return nil }
        return UnlockProbeDefinition(
            id: id,
            name: name,
            category: category,
            systemImage: "link",
            url: parsedURL
        )
    }
}

nonisolated enum UnlockProbeStatus: Equatable, Sendable {
    case available
    case limited
    case failed

    var systemImage: String {
        switch self {
        case .available: "checkmark.circle.fill"
        case .limited: "exclamationmark.triangle.fill"
        case .failed: "xmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .available: .green
        case .limited: .orange
        case .failed: .red
        }
    }

    var title: String {
        switch self {
        case .available: UnlockTestStrings.text("Available", "可访问")
        case .limited: UnlockTestStrings.text("Limited", "可能受限")
        case .failed: UnlockTestStrings.text("Unavailable", "不可访问")
        }
    }
}

nonisolated struct UnlockProbeResult: Equatable, Sendable {
    let status: UnlockProbeStatus
    let detail: String
    let latencyMilliseconds: Int?
    let region: String?
    let testedAt: Date
}

nonisolated enum UnlockProbeEvaluator {
    private static let restrictionMarkers = [
        "not available in your country",
        "not available in your region",
        "unavailable in your country",
        "unavailable in your region",
        "unsupported region",
        "geo blocked",
    ]

    static func evaluate(
        statusCode: Int,
        body: Data,
        latencyMilliseconds: Int,
        region: String?
    ) -> UnlockProbeResult {
        let text = String(decoding: body.prefix(256_000), as: UTF8.self).lowercased()
        let isRestricted = restrictionMarkers.contains { text.contains($0) }
        let status: UnlockProbeStatus
        let detail: String

        if isRestricted || statusCode == 451 {
            status = .limited
            detail = UnlockTestStrings.text("A regional restriction was detected.", "检测到地区限制。")
        } else if (200..<400).contains(statusCode) {
            status = .available
            detail = UnlockTestStrings.text("The public service endpoint responded normally.", "服务公开入口响应正常。")
        } else if statusCode == 401 || statusCode == 403 {
            status = .limited
            detail = UnlockTestStrings.text("The endpoint is reachable but denied this request.", "入口可达，但当前请求被拒绝。")
        } else {
            status = .failed
            detail = UnlockTestStrings.text("HTTP status \(statusCode).", "HTTP 状态码 \(statusCode)。")
        }

        return UnlockProbeResult(
            status: status,
            detail: detail,
            latencyMilliseconds: latencyMilliseconds,
            region: region,
            testedAt: .now
        )
    }
}

actor UnlockProbeRunner {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 12
        configuration.waitsForConnectivity = false
        configuration.httpAdditionalHeaders = [
            "Accept-Language": "en-US,en;q=0.8",
            "User-Agent": "Vela/1.0 macOS UnlockTest",
        ]
        session = URLSession(configuration: configuration)
    }

    func run(_ definition: UnlockProbeDefinition) async -> UnlockProbeResult {
        let startedAt = ContinuousClock.now
        do {
            var request = URLRequest(url: definition.url)
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return failure(UnlockTestStrings.text("The server returned an invalid response.", "服务器返回了无效响应。"))
            }
            let elapsed = startedAt.duration(to: .now)
            let milliseconds = max(0, Int(elapsed.components.seconds * 1_000)
                + Int(elapsed.components.attoseconds / 1_000_000_000_000_000))
            return UnlockProbeEvaluator.evaluate(
                statusCode: http.statusCode,
                body: data,
                latencyMilliseconds: milliseconds,
                region: region(from: http)
            )
        } catch is CancellationError {
            return failure(UnlockTestStrings.text("Test cancelled.", "测试已取消。"))
        } catch {
            return failure(error.localizedDescription)
        }
    }

    private func region(from response: HTTPURLResponse) -> String? {
        let keys = ["cf-ipcountry", "x-vercel-ip-country", "x-country-code"]
        for (key, value) in response.allHeaderFields {
            guard let key = key as? String,
                  keys.contains(key.lowercased()),
                  let value = value as? String,
                  !value.isEmpty
            else { continue }
            return value.uppercased()
        }
        return nil
    }

    private func failure(_ detail: String) -> UnlockProbeResult {
        UnlockProbeResult(
            status: .failed,
            detail: detail,
            latencyMilliseconds: nil,
            region: nil,
            testedAt: .now
        )
    }
}

@MainActor
@Observable
final class UnlockTestsViewModel {
    private let runner: UnlockProbeRunner
    private(set) var services: [UnlockProbeDefinition]
    private(set) var results: [String: UnlockProbeResult] = [:]
    private(set) var runningServiceIDs: Set<String> = []
    private(set) var isRunningAll = false

    init(
        services: [UnlockProbeDefinition] = UnlockProbeDefinition.defaults,
        runner: UnlockProbeRunner = UnlockProbeRunner()
    ) {
        self.services = services
        self.runner = runner
    }

    func runAll() async {
        guard !isRunningAll else { return }
        isRunningAll = true
        runningServiceIDs = Set(services.map(\.id))
        defer {
            isRunningAll = false
            runningServiceIDs.removeAll()
        }

        await withTaskGroup(of: (String, UnlockProbeResult).self) { group in
            for service in services {
                group.addTask { [runner] in
                    (service.id, await runner.run(service))
                }
            }
            for await (id, result) in group {
                results[id] = result
                runningServiceIDs.remove(id)
            }
        }
    }

    func run(_ service: UnlockProbeDefinition) async {
        guard !runningServiceIDs.contains(service.id) else { return }
        runningServiceIDs.insert(service.id)
        results[service.id] = await runner.run(service)
        runningServiceIDs.remove(service.id)
    }

    func replaceCustomServices(with customServices: [UnlockProbeDefinition]) {
        let customIDs = Set(customServices.map(\.id))
        services = UnlockProbeDefinition.defaults + customServices
        results = results.filter { services.map(\.id).contains($0.key) }
        runningServiceIDs = runningServiceIDs.filter { services.map(\.id).contains($0) }
        if customIDs.isEmpty {
            runningServiceIDs = runningServiceIDs.filter { !$0.hasPrefix("custom.") }
        }
    }
}

struct UnlockTestsView: View {
    @AppStorage("unlockTests.customDefinitions.v1") private var storedCustomDefinitions = "[]"
    @State private var viewModel = UnlockTestsViewModel()
    @State private var isAddingCustomTest = false

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                VelaPageCanvas()

                VStack(alignment: .leading, spacing: VelaSpacing.standard) {
                    header

                    ScrollView {
                        LazyVGrid(
                            columns: columns(for: geometry.size.width),
                            alignment: .leading,
                            spacing: VelaSpacing.standard
                        ) {
                            ForEach(viewModel.services) { service in
                                serviceCard(service)
                                    .contextMenu {
                                        if service.id.hasPrefix("custom.") {
                                            Button(role: .destructive) {
                                                deleteCustomTest(id: service.id)
                                            } label: {
                                                Label(
                                                    UnlockTestStrings.text("Delete Custom Test", "删除自定义测试"),
                                                    systemImage: "trash"
                                                )
                                            }
                                        }
                                    }
                            }
                        }
                        .padding(.bottom, VelaSpacing.xLarge)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .velaContainsNestedScrolling()
                }
                .padding(.horizontal, VelaSpacing.xLarge)
                .padding(.vertical, VelaSpacing.large)
            }
        }
        .environment(\.colorScheme, .light)
        .onAppear(perform: restoreCustomTests)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: VelaSpacing.large) {
            VStack(alignment: .leading, spacing: 6) {
                Text(UnlockTestStrings.title)
                    .font(VelaTypography.pageTitle)
                Text(UnlockTestStrings.subtitle)
                    .font(VelaTypography.body)
                    .foregroundStyle(.secondary)
                Text(UnlockTestStrings.text(
                    "Results indicate public reachability, not account entitlement or the full regional catalog.",
                    "结果仅表示公开入口可达性，不代表账号权益或完整地区片库。"
                ))
                    .font(VelaTypography.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            HStack(spacing: VelaSpacing.small) {
                Button {
                    isAddingCustomTest = true
                } label: {
                    Label(
                        UnlockTestStrings.text("Custom Test", "自定义测试"),
                        systemImage: "plus"
                    )
                    .frame(minWidth: 110)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .accessibilityIdentifier("unlockTests.addCustom")
                .popover(isPresented: $isAddingCustomTest, arrowEdge: .top) {
                    AddUnlockTestSheet { definition in
                        saveCustomTest(definition)
                        isAddingCustomTest = false
                    } onCancel: {
                        isAddingCustomTest = false
                    }
                }

                Button {
                    Task { await viewModel.runAll() }
                } label: {
                    Label(
                        viewModel.isRunningAll
                            ? UnlockTestStrings.text("Testing…", "测试中…")
                            : UnlockTestStrings.text("Test All", "全部测试"),
                        systemImage: viewModel.isRunningAll ? "arrow.triangle.2.circlepath" : "play.fill"
                    )
                    .frame(minWidth: 112)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(viewModel.isRunningAll)
            }
        }
    }

    private func serviceCard(_ service: UnlockProbeDefinition) -> some View {
        let result = viewModel.results[service.id]
        let isRunning = viewModel.runningServiceIDs.contains(service.id)

        return VStack(alignment: .leading, spacing: VelaSpacing.medium) {
            HStack(spacing: 10) {
                Image(systemName: service.systemImage)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 36, height: 36)
                    .background(Color.accentColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 3) {
                    Text(service.name)
                        .font(VelaTypography.sectionTitle)
                    Text(service.category)
                        .font(VelaTypography.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if isRunning {
                    ProgressView().controlSize(.small)
                } else if let result {
                    Image(systemName: result.status.systemImage)
                        .foregroundStyle(result.status.color)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(result?.status.title ?? UnlockTestStrings.text("Not tested", "未测试"))
                    .font(VelaTypography.body.weight(.semibold))
                    .foregroundStyle(result?.status.color ?? Color.secondary)
                Text(result?.detail ?? UnlockTestStrings.text("Run a test to check this service.", "运行测试以检查此服务。"))
                    .font(VelaTypography.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(minHeight: 34, alignment: .topLeading)
            }

            HStack(spacing: 12) {
                if let latency = result?.latencyMilliseconds {
                    Label("\(latency) ms", systemImage: "timer")
                }
                if let region = result?.region {
                    Label(region, systemImage: "mappin.and.ellipse")
                }
                Spacer()
                Button {
                    Task { await viewModel.run(service) }
                } label: {
                    Label(
                        isRunning
                            ? UnlockTestStrings.text("Testing…", "测试中…")
                            : UnlockTestStrings.text("Test", "测试"),
                        systemImage: isRunning ? "arrow.triangle.2.circlepath" : "play.fill"
                    )
                    .frame(minWidth: 104)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(isRunning)
            }
            .font(VelaTypography.caption)
        }
        .padding(VelaSpacing.standard)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .velaPanelSurface(radius: 18)
    }

    private func columns(for width: CGFloat) -> [GridItem] {
        let available = max(0, width - VelaSpacing.xLarge * 2)
        let count: Int
        switch available {
        case 1_320...: count = 5
        case 1_040...: count = 4
        case 760...: count = 3
        default: count = 2
        }
        return Array(
            repeating: GridItem(.flexible(minimum: 210), spacing: VelaSpacing.standard),
            count: count
        )
    }

    private func restoreCustomTests() {
        let stored = (try? JSONDecoder().decode(
            [StoredUnlockProbeDefinition].self,
            from: Data(storedCustomDefinitions.utf8)
        )) ?? []
        viewModel.replaceCustomServices(with: stored.compactMap(\.probeDefinition))
    }

    private func saveCustomTest(_ definition: StoredUnlockProbeDefinition) {
        var stored = decodedCustomTests()
        stored.append(definition)
        persist(stored)
    }

    private func deleteCustomTest(id: String) {
        persist(decodedCustomTests().filter { $0.id != id })
    }

    private func decodedCustomTests() -> [StoredUnlockProbeDefinition] {
        (try? JSONDecoder().decode(
            [StoredUnlockProbeDefinition].self,
            from: Data(storedCustomDefinitions.utf8)
        )) ?? []
    }

    private func persist(_ definitions: [StoredUnlockProbeDefinition]) {
        guard let data = try? JSONEncoder().encode(definitions),
              let value = String(data: data, encoding: .utf8)
        else { return }
        storedCustomDefinitions = value
        viewModel.replaceCustomServices(with: definitions.compactMap(\.probeDefinition))
    }
}

private struct AddUnlockTestSheet: View {
    let onSave: (StoredUnlockProbeDefinition) -> Void
    let onCancel: () -> Void

    @State private var name = ""
    @State private var category = "Custom"
    @State private var urlText = ""

    private var validURL: URL? {
        guard let url = URL(string: urlText.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "")
        else { return nil }
        return url
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && validURL != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: VelaSpacing.large) {
            VStack(alignment: .leading, spacing: 5) {
                Text(UnlockTestStrings.text("Add Custom Test", "新增自定义测试"))
                    .font(VelaTypography.pageTitle)
                Text(UnlockTestStrings.text(
                    "Vela will request this public HTTP or HTTPS endpoint using the same privacy-safe probe as built-in tests.",
                    "Vela 会使用与内置测试相同的隐私安全探测请求此公开 HTTP 或 HTTPS 地址。"
                ))
                .font(VelaTypography.body)
                .foregroundStyle(.secondary)
            }

            Form {
                TextField(UnlockTestStrings.text("Name", "名称"), text: $name)
                    .accessibilityIdentifier("unlockTests.custom.name")
                TextField(UnlockTestStrings.text("Category", "分类"), text: $category)
                    .accessibilityIdentifier("unlockTests.custom.category")
                TextField("https://example.com/", text: $urlText)
                    .accessibilityIdentifier("unlockTests.custom.url")
            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack {
                Spacer()
                Button(UnlockTestStrings.text("Cancel", "取消"), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("unlockTests.custom.cancel")
                Button(UnlockTestStrings.text("Add Test", "添加测试")) {
                    guard let validURL else { return }
                    onSave(
                        StoredUnlockProbeDefinition(
                            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                            category: category.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? "Custom"
                                : category.trimmingCharacters(in: .whitespacesAndNewlines),
                            url: validURL
                        )
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSave)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("unlockTests.custom.save")
            }
        }
        .padding(VelaSpacing.large)
        .frame(width: 520, height: 430, alignment: .topLeading)
        .background(VelaPageCanvas())
        .accessibilityIdentifier("unlockTests.custom.sheet")
    }
}
