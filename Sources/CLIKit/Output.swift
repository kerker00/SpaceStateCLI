import Foundation
import SpaceAPI
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// What a space looks like right now; the JSON of `show`, `search` and `watch`.
public struct Snapshot: Encodable, Sendable {
    public let endpoint: URL
    public let name: String?
    public var status: SpaceStatus {
        error == nil && freshness == .current ? reportedStatus : .unknown
    }
    public let reportedStatus: SpaceStatus
    public let message: String?
    /// When the space says its state last changed.
    public let since: Date?
    /// Original successful observation, never synthesized for missing lastSeen.
    public var checkedAt: Date? {
        guard let timing, let observed = Self.date(timing.observedAt), observed <= timing.receivedAt else { return nil }
        return observed
    }
    public let attemptedAt: Date
    public var receivedAt: Date? { Self.date(timing?.receivedAt) }
    public var expiresAt: Date? { Self.date(timing?.expiresAt) }
    public var source: ObservationSource? { timing?.source }
    public var freshness: ObservationFreshness {
        guard checkedAt != nil, receivedAt != nil, expiresAt != nil else { return .unknown }
        return timing?.freshness(at: evaluatedAt) ?? .unknown
    }
    public let error: String?
    /// The whole document, for `info`; not part of the JSON.
    public let info: SpaceInfo?
    public let sensors: SensorOutput?
    private let timing: ObservationTiming?
    private var evaluatedAt: Date
    var evaluationDate: Date { evaluatedAt }

    private enum CodingKeys: String, CodingKey {
        case endpoint, name, status, reportedStatus, message, since, checkedAt, attemptedAt, receivedAt, expiresAt, source, freshness, error, sensors
    }

    /// Falls back to the target's known name when the space cannot be reached.
    public init(_ target: Target, info: SpaceInfo?, error: String? = nil, now: Date = Date()) {
        self.init(target, info: info, timing: info.map { _ in
            ObservationTiming(source: .direct, observedAt: now, receivedAt: now)
        }, error: error, attemptedAt: now, now: now)
    }

    public init(_ target: Target, observation: StatusObservation<SpaceInfo>, attemptedAt: Date? = nil, now: Date = Date()) {
        self.init(target, info: observation.value, timing: observation.timing,
                  error: nil, attemptedAt: attemptedAt ?? now, now: now)
    }

    private init(_ target: Target, info: SpaceInfo?, timing: ObservationTiming?, error: String?, attemptedAt: Date, now: Date) {
        endpoint = target.endpoint
        name = info?.name ?? target.name
        reportedStatus = info?.status ?? .unknown
        message = info?.state?.message
        since = Self.date(info?.state?.lastChange).flatMap { $0 <= now ? $0 : nil }
        self.timing = timing
        self.attemptedAt = attemptedAt
        evaluatedAt = now
        self.error = error ?? (info == nil ? "no answer" : nil)
        self.info = info
        sensors = info.flatMap { SensorOutput($0.sensors) }
    }

    /// A directory entry carries the state the aggregator saw when it last reached the space.
    public init(_ entry: DirectoryEntry, now: Date = Date()) {
        self.init(entry, receivedAt: now, attemptedAt: now, now: now)
    }

    public init(_ entry: DirectoryEntry, receivedAt: Date?, maximumAge: TimeInterval = ObservationTiming.defaultMaximumAge,
                error: String? = nil, attemptedAt: Date, now: Date = Date()) {
        self.init(Target(entry), info: entry.info, timing: receivedAt.map {
            ObservationTiming(source: .aggregator, observedAt: entry.lastSeen, receivedAt: $0,
                maximumAge: maximumAge, sourceReachable: entry.reachable)
        }, error: error, attemptedAt: attemptedAt, now: now)
    }

    public func evaluated(at date: Date) -> Snapshot {
        var copy = self
        copy.evaluatedAt = date
        return copy
    }

    public func failedAttempt(at date: Date, error: String) -> Snapshot {
        Snapshot(Target(endpoint: endpoint, name: name), info: info, timing: timing,
                 error: error, attemptedAt: date, now: date)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(endpoint, forKey: .endpoint)
        try values.encodeIfPresent(name, forKey: .name)
        try values.encode(status, forKey: .status)
        try values.encode(reportedStatus, forKey: .reportedStatus)
        try values.encodeIfPresent(message, forKey: .message)
        try values.encodeIfPresent(since, forKey: .since)
        try values.encodeIfPresent(checkedAt, forKey: .checkedAt)
        try values.encode(attemptedAt, forKey: .attemptedAt)
        try values.encodeIfPresent(receivedAt, forKey: .receivedAt)
        try values.encodeIfPresent(expiresAt, forKey: .expiresAt)
        try values.encodeIfPresent(source?.rawValue, forKey: .source)
        try values.encode(freshness.rawValue, forKey: .freshness)
        try values.encodeIfPresent(error, forKey: .error)
        try values.encodeIfPresent(sensors, forKey: .sensors)
    }

