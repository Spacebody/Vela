nonisolated enum EngineState: Equatable, Sendable {
    case stopped
    case validating
    case starting
    case running(EngineHealth)
    case stopping
    case recovering
    case failed(EngineFailure)
}
