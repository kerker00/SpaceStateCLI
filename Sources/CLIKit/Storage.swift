import Foundation
import SpaceAPI

/// Where the optional config and the directory cache live, following the XDG base directories.
public enum Paths {
    public static func savedSpaces(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        base("XDG_CONFIG_HOME", ".config", environment).appending(path: "spacestate/spaces")
    }

    public static func directoryCache(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        base("XDG_CACHE_HOME", ".cache", environment).appending(path: "spacestate/directory.json")
    }

    private static func base(_ variable: String, _ fallback: String, _ environment: [String: String]) -> URL {
        if let path = environment[variable], path.hasPrefix("/") { return URL(filePath: path) }
        let home = environment["HOME"].map { URL(filePath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser
        return home.appending(path: fallback)
    }
}

/// The saved spaces: a plain text file with one endpoint per line and an optional `# name`.
/// It is optional, may be edited by hand, and lines the tool does not touch stay as they are.
public struct SavedSpaces: Sendable {
    public let file: URL

    public init(file: URL = Paths.savedSpaces()) {
        self.file = file
    }

    public func load() throws -> [Target] {
        try lines().enumerated().compactMap { index, line in
            do {
                return try Self.parse(line)
            } catch let error as UsageError {
                throw UsageError("\(file.path), line \(index + 1): \(error.description)")
            }
        }
    }

    /// Appends the targets that are not saved yet and returns them.
    @discardableResult
    public func add(_ targets: [Target]) throws -> [Target] {
        var known = Set(try load().map(\.endpoint))
        let new = targets.filter { known.insert($0.endpoint).inserted }
        guard !new.isEmpty else { return [] }
        var lines = try lines()
        if lines.isEmpty { lines = ["# Spaces shown by `spacestate` without arguments: endpoint, then an optional # name."] }
        lines += new.map { target in target.name.map { "\(target.endpoint.absoluteString)  # \(Output.plain($0))" } ?? target.endpoint.absoluteString }
        try write(lines)
        return new
    }

    public func remove(_ targets: [Target]) throws {
        let endpoints = Set(targets.map(\.endpoint))
        try write(try lines().filter { line in
            guard let target = try? Self.parse(line) else { return true }
            return !endpoints.contains(target.endpoint)
        })
    }

    static func parse(_ line: String) throws -> Target? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
        let url = trimmed.prefix { !$0.isWhitespace }
        let rest = trimmed.dropFirst(url.count).trimmingCharacters(in: .whitespaces)
        let name = rest.hasPrefix("#") ? rest.dropFirst().trimmingCharacters(in: .whitespaces) : ""
        return Target(endpoint: try Resolver.webURL(String(url)), name: name.isEmpty ? nil : name)
    }

    private func lines() throws -> [String] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        var lines = try String(contentsOf: file, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines
    }

    private func write(_ lines: [String]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file, options: .atomic)
    }
}

/// Loads the SpaceAPI directory, keeping a copy so names resolve without a 300 KB download each time.
public enum DirectoryLoader {
    /// - Parameter maxAge: How old the cached copy may be; `nil` always downloads, without falling back to the cache.
    public static func load(
        from url: URL, cache: URL?, maxAge: TimeInterval?, client: StatusClient = StatusClient(), now: Date = Date()
    ) async throws -> [DirectoryEntry] {
        if let cache, let maxAge, let modified = modificationDate(cache), now.timeIntervalSince(modified) < maxAge,
           let entries = cached(cache) {
            return entries
        }
        do {
            let data = try await client.data(from: url, maximumBytes: StatusClient.maxDirectoryResponseBytes)
            let entries = try SpaceDirectory.decode(data)
            if let cache {
                try? FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: cache, options: .atomic)
            }
            return entries
        } catch {
            // A stale list still resolves names; the states are fetched from each space anyway.
            if maxAge != nil, let cache, let entries = cached(cache) { return entries }
            throw error
        }
    }

    private static func modificationDate(_ file: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
    }

    private static func cached(_ file: URL) -> [DirectoryEntry]? {
        (try? Data(contentsOf: file)).flatMap { try? SpaceDirectory.decode($0) }
    }
}
