import Foundation

public struct SecretValue: Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable
{
    private let storage: String

    public init(_ value: String) {
        storage = value
    }

    public var description: String { "<redacted>" }
    public var debugDescription: String { "SecretValue(<redacted>)" }
    public var customMirror: Mirror {
        Mirror(self, children: ["value": "<redacted>"])
    }

    public func withValue<Result>(_ operation: (String) throws -> Result) rethrows -> Result {
        try operation(storage)
    }
}
