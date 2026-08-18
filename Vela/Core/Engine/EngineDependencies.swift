import Foundation

nonisolated protocol ProfileManaging: Actor {
    func prepareStorage() throws
    func importProfile(from source: URL, name: String?) throws -> Profile
    func profiles() throws -> [Profile]
    func selectedProfileID() throws -> UUID?
    func selectProfile(id: UUID) throws
    func clearSelectedProfile() throws
    func deleteProfile(id: UUID) throws
    func configurationURL(for profileID: UUID) -> URL
    func buildRuntimeConfiguration(
        for profileID: UUID,
        parameters: RuntimeConfigParameters,
        using builder: RuntimeConfigBuilder
    ) throws -> URL
    func buildRuntimeConfiguration(
        for profileID: UUID,
        parameters: RuntimeConfigParameters,
        using builder: RuntimeConfigBuilder,
        context: ConfigurationCompilationContext
    ) throws -> URL
}

extension ProfileManaging {
    func clearSelectedProfile() throws {}

    func deleteProfile(id: UUID) throws {
        throw ProfileStoreError.profileNotFound(id)
    }

    func buildRuntimeConfiguration(
        for profileID: UUID,
        parameters: RuntimeConfigParameters,
        using builder: RuntimeConfigBuilder,
        context _: ConfigurationCompilationContext
    ) throws -> URL {
        try buildRuntimeConfiguration(
            for: profileID,
            parameters: parameters,
            using: builder
        )
    }
}

extension ProfileStore: ProfileManaging {}
