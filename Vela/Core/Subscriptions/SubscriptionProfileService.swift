import Foundation

nonisolated enum SubscriptionUpdateState: Equatable, Sendable {
    case idle
    case checking
    case downloading(received: Int64, expected: Int64?)
    case validating
    case applying
    case verifying
    case rollingBack
    case unchanged
    case succeeded(Date)
    case failed(UserFacingError)
}

nonisolated struct RemoteProfileCreationRequest: Equatable, Sendable {
    var name: String
    var secret: SubscriptionSecretEnvelope
    var autoUpdateEnabled: Bool
    var schedule: SubscriptionSchedule
    var updateImmediately: Bool

    init(
        name: String,
        secret: SubscriptionSecretEnvelope,
        autoUpdateEnabled: Bool = true,
        schedule: SubscriptionSchedule = SubscriptionUpdatePolicy.defaultSchedule,
        updateImmediately: Bool = true
    ) {
        self.name = name
        self.secret = secret
        self.autoUpdateEnabled = autoUpdateEnabled
        self.schedule = schedule
        self.updateImmediately = updateImmediately
    }
}

nonisolated enum SubscriptionAuthenticationKind: String, Equatable, Sendable {
    case none
    case bearer
    case basic
}

nonisolated enum SubscriptionAuthenticationEdit: Equatable, Sendable {
    case keepExisting
    case replace(SubscriptionAuthentication)
}

nonisolated struct RemoteProfileEditableSettings: Equatable, Sendable {
    let name: String
    let url: URL
    let authenticationKind: SubscriptionAuthenticationKind
    let userAgent: String?
    let userAgentPreset: SubscriptionUserAgent
    let proxyMode: SubscriptionProxyMode
    let allowInsecureHTTP: Bool
    let allowInvalidCertificates: Bool
    let requestTimeout: TimeInterval
    let conversionPreferences: SubscriptionConversionPreferences
    let autoUpdateEnabled: Bool
    let schedule: SubscriptionSchedule
}

nonisolated enum RemoteProfileURLDraftPolicy {
    static func replacement(
        currentURL: URL,
        normalizedDraft: NormalizedSubscriptionURL
    ) -> NormalizedSubscriptionURL? {
        guard normalizedDraft.url != currentURL
            || normalizedDraft.embeddedAuthentication != nil
        else {
            return nil
        }
        return normalizedDraft
    }
}

nonisolated struct RemoteProfileEditRequest: Equatable, Sendable {
    var name: String
    var replacementURL: URL?
    var authentication: SubscriptionAuthenticationEdit
    var userAgent: String?
    var userAgentPreset: SubscriptionUserAgent
    var proxyMode: SubscriptionProxyMode
    var allowInsecureHTTP: Bool
    var allowInvalidCertificates: Bool
    var requestTimeout: TimeInterval
    var conversionPreferences: SubscriptionConversionPreferences
    var autoUpdateEnabled: Bool
    var schedule: SubscriptionSchedule

    init(
        name: String,
        replacementURL: URL?,
        authentication: SubscriptionAuthenticationEdit,
        userAgent: String?,
        userAgentPreset: SubscriptionUserAgent? = nil,
        proxyMode: SubscriptionProxyMode = .direct,
        allowInsecureHTTP: Bool,
        allowInvalidCertificates: Bool = false,
        requestTimeout: TimeInterval = 20,
        conversionPreferences: SubscriptionConversionPreferences = SubscriptionConversionPreferences(),
        autoUpdateEnabled: Bool,
        schedule: SubscriptionSchedule
    ) {
        self.name = name
        self.replacementURL = replacementURL
        self.authentication = authentication
        self.userAgent = userAgent
        self.userAgentPreset = userAgentPreset ?? (userAgent == nil ? .clashVerge : .custom)
        self.proxyMode = proxyMode
        self.allowInsecureHTTP = allowInsecureHTTP
        self.allowInvalidCertificates = allowInvalidCertificates
        self.requestTimeout = requestTimeout
        self.conversionPreferences = conversionPreferences
        self.autoUpdateEnabled = autoUpdateEnabled
        self.schedule = schedule
    }
}