    public var failed: Bool { error != nil }

    var sensorSummary: String? {
        error == nil && freshness == .current ? sensors?.compact : nil
    }

    private static func date(_ date: Date?) -> Date? {
        guard let date, date.timeIntervalSince1970.isFinite,
              (0...253_402_300_799).contains(date.timeIntervalSince1970) else { return nil }
        return date
    }
}

/// Colors only when stdout is a terminal, honouring `NO_COLOR` and `TERM=dumb`.
public func terminalSupportsColor(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
    isatty(STDOUT_FILENO) != 0 && (environment["NO_COLOR"] ?? "").isEmpty && environment["TERM"] != "dumb"
}

public enum Output {
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

    /// One aligned line per space: name, state, duration, message/error and current compact sensors.
    public static func table(_ snapshots: [Snapshot], color: Bool, now: Date = Date(), includeSensors: Bool = true) -> String {
        let width = snapshots.map { label($0).count }.max() ?? 0
        return snapshots.map { snapshot in
            let snapshot = snapshot.evaluated(at: now)
            let since = snapshot.status == .unknown ? "" : snapshot.since.map { "for \(elapsed(since: $0, now: now))" } ?? ""
            let detail = detail(snapshot, includeSensors: includeSensors)
            return trim([pad(label(snapshot), width), mark(snapshot.status, color: color), pad(since, 10), plain(detail)])
        }.joined(separator: "\n")
    }

    /// A watch line for a space whose state changed, prefixed with the local time.
    public static func change(_ snapshot: Snapshot, color: Bool, now: Date = Date()) -> String {
        let snapshot = snapshot.evaluated(at: now)
        let time = now.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
        let detail = detail(snapshot)
        return trim([time, label(snapshot), mark(snapshot.status, color: color), plain(detail)])
    }

    public static func search(_ entries: [DirectoryEntry], color: Bool) -> String {
        searchSnapshots(entries.map { Snapshot($0) }, color: color)
    }

    public static func searchSnapshots(_ snapshots: [Snapshot], color: Bool, now: Date = Date()) -> String {
        let width = snapshots.map { label($0).count }.max() ?? 0
        return snapshots.map { snapshot in
            let snapshot = snapshot.evaluated(at: now)
            let host = snapshot.endpoint.host ?? snapshot.endpoint.absoluteString
            let age = snapshot.freshness == .current ? "" : detail(snapshot)
            return trim([pad(label(snapshot), width), mark(snapshot.status, color: color), dim(host, color), plain(age)])
        }.joined(separator: "\n")
    }

    public static func searchJSON(_ entries: [DirectoryEntry]) throws -> String {
        try json(entries.map { Snapshot($0) })
    }

    /// Waybar's `text`, `tooltip`, `class` and `alt` contract; the tooltip is Pango markup.
    public static func waybar(_ snapshot: Snapshot, now: Date = Date()) throws -> String {
        let snapshot = snapshot.evaluated(at: now)
        let text = detail(snapshot)
        let tooltip = plain(text.isEmpty ? snapshot.endpoint.absoluteString : text)
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return try json(Waybar(text: "\(label(snapshot)): \(snapshot.status.rawValue)", tooltip: tooltip,
                              class: snapshot.failed ? "error" : snapshot.status.rawValue,
                              alt: snapshot.status.rawValue))
    }

    private static func detail(_ snapshot: Snapshot, includeSensors: Bool = true) -> String {
        if let error = snapshot.error { return "unreachable: \(error)" }
        switch snapshot.freshness {
        case .stale: return "stale observation; last known \(snapshot.reportedStatus.rawValue)"
        case .unknown: return snapshot.info == nil ? "" : "no current observation; last known \(snapshot.reportedStatus.rawValue)"
        case .current:
            return [snapshot.message, includeSensors ? snapshot.sensorSummary : nil]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        }
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
        plain(snapshot.name ?? snapshot.endpoint.host ?? snapshot.endpoint.absoluteString)
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
