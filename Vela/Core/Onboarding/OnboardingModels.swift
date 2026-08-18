import Foundation

nonisolated enum OnboardingStepID: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case welcome
    case privacy
    case addConfiguration = "add-configuration"
    case validation
    case networkModeEducation = "network-mode-education"
    case optionalTools = "optional-tools"
    case finish

    var id: String { rawValue }

    var ordinal: Int {
        Self.allCases.firstIndex(of: self).map { $0 + 1 } ?? 1
    }

    var next: Self? {
        guard let index = Self.allCases.firstIndex(of: self) else { return nil }
        let nextIndex = Self.allCases.index(after: index)
        return nextIndex < Self.allCases.endIndex ? Self.allCases[nextIndex] : nil
    }

    var previous: Self? {
        guard let index = Self.allCases.firstIndex(of: self), index > 0 else {
            return nil
        }
        return Self.allCases[Self.allCases.index(before: index)]
    }
}

nonisolated enum OnboardingProgressValidationError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
    case invalidFlowVersion(Int)
    case duplicateCompletedStep(OnboardingStepID)
    case completedStepsOutOfOrder
    case conflictingTerminalDates
    case completionIsMissingSteps
}

nonisolated struct OnboardingProgress: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    static let currentFlowVersion = 1

    var schemaVersion: Int
    var flowVersion: Int
    var completedStepIDs: [OnboardingStepID]
    var lastStepID: OnboardingStepID?
    var completedAt: Date?
    var skippedAt: Date?

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        flowVersion: Int = Self.currentFlowVersion,
        completedStepIDs: [OnboardingStepID] = [],
        lastStepID: OnboardingStepID? = nil,
        completedAt: Date? = nil,
        skippedAt: Date? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.flowVersion = flowVersion
        self.completedStepIDs = completedStepIDs
        self.lastStepID = lastStepID
        self.completedAt = completedAt
        self.skippedAt = skippedAt
    }

    static func empty(flowVersion: Int = Self.currentFlowVersion) -> Self {
        Self(flowVersion: flowVersion)
    }

    var isCompleted: Bool { completedAt != nil }
    var isSkipped: Bool { skippedAt != nil }
    var isTerminal: Bool { isCompleted || isSkipped }

    var firstIncompleteStepID: OnboardingStepID? {
        let completed = Set(completedStepIDs)
        return OnboardingStepID.allCases.first { !completed.contains($0) }
    }

    var resumeStepID: OnboardingStepID {
        if let lastStepID, !completedStepIDs.contains(lastStepID) {
            return lastStepID
        }
        return firstIncompleteStepID ?? .finish
    }

    func validated() throws -> Self {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw OnboardingProgressValidationError.unsupportedSchemaVersion(
                schemaVersion
            )
        }
        guard flowVersion > 0 else {
            throw OnboardingProgressValidationError.invalidFlowVersion(flowVersion)
        }

        var seen = Set<OnboardingStepID>()
        for stepID in completedStepIDs {
            guard seen.insert(stepID).inserted else {
                throw OnboardingProgressValidationError.duplicateCompletedStep(stepID)
            }
        }
        let canonical = OnboardingStepID.allCases.filter(seen.contains)
        guard canonical == completedStepIDs else {
            throw OnboardingProgressValidationError.completedStepsOutOfOrder
        }
        guard completedAt == nil || skippedAt == nil else {
            throw OnboardingProgressValidationError.conflictingTerminalDates
        }
        guard completedAt == nil || completedStepIDs == OnboardingStepID.allCases else {
            throw OnboardingProgressValidationError.completionIsMissingSteps
        }
        return self
    }

    mutating func recordArrival(at stepID: OnboardingStepID) {
        lastStepID = stepID
    }

    mutating func markStepCompleted(_ stepID: OnboardingStepID) {
        let completed = Set(completedStepIDs).union([stepID])
        completedStepIDs = OnboardingStepID.allCases.filter(completed.contains)
    }

    mutating func markSkipped(at date: Date) {
        lastStepID = lastStepID ?? firstIncompleteStepID ?? .finish
        completedAt = nil
        skippedAt = date
    }

    mutating func markCompleted(at date: Date) {
        completedStepIDs = OnboardingStepID.allCases
        lastStepID = .finish
        completedAt = date
        skippedAt = nil
    }

    mutating func reopen() {
        completedAt = nil
        skippedAt = nil
        if completedStepIDs == OnboardingStepID.allCases {
            completedStepIDs = []
        }
        lastStepID = firstIncompleteStepID ?? .welcome
    }
}

nonisolated enum OnboardingFlowMode: String, Codable, Equatable, Sendable {
    case full
    case tour
}

nonisolated struct OnboardingLaunchContext: Equatable, Sendable {
    var hasExistingUserData: Bool
    var isTourRequested: Bool

    init(hasExistingUserData: Bool, isTourRequested: Bool = false) {
        self.hasExistingUserData = hasExistingUserData
        self.isTourRequested = isTourRequested
    }
}

nonisolated enum OnboardingPresentationDecision: Equatable, Sendable {
    case present(mode: OnboardingFlowMode, startAt: OnboardingStepID)
    case offerTour
    case none
}

nonisolated enum OnboardingDecisionPolicy {
    static func decide(
        progress: OnboardingProgress?,
        context: OnboardingLaunchContext,
        currentFlowVersion: Int = OnboardingProgress.currentFlowVersion
    ) -> OnboardingPresentationDecision {
        if context.isTourRequested {
            return .present(mode: .tour, startAt: .welcome)
        }

        guard let progress else {
            return context.hasExistingUserData
                ? .offerTour
                : .present(mode: .full, startAt: .welcome)
        }

        guard progress.flowVersion == currentFlowVersion else {
            return .offerTour
        }
        guard !progress.isTerminal else { return .none }
        return .present(mode: .full, startAt: progress.resumeStepID)
    }
}

nonisolated struct OnboardingClock: Sendable {
    private let nowProvider: @Sendable () -> Date

    init(now: @escaping @Sendable () -> Date) {
        nowProvider = now
    }

    func now() -> Date { nowProvider() }

    static let live = Self { Date() }
}
