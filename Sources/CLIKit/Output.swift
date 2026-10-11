import Foundation
import SpaceAPI
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

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
        self.init(Target(endpoint: endpoint, name: nil), info: info, error: error, now: now)
    }

    /// Falls back to the target's known name when the space cannot be reached.
    public init(_ target: Target, info: SpaceInfo?, error: String? = nil, now: Date = Date()) {
        endpoint = target.endpoint.absoluteString
        name = info?.name ?? target.name
        status = info?.status ?? .unknown
        message = info?.state?.message
        lastChange = info?.state?.lastChange
        fetchedAt = info == nil ? nil : now
        observedAt = now
        network = info == nil ? "error" : "ok"
        self.error = error
    }

    public var failed: Bool { network == "error" }
}

/// Colors only when stdout is a terminal, honouring `NO_COLOR` and `TERM=dumb`.
public func terminalSupportsColor(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
    isatty(STDOUT_FILENO) != 0 && (environment["NO_COLOR"] ?? "").isEmpty && environment["TERM"] != "dumb"
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

    /// One aligned line per space: name, state, how long it has been in that state, and its message or error.
    public static func table(_ snapshots: [Snapshot], color: Bool, now: Date = Date()) -> String {
        let width = snapshots.map { label($0).count }.max() ?? 0
        return snapshots.map { snapshot in
            let since = snapshot.lastChange.map { "for \(elapsed(since: $0, now: now))" } ?? ""
            let detail = snapshot.failed ? "unreachable: \(snapshot.error ?? "no answer")" : snapshot.message ?? ""
            return trim([pad(label(snapshot), width), mark(snapshot.status, color: color), pad(since, 10), plain(detail)])
        }.joined(separator: "\n")
    }

    /// A watch line for a space whose state changed, prefixed with the local time.
    public static func change(_ snapshot: Snapshot, color: Bool, now: Date = Date()) -> String {
        let time = now.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
        let detail = snapshot.failed ? "unreachable: \(snapshot.error ?? "no answer")" : snapshot.message ?? ""
        return trim([time, label(snapshot), mark(snapshot.status, color: color), plain(detail)])
    }

    public static func search(_ entries: [DirectoryEntry], color: Bool) -> String {
        let width = entries.map { plain($0.info.name).count }.max() ?? 0
        return entries.map { entry in
            let host = entry.endpoint.host ?? entry.endpoint.absoluteString
            return trim([pad(plain(entry.info.name), width), mark(entry.info.status, color: color), dim(host, color)])
        }.joined(separator: "\n")
    }

    public static func searchJSON(_ entries: [DirectoryEntry]) throws -> String {
        try json(SearchResult(spaces: entries.map { Snapshot(endpoint: $0.endpoint, info: $0.info) }))
    }

    /// Waybar's `text`, `tooltip`, `class` and `alt` contract; the tooltip is Pango markup.
    public static func waybar(_ snapshot: Snapshot) throws -> String {
        let tooltip = plain(snapshot.message ?? snapshot.error ?? snapshot.endpoint)
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return try json(Waybar(text: "\(label(snapshot)): \(snapshot.status.rawValue)", tooltip: tooltip,
                              class: snapshot.failed ? "error" : snapshot.status.rawValue,
                              alt: snapshot.status.rawValue))
    }

    /// `-q`: 0 when every space is open, 2 when any state is unknown, 1 otherwise.
    public static func exitCode(_ snapshots: [Snapshot]) -> Int32 {
        if snapshots.contains(where: { $0.status == .unknown }) { return 2 }
        return snapshots.allSatisfy { $0.status == .open } ? 0 : 1
    }

    public static func elapsed(since date: Date, now: Date) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(date) / 60))
        switch minutes {
        case ..<1: return "<1 min"
        case ..<60: return "\(minutes) min"
        case ..<(48 * 60): return "\(minutes / 60) h"
        default: return "\(minutes / (24 * 60)) days"
        }
    }

    private static func label(_ snapshot: Snapshot) -> String {
        plain(snapshot.name ?? URL(string: snapshot.endpoint)?.host ?? snapshot.endpoint)
    }

    private static func mark(_ status: SpaceStatus, color: Bool) -> String {
        let text: String
        let code: String
        switch status {
        case .open: (text, code) = ("● open   ", "32")
        case .closed: (text, code) = ("○ closed ", "31")
        case .unknown: (text, code) = ("? unknown", "2")
        }
        return color ? "\u{1B}[\(code)m\(text)\u{1B}[0m" : text
    }

    private static func dim(_ text: String, _ color: Bool) -> String {
        color ? "\u{1B}[2m\(text)\u{1B}[0m" : text
    }

    private static func pad(_ text: String, _ width: Int) -> String {
        text + String(repeating: " ", count: max(0, width - text.count))
    }

    private static func trim(_ columns: [String]) -> String {
        var line = columns.joined(separator: "  ")
        while line.last == " " { line.removeLast() }
        return line
    }
}
