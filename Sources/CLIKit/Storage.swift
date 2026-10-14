import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
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
        for target in targets { try Resolver.validateEndpoint(target.endpoint) }
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
        for target in targets { try Resolver.validateEndpoint(target.endpoint) }
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
        guard rest.isEmpty || rest.hasPrefix("#") else {
            throw UsageError("Expected one endpoint followed by an optional # comment")
        }
        let name = rest.hasPrefix("#") ? rest.dropFirst().trimmingCharacters(in: .whitespaces) : ""
        return Target(endpoint: try Resolver.webURL(String(url)), name: name.isEmpty ? nil : name)
    }

    private func lines() throws -> [String] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        // CRLF is one extended grapheme cluster in Swift, so normalize it before
        // splitting by the LF Character. Bare controls inside a URL remain invalid.
        let content = try String(contentsOf: file, encoding: .utf8)
            .replacingOccurrences(of: "\r\n", with: "\n")
        var lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines
    }

    private func write(_ lines: [String]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file, options: .atomic)
    }
}

/// Loads the SpaceAPI directory, keeping a copy so names resolve without a 300 KB download each time.
public struct DirectoryDocument: Sendable {
    public let entries: [DirectoryEntry]
    public let receivedAt: Date?
    public let attemptedAt: Date
    public let maximumObservationAge: TimeInterval
    public let error: String?

    public func snapshots(at date: Date = Date()) -> [Snapshot] {
        entries.map { Snapshot($0, receivedAt: receivedAt, maximumAge: maximumObservationAge,
            error: error, attemptedAt: attemptedAt, now: date) }
    }
}

public enum DirectoryLoader {
    /// - Parameter maxAge: How old the cached copy may be; `nil` always downloads, without falling back to the cache.
    public static func load(
        from url: URL, cache: URL?, maxAge: TimeInterval?, client: StatusClient = StatusClient(), now: Date = Date()
    ) async throws -> [DirectoryEntry] {
        try await document(from: url, cache: cache, maxAge: maxAge, now: { now }) {
            let data = try await client.data(from: url, maximumBytes: StatusClient.maxDirectoryResponseBytes)
            return (data, ObservationTiming.defaultMaximumAge)
        }.entries
    }

    /// The original successful download and each entry's lastSeen survive cache
    /// reuse. A failed refresh may supply names, but never a current opening flag.
    public static func loadDocument(from url: URL, cache: URL?, maxAge: TimeInterval?,
                                    now: @escaping @Sendable () -> Date = { Date() }, load: StatusClient.Loader? = nil) async throws -> DirectoryDocument {
        try await document(from: url, cache: cache, maxAge: maxAge, now: now) {
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response): (Data, URLResponse)
            if let load { (data, response) = try await load(request) }
            else { (data, response) = try await StatusClient.limitedLoad(request, maximumBytes: StatusClient.maxDirectoryResponseBytes) }
            guard data.count <= StatusClient.maxDirectoryResponseBytes else { throw StatusClientError.responseTooLarge }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw StatusClientError.httpStatus(http.statusCode)
            }
            var age = ObservationTiming.defaultMaximumAge
            if let field = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "X-SpacePush-Max-Data-Age") {
                let text = field.trimmingCharacters(in: .whitespaces)
                if !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }), let seconds = Int64(text), seconds > 0 {
                    age = TimeInterval(seconds)
                } else { age = 0 }
            }
            return (data, age)
        }
    }

    private static func document(from url: URL, cache: URL?, maxAge: TimeInterval?, now: @Sendable () -> Date,
                                 read: () async throws -> (Data, TimeInterval)) async throws -> DirectoryDocument {
        try Resolver.validateEndpoint(url)
        try Task.checkCancellation()
        let attemptedAt = now()
        if let cache, let maxAge, let stored = cached(cache, source: url), let receivedAt = stored.receivedAt,
           receivedAt <= attemptedAt, attemptedAt.timeIntervalSince(receivedAt) < maxAge {
            return stored.document(attemptedAt: attemptedAt)
        }
        do {
            let (data, age) = try await read()
            let entries = try SpaceDirectory.decode(data)
            try Task.checkCancellation()
            let receivedAt = now()
            if let cache {
                try? FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
                let stored = CacheEnvelope(version: 1, source: url, receivedAt: receivedAt, maximumObservationAge: age, body: data)
                if let encoded = try? JSONEncoder().encode(stored) { try? encoded.write(to: cache, options: .atomic) }
            }
            return DirectoryDocument(entries: entries, receivedAt: receivedAt, attemptedAt: attemptedAt,
                                     maximumObservationAge: age, error: nil)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // A stale list still resolves names; the states are fetched from each space anyway.
            try Task.checkCancellation()
            if maxAge != nil, let cache, let stored = cached(cache, source: url) {
                return stored.document(attemptedAt: attemptedAt, error: "directory unavailable; showing cached names")
            }
            throw error
        }
    }

    private static func modificationDate(_ file: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
    }

    private struct CacheEnvelope: Codable {
        let version: Int
        let source: URL
        let receivedAt: Date
        let maximumObservationAge: TimeInterval
        let body: Data
    }

    private struct CachedDirectory {
        let entries: [DirectoryEntry]
        let receivedAt: Date?
        let maximumObservationAge: TimeInterval
        func document(attemptedAt: Date, error: String? = nil) -> DirectoryDocument {
            DirectoryDocument(entries: entries, receivedAt: receivedAt, attemptedAt: attemptedAt,
                              maximumObservationAge: maximumObservationAge, error: error)
        }
    }

    private static func cached(_ file: URL, source: URL) -> CachedDirectory? {
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? NSNumber
        // A bounded raw body expands as base64 in the versioned cache envelope.
        guard let size, size.intValue <= StatusClient.maxDirectoryResponseBytes * 2,
              let data = try? Data(contentsOf: file) else { return nil }
        if let stored = try? JSONDecoder().decode(CacheEnvelope.self, from: data) {
            guard stored.version == 1, stored.source == source,
                  stored.body.count <= StatusClient.maxDirectoryResponseBytes,
                  let entries = try? SpaceDirectory.decode(stored.body) else { return nil }
            return CachedDirectory(entries: entries, receivedAt: stored.receivedAt,
                                   maximumObservationAge: stored.maximumObservationAge)
        }
        // Older raw-array caches retain their file time and original lastSeen;
        // reading or touching a new envelope never resets its stored receipt.
        guard data.count <= StatusClient.maxDirectoryResponseBytes,
              let entries = try? SpaceDirectory.decode(data) else { return nil }
        return CachedDirectory(entries: entries, receivedAt: modificationDate(file),
                               maximumObservationAge: ObservationTiming.defaultMaximumAge)
    }
}
