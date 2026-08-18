import Foundation

nonisolated struct YAMLPointer: Codable, Equatable, Hashable, Sendable, Comparable {
    static let root = YAMLPointer(components: [])

    let rawValue: String
    let components: [String]

    init(_ rawValue: String) throws {
        guard rawValue.isEmpty || rawValue.first == "/" else {
            throw YAMLPointerError.mustStartWithSlash(rawValue)
        }

        self.rawValue = rawValue
        if rawValue.isEmpty {
            components = []
        } else {
            components = try rawValue.dropFirst().split(
                separator: "/",
                omittingEmptySubsequences: false
            ).map { try Self.unescape(String($0), pointer: rawValue) }
        }
    }

    init(components: [String]) {
        self.components = components
        rawValue = components.isEmpty
            ? ""
            : "/" + components.map(Self.escape).joined(separator: "/")
    }

    var isRoot: Bool { components.isEmpty }

    func isAncestor(of other: YAMLPointer) -> Bool {
        components.count < other.components.count
            && other.components.prefix(components.count).elementsEqual(components)
    }

    static func < (lhs: YAMLPointer, rhs: YAMLPointer) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode(String.self))
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    private static func escape(_ component: String) -> String {
        component
            .replacingOccurrences(of: "~", with: "~0")
            .replacingOccurrences(of: "/", with: "~1")
    }

    private static func unescape(_ component: String, pointer: String) throws -> String {
        var result = ""
        var index = component.startIndex
        while index < component.endIndex {
            let character = component[index]
            guard character == "~" else {
                result.append(character)
                index = component.index(after: index)
                continue
            }

            let escapeIndex = component.index(after: index)
            guard escapeIndex < component.endIndex else {
                throw YAMLPointerError.invalidEscape(pointer)
            }
            switch component[escapeIndex] {
            case "0": result.append("~")
            case "1": result.append("/")
            default: throw YAMLPointerError.invalidEscape(pointer)
            }
            index = component.index(after: escapeIndex)
        }
        return result
    }
}
nonisolated enum YAMLPointerError: Error, Equatable, Sendable {
    case mustStartWithSlash(String)
    case invalidEscape(String)
}

extension YAMLPointerError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .mustStartWithSlash(pointer):
            "JSON Pointer must be empty or start with '/': \(pointer)"
        case let .invalidEscape(pointer):
            "JSON Pointer contains an escape other than ~0 or ~1: \(pointer)"
        }
    }
}
