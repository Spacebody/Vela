#if DEBUG
  import SwiftUI

  nonisolated enum TunFlowVisualScenario: String, CaseIterable, Sendable {
    case notInstalledDarkChinese
    case notInstalledLightEnglish
    case registering
    case needsApproval
    case approvalDenied
    case helperEnabledConnecting
    case helperIncompatible
    case helperDamaged
    case profileRequired
    case invalidConfiguration
    case readyToStart
    case preparingTarget
    case disablingSystemProxy
    case stoppingSource
    case startingPrivilegedBackend
    case connectingController
    case waitingForInterface
    case verifyingRoutes
    case verifyingDNS
    case committing
    case runningSuccess
    case startFailureRollbackSucceeded
    case verificationFailureRollbackSucceeded
    case rollbackFailed
    case recoveryPreflight
    case recoveryInProgress
    case recoverySucceeded
    case recoveryFailed
    case minimum720Chinese
    case default780English
    case increaseContrast
    case reduceMotion
    case pseudoLocale
    case doubleLength
    case voiceOverCurrentStep
    case keyboardStates

    static let launchArgument = "-VelaTunScenario"

    static func resolved(
      arguments: [String] = ProcessInfo.processInfo.arguments,
      fallbackState: VisualUITestConfiguration.State
    ) -> Self {
      if let index = arguments.lastIndex(of: launchArgument) {
        let valueIndex = arguments.index(after: index)
        if valueIndex < arguments.endIndex,
          let scenario = Self(rawValue: arguments[valueIndex])
        {
          return scenario
        }
      }
      return switch fallbackState {
      case .loading: .notInstalledLightEnglish
      case .pendingMutation: .registering
      case .failure: .helperDamaged
      case .permissionRequired: .needsApproval
      case .transitioning: .preparingTarget
      case .rollbackFailed: .rollbackFailed
      default: .notInstalledLightEnglish
      }
    }

    var isTransition: Bool {
      switch self {
      case .preparingTarget, .disablingSystemProxy, .stoppingSource,
        .startingPrivilegedBackend, .connectingController, .waitingForInterface,
        .verifyingRoutes, .verifyingDNS, .committing:
        true
      default:
        false
      }
    }

    var isRecovery: Bool {
      switch self {
      case .helperIncompatible, .helperDamaged, .startFailureRollbackSucceeded,
        .verificationFailureRollbackSucceeded, .rollbackFailed, .recoveryPreflight,
        .recoveryInProgress, .recoverySucceeded, .recoveryFailed:
        true
      default:
        false
      }
    }

    var isSuccess: Bool {
      self == .runningSuccess || self == .recoverySucceeded
    }

    var setupProgress: Int {
      switch self {
      case .notInstalledDarkChinese, .notInstalledLightEnglish, .registering,
        .minimum720Chinese, .default780English, .increaseContrast, .reduceMotion,
        .pseudoLocale, .doubleLength, .voiceOverCurrentStep, .keyboardStates:
        0
      case .needsApproval, .approvalDenied, .helperEnabledConnecting,
        .helperIncompatible, .helperDamaged:
        1
      case .profileRequired, .invalidConfiguration, .readyToStart:
        2
      case .preparingTarget, .disablingSystemProxy, .stoppingSource,
        .startingPrivilegedBackend, .connectingController:
        2
      case .waitingForInterface, .verifyingRoutes, .verifyingDNS, .committing:
        3
      case .runningSuccess, .recoverySucceeded:
        4
      case .startFailureRollbackSucceeded, .verificationFailureRollbackSucceeded,
        .rollbackFailed, .recoveryPreflight, .recoveryInProgress, .recoveryFailed:
        3
      }
    }
  }

  struct TunFlowVisualFixtureView: View {
    let configuration: VisualUITestConfiguration

    private var scenario: TunFlowVisualScenario {
      TunFlowVisualScenario.resolved(fallbackState: configuration.state)
    }

    private var copy: VisualFixtureLocalizedCopy {
      VisualFixtureLocalizedCopy(locale: configuration.localeIdentifier)
    }

    var body: some View {
      ZStack {
        VelaPageCanvas()

        VStack(alignment: .leading, spacing: 0) {
          header
            .background(.ultraThinMaterial)
          ScrollView {
            bodyContent
              .padding(VelaSpacing.large)
              .frame(maxWidth: .infinity, alignment: .topLeading)
              .velaPanelSurface()
              .padding(VelaSpacing.standard)
          }
          footer
            .background(.ultraThinMaterial)
        }
      }
      .frame(width: fixtureSize.width, height: fixtureSize.height)
      .overlay(alignment: .topLeading) {
        VisualSurfaceMarker(identifier: "tun.onboarding", label: "TUN onboarding")
      }
      .overlay(alignment: .topTrailing) {
        VisualSurfaceMarker(
          identifier: "tun.fixture.\(scenario.rawValue)",
          label: "TUN visual scenario: \(scenario.rawValue)"
        )
      }
      .overlay(alignment: .bottomTrailing) {
        VisualReadyMarker(fixtureID: configuration.fixtureID)
      }
      .environment(\.visualUITestConfiguration, configuration)
      .environment(\.locale, configuration.locale)
      .preferredColorScheme(configuration.colorScheme)
    }

    @ViewBuilder
    private var header: some View {
      if scenario.isTransition {
        VStack(alignment: .leading, spacing: VelaSpacing.medium) {
          titleRow(
            copy.text("Switching to TUN", "正在切换到 TUN"),
            label: phaseTitle,
            semanticStatus: .pending
          )
          transitionContext
        }
        .padding(.horizontal, VelaSpacing.large)
        .padding(.vertical, VelaSpacing.medium)
      } else if scenario.isRecovery {
        titleRow(
          copy.text("TUN Recovery", "TUN 恢复"),
          label: scenario.isSuccess
            ? copy.text("Recovered", "已恢复")
            : copy.text("Needs Attention", "需要处理"),
          semanticStatus: scenario.isSuccess ? .success : .error
        )
        .padding(.horizontal, VelaSpacing.large)
        .padding(.vertical, VelaSpacing.medium)
      } else {
        VStack(alignment: .leading, spacing: VelaSpacing.medium) {
          Text(copy.text("Set Up TUN", "设置 TUN"))
            .font(VelaTypography.pageTitle)
            .accessibilityAddTraits(.isHeader)
          setupProgress
        }
        .padding(.horizontal, VelaSpacing.large)
        .padding(.vertical, VelaSpacing.medium)
      }
    }

    private func titleRow(
      _ title: String,
      label: String,
      semanticStatus: VelaSemanticStatus
    ) -> some View {
      HStack(alignment: .firstTextBaseline) {
        Text(title)
          .font(VelaTypography.pageTitle)
          .accessibilityAddTraits(.isHeader)
        Spacer()
        VelaStatusPill(status: semanticStatus, label: label)
      }
    }

    private var setupProgress: some View {
      HStack(spacing: VelaSpacing.small) {
        ForEach(Array(stepTitles.enumerated()), id: \.offset) { index, title in
          HStack(spacing: VelaSpacing.small) {
            Image(systemName: stepSymbol(index))
              .foregroundStyle(stepColor(index))
              .frame(width: 26, height: 26)
              .background(stepColor(index).opacity(0.1), in: Circle())
            Text(title)
              .font(VelaTypography.caption)
              .lineLimit(1)
          }
          .frame(maxWidth: .infinity)
          .accessibilityElement(children: .combine)
          .accessibilityValue(stepAccessibilityValue(index))
          if index < stepTitles.count - 1 {
            Rectangle()
              .fill(
                index < scenario.setupProgress
                  ? Color.green.opacity(0.55) : VelaAppearance.separator
              )
              .frame(height: 1)
          }
        }
      }
      .frame(height: 40)
      .accessibilityIdentifier("tun.setup.progress")
    }

    @ViewBuilder
    private var bodyContent: some View {
      if scenario.isTransition {
        transitionBody
      } else if scenario.isRecovery {
        recoveryBody
      } else if scenario == .runningSuccess {
        runningBody
      } else {
        setupBody
      }
    }

    private var setupBody: some View {
      VStack(alignment: .leading, spacing: VelaSpacing.large) {
        Label(stateTitle, systemImage: stateSymbol)
          .font(VelaTypography.sectionTitle)
        Text(stateDetail)
          .font(VelaTypography.body)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        Grid(alignment: .leading, horizontalSpacing: VelaSpacing.section) {
          fixtureRow(copy.text("Privileged Component", "特权组件"), componentValue)
          fixtureRow(copy.text("Configuration", "配置"), configurationValue)
          fixtureRow(copy.text("TUN Stack", "TUN 栈"), "mixed")
          fixtureRow(copy.text("Routes", "路由"), copy.text("Automatic", "自动"))
          fixtureRow(copy.text("DNS", "DNS"), copy.text("Hijack enabled", "劫持已启用"))
        }

        DisclosureGroup(copy.text("Security and technical details", "安全与技术详情")) {
          Text(
            copy.text(
              "Vela verifies the bundled helper, protocol range, selected configuration, and Mihomo core before starting the existing transition transaction.",
              "Vela 会在启动现有切换事务前验证随附 Helper、协议范围、所选配置和 Mihomo 内核。"
            )
          )
          .font(VelaTypography.caption)
          .foregroundStyle(.secondary)
          .padding(.top, VelaSpacing.small)
        }
      }
      .accessibilityIdentifier("tun.fixture.setup")
    }

    private var transitionBody: some View {
      VStack(alignment: .leading, spacing: VelaSpacing.large) {
        Text(
          copy.text(
            "The active transaction continues in EngineStore. Progress reflects real phases and never invents a percentage.",
            "当前事务继续由 EngineStore 执行。进度只反映真实阶段，不虚构百分比。"
          )
        )
        .foregroundStyle(.secondary)

        VStack(spacing: VelaSpacing.small) {
          ForEach(Array(transitionPhases.enumerated()), id: \.offset) { index, phase in
            HStack(spacing: VelaSpacing.medium) {
              Image(systemName: transitionPhaseSymbol(index))
                .foregroundStyle(transitionPhaseColor(index))
                .frame(width: VelaSpacing.section)
              Text(phase)
              Spacer()
            }
            .accessibilityElement(children: .combine)
          }
        }
        .accessibilityIdentifier("tun.transition.phases")
      }
    }

    private var recoveryBody: some View {
      VStack(alignment: .leading, spacing: VelaSpacing.large) {
        VelaStateBanner(
          kind: scenario.isSuccess ? .info : .error,
          title: stateTitle,
          detail: stateDetail
        )

        Grid(alignment: .leading, horizontalSpacing: VelaSpacing.section) {
          fixtureRow(copy.text("Failed Phase", "失败阶段"), phaseTitle)
          fixtureRow(copy.text("Previous Backend", "之前的后端"), copy.text("System Proxy", "系统代理"))
          fixtureRow(copy.text("Requested Backend", "请求的后端"), "TUN")
          fixtureRow(copy.text("Transaction", "事务"), "7A14C2E0-20B7-4CE1")
          fixtureRow(copy.text("Rollback", "回滚"), rollbackValue)
          fixtureRow(copy.text("System Proxy", "系统代理"), proxyValue)
          fixtureRow(copy.text("Privileged Component", "特权组件"), componentValue)
        }
      }
      .accessibilityIdentifier("tun.fixture.recovery")
    }

    private var runningBody: some View {
      VStack(alignment: .leading, spacing: VelaSpacing.large) {
        VelaStateBanner(
          kind: .info,
          title: copy.text("TUN Is Running", "TUN 正在运行"),
          detail: copy.text(
            "The interface, controller, routes, DNS, and owner lease are verified.",
            "接口、控制器、路由、DNS 和所有者租约均已验证。"
          )
        )
        Grid(alignment: .leading, horizontalSpacing: VelaSpacing.section) {
          fixtureRow(copy.text("Interface", "接口"), "utun7")
          fixtureRow(copy.text("Controller", "控制器"), copy.text("Reachable", "可访问"))
          fixtureRow(copy.text("Routes", "路由"), copy.text("Applied", "已应用"))
          fixtureRow(copy.text("DNS", "DNS"), copy.text("Ready", "就绪"))
          fixtureRow(copy.text("System Proxy", "系统代理"), copy.text("Disabled", "已停用"))
          fixtureRow(copy.text("Owner Lease", "所有者租约"), copy.text("Valid", "有效"))
        }
      }
    }

    private var transitionContext: some View {
      Grid(alignment: .leading, horizontalSpacing: VelaSpacing.section) {
        GridRow {
          Text(copy.text("Current", "当前")).foregroundStyle(.secondary)
          Text(copy.text("System Proxy", "系统代理"))
          Text(copy.text("Requested", "请求")).foregroundStyle(.secondary)
          Text("TUN")
        }
        GridRow {
          Text(copy.text("Transaction", "事务")).foregroundStyle(.secondary)
          Text("7A14C2E0-20B7-4CE1")
            .fontDesign(.monospaced)
          Color.clear
          Color.clear
        }
      }
      .font(VelaTypography.caption)
      .accessibilityIdentifier("tun.transition.context")
    }

    private var footer: some View {
      HStack(spacing: VelaSpacing.small) {
        Button(dismissTitle) {}
          .keyboardShortcut(.cancelAction)
          .accessibilityIdentifier("tun.dismissAction")
        Spacer()
        if let secondaryTitle {
          Button(secondaryTitle) {}
            .accessibilityIdentifier("tun.secondaryAction")
        }
        if let primaryTitle {
          Button(primaryTitle) {}
            .keyboardShortcut(.defaultAction)
            .disabled(primaryDisabled)
            .accessibilityIdentifier("tun.primaryAction")
        } else if scenario.isTransition {
          ProgressView()
            .controlSize(.small)
          Text(phaseTitle)
            .font(VelaTypography.caption)
            .foregroundStyle(.secondary)
        }
      }
      .controlSize(.regular)
      .padding(.horizontal, VelaSpacing.large)
      .padding(.vertical, VelaSpacing.medium)
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("tun.flow.footer")
    }

    private func fixtureRow(_ title: String, _ value: String) -> some View {
      GridRow {
        Text(title)
          .font(VelaTypography.caption)
          .foregroundStyle(.secondary)
        Text(value)
          .font(VelaTypography.body)
          .textSelection(.enabled)
      }
    }

    private var fixtureSize: CGSize {
      scenario == .minimum720Chinese
        ? CGSize(width: 720, height: 500) : CGSize(width: 780, height: 560)
    }

    private var stepTitles: [String] {
      [
        copy.text("Install", "安装"), copy.text("Approve", "批准"),
        copy.text("Start", "启动"), copy.text("Verify", "验证"),
      ]
    }

    private func stepSymbol(_ index: Int) -> String {
      if index < scenario.setupProgress { return "checkmark.circle.fill" }
      if index == scenario.setupProgress { return "circle.inset.filled" }
      return "circle"
    }

    private func stepColor(_ index: Int) -> Color {
      if index < scenario.setupProgress { return .green }
      if index == scenario.setupProgress { return .accentColor }
      return .secondary
    }

    private func stepAccessibilityValue(_ index: Int) -> String {
      if index < scenario.setupProgress { return copy.text("Complete", "已完成") }
      if index == scenario.setupProgress { return copy.text("Current", "当前") }
      return copy.text("Pending", "待处理")
    }

    private var stateTitle: String {
      switch scenario {
      case .registering: copy.text("Registering Privileged Component", "正在注册特权组件")
      case .needsApproval: copy.text("Approval Required", "需要批准")
      case .approvalDenied: copy.text("Approval Was Not Granted", "未获得批准")
      case .helperEnabledConnecting: copy.text("Verifying Helper Handshake", "正在验证 Helper 握手")
      case .helperIncompatible: copy.text("Helper Protocol Is Incompatible", "Helper 协议不兼容")
      case .helperDamaged: copy.text("Privileged Component Is Damaged", "特权组件已损坏")
      case .profileRequired: copy.text("Configuration Required", "需要配置")
      case .invalidConfiguration: copy.text("Configuration Needs Attention", "配置需要处理")
      case .readyToStart: copy.text("Ready to Start TUN", "可以启动 TUN")
      case .startFailureRollbackSucceeded: copy.text("TUN Start Failed", "TUN 启动失败")
      case .verificationFailureRollbackSucceeded: copy.text("TUN Verification Failed", "TUN 验证失败")
      case .rollbackFailed: copy.text("Transition and Rollback Failed", "切换和回滚均失败")
      case .recoveryPreflight: copy.text("Recovery Checks", "恢复检查")
      case .recoveryInProgress: copy.text("Recovery In Progress", "正在恢复")
      case .recoverySucceeded: copy.text("Recovery Succeeded", "恢复成功")
      case .recoveryFailed: copy.text("Recovery Could Not Complete", "恢复未能完成")
      default: copy.text("Install the Privileged Component", "安装特权组件")
      }
    }

    private var stateDetail: String {
      switch scenario {
      case .needsApproval, .approvalDenied:
        copy.text(
          "Approve Vela in System Settings > General > Login Items & Extensions, then choose Check Again.",
          "请在“系统设置 > 通用 > 登录项与扩展”中批准 Vela，然后选择“再次检查”。"
        )
      case .profileRequired:
        copy.text("Select a configuration before enabling TUN.", "启用 TUN 前请选择配置。")
      case .invalidConfiguration:
        copy.text(
          "The selected configuration did not pass Mihomo validation.", "所选配置未通过 Mihomo 验证。")
      case .startFailureRollbackSucceeded, .verificationFailureRollbackSucceeded:
        copy.text(
          "The previous backend was restored. Review Diagnostics before retrying.",
          "之前的后端已恢复。重试前请查看诊断。")
      case .rollbackFailed, .recoveryFailed:
        copy.text(
          "The previous network state could not be verified. Open Recovery before another network change.",
          "无法验证之前的网络状态。再次更改网络前请打开恢复。")
      case .recoverySucceeded:
        copy.text(
          "System Proxy ownership and the previous backend were verified.", "系统代理所有权和之前的后端已验证。")
      default:
        copy.text(
          "Vela uses the existing authenticated helper and bounded transition transaction. No terminal command is required.",
          "Vela 使用现有的认证 Helper 和有界切换事务，无需终端命令。"
        )
      }
    }

    private var stateSymbol: String {
      switch scenario {
      case .needsApproval, .approvalDenied: "person.badge.key.fill"
      case .registering, .helperEnabledConnecting: "clock.arrow.circlepath"
      case .profileRequired, .invalidConfiguration: "doc.badge.exclamationmark"
      case .readyToStart: "checkmark.circle.fill"
      default: "shield.lefthalf.filled"
      }
    }

    private var componentValue: String {
      switch scenario {
      case .needsApproval, .approvalDenied: copy.text("Needs Approval", "需要批准")
      case .helperIncompatible: copy.text("Protocol Incompatible", "协议不兼容")
      case .helperDamaged: copy.text("Damaged", "已损坏")
      case .registering: copy.text("Registering", "正在注册")
      default: copy.text("Verified", "已验证")
      }
    }

    private var configurationValue: String {
      switch scenario {
      case .profileRequired: copy.text("Not Selected", "未选择")
      case .invalidConfiguration: copy.text("Validation Failed", "验证失败")
      default: "Main"
      }
    }

    private var rollbackValue: String {
      switch scenario {
      case .rollbackFailed, .recoveryFailed: copy.text("Failed", "失败")
      case .recoveryInProgress: copy.text("In Progress", "进行中")
      default: copy.text("Restored", "已恢复")
      }
    }

    private var proxyValue: String {
      scenario == .rollbackFailed || scenario == .recoveryFailed
        ? copy.text("Unverified", "未验证") : copy.text("Restored", "已恢复")
    }

    private var transitionPhases: [String] {
      [
        copy.text("Prepare target", "准备目标"),
        copy.text("Disable System Proxy", "停用系统代理"),
        copy.text("Stop current backend", "停止当前后端"),
        copy.text("Start privileged backend", "启动特权后端"),
        copy.text("Verify interface, routes, and DNS", "验证接口、路由和 DNS"),
        copy.text("Commit", "提交"),
      ]
    }

    private var transitionPhaseIndex: Int {
      switch scenario {
      case .preparingTarget: 0
      case .disablingSystemProxy: 1
      case .stoppingSource: 2
      case .startingPrivilegedBackend, .connectingController: 3
      case .waitingForInterface, .verifyingRoutes, .verifyingDNS: 4
      case .committing: 5
      default: 0
      }
    }

    private func transitionPhaseSymbol(_ index: Int) -> String {
      if index < transitionPhaseIndex { return "checkmark.circle.fill" }
      if index == transitionPhaseIndex { return "clock.arrow.circlepath" }
      return "circle"
    }

    private func transitionPhaseColor(_ index: Int) -> Color {
      if index < transitionPhaseIndex { return .green }
      if index == transitionPhaseIndex { return .accentColor }
      return .secondary
    }

    private var phaseTitle: String {
      scenario.isTransition
        ? transitionPhases[transitionPhaseIndex] : copy.text("Start Target", "启动目标")
    }

    private var dismissTitle: String {
      if scenario.isTransition { return copy.text("Hide", "隐藏") }
      if scenario.isRecovery || scenario.isSuccess { return copy.text("Close", "关闭") }
      return copy.text("Not Now", "暂不")
    }

    private var primaryTitle: String? {
      if scenario.isTransition { return nil }
      return switch scenario {
      case .needsApproval, .approvalDenied:
        copy.text("Open Login Items Settings", "打开登录项设置")
      case .helperIncompatible, .helperDamaged, .rollbackFailed, .recoveryPreflight,
        .recoveryInProgress, .recoveryFailed:
        copy.text("Open Recovery", "打开恢复")
      case .startFailureRollbackSucceeded, .verificationFailureRollbackSucceeded:
        copy.text("Try Again", "重试")
      case .runningSuccess, .recoverySucceeded:
        copy.text("Done", "完成")
      case .profileRequired, .invalidConfiguration, .readyToStart:
        copy.text("Enable TUN", "启用 TUN")
      case .registering, .helperEnabledConnecting:
        copy.text("Check Again", "再次检查")
      default:
        copy.text("Install Privileged Component", "安装特权组件")
      }
    }

    private var secondaryTitle: String? {
      return switch scenario {
      case .needsApproval, .approvalDenied:
        copy.text("Check Again", "再次检查")
      case .startFailureRollbackSucceeded, .verificationFailureRollbackSucceeded,
        .rollbackFailed, .recoveryPreflight, .recoveryInProgress, .recoveryFailed:
        copy.text("Copy Redacted Details", "复制已脱敏详情")
      default:
        nil
      }
    }

    private var primaryDisabled: Bool {
      switch scenario {
      case .registering, .helperEnabledConnecting, .profileRequired, .invalidConfiguration:
        true
      default:
        false
      }
    }
  }
#endif
