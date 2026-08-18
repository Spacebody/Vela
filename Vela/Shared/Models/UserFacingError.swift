import Foundation

nonisolated enum UserFacingErrorCategory: String, Codable, Equatable, Sendable {
    case general
    case subscription
    case provider
    case connections
    case rules
    case configuration
    case data
    case startup
}

nonisolated enum UserRecoveryAction: String, Codable, CaseIterable, Equatable, Sendable {
    case retry
    case editSubscription
    case reenterCredentials
    case usePreviousRevision
    case openDiagnostics
    case openLoginItemsSettings
    case copyRedactedDetails
}

nonisolated struct UserFacingError: Error, Identifiable, Equatable, Sendable {
    let id: UUID
    let title: String
    let message: String
    let technicalDetails: String?
    let suggestedAction: String?
    let isRetryable: Bool
    let category: UserFacingErrorCategory
    let recoveryActions: [UserRecoveryAction]
    let correlationID: UUID

    init(
        id: UUID = UUID(),
        title: String,
        message: String,
        technicalDetails: String? = nil,
        suggestedAction: String? = nil,
        isRetryable: Bool,
        category: UserFacingErrorCategory = .general,
        recoveryActions: [UserRecoveryAction] = [],
        correlationID: UUID = UUID()
    ) {
        self.id = id
        self.title = title
        self.message = message
        self.technicalDetails = technicalDetails
        self.suggestedAction = suggestedAction
        self.isRetryable = isRetryable
        self.category = category
        self.recoveryActions = recoveryActions
        self.correlationID = correlationID
    }

    var redactedTechnicalDetails: String? {
        technicalDetails.map(DiagnosticTextSanitizer.redact)
    }
}