actor SubscriptionProfileService: SubscriptionUpdating {
    private let profileStore: ProfileStore
    private let secretStore: SubscriptionSecretStore
    private let httpClient: any SubscriptionHTTPFetching
    private let transactionCoordinator: RuntimeConfigTransactionCoordinator
    private let runtimeMutationGate: RuntimeMutationGate
    private let now: @Sendable () -> Date
    private let scheduleJitterFraction: @Sendable () -> Double
    private var states: [UUID: SubscriptionUpdateState] = [:]
    private var inFlightProfiles: Set<UUID> = []

    init(
        profileStore: ProfileStore,
        secretStore: SubscriptionSecretStore,
        httpClient: any SubscriptionHTTPFetching,
        transactionCoordinator: RuntimeConfigTransactionCoordinator,
        runtimeMutationGate: RuntimeMutationGate = RuntimeMutationGate(),
        now: @escaping @Sendable () -> Date = { .now },
        scheduleJitterFraction: @escaping @Sendable () -> Double = {
            Double.random(in: -0.05 ... 0.05)
        }
    ) {
        self.profileStore = profileStore
        self.secretStore = secretStore
        self.httpClient = httpClient
        self.transactionCoordinator = transactionCoordinator
        self.runtimeMutationGate = runtimeMutationGate
        self.now = now
        self.scheduleJitterFraction = scheduleJitterFraction
    }

    @discardableResult
    func createRemoteProfile(_ request: RemoteProfileCreationRequest) async throws -> Profile {
        var request = request
        let normalized = try SubscriptionURLNormalizer.normalizeWithAuthentication(
            request.secret.url.absoluteString
        )
        request.secret.url = normalized.url
        if request.secret.authentication == .none,
            let embedded = normalized.embeddedAuthentication
        {
            request.secret.authentication = embedded
        }
        try SubscriptionURLPolicy.validate(
            request.secret.url,
            allowInsecureHTTP: request.secret.allowInsecureHTTP
        )
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "1.0"
        _ = try request.secret.userAgentPreset.resolvedValue(
            appVersion: appVersion,
            customValue: request.secret.userAgent
        )
        let trimmedName = request.name.trimmingCharacters(in: .whitespacesAndNewlines)
        request.name = trimmedName.isEmpty
            ? defaultProfileName(for: request.secret.url)
            : trimmedName
        let timestamp = now()
        let metadata = RemoteProfileMetadata(
            redactedURL: SubscriptionURLRedactor.redact(request.secret.url),
            autoUpdateEnabled: request.autoUpdateEnabled,
            schedule: request.schedule,
            nextScheduledUpdateAt: request.autoUpdateEnabled
                ? nextScheduledDate(after: timestamp, schedule: request.schedule)
                : nil
        )
        let existingProfileIDs: Set<UUID>
        do {
            existingProfileIDs = Set(try await profileStore.profiles().map(\.id))
        } catch {
            throw SubscriptionUpdateFailure.runtimeBuildFailed
        }

        let profile: Profile
        do {
            profile = try await profileStore.createRemoteProfile(
                name: request.name,
                metadata: metadata
            )
        } catch {
            switch await committedCreateLookup(
                excluding: existingProfileIDs,
                desiredName: request.name,
                desiredMetadata: metadata
            ) {
            case let .committed(created):
                // ProfileStore writes metadata atomically before applying its
                // final permissions. A late permission error can therefore
                // report failure after the Profile is already durable.
                profile = created
            case .notCommitted:
                throw SubscriptionUpdateFailure.runtimeBuildFailed
            case .unavailable:
                throw SubscriptionUpdateFailure.profileMutationRecoveryFailed
            }
        }

        do {
            try await secretStore.save(request.secret, for: profile.id)
        } catch {
            switch await secretLookup(profile.id) {
            case let .present(envelope) where envelope == request.secret:
                // A secure-store implementation may commit atomically and then
                // surface a late error. The desired pair is already durable.
                break
            case .missing:
                try await reconcileCreateAfterSecretWriteFailure(
                    profile: profile,
                    secret: request.secret
                )
            case .present, .unavailable:
                throw SubscriptionUpdateFailure.profileMutationRecoveryFailed
            }
        }

        if request.updateImmediately {
            do {
                try await update(profileID: profile.id, reason: .manual)
            } catch {
                // The profile remains editable so the user can fix credentials or URL.
            }
        }
        return try await profileStore.profile(id: profile.id) ?? profile
    }

    func deleteProfile(_ profileID: UUID) async throws {
        let lease = try await runtimeMutationGate.acquire(.profileMutation)
        do {
            try await deleteProfileExclusively(profileID)
            await runtimeMutationGate.release(lease)
        } catch {
            await runtimeMutationGate.release(lease)
            throw error
        }
    }

    private func deleteProfileExclusively(_ profileID: UUID) async throws {
        let existingEnvelope: SubscriptionSecretEnvelope?
        do {
            existingEnvelope = try await secretStore.envelope(for: profileID)
        } catch {
            throw SubscriptionUpdateFailure.secretMissing
        }
        do {
            try await secretStore.removeEnvelope(for: profileID)
        } catch {
            switch await secretLookup(profileID) {
            case .missing:
                // Treat a late error after an atomic deletion as committed and
                // continue deleting the matching Profile record.
                break
            case let .present(envelope) where envelope == existingEnvelope:
                throw SubscriptionUpdateFailure.secretMissing
            case .present, .unavailable:
                throw SubscriptionUpdateFailure.profileMutationRecoveryFailed
            }
        }
        do {
            try await profileStore.deleteProfile(id: profileID)
            finishDeletedProfile(profileID)
        } catch let deletionError {
            if Self.isCommittedDeleteCleanupFailure(deletionError) {
                finishDeletedProfile(profileID)
                throw SubscriptionUpdateFailure.profileDeletionCleanupFailed
            }
            switch await profileLookup(profileID) {
            case .absent:
                // ProfileStore can report a post-commit staged-artifact cleanup
                // failure after the index deletion is already durable. Restoring
                // the Keychain envelope here would create a permanent orphan.
                finishDeletedProfile(profileID)
                throw SubscriptionUpdateFailure.profileDeletionCleanupFailed
            case .unavailable:
                // The commit state cannot be proven, so do not guess and risk
                // writing an orphan credential under a deleted profile ID.
                throw SubscriptionUpdateFailure.profileMutationRecoveryFailed
            case .present:
                break
            }

            guard let existingEnvelope else {
                try await retryDeletionWithoutSecret(profileID)
                return
            }

            do {
                try await secretStore.save(existingEnvelope, for: profileID)
                throw SubscriptionUpdateFailure.runtimeBuildFailed
            } catch let failure as SubscriptionUpdateFailure {
                throw failure
            } catch {
                switch await secretLookup(profileID) {
                case let .present(envelope) where envelope == existingEnvelope:
                    // The rollback committed before its late error. The original
                    // Profile/secret pair is intact, so do not delete it.
                    throw SubscriptionUpdateFailure.runtimeBuildFailed
                case .missing:
                    break
                case .present, .unavailable:
                    throw SubscriptionUpdateFailure.profileMutationRecoveryFailed
                }

                // The rollback write failed. Converge in the forward direction:
                // a successful retry leaves both the profile and its secret gone.
                do {
                    try await profileStore.deleteProfile(id: profileID)
                    finishDeletedProfile(profileID)
                    return
                } catch let deletionError {
                    if Self.isCommittedDeleteCleanupFailure(deletionError) {
                        finishDeletedProfile(profileID)
                        throw SubscriptionUpdateFailure.profileDeletionCleanupFailed
                    }
                    switch await profileLookup(profileID) {
                    case .absent:
                        finishDeletedProfile(profileID)
                        throw SubscriptionUpdateFailure.profileDeletionCleanupFailed
                    case .unavailable:
                        throw SubscriptionUpdateFailure.profileMutationRecoveryFailed
                    case .present:
                        break
                    }
                }

                // The forward retry also failed. One final rollback retry can
                // restore the exact pre-operation state without persisting it.
                do {
                    try await secretStore.save(existingEnvelope, for: profileID)
                    throw SubscriptionUpdateFailure.runtimeBuildFailed
                } catch let failure as SubscriptionUpdateFailure {
                    throw failure
                } catch {
                    if case let .present(envelope) = await secretLookup(profileID),
                        envelope == existingEnvelope
                    {
                        throw SubscriptionUpdateFailure.runtimeBuildFailed
                    }
                    throw SubscriptionUpdateFailure.profileMutationRecoveryFailed
                }
            }
        }
    }

    func editableSettings(for profileID: UUID) async throws -> RemoteProfileEditableSettings {
        guard let profile = try await profileStore.profile(id: profileID),
            profile.sourceKind == .remoteSubscription,
            let metadata = profile.remote
        else {
            throw SubscriptionUpdateFailure.invalidURL
        }
        let secret: SubscriptionSecretEnvelope
        do {
            guard let stored = try await secretStore.envelope(for: profileID) else {
                throw SubscriptionUpdateFailure.secretMissing
            }
            secret = stored
        } catch let failure as SubscriptionUpdateFailure {
            throw failure
        } catch {
            throw SubscriptionUpdateFailure.secretMissing
        }

        let authenticationKind: SubscriptionAuthenticationKind = switch secret.authentication {
        case .none: .none
        case .bearer: .bearer
        case .basic: .basic
        }
        return RemoteProfileEditableSettings(
            name: profile.name,
            url: secret.url,
            authenticationKind: authenticationKind,
            userAgent: secret.userAgent,
            userAgentPreset: secret.userAgentPreset,
            proxyMode: secret.proxyMode,
            allowInsecureHTTP: secret.allowInsecureHTTP,
            allowInvalidCertificates: secret.allowInvalidCertificates,
            requestTimeout: secret.requestTimeout,
            conversionPreferences: secret.conversionPreferences,
            autoUpdateEnabled: metadata.autoUpdateEnabled,
            schedule: metadata.schedule
        )
    }

    @discardableResult
    func editRemoteProfile(
        _ profileID: UUID,
        request: RemoteProfileEditRequest
    ) async throws -> Profile {
        guard !inFlightProfiles.contains(profileID) else {
            throw SubscriptionUpdateFailure.cancelled
        }
        guard let profile = try await profileStore.profile(id: profileID),
            profile.sourceKind == .remoteSubscription,
            var metadata = profile.remote
        else {
            throw SubscriptionUpdateFailure.invalidURL
        }
        let previousSecret: SubscriptionSecretEnvelope
        do {
            guard let stored = try await secretStore.envelope(for: profileID) else {
                throw SubscriptionUpdateFailure.secretMissing
            }
            previousSecret = stored
        } catch let failure as SubscriptionUpdateFailure {
            throw failure
        } catch {
            throw SubscriptionUpdateFailure.secretMissing
        }

        var editedSecret = previousSecret
        if let replacementURL = request.replacementURL {
            let normalized = try SubscriptionURLNormalizer.normalizeWithAuthentication(
                replacementURL.absoluteString
            )
            editedSecret.url = normalized.url
            if case .keepExisting = request.authentication,
                let embedded = normalized.embeddedAuthentication
            {
                editedSecret.authentication = embedded
            }
        }
        if case let .replace(authentication) = request.authentication {
            editedSecret.authentication = authentication
        }
        editedSecret.userAgent = request.userAgent?.nilIfBlank
        editedSecret.userAgentPreset = request.userAgentPreset
        editedSecret.proxyMode = request.proxyMode
        editedSecret.allowInsecureHTTP = request.allowInsecureHTTP
        editedSecret.allowInvalidCertificates = request.allowInvalidCertificates
        editedSecret.requestTimeout = min(max(request.requestTimeout, 5), 120)
        editedSecret.conversionPreferences = request.conversionPreferences

        try SubscriptionURLPolicy.validate(
            editedSecret.url,
            allowInsecureHTTP: editedSecret.allowInsecureHTTP
        )
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "1.0"
        _ = try editedSecret.userAgentPreset.resolvedValue(
            appVersion: appVersion,
            customValue: editedSecret.userAgent
        )

        let scheduleChanged = metadata.schedule != request.schedule
        let automaticUpdateChanged = metadata.autoUpdateEnabled != request.autoUpdateEnabled
        let authenticationWasExplicitlyReplaced: Bool = if case .replace = request.authentication {
            true
        } else {
            false
        }
        let sourceIdentityChanged = request.replacementURL != nil
            || authenticationWasExplicitlyReplaced
            || editedSecret != previousSecret
        metadata.redactedURL = SubscriptionURLRedactor.redact(editedSecret.url)
        metadata.autoUpdateEnabled = request.autoUpdateEnabled
        metadata.schedule = request.schedule
        if sourceIdentityChanged {
            metadata.etag = nil
            metadata.lastModified = nil
            metadata.lastCheckedAt = nil
            metadata.lastSuccessfulUpdateAt = nil
            metadata.contentSHA256 = nil
            metadata.lastHTTPStatus = nil
            metadata.usage = nil
            metadata.suggestedFileName = nil
            metadata.suggestedUpdateIntervalMinutes = nil
            metadata.profileWebPageURL = nil
            metadata.lastFailure = nil
        }
        if !request.autoUpdateEnabled {
            metadata.nextScheduledUpdateAt = nil
        } else if sourceIdentityChanged || scheduleChanged || automaticUpdateChanged
            || metadata.nextScheduledUpdateAt == nil
        {
            metadata.nextScheduledUpdateAt = nextScheduledDate(
                after: now(),
                schedule: request.schedule
            )
        }

        do {
            try await secretStore.save(editedSecret, for: profileID)
        } catch {
            switch await secretLookup(profileID) {
            case let .present(envelope) where envelope == editedSecret:
                // Desired secret committed despite the late error.
                break
            case let .present(envelope) where envelope == previousSecret:
                throw SubscriptionUpdateFailure.secretMissing
            case .missing, .present, .unavailable:
                throw SubscriptionUpdateFailure.profileMutationRecoveryFailed
            }
        }
        do {
            return try await profileStore.updateRemoteSettings(
                for: profileID,
                name: request.name,
                metadata: metadata
            )
        } catch {
            switch await editCommitLookup(
                profileID: profileID,
                original: profile,
                desiredName: request.name,
                desiredMetadata: metadata
            ) {
            case let .desired(committed):
                return committed
            case .unavailable:
                throw SubscriptionUpdateFailure.profileMutationRecoveryFailed
            case .original:
                break
            }

            do {
                try await secretStore.save(previousSecret, for: profileID)
                throw SubscriptionUpdateFailure.runtimeBuildFailed
            } catch let failure as SubscriptionUpdateFailure {
                throw failure
            } catch {
                switch await secretLookup(profileID) {
                case let .present(envelope) where envelope == previousSecret:
                    // The rollback committed before its late error; metadata is
                    // still original, so the original pair is consistent.
                    throw SubscriptionUpdateFailure.runtimeBuildFailed
                case let .present(envelope) where envelope == editedSecret:
                    break
                case .missing, .present, .unavailable:
                    throw SubscriptionUpdateFailure.profileMutationRecoveryFailed
                }

                // The Keychain rollback failed. Retry the metadata update so
                // the durable profile converges on the already-written secret.
                do {
                    return try await profileStore.updateRemoteSettings(
                        for: profileID,
                        name: request.name,
                        metadata: metadata
                    )
                } catch {
                    switch await editCommitLookup(
                        profileID: profileID,
                        original: profile,
                        desiredName: request.name,
                        desiredMetadata: metadata
                    ) {
                    case let .desired(committed):
                        return committed
                    case .unavailable:
                        throw SubscriptionUpdateFailure.profileMutationRecoveryFailed
                    case .original:
                        break
                    }
                }

                // Forward completion failed too. A final exact-secret rollback
                // restores the original pair when the secure store is available.
                do {
                    try await secretStore.save(previousSecret, for: profileID)
                    throw SubscriptionUpdateFailure.runtimeBuildFailed
                } catch let failure as SubscriptionUpdateFailure {
                    throw failure
                } catch {
                    if case let .present(envelope) = await secretLookup(profileID),
                        envelope == previousSecret
                    {
                        throw SubscriptionUpdateFailure.runtimeBuildFailed
                    }
                    throw SubscriptionUpdateFailure.profileMutationRecoveryFailed
                }
            }
        }
    }

    /// Reconciles the only partial create state: the profile index committed,
    /// but the first Keychain write failed. No secret is copied to disk. The
    /// method either converges on a complete profile, removes the profile, or
    /// reports an explicit recovery-required failure.
    private func reconcileCreateAfterSecretWriteFailure(
        profile: Profile,
        secret: SubscriptionSecretEnvelope
    ) async throws {
        do {
            try await profileStore.deleteProfile(id: profile.id)
            throw SubscriptionUpdateFailure.secretMissing
        } catch let failure as SubscriptionUpdateFailure {
            throw failure
        } catch let deletionError {
            if Self.isCommittedDeleteCleanupFailure(deletionError) {
                throw SubscriptionUpdateFailure.profileDeletionCleanupFailed
            }
            switch await profileLookup(profile.id) {
            case .absent:
                throw SubscriptionUpdateFailure.profileDeletionCleanupFailed
            case .unavailable:
                throw SubscriptionUpdateFailure.profileMutationRecoveryFailed
            case .present:
                break
            }
        }

        // Deletion compensation failed while the profile is still durable.
        // Completing the original Keychain write is a safe forward repair.
        do {
            try await secretStore.save(secret, for: profile.id)
            return
        } catch {
            switch await secretLookup(profile.id) {
            case let .present(envelope) where envelope == secret:
                return
            case .missing:
                break
            case .present, .unavailable:
                throw SubscriptionUpdateFailure.profileMutationRecoveryFailed
            }
        }

        // If the secure store is still unavailable, retry the rollback. This
        // preserves the invariant that a failed create leaves no profile.
        do {
            try await profileStore.deleteProfile(id: profile.id)
            throw SubscriptionUpdateFailure.secretMissing
        } catch let failure as SubscriptionUpdateFailure {
            throw failure
        } catch let deletionError {
            if Self.isCommittedDeleteCleanupFailure(deletionError) {
                throw SubscriptionUpdateFailure.profileDeletionCleanupFailed
            }
            switch await profileLookup(profile.id) {
            case .absent:
                throw SubscriptionUpdateFailure.profileDeletionCleanupFailed
            case .unavailable:
                throw SubscriptionUpdateFailure.profileMutationRecoveryFailed
            case .present:
                break
            }
        }

        // Both directions failed twice. Do not hide the split state or include
        // any underlying path, URL, username, token, or password in the error.
        throw SubscriptionUpdateFailure.profileMutationRecoveryFailed
    }

    private func retryDeletionWithoutSecret(_ profileID: UUID) async throws {
        do {
            try await profileStore.deleteProfile(id: profileID)
            finishDeletedProfile(profileID)
        } catch let deletionError {
            if Self.isCommittedDeleteCleanupFailure(deletionError) {
                finishDeletedProfile(profileID)
                throw SubscriptionUpdateFailure.profileDeletionCleanupFailed
            }
            switch await profileLookup(profileID) {
            case .absent:
                finishDeletedProfile(profileID)
                throw SubscriptionUpdateFailure.profileDeletionCleanupFailed
            case .present:
                throw SubscriptionUpdateFailure.runtimeBuildFailed
            case .unavailable:
                throw SubscriptionUpdateFailure.profileMutationRecoveryFailed
            }
        }
    }

    nonisolated private static func isCommittedDeleteCleanupFailure(_ error: any Error) -> Bool {
        guard let storeError = error as? ProfileStoreError else { return false }
        if case .configurationDeleteCleanupFailed = storeError {
            return true
        }
        return false
    }

    private func finishDeletedProfile(_ profileID: UUID) {
        states.removeValue(forKey: profileID)
        inFlightProfiles.remove(profileID)
    }

    private func profileLookup(_ profileID: UUID) async -> SubscriptionProfileLookup {
        do {
            if let profile = try await profileStore.profile(id: profileID) {
                return .present(profile)
            }
            return .absent
        } catch {
            return .unavailable
        }
    }

    private func secretLookup(_ profileID: UUID) async -> SubscriptionSecretLookup {
        do {
            if let envelope = try await secretStore.envelope(for: profileID) {
                return .present(envelope)
            }
            return .missing
        } catch {
            return .unavailable
        }
    }

    private func editCommitLookup(
        profileID: UUID,
        original: Profile,
        desiredName: String,
        desiredMetadata: RemoteProfileMetadata
    ) async -> SubscriptionEditCommitLookup {
        guard case let .present(persisted) = await profileLookup(profileID) else {
            return .unavailable
        }
        let trimmedName = desiredName.trimmingCharacters(in: .whitespacesAndNewlines)
        if persisted.name == trimmedName, persisted.remote == desiredMetadata {
            return .desired(persisted)
        }
        if persisted == original {
            return .original
        }
        return .unavailable
    }

    private func committedCreateLookup(
        excluding existingProfileIDs: Set<UUID>,
        desiredName: String,
        desiredMetadata: RemoteProfileMetadata
    ) async -> SubscriptionCreateCommitLookup {
        let profiles: [Profile]
        do {
            profiles = try await profileStore.profiles()
        } catch {
            return .unavailable
        }
        let inserted = profiles.filter { !existingProfileIDs.contains($0.id) }
        guard !inserted.isEmpty else { return .notCommitted }
        let trimmedName = desiredName.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = inserted.filter {
            $0.sourceKind == .remoteSubscription
                && $0.name == trimmedName
                && $0.remote == desiredMetadata
        }
        guard matching.count == 1, let created = matching.first else {
            // More than one matching record means this service cannot prove
            // which identifier owns the pending secret. Never guess with credentials.
            return .unavailable
        }
        return .committed(created)
    }

    func updateState(for profileID: UUID) -> SubscriptionUpdateState {
        states[profileID] ?? .idle
    }

    func rawConfiguration(for profileID: UUID) async throws -> String {
        let data = try await profileStore.readConfiguration(for: profileID)
        guard let value = String(data: data, encoding: .utf8) else {
            throw SubscriptionUpdateFailure.invalidEncoding
        }
        return value
    }

    func update(profileID: UUID, reason _: SubscriptionUpdateReason) async throws {
        guard inFlightProfiles.insert(profileID).inserted else {
            return
        }
        defer { inFlightProfiles.remove(profileID) }

        guard var profile = try await profileStore.profile(id: profileID),
            profile.sourceKind == .remoteSubscription,
            var metadata = profile.remote
        else {
            throw SubscriptionUpdateFailure.invalidURL
        }
        guard let secret = try await secretStore.envelope(for: profileID) else {
            let failure = SubscriptionUpdateFailure.secretMissing
            try? await persistFailure(failure, profileID: profileID, metadata: &metadata)
            throw failure
        }

        states[profileID] = .checking
        let checkedAt = now()
        do {
            let outcome = try await httpClient.fetch(
                SubscriptionHTTPRequest(
                    secret: secret,
                    etag: metadata.etag,
                    lastModified: metadata.lastModified,
                    knownContentSHA256: metadata.contentSHA256,
                    allowsProxyFallback: true
                )
            )
            switch outcome {
            case let .notModified(httpMetadata), let .unchanged(httpMetadata):
                apply(httpMetadata, to: &metadata)
                metadata.lastCheckedAt = checkedAt
                metadata.nextScheduledUpdateAt = metadata.autoUpdateEnabled
                    ? nextScheduledDate(after: checkedAt, schedule: metadata.schedule)
                    : nil
                metadata.lastFailure = nil
                _ = try await profileStore.updateRemoteMetadata(
                    for: profileID,
                    metadata: metadata
                )
                states[profileID] = .unchanged

            case let .downloaded(download):
                states[profileID] = .downloading(
                    received: download.metadata.byteCount,
                    expected: download.metadata.byteCount
                )
                // Keep the last durable metadata unchanged until the runtime
                // transaction commits. A failed apply must never publish a
                // successful-update timestamp or validators for bytes that are
                // not the current revision.
                var candidateMetadata = metadata
                apply(download.metadata, to: &candidateMetadata)
                candidateMetadata.lastCheckedAt = checkedAt
                candidateMetadata.lastSuccessfulUpdateAt = checkedAt
                candidateMetadata.nextScheduledUpdateAt = candidateMetadata.autoUpdateEnabled
                    ? nextScheduledDate(after: checkedAt, schedule: candidateMetadata.schedule)
                    : nil
                candidateMetadata.lastFailure = nil
                candidateMetadata.originalFormat = download.conversion.detectedFormat
                candidateMetadata.convertedLocally = download.conversion.convertedLocally
                candidateMetadata.lastConvertedNodeCount = download.conversion.nodeCount
                candidateMetadata.lastRejectedItemCount = download.conversion.rejectedItemCount
                candidateMetadata.lastConversionWarnings = download.conversion.warnings
                states[profileID] = .validating
                states[profileID] = .applying
                _ = try await transactionCoordinator.apply(
                    rawData: download.data,
                    profileID: profileID,
                    sourceFileName: profile.originalFileName,
                    updatedRemoteMetadata: candidateMetadata
                )
                states[profileID] = .verifying
                metadata = candidateMetadata
                profile = try await profileStore.profile(id: profileID) ?? profile
                _ = profile
                states[profileID] = .succeeded(checkedAt)
            }
        } catch let failure as SubscriptionUpdateFailure where failure == .cancelled {
            metadata.nextScheduledUpdateAt = metadata.autoUpdateEnabled
                ? nextScheduledDate(after: now(), schedule: metadata.schedule)
                : nil
            _ = try? await profileStore.updateRemoteMetadata(
                for: profileID,
                metadata: metadata
            )
            states[profileID] = .idle
            throw failure
        } catch let failure as SubscriptionUpdateFailure {
            try? await persistFailure(failure, profileID: profileID, metadata: &metadata)
            states[profileID] = .failed(Self.userFacingError(for: failure))
            throw failure
        } catch let transactionError as RuntimeConfigTransactionError {
            let failure = Self.subscriptionFailure(for: transactionError)
            try? await persistFailure(failure, profileID: profileID, metadata: &metadata)
            states[profileID] = .failed(Self.userFacingError(for: failure))
            throw failure
        } catch is CancellationError {
            let failure = SubscriptionUpdateFailure.cancelled
            metadata.nextScheduledUpdateAt = metadata.autoUpdateEnabled
                ? nextScheduledDate(after: now(), schedule: metadata.schedule)
                : nil
            _ = try? await profileStore.updateRemoteMetadata(
                for: profileID,
                metadata: metadata
            )
            states[profileID] = .idle
            throw failure
        } catch {
            let failure = SubscriptionUpdateFailure.transportFailed
            try? await persistFailure(failure, profileID: profileID, metadata: &metadata)
            states[profileID] = .failed(Self.userFacingError(for: failure))
            throw failure
        }
    }

    func scheduleRetry(
        profileID: UUID,
        failure: SubscriptionUpdateFailure,
        consecutiveFailureCount: Int,
        at date: Date
    ) async {
        guard let profile = try? await profileStore.profile(id: profileID),
            var metadata = profile.remote,
            metadata.autoUpdateEnabled
        else { return }

        let persistedCount = metadata.lastFailure?.consecutiveCount
        let attempt = max(persistedCount ?? consecutiveFailureCount, 1)
        let normalDelay = TimeInterval(
            SubscriptionUpdateScheduler.normalizedMinutes(for: metadata.schedule) * 60
        )
        let retryDelay = Self.retryDelay(
            for: failure,
            consecutiveFailureCount: attempt,
            normalScheduleDelay: normalDelay
        )
        metadata.nextScheduledUpdateAt = date.addingTimeInterval(retryDelay)
        _ = try? await profileStore.updateRemoteMetadata(for: profileID, metadata: metadata)
    }

    private func apply(
        _ response: SubscriptionHTTPMetadata,
        to metadata: inout RemoteProfileMetadata
    ) {
        metadata.etag = response.etag ?? metadata.etag
        metadata.lastModified = response.lastModified ?? metadata.lastModified
        metadata.contentSHA256 = response.contentSHA256 ?? metadata.contentSHA256
        metadata.lastHTTPStatus = response.statusCode
        metadata.usage = response.usage ?? metadata.usage
        metadata.suggestedFileName = response.suggestedFileName ?? metadata.suggestedFileName
        metadata.suggestedUpdateIntervalMinutes = response.suggestedUpdateIntervalMinutes
            ?? metadata.suggestedUpdateIntervalMinutes
        metadata.profileWebPageURL = response.profileWebPageURL ?? metadata.profileWebPageURL
    }

    private func defaultProfileName(for url: URL) -> String {
        let lastComponent = url.deletingPathExtension().lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return lastComponent.isEmpty ? "Remote Profile" : lastComponent
    }

    private func persistFailure(
        _ failure: SubscriptionUpdateFailure,
        profileID: UUID,
        metadata: inout RemoteProfileMetadata
    ) async throws {
        let timestamp = now()
        let previousFailureCount = metadata.lastFailure.map {
            max($0.consecutiveCount ?? 1, 1)
        } ?? 0
        metadata.lastCheckedAt = timestamp
        let nextFailureCount = previousFailureCount == Int.max
            ? Int.max
            : previousFailureCount + 1
        metadata.lastFailure = PersistedFailureSummary(
            kind: String(describing: failure),
            message: failure.localizedDescription,
            occurredAt: timestamp,
            consecutiveCount: nextFailureCount
        )
        if metadata.autoUpdateEnabled {
            let normalScheduleDelay = TimeInterval(
                SubscriptionUpdateScheduler.normalizedMinutes(for: metadata.schedule) * 60
            )
            metadata.nextScheduledUpdateAt = timestamp.addingTimeInterval(
                Self.retryDelay(
                    for: failure,
                    consecutiveFailureCount: nextFailureCount,
                    normalScheduleDelay: normalScheduleDelay
                )
            )
        } else {
            metadata.nextScheduledUpdateAt = nil
        }
        _ = try await profileStore.updateRemoteMetadata(for: profileID, metadata: metadata)
    }

    nonisolated static func retryDelay(
        for failure: SubscriptionUpdateFailure,
        consecutiveFailureCount: Int,
        normalScheduleDelay: TimeInterval
    ) -> TimeInterval {
        let maximumDelay = TimeInterval(6 * 60 * 60)
        switch failure {
        case .authenticationFailed:
            return max(normalScheduleDelay, maximumDelay)
        case let .rateLimited(retryAfterSeconds?):
            guard retryAfterSeconds.isFinite else { return maximumDelay }
            return min(max(retryAfterSeconds, 5 * 60), maximumDelay)
        case .cancelled:
            return normalScheduleDelay
        default:
            let index = min(
                max(consecutiveFailureCount - 1, 0),
                SubscriptionUpdateScheduler.retryBackoffMinutes.count - 1
            )
            return TimeInterval(
                SubscriptionUpdateScheduler.retryBackoffMinutes[index] * 60
            )
        }
    }

    private func nextScheduledDate(
        after date: Date,
        schedule: SubscriptionSchedule
    ) -> Date {
        let baseInterval = TimeInterval(
            SubscriptionUpdateScheduler.normalizedMinutes(for: schedule) * 60
        )
        let jitter = min(max(scheduleJitterFraction(), -0.05), 0.05)
        return date.addingTimeInterval(baseInterval * (1 + jitter))
    }

    private static func subscriptionFailure(
        for error: RuntimeConfigTransactionError
    ) -> SubscriptionUpdateFailure {
        switch error {
        case .runtimeBuildFailed: .runtimeBuildFailed
        case .configurationValidationFailed: .configurationValidationFailed
        case .hotReloadFailed: .hotReloadFailed
        case .controllerDidNotRecover: .controllerDidNotRecover
        case .healthVerificationFailed: .healthVerificationFailed
        case .rollbackFailed, .recoveryFailed: .rollbackFailed
        case .transactionAlreadyRunning: .cancelled
        case .stagingFailed, .activeReplacementFailed, .revisionCommitFailed,
            .executableResolutionFailed, .journalCorrupt:
            .runtimeBuildFailed
        }
    }

    private static func userFacingError(
        for failure: SubscriptionUpdateFailure
    ) -> UserFacingError {
        UserFacingError(
            title: "Subscription Update Failed",
            message: failure.localizedDescription,
            technicalDetails: String(describing: failure),
            suggestedAction: failure == .authenticationFailed
                ? "Re-enter the subscription credentials and try again."
                : "Check the profile settings and retry the update.",
            isRetryable: failure != .authenticationFailed,
            category: .subscription,
            recoveryActions: failure == .authenticationFailed
                ? [.editSubscription, .reenterCredentials, .openDiagnostics]
                : [.retry, .editSubscription, .usePreviousRevision, .openDiagnostics]
        )
    }
}

private nonisolated extension String {
    var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

private nonisolated enum SubscriptionProfileLookup: Sendable {
    case present(Profile)
    case absent
    case unavailable
}

private nonisolated enum SubscriptionSecretLookup: Sendable {
    case present(SubscriptionSecretEnvelope)
    case missing
    case unavailable
}

private nonisolated enum SubscriptionEditCommitLookup: Sendable {
    case desired(Profile)
    case original
    case unavailable
}

private nonisolated enum SubscriptionCreateCommitLookup: Sendable {
    case committed(Profile)
    case notCommitted
    case unavailable
}
