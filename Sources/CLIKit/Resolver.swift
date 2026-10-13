import Foundation
import SpaceAPI

public enum CLI {
    public static let version = "0.3.0"
}

public struct UsageError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// A space to query: its endpoint and, when known, its name.
public struct Target: Sendable, Hashable {
    public let endpoint: URL
    public let name: String?

    public init(endpoint: URL, name: String?) {
        self.endpoint = endpoint
        self.name = name
    }

    public init(_ entry: DirectoryEntry) {
        self.init(endpoint: entry.endpoint, name: entry.info.name)
    }
}

public enum Resolution: Equatable, Sendable {
    case found(Target)
    case ambiguous([Target])
    case notFound
}

/// Turns what a person types into a space: an endpoint URL, or a name looked up among candidates.
public enum Resolver {
    /// Arguments with a scheme are endpoints; everything else is a name.
    public static func isURL(_ argument: String) -> Bool {
        argument.contains("://")
    }

    public static func webURL(_ string: String) throws -> URL {
        do {
            return try SpaceEndpoint.parse(string)
        } catch {
            throw invalidEndpoint
        }
    }

    static func validateEndpoint(_ url: URL) throws {
        do {
            try SpaceEndpoint.validate(url)
        } catch {
            throw invalidEndpoint
        }
    }

    // Input may contain credentials or terminal controls; do not repeat it in errors.
    private static var invalidEndpoint: UsageError {
        UsageError("Expected an HTTP(S) endpoint with a host and valid port, without credentials or control characters")
    }

    /// Prefers an exact name, then names starting with the query, then names or hosts containing it.
    /// Several matches at the first level that has any are ambiguous; nothing is guessed.
    public static func resolve(_ query: String, in candidates: [Target]) -> Resolution {
        let wanted = fold(query)
        guard !wanted.isEmpty else { return .notFound }
        let named = candidates.map { (target: $0, name: fold($0.name ?? "")) }
        let levels: [(String, Target) -> Bool] = [
            { name, _ in name == wanted },
            { name, _ in name.hasPrefix(wanted) },
            { name, target in name.contains(wanted) || fold(target.endpoint.host ?? "").contains(wanted) },
        ]
        for matches in levels {
            let found = named.filter { matches($0.name, $0.target) }.map(\.target)
            if found.count == 1 { return .found(found[0]) }
            if found.count > 1 { return .ambiguous(found) }
        }
        return .notFound
    }

    /// Case, accents and repeated spaces do not matter when comparing names.
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// Parses an interval such as `90`, `30s`, `5m` or `1h` into seconds, between 5 seconds and a day.
public func pollInterval(_ text: String) throws -> Double {
    let units: [Character: Double] = ["s": 1, "m": 60, "h": 3600]
    let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
    let unit = trimmed.last.flatMap { units[$0] }
    let number = unit == nil ? trimmed : String(trimmed.dropLast())
    guard let value = Double(number), value.isFinite else {
        throw UsageError("Interval must be a number of seconds or use s, m or h, such as 30s or 5m")
    }
    let seconds = value * (unit ?? 1)
    guard seconds >= 5, seconds <= 86400 else { throw UsageError("Interval must be between 5s and 24h") }
    return seconds
}
