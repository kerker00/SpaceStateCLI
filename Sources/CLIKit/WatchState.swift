import Foundation

/// Last successful values stay available on a failed check, without redating the
/// source evidence or keeping the old open/closed value current.
public struct WatchState: Sendable {
    private var successful: [URL: Snapshot] = [:]
    public init() {}

    public mutating func record(_ results: [Snapshot]) -> [Snapshot] {
        results.map { result in
            if let error = result.error, let previous = successful[result.endpoint] {
                return previous.failedAttempt(at: result.attemptedAt, error: error).evaluated(at: result.evaluationDate)
            }
            if result.error == nil, result.info != nil { successful[result.endpoint] = result }
            return result
        }
    }

    /// A wake at an expiry does not count as a network check or move its deadline.
    public static func nextWake(_ snapshots: [Snapshot], after date: Date, pollAt: Date) -> Date {
        if snapshots.contains(where: { changed($0, $0.evaluated(at: date)) }) { return min(date, pollAt) }
        let expiry = snapshots.compactMap(\.expiresAt).filter { $0 > date }.min()
        return min(expiry ?? pollAt, pollAt)
    }

    public static func changed(_ before: Snapshot, _ after: Snapshot) -> Bool {
        before.status != after.status || before.freshness != after.freshness || before.failed != after.failed
    }
}

/// The production watch loop has injected time, waiting and I/O for deterministic
/// tests. Expiry records preserve request times and do not consume the check count.
public enum WatchLoop {
    public static func run(interval: TimeInterval, count: Int?, fetch: () async throws -> [Snapshot],
                           now: () -> Date = { Date() },
                           wait: (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                           emit: ([Snapshot], Bool) throws -> Void) async throws {
        guard interval.isFinite, interval > 0, count.map({ $0 > 0 }) ?? true else {
            throw UsageError("Invalid watch interval or check count")
        }
        var state = WatchState()
        var checks = 0
        while true {
            try Task.checkCancellation()
            var results = state.record(try await fetch()).map { $0.evaluated(at: now()) }
            try emit(results, checks == 0)
            checks += 1
            if let count, checks >= count { return }
            let pollAt = now().addingTimeInterval(interval)
            while true {
                try Task.checkCancellation()
                let evaluatedAt = now()
                let updated = results.map { $0.evaluated(at: evaluatedAt) }
                let changes = zip(results, updated).compactMap { before, after in
                    WatchState.changed(before, after) ? after : nil
                }
                if !changes.isEmpty { try emit(changes, false) }
                results = updated
                // A delayed timer (e.g. system sleep) must publish the expired
                // state before a possibly slow new network check.
                if evaluatedAt >= pollAt { break }
                let wake = WatchState.nextWake(results, after: evaluatedAt, pollAt: pollAt)
                try await wait(.seconds(max(0, wake.timeIntervalSince(evaluatedAt))))
            }
        }
    }
}
