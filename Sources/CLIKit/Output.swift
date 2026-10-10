import Foundation
import SpaceAPI

public struct Snapshot: Encodable, Sendable {
    public let schemaVersion = 1
    public let endpoint: String
    public let name: String?
    public let status: SpaceStatus
    public let message: String?
    public let lastChange: Date?
    public let fetchedAt: Date?
    public let observedAt: Date
    public let network: String
    public let error: String?

    public init(endpoint: URL, info: SpaceInfo?, error: String? = nil, now: Date = Date()) {
        self.endpoint = endpoint.absoluteString
        name = info?.name
        status = info?.status ?? .unknown
        message = info?.state?.message
        lastChange = info?.state?.lastChange
        fetchedAt = info == nil ? nil : now
        observedAt = now
        network = info == nil ? "error" : "ok"
        self.error = error
    }
}

public enum Output {
    private struct SearchResult: Encodable {
        let schemaVersion = 1
        let spaces: [Snapshot]
    }
    private struct Waybar: Encodable {
        let text: String
        let tooltip: String
        let `class`: String
        let alt: String
    }

    public static func json<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    /// Control characters cannot inject extra terminal or NDJSON lines.
    public static func plain(_ value: String) -> String {
        String(value.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }.joined())
    }

    public static func snapshot(_ snapshot: Snapshot, format: String) throws -> String {
        if format == "json" || format == "ndjson" { return try json(snapshot) }
        let text = "\(plain(snapshot.name ?? "Space")): \(snapshot.status.rawValue)"
        if format == "waybar-json" {
            // Waybar renders tooltips as Pango markup.
            let tooltip = plain(snapshot.message ?? snapshot.error ?? snapshot.endpoint)
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
            return try json(Waybar(text: text, tooltip: tooltip,
                                  class: snapshot.network == "error" ? "error" : snapshot.status.rawValue,
                                  alt: snapshot.status.rawValue))
        }
        return text + (snapshot.message.map { " — \(plain($0))" } ?? "")
    }

    public static func search(_ entries: [DirectoryEntry], format: String) throws -> String {
        if format == "json" {
            return try json(SearchResult(spaces: entries.map { Snapshot(endpoint: $0.endpoint, info: $0.info) }))
        }
        return entries.map { "\(plain($0.info.name))\t\($0.info.status.rawValue)\t\(plain($0.endpoint.absoluteString))" }.joined(separator: "\n")
    }
}
