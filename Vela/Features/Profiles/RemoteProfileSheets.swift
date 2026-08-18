import SwiftUI

struct AddRemoteProfileSheet: View {
    @Environment(\.dismiss) private var dismiss
    let remoteProfiles: RemoteProfilesViewModel
    let created: (Profile) -> Void
    @State private var name = ""
    @State private var url = ""
    @State private var authentication: AuthenticationChoice = .none
    @State private var username = ""
    @State private var password = ""
    @State private var token = ""
    @State private var userAgentPreset: SubscriptionUserAgent = .clashVerge
    @State private var userAgent = ""
    @State private var proxyMode: SubscriptionProxyMode = .direct
    @State private var allowHTTP = false
    @State private var allowInvalidCertificates = false
    @State private var requestTimeout: Double = 20
    @State private var continueOnInvalidNode = true
    @State private var removeDuplicateNodes = true
    @State private var renameDuplicateNodes = true
    @State private var autoUpdate = true
    @State private var schedule: RemoteScheduleChoice = .daily
    @State private var customScheduleMinutes = 60

    var body: some View {
        VStack(spacing: 0) {
            RemoteProfileSheetHeader(
                title: VelaL10n.string(
                    "profiles.subscription.add.title",
                    defaultValue: "Add Remote Subscription"
                ),
                subtitle: VelaL10n.string(
                    "profiles.subscription.add.subtitle",
                    defaultValue: "Configure the subscription source and update behavior."
                ),
                systemImage: "link.badge.plus"
            )

            Divider()

            if let error = remoteProfiles.lastError {
                VelaStateBanner(
                    kind: .error,
                    title: error.title,
                    detail: [error.message, error.suggestedAction]
                        .compactMap { $0 }
                        .joined(separator: " "),
                    dismissalID: error.id.uuidString,
                    onDismiss: { remoteProfiles.dismissError() }
                )
                .padding(.horizontal, VelaSpacing.medium)
                .padding(.top, VelaSpacing.medium)
                .accessibilityIdentifier("profiles.subscription.create.error")
            }
            Form {
                Section(VelaL10n.string("legacy.remoteProfile", defaultValue: "Remote Profile")) {
                    TextField(VelaL10n.string("legacy.name", defaultValue: "Name"), text: $name)
                    TextField(VelaL10n.string("legacy.subscriptionUrl", defaultValue: "Subscription URL"), text: $url)
                }
                Section(VelaL10n.string("legacy.authentication", defaultValue: "Authentication")) {
                    Picker(VelaL10n.string("legacy.type", defaultValue: "Type"), selection: $authentication) {
                        ForEach(AuthenticationChoice.allCases) { Text($0.title).tag($0) }
                    }
                    if authentication == .bearer {
                        SecureField(VelaL10n.string("legacy.bearerToken", defaultValue: "Bearer Token"), text: $token)
                    } else if authentication == .basic {
                        TextField(VelaL10n.string("legacy.username", defaultValue: "Username"), text: $username)
                        SecureField(VelaL10n.string("legacy.password", defaultValue: "Password"), text: $password)
                    }
                    Picker(
                        VelaL10n.string(
                            "profiles.subscription.userAgent",
                            defaultValue: "User-Agent"
                        ),
                        selection: $userAgentPreset
                    ) {
                        ForEach(SubscriptionUserAgent.allCases) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                    if userAgentPreset == .custom {
                        TextField(VelaL10n.string("legacy.customUserAgentOptional", defaultValue: "Custom User-Agent"), text: $userAgent)
                    }
                    Picker(
                        VelaL10n.string(
                            "profiles.subscription.proxyMode",
                            defaultValue: "Download using"
                        ),
                        selection: $proxyMode
                    ) {
                        ForEach(SubscriptionProxyMode.allCases) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                }
                Section(VelaL10n.string("legacy.updates", defaultValue: "Updates")) {
                    Toggle(VelaL10n.string("legacy.updateAutomatically", defaultValue: "Update automatically"), isOn: $autoUpdate)
                    Picker(VelaL10n.string("legacy.schedule", defaultValue: "Schedule"), selection: $schedule) {
                        ForEach(RemoteScheduleChoice.allCases) { Text($0.title).tag($0) }
                    }
                    .disabled(!autoUpdate)
                    if schedule == .custom {
                        TextField(
                            VelaL10n.string("legacy.customIntervalMinutes", defaultValue: "Custom interval (minutes)"),
                            value: $customScheduleMinutes,
                            format: .number
                        )
                        .disabled(!autoUpdate)
                        Text(VelaL10n.string("legacy.allowedRange15MinutesTo30Days", defaultValue: "Allowed range: 15 minutes to 30 days."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                DisclosureGroup(
                    VelaL10n.string("legacy.advanced", defaultValue: "Advanced")
                ) {
                    Toggle(VelaL10n.string("legacy.allowInsecureHttpForThisProfile", defaultValue: "Allow insecure HTTP for this profile"), isOn: $allowHTTP)
                    Toggle(
                        VelaL10n.string(
                            "profiles.subscription.allowInvalidTLS",
                            defaultValue: "Allow invalid TLS certificates"
                        ),
                        isOn: $allowInvalidCertificates
                    )
                    if allowInvalidCertificates {
                        Text(
                            VelaL10n.string(
                                "profiles.subscription.invalidTLSWarning",
                                defaultValue: "This weakens transport security and should only be used for a trusted private provider."
                            )
                        )
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    Stepper(
                        VelaL10n.string(
                            "profiles.subscription.requestTimeoutFormat",
                            defaultValue: "Request timeout: %lld seconds",
                            arguments: Int64(requestTimeout)
                        ),
                        value: $requestTimeout,
                        in: 5 ... 120,
                        step: 5
                    )
                    Toggle(
                        VelaL10n.string(
                            "profiles.subscription.ignoreInvalidNodes",
                            defaultValue: "Ignore invalid nodes and continue"
                        ),
                        isOn: $continueOnInvalidNode
                    )
                    Toggle(
                        VelaL10n.string(
                            "profiles.subscription.removeDuplicateNodes",
                            defaultValue: "Remove duplicate nodes"
                        ),
                        isOn: $removeDuplicateNodes
                    )
                    Toggle(
                        VelaL10n.string(
                            "profiles.subscription.renameDuplicateNodes",
                            defaultValue: "Rename duplicate node names"
                        ),
                        isOn: $renameDuplicateNodes
                    )
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            VelaLiquidGlassGroup(spacing: VelaSpacing.small) {
                HStack {
                    Button(VelaL10n.string("legacy.cancel", defaultValue: "Cancel"), role: .cancel) {
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)

                    Spacer()

                    if remoteProfiles.isCreating {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel(
                                VelaL10n.string(
                                    "profiles.subscription.creating",
                                    defaultValue: "Adding subscription"
                                )
                            )
                    }

                    Button(VelaL10n.string("legacy.addUpdate", defaultValue: "Add & Update")) {
                        add()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit || remoteProfiles.isCreating)
                }
            }
            .padding(VelaSpacing.standard)
        }
        .background { VelaPageCanvas() }
        .frame(width: 560)
        .frame(minHeight: 500, idealHeight: 620, maxHeight: 650)
        .clipped()
    }

    private var canSubmit: Bool {
        (try? SubscriptionURLNormalizer.normalize(url)) != nil
            && (userAgentPreset != .custom || !userAgent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            && !userAgent.contains("\n") && !userAgent.contains("\r")
            && (schedule != .custom || (15 ... 43_200).contains(customScheduleMinutes))
    }

    private func add() {
        guard let normalized = try? SubscriptionURLNormalizer.normalizeWithAuthentication(url) else { return }
        let selectedAuth: SubscriptionAuthentication = switch authentication {
        case .none: .none
        case .bearer: .bearer(token: token)
        case .basic: .basic(username: username, password: password)
        }
        let auth = selectedAuth == .none
            ? (normalized.embeddedAuthentication ?? .none)
            : selectedAuth
        let request = RemoteProfileCreationRequest(
            name: name,
            secret: SubscriptionSecretEnvelope(
                url: normalized.url,
                authentication: auth,
                userAgent: userAgentPreset == .custom ? userAgent : nil,
                userAgentPreset: userAgentPreset,
                proxyMode: proxyMode,
                allowInsecureHTTP: allowHTTP,
                allowInvalidCertificates: allowInvalidCertificates,
                requestTimeout: requestTimeout,
                conversionPreferences: SubscriptionConversionPreferences(
                    continueOnInvalidNode: continueOnInvalidNode,
                    removeDuplicateNodes: removeDuplicateNodes,
                    renameDuplicateNodes: renameDuplicateNodes
                )
            ),
            autoUpdateEnabled: autoUpdate,
            schedule: schedule.value(customMinutes: customScheduleMinutes),
            updateImmediately: true
        )
        Task {
            if let profile = await remoteProfiles.create(request) { created(profile) }
        }
    }
}

struct EditRemoteProfileSheet: View {
    @Environment(\.dismiss) private var dismiss
    let profile: Profile
    let remoteProfiles: RemoteProfilesViewModel
    @Binding private var cachedSettings: RemoteProfileEditableSettings?
    let embedded: Bool
    let saved: (Profile) -> Void

    @State private var isLoading = true
    @State private var isSaving = false
    @State private var loadFailed = false
    @State private var name = ""
    @State private var subscriptionURL = ""
    @State private var originalSubscriptionURL: URL?
    @State private var currentAuthentication: SubscriptionAuthenticationKind = .none
    @State private var authentication: AuthenticationEditChoice = .keepExisting
    @State private var username = ""
    @State private var password = ""
    @State private var token = ""
    @State private var userAgentPreset: SubscriptionUserAgent = .clashVerge
    @State private var userAgent = ""
    @State private var proxyMode: SubscriptionProxyMode = .direct
    @State private var allowHTTP = false
    @State private var allowInvalidCertificates = false
    @State private var requestTimeout: Double = 20
    @State private var continueOnInvalidNode = true
    @State private var removeDuplicateNodes = true
    @State private var renameDuplicateNodes = true
    @State private var autoUpdate = true
    @State private var schedule: RemoteScheduleChoice = .daily
    @State private var customScheduleMinutes = 60
    @State private var saveErrorMessage: String?

    init(
        profile: Profile,
        remoteProfiles: RemoteProfilesViewModel,
        cachedSettings: Binding<RemoteProfileEditableSettings?>,
        embedded: Bool = false,
        saved: @escaping (Profile) -> Void
    ) {
        self.profile = profile
        self.remoteProfiles = remoteProfiles
        _cachedSettings = cachedSettings
        self.embedded = embedded
        self.saved = saved
    }

    var body: some View {
        VStack(spacing: 0) {
            RemoteProfileSheetHeader(
                title: VelaL10n.string(
                    "profiles.subscription.edit.title",
                    defaultValue: "Edit Remote Subscription"
                ),
                subtitle: profile.name,
                systemImage: "link.badge.plus"
            )

            Divider()

            if isLoading {
                ProgressView(VelaL10n.string("legacy.loadingProtectedSubscriptionSettingsDialog", defaultValue: "Loading protected subscription settings…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if loadFailed {
                ContentUnavailableView(
                    VelaL10n.string("legacy.settingsUnavailable", defaultValue: "Settings Unavailable"),
                    systemImage: "key.slash",
                    description: Text(VelaL10n.string("legacy.velaCouldNotReadThisProfileSProtectedSettingsFromKeychain", defaultValue: "Vela could not read this profile's protected settings from Keychain."))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Form {
                    Section(VelaL10n.string("legacy.remoteProfile", defaultValue: "Remote Profile")) {
                        TextField(VelaL10n.string("legacy.name", defaultValue: "Name"), text: $name)
                        TextField(
                            VelaL10n.string(
                                "legacy.subscriptionUrl",
                                defaultValue: "Subscription URL"
                            ),
                            text: $subscriptionURL
                        )
                        .accessibilityIdentifier("profiles.remoteEditor.url")
                    }

                    Section(VelaL10n.string("legacy.authentication", defaultValue: "Authentication")) {
                        LabeledContent(
                            VelaL10n.string("legacy.currentType", defaultValue: "Current Type"),
                            value: authenticationKindTitle(currentAuthentication)
                        )
                        Picker(VelaL10n.string("legacy.change", defaultValue: "Change"), selection: $authentication) {
                            ForEach(AuthenticationEditChoice.allCases) { choice in
                                Text(choice.title).tag(choice)
                            }
                        }
                        if authentication == .bearer {
                            SecureField(VelaL10n.string("legacy.newBearerToken", defaultValue: "New Bearer Token"), text: $token)
                        } else if authentication == .basic {
                            TextField(VelaL10n.string("legacy.newUsername", defaultValue: "New Username"), text: $username)
                            SecureField(VelaL10n.string("legacy.newPassword", defaultValue: "New Password"), text: $password)
                        }
                        Picker(
                            VelaL10n.string(
                                "profiles.subscription.userAgent",
                                defaultValue: "User-Agent"
                            ),
                            selection: $userAgentPreset
                        ) {
                            ForEach(SubscriptionUserAgent.allCases) { option in
                                Text(option.displayName).tag(option)
                            }
                        }
                        if userAgentPreset == .custom {
                            TextField(VelaL10n.string("legacy.customUserAgentOptional", defaultValue: "Custom User-Agent"), text: $userAgent)
                        }
                        Picker(
                            VelaL10n.string(
                                "profiles.subscription.proxyMode",
                                defaultValue: "Download using"
                            ),
                            selection: $proxyMode
                        ) {
                            ForEach(SubscriptionProxyMode.allCases) { option in
                                Text(option.displayName).tag(option)
                            }
                        }
                    }

                    Section(VelaL10n.string("legacy.updates", defaultValue: "Updates")) {
                        Toggle(VelaL10n.string("legacy.updateAutomatically", defaultValue: "Update automatically"), isOn: $autoUpdate)
                        Picker(VelaL10n.string("legacy.schedule", defaultValue: "Schedule"), selection: $schedule) {
                            ForEach(RemoteScheduleChoice.allCases) { choice in
                                Text(choice.title).tag(choice)
                            }
                        }
                        .disabled(!autoUpdate)
                        if schedule == .custom {
                            TextField(
                                VelaL10n.string("legacy.customIntervalMinutes", defaultValue: "Custom interval (minutes)"),
                                value: $customScheduleMinutes,
                                format: .number
                            )
                            .disabled(!autoUpdate)
                            Text(VelaL10n.string("legacy.allowedRange15MinutesTo30Days", defaultValue: "Allowed range: 15 minutes to 30 days."))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    DisclosureGroup(
                        VelaL10n.string("legacy.advanced", defaultValue: "Advanced")
                    ) {
                        Toggle(VelaL10n.string("legacy.allowInsecureHttpForThisProfile", defaultValue: "Allow insecure HTTP for this profile"), isOn: $allowHTTP)
                        Toggle(
                            VelaL10n.string(
                                "profiles.subscription.allowInvalidTLS",
                                defaultValue: "Allow invalid TLS certificates"
                            ),
                            isOn: $allowInvalidCertificates
                        )
                        if allowInvalidCertificates {
                            Text(
                                VelaL10n.string(
                                    "profiles.subscription.invalidTLSWarning",
                                    defaultValue: "This weakens transport security and should only be used for a trusted private provider."
                                )
                            )
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        Stepper(
                            VelaL10n.string(
                                "profiles.subscription.requestTimeoutFormat",
                                defaultValue: "Request timeout: %lld seconds",
                                arguments: Int64(requestTimeout)
                            ),
                            value: $requestTimeout,
                            in: 5 ... 120,
                            step: 5
                        )
                        Toggle(
                            VelaL10n.string(
                                "profiles.subscription.ignoreInvalidNodes",
                                defaultValue: "Ignore invalid nodes and continue"
                            ),
                            isOn: $continueOnInvalidNode
                        )
                        Toggle(
                            VelaL10n.string(
                                "profiles.subscription.removeDuplicateNodes",
                                defaultValue: "Remove duplicate nodes"
                            ),
                            isOn: $removeDuplicateNodes
                        )
                        Toggle(
                            VelaL10n.string(
                                "profiles.subscription.renameDuplicateNodes",
                                defaultValue: "Rename duplicate node names"
                            ),
                            isOn: $renameDuplicateNodes
                        )
                    }
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if let saveErrorMessage {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(saveErrorMessage)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .accessibilityIdentifier("profiles.remoteEditor.error")
            }

            Divider()
            VelaLiquidGlassGroup(spacing: VelaSpacing.small) {
                HStack {
                    Button(VelaL10n.string("legacy.cancel", defaultValue: "Cancel"), role: .cancel) {
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)

                    Spacer()

                    if isSaving {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel(VelaL10n.string("legacy.savingSubscriptionSettings", defaultValue: "Saving subscription settings"))
                    }
                    if loadFailed {
                        Button(VelaL10n.string("legacy.tryAgain", defaultValue: "Try Again")) {
                            Task { await load() }
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Button(VelaL10n.string("legacy.save", defaultValue: "Save")) {
                            save(updateAfterSaving: false)
                        }
                        .buttonStyle(.bordered)
                        .disabled(isLoading || isSaving || !canSubmit)

                        Button(
                            VelaL10n.string(
                                "profiles.subscription.saveAndUpdate",
                                defaultValue: "Save & Update"
                            )
                        ) {
                            save(updateAfterSaving: true)
                        }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(isLoading || isSaving || !canSubmit)
                    }
                }
            }
            .padding(VelaSpacing.standard)
        }
        .background { VelaPageCanvas() }
        .frame(width: embedded ? nil : 580)
        .frame(
            minHeight: embedded ? nil : 500,
            idealHeight: embedded ? nil : 620,
            maxHeight: embedded ? .infinity : 650
        )
        .clipped()
        .accessibilityIdentifier("profiles.remoteEditor")
        .task { await load() }
        .onDisappear {
            clearSensitiveDrafts()
        }
    }

    private var canSubmit: Bool {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !userAgent.contains("\n"), !userAgent.contains("\r"),
            userAgentPreset != .custom || !userAgent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            schedule != .custom || (15 ... 43_200).contains(customScheduleMinutes)
        else { return false }

        if (try? SubscriptionURLNormalizer.normalize(subscriptionURL)) == nil {
            return false
        }
        return switch authentication {
        case .keepExisting, .none:
            true
        case .bearer:
            !token.isEmpty
        case .basic:
            !username.isEmpty && !password.isEmpty
        }
    }

    private func load() async {
        isLoading = true
        loadFailed = false
        saveErrorMessage = nil
        defer { isLoading = false }

        if let cachedSettings {
            apply(cachedSettings)
            return
        }

        guard let settings = await remoteProfiles.editableSettings(for: profile.id) else {
            loadFailed = true
            return
        }
        cachedSettings = settings
        apply(settings)
    }

    private func apply(_ settings: RemoteProfileEditableSettings) {
        name = settings.name
        subscriptionURL = settings.url.absoluteString
        originalSubscriptionURL = settings.url
        currentAuthentication = settings.authenticationKind
        userAgent = settings.userAgent ?? ""
        userAgentPreset = settings.userAgentPreset
        proxyMode = settings.proxyMode
        allowHTTP = settings.allowInsecureHTTP
        allowInvalidCertificates = settings.allowInvalidCertificates
        requestTimeout = settings.requestTimeout
        continueOnInvalidNode = settings.conversionPreferences.continueOnInvalidNode
        removeDuplicateNodes = settings.conversionPreferences.removeDuplicateNodes
        renameDuplicateNodes = settings.conversionPreferences.renameDuplicateNodes
        autoUpdate = settings.autoUpdateEnabled
        schedule = RemoteScheduleChoice(schedule: settings.schedule)
        customScheduleMinutes = settings.schedule.minutes
        authentication = .keepExisting
        username = ""
        password = ""
        token = ""
    }

    private func save(updateAfterSaving: Bool) {
        guard let originalSubscriptionURL,
            let normalizedDraft = try? SubscriptionURLNormalizer.normalizeWithAuthentication(
                subscriptionURL
            )
        else { return }
        let urlReplacement = RemoteProfileURLDraftPolicy.replacement(
            currentURL: originalSubscriptionURL,
            normalizedDraft: normalizedDraft
        )
        let authenticationEdit: SubscriptionAuthenticationEdit = switch authentication {
        case .keepExisting:
            if let embeddedAuthentication = urlReplacement?.embeddedAuthentication {
                .replace(embeddedAuthentication)
            } else {
                .keepExisting
            }
        case .none:
            .replace(.none)
        case .bearer:
            .replace(.bearer(token: token))
        case .basic:
            .replace(.basic(username: username, password: password))
        }
        let request = RemoteProfileEditRequest(
            name: name,
            replacementURL: urlReplacement?.url,
            authentication: authenticationEdit,
            userAgent: userAgentPreset == .custom ? userAgent : nil,
            userAgentPreset: userAgentPreset,
            proxyMode: proxyMode,
            allowInsecureHTTP: allowHTTP,
            allowInvalidCertificates: allowInvalidCertificates,
            requestTimeout: requestTimeout,
            conversionPreferences: SubscriptionConversionPreferences(
                continueOnInvalidNode: continueOnInvalidNode,
                removeDuplicateNodes: removeDuplicateNodes,
                renameDuplicateNodes: renameDuplicateNodes
            ),
            autoUpdateEnabled: autoUpdate,
            schedule: schedule.value(customMinutes: customScheduleMinutes)
        )
        isSaving = true
        saveErrorMessage = nil
        Task {
            let edited = await remoteProfiles.edit(profile.id, request: request)
            guard let edited else {
                isSaving = false
                saveErrorMessage = remoteEditFailureMessage
                return
            }
            if updateAfterSaving {
                await remoteProfiles.update(edited.id)
                if remoteProfiles.lastError != nil {
                    isSaving = false
                    saveErrorMessage = remoteEditFailureMessage
                    return
                }
            }
            isSaving = false
            saved(edited)
        }
    }

    private func clearSensitiveDrafts() {
        subscriptionURL = ""
        originalSubscriptionURL = nil
        username = ""
        password = ""
        token = ""
    }

    private var remoteEditFailureMessage: String {
        guard let error = remoteProfiles.lastError else {
            return VelaL10n.string(
                "profiles.subscription.editFailed",
                defaultValue: "The subscription changes could not be saved."
            )
        }
        return [error.message, error.suggestedAction]
            .compactMap { $0 }
            .joined(separator: " ")
    }

    private func authenticationKindTitle(_ kind: SubscriptionAuthenticationKind) -> String {
        switch kind {
        case .none:
            VelaL10n.string("profiles.authentication.none", defaultValue: "None")
        case .bearer:
            VelaL10n.string("profiles.authentication.bearer", defaultValue: "Bearer")
        case .basic:
            VelaL10n.string("profiles.authentication.basic", defaultValue: "Basic")
        }
    }
}

private enum AuthenticationEditChoice: String, CaseIterable, Identifiable {
    case keepExisting
    case none
    case bearer
    case basic

    var id: Self { self }

    var title: String {
        switch self {
        case .keepExisting:
            VelaL10n.string("profiles.authentication.keepExisting", defaultValue: "Keep Existing")
        case .none:
            VelaL10n.string("profiles.authentication.remove", defaultValue: "Remove Authentication")
        case .bearer:
            VelaL10n.string("profiles.authentication.replaceBearer", defaultValue: "Replace Bearer Token")
        case .basic:
            VelaL10n.string("profiles.authentication.replaceBasic", defaultValue: "Replace Basic Credentials")
        }
    }
}

private extension SubscriptionUserAgent {
    var displayName: String {
        switch self {
        case .vela:
            VelaL10n.string("profiles.subscription.userAgent.vela", defaultValue: "Vela")
        case .clashVerge:
            VelaL10n.string(
                "profiles.subscription.userAgent.clashVerge",
                defaultValue: "Clash Verge"
            )
        case .mihomo:
            VelaL10n.string("profiles.subscription.userAgent.mihomo", defaultValue: "Mihomo")
        case .clashMetaForAndroid:
            VelaL10n.string(
                "profiles.subscription.userAgent.clashMetaForAndroid",
                defaultValue: "Clash Meta for Android"
            )
        case .custom: VelaL10n.string("legacy.custom", defaultValue: "Custom")
        }
    }
}

private extension SubscriptionProxyMode {
    var displayName: String {
        switch self {
        case .direct:
            VelaL10n.string("profiles.subscription.proxyMode.direct", defaultValue: "Direct")
        case .vela:
            VelaL10n.string("profiles.subscription.proxyMode.vela", defaultValue: "Vela Proxy")
        case .system:
            VelaL10n.string(
                "profiles.subscription.proxyMode.system",
                defaultValue: "System Proxy"
            )
        }
    }
}

private struct RemoteProfileSheetHeader: View {
    let title: String
    let subtitle: String
    let systemImage: String

    var body: some View {
        HStack(spacing: VelaSpacing.medium) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 40, height: 40)
                .background(
                    Color.accentColor.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: VelaSpacing.micro) {
                Text(title)
                    .font(VelaTypography.sectionTitle)
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(VelaTypography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, VelaSpacing.standard)
        .padding(.vertical, VelaSpacing.medium)
        .accessibilityElement(children: .combine)
    }
}

private enum AuthenticationChoice: String, CaseIterable, Identifiable {
    case none, bearer, basic
    var id: Self { self }
    var title: String {
        switch self {
        case .none:
            VelaL10n.string("profiles.authentication.none", defaultValue: "None")
        case .bearer:
            VelaL10n.string("profiles.authentication.bearer", defaultValue: "Bearer")
        case .basic:
            VelaL10n.string("profiles.authentication.basic", defaultValue: "Basic")
        }
    }
}

private enum RemoteScheduleChoice: String, CaseIterable, Identifiable {
    case hourly, sixHours, twelveHours, daily, custom
    var id: Self { self }
    var title: String {
        switch self {
        case .hourly:
            VelaL10n.string("profiles.schedule.hourly", defaultValue: "Hourly")
        case .sixHours:
            VelaL10n.string("profiles.schedule.everySixHours", defaultValue: "Every 6 Hours")
        case .twelveHours:
            VelaL10n.string("profiles.schedule.everyTwelveHours", defaultValue: "Every 12 Hours")
        case .daily:
            VelaL10n.string("profiles.schedule.daily", defaultValue: "Daily")
        case .custom:
            VelaL10n.string("profiles.schedule.custom", defaultValue: "Custom")
        }
    }
    func value(customMinutes: Int) -> SubscriptionSchedule {
        switch self {
        case .hourly: .hourly
        case .sixHours: .everySixHours
        case .twelveHours: .everyTwelveHours
        case .daily: .daily
        case .custom: .custom(minutes: customMinutes)
        }
    }

    init(schedule: SubscriptionSchedule) {
        self = switch schedule {
        case .hourly: .hourly
        case .everySixHours: .sixHours
        case .everyTwelveHours: .twelveHours
        case .daily: .daily
        case .custom: .custom
        }
    }
}
