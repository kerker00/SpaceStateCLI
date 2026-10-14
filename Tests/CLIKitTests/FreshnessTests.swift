import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpaceAPI
import Synchronization
import Testing
@testable import CLIKit

private final class FreshnessClock: Sendable {
    private let storage: Mutex<Date>
    init(_ seconds: TimeInterval = 1000) { storage = Mutex(Date(timeIntervalSince1970: seconds)) }
    var date: Date {
        get { storage.withLock { $0 } }
        set { storage.withLock { $0 = newValue } }
    }
}

struct FreshnessTests {
    private let endpoint = URL(string: "https://space.example/api")!
    private let directory = URL(string: "https://directory.example/api")!
    private let date = Date(timeIntervalSince1970: 1000)
    private let body = Data(#"[{"url":"https://space.example/api","lastSeen":990,"data":{"space":"A","state":{"open":true}}}]"#.utf8)

    private func info() -> SpaceInfo {
        SpaceInfo(name: "A", state: .init(open: true, lastChange: Date(timeIntervalSince1970: 1), message: "Guests welcome", triggerPerson: nil))
    }
    private func snapshot() -> Snapshot {
        let timing = ObservationTiming(source: .spacePush, observedAt: Date(timeIntervalSince1970: 900),
                                       receivedAt: date, maximumAge: 200)
        return Snapshot(Target(endpoint: endpoint, name: nil), observation: StatusObservation(value: info(), timing: timing),
                        attemptedAt: Date(timeIntervalSince1970: 980), now: date)
    }
    private func loader(age: String = "200") -> StatusClient.Loader {
        let body = body
        return { request in
            (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["X-SpacePush-Max-Data-Age": age])!)
        }
    }
    private func file() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "spacestate-c01-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appending(path: "directory.json")
    }
    private func object(_ snapshot: Snapshot) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(Output.json(snapshot).utf8)) as? [String: Any])
    }

    @Test func missingDirectoryTimeIsNotReplacedWithTheClientClock() throws {
        let entry = DirectoryEntry(endpoint: endpoint, info: info(), lastSeen: nil)
        let value = Snapshot(entry, now: date)
        #expect(value.checkedAt == nil)
        #expect(value.status == .unknown)
        #expect(value.reportedStatus == .open)
        #expect(value.freshness == .unknown)
        #expect(!value.failed)
        let json = try object(value)
        #expect(json["checkedAt"] == nil)
        #expect(json["expiresAt"] == nil)
        #expect(json["attemptedAt"] != nil)
        #expect(json["receivedAt"] != nil)
    }

    @Test func expiredFutureAndUnreachableEntriesDoNotCountAsOpenOrClosed() {
        let entries = [
            DirectoryEntry(endpoint: endpoint, info: info(), lastSeen: Date(timeIntervalSince1970: 99)),
            DirectoryEntry(endpoint: endpoint, info: info(), lastSeen: Date(timeIntervalSince1970: 1001)),
            DirectoryEntry(endpoint: endpoint, info: info(), lastSeen: Date(timeIntervalSince1970: 990), reachable: false),
        ]
        let values = entries.map { Snapshot($0, now: date) }
        #expect(values.allSatisfy { $0.status == .unknown })
        #expect(values.filter { $0.status == .open }.isEmpty)
        #expect(Output.exitCode(values) == 2)
        #expect(values.allSatisfy { !$0.failed })
    }

    @Test func observationReceiptAttemptAndStateChangeStaySeparate() {
        let value = snapshot()
        #expect(value.checkedAt == Date(timeIntervalSince1970: 900))
        #expect(value.receivedAt == date)
        #expect(value.attemptedAt == Date(timeIntervalSince1970: 980))
        #expect(value.expiresAt == Date(timeIntervalSince1970: 1100))
        #expect(value.since == Date(timeIntervalSince1970: 1))
        #expect(value.status == .open)
    }

    @Test func expiryChangesJSONTextQuietAndWaybarWithoutRestampingTimes() throws {
        let value = snapshot().evaluated(at: Date(timeIntervalSince1970: 1100))
        #expect(value.freshness == .stale)
        #expect(value.status == .unknown)
        #expect(value.checkedAt == snapshot().checkedAt)
        #expect(value.attemptedAt == snapshot().attemptedAt)
        let json = try object(value)
        #expect(json["status"] as? String == "unknown")
        #expect(json["freshness"] as? String == "stale")
        #expect(json["reportedStatus"] as? String == "open")
        #expect(json["error"] == nil)
        let text = Output.table([value], color: false, now: Date(timeIntervalSince1970: 1100))
        #expect(text.contains("stale observation; last known open"))
        #expect(!text.contains("Guests welcome"))
        #expect(!text.contains("for "))
        #expect(Output.exitCode([value]) == 2)
        let waybar = try #require(JSONSerialization.jsonObject(with: Data(Output.waybar(value, now: Date(timeIntervalSince1970: 1100)).utf8)) as? [String: Any])
        #expect(waybar["class"] as? String == "unknown")
        #expect((waybar["tooltip"] as? String)?.contains("stale observation") == true)
    }

    @Test func unusableDatesAreOmittedInsteadOfBreakingJSONOrDurationOutput() throws {
        var information = info()
        information.state?.lastChange = Date(timeIntervalSince1970: 1e300)
        for time: TimeInterval in [.nan, 1e300, 1001] {
            let timing = ObservationTiming(source: .aggregator, observedAt: Date(timeIntervalSince1970: time), receivedAt: date)
            let value = Snapshot(Target(endpoint: endpoint, name: nil), observation: StatusObservation(value: information, timing: timing), now: date)
            let json = try object(value)
            #expect(json["checkedAt"] == nil)
            #expect(json["since"] == nil)
            #expect(json["status"] as? String == "unknown")
            #expect(Output.table([value], color: false, now: date).contains("unknown"))
        }
    }

    @Test func cacheReusePreservesReceiptPolicyAndOriginalLastSeen() async throws {
        let cache = try file(); defer { try? FileManager.default.removeItem(at: cache.deletingLastPathComponent()) }
        let clock = FreshnessClock()
        _ = try await DirectoryLoader.loadDocument(from: directory, cache: cache, maxAge: 3600, now: { clock.date }, load: loader())
        clock.date = Date(timeIntervalSince1970: 1100)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1e9)], ofItemAtPath: cache.path)
        let calls = Mutex(0)
        let read: StatusClient.Loader = { _ in calls.withLock { $0 += 1 }; throw URLError(.cannotConnectToHost) }
        let reused = try await DirectoryLoader.loadDocument(from: directory, cache: cache, maxAge: 3600, now: { clock.date }, load: read)
        #expect(reused.receivedAt == date)
        #expect(reused.attemptedAt == clock.date)
        #expect(reused.maximumObservationAge == 200)
        #expect(reused.snapshots(at: clock.date)[0].checkedAt == Date(timeIntervalSince1970: 990))
        clock.date = Date(timeIntervalSince1970: 1200)
        let stale = try await DirectoryLoader.loadDocument(from: directory, cache: cache, maxAge: 3600, now: { clock.date }, load: read)
        #expect(stale.snapshots(at: clock.date)[0].status == .unknown)
        #expect(stale.snapshots(at: clock.date)[0].freshness == .stale)
        #expect(calls.withLock { $0 } == 0)
    }

    @Test func failedRefreshUsesNamesWithoutCurrentFlagsOrCacheRewrite() async throws {
        let cache = try file(); defer { try? FileManager.default.removeItem(at: cache.deletingLastPathComponent()) }
        let clock = FreshnessClock()
        _ = try await DirectoryLoader.loadDocument(from: directory, cache: cache, maxAge: 3600, now: { clock.date }, load: loader())
        let original = try Data(contentsOf: cache)
        clock.date = Date(timeIntervalSince1970: 5000)
        let fallback = try await DirectoryLoader.loadDocument(from: directory, cache: cache, maxAge: 3600, now: { clock.date }, load: { _ in throw URLError(.cannotConnectToHost) })
        let value = fallback.snapshots(at: clock.date)[0]
        #expect(value.name == "A")
        #expect(value.status == .unknown)
        #expect(value.failed)
        #expect(value.checkedAt == Date(timeIntervalSince1970: 990))
        #expect(value.receivedAt == date)
        #expect(value.attemptedAt == clock.date)
        #expect(try Data(contentsOf: cache) == original)
    }

    @Test func futureCacheReceiptForcesARefreshAndRemainsUnprovenOnFailure() async throws {
        let cache = try file(); defer { try? FileManager.default.removeItem(at: cache.deletingLastPathComponent()) }
        let clock = FreshnessClock()
        _ = try await DirectoryLoader.loadDocument(from: directory, cache: cache, maxAge: 3600, now: { clock.date }, load: loader())
        clock.date = Date(timeIntervalSince1970: 999)
        let calls = Mutex(0)
        let result = try await DirectoryLoader.loadDocument(from: directory, cache: cache, maxAge: 3600, now: { clock.date }, load: { _ in
            calls.withLock { $0 += 1 }; throw URLError(.cannotConnectToHost)
        })
        #expect(calls.withLock { $0 } == 1)
        #expect(result.snapshots(at: clock.date)[0].status == .unknown)
        #expect(result.snapshots(at: clock.date)[0].freshness == .unknown)
    }

    @Test func cancellationNeverUsesTheStaleCacheFallback() async throws {
        let cache = try file(); defer { try? FileManager.default.removeItem(at: cache.deletingLastPathComponent()) }
        let clock = FreshnessClock()
        _ = try await DirectoryLoader.loadDocument(from: directory, cache: cache, maxAge: 3600, now: { clock.date }, load: loader())
        clock.date = Date(timeIntervalSince1970: 5000)
        await #expect(throws: CancellationError.self) {
            try await DirectoryLoader.loadDocument(from: directory, cache: cache, maxAge: 3600, now: { clock.date }, load: { _ in throw CancellationError() })
        }
    }

    @Test func legacyCacheIsReadableAndNewCacheCannotCrossDirectorySources() async throws {
        let cache = try file(); defer { try? FileManager.default.removeItem(at: cache.deletingLastPathComponent()) }
        let clock = FreshnessClock()
        try body.write(to: cache)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: cache.path)
        let legacy = try await DirectoryLoader.loadDocument(from: directory, cache: cache, maxAge: 3600, now: { clock.date }, load: { _ in throw URLError(.cannotConnectToHost) })
        #expect(legacy.snapshots(at: date)[0].status == .open)
        #expect(legacy.receivedAt == date)
        _ = try await DirectoryLoader.loadDocument(from: directory, cache: cache, maxAge: nil, now: { clock.date }, load: loader())
        await #expect(throws: URLError.self) {
            try await DirectoryLoader.loadDocument(from: URL(string: "https://other-directory.example/api")!, cache: cache,
                maxAge: 3600, now: { clock.date }, load: { _ in throw URLError(.cannotConnectToHost) })
        }
    }

    @Test func malformedDirectoryPolicyNeverBecomesFreshByDefault() async throws {
        let clock = FreshnessClock()
        for policy in ["invalid", "0", "-1"] {
            let result = try await DirectoryLoader.loadDocument(from: directory, cache: nil, maxAge: nil,
                now: { clock.date }, load: loader(age: policy))
            #expect(result.snapshots(at: date)[0].status == .unknown)
            #expect(result.snapshots(at: date)[0].freshness == .unknown)
            #expect(result.error == nil)
        }
    }

    @Test func productionWatchLoopEmitsExpiryWithoutFetchingOrCountingACheck() async throws {
        let clock = FreshnessClock()
        let calls = Mutex(0)
        let frames = Mutex<[(Snapshot, Bool)]>([])
        let waits = Mutex<[Duration]>([])
        let target = Target(endpoint: endpoint, name: nil)
        let information = info()
        try await WatchLoop.run(interval: 3600, count: 2, fetch: {
            calls.withLock { $0 += 1 }
            return [Snapshot(target, info: information, now: clock.date)]
        }, now: { clock.date }, wait: { duration in
            waits.withLock { $0.append(duration) }
            clock.date = clock.date.addingTimeInterval(TimeInterval(duration.components.seconds))
        }, emit: { snapshots, initial in frames.withLock { $0 += snapshots.map { ($0, initial) } } })
        let records = frames.withLock { $0 }
        #expect(calls.withLock { $0 } == 2)
        #expect(waits.withLock { $0 } == [.seconds(900), .seconds(2700)])
        #expect(records.map { $0.0.status } == [.open, .unknown, .open])
        #expect(records.map { $0.1 } == [true, false, false])
        #expect(records[1].0.freshness == .stale)
        #expect(records[1].0.checkedAt == records[0].0.checkedAt)
        #expect(records[1].0.attemptedAt == records[0].0.attemptedAt)
    }

    @Test func failedWatchCheckKeepsLastKnownValueAndOriginalEvidence() {
        var state = WatchState()
        _ = state.record([snapshot()])
        let failure = Snapshot(Target(endpoint: endpoint, name: nil), info: nil, error: "offline", now: Date(timeIntervalSince1970: 1200))
        let retained = state.record([failure])[0]
        #expect(retained.status == .unknown)
        #expect(retained.freshness == .stale)
        #expect(retained.reportedStatus == .open)
        #expect(retained.info?.name == "A")
        #expect(retained.checkedAt == Date(timeIntervalSince1970: 900))
        #expect(retained.receivedAt == date)
        #expect(retained.attemptedAt == failure.attemptedAt)
        #expect(retained.error == "offline")
    }

    @Test func alreadyPassedExpiryWakesImmediatelyAndCancellationStopsTheLoop() async throws {
        let value = snapshot()
        let expired = Date(timeIntervalSince1970: 1200)
        #expect(WatchState.nextWake([value], after: expired, pollAt: Date(timeIntervalSince1970: 4000)) == expired)
        let calls = Mutex(0)
        await #expect(throws: CancellationError.self) {
            try await WatchLoop.run(interval: 3600, count: nil, fetch: { calls.withLock { $0 += 1 }; return [value] },
                now: { date }, wait: { _ in throw CancellationError() }, emit: { _, _ in })
        }
        #expect(calls.withLock { $0 } == 1)
    }

    @Test func delayedWakePublishesExpiredDataBeforeTheNextNetworkCheck() async throws {
        let clock = FreshnessClock()
        let calls = Mutex(0)
        let frames = Mutex<[Snapshot]>([])
        let target = Target(endpoint: endpoint, name: nil)
        let information = info()
        try await WatchLoop.run(interval: 3600, count: 2, fetch: {
            let check = calls.withLock { $0 += 1; return $0 }
            if check == 2 { #expect(frames.withLock { $0.last?.status } == .unknown) }
            return [Snapshot(target, info: information, now: clock.date)]
        }, now: { clock.date }, wait: { _ in clock.date = Date(timeIntervalSince1970: 5000) },
        emit: { snapshots, _ in frames.withLock { $0 += snapshots } })
        #expect(frames.withLock { $0.map(\.status) } == [.open, .unknown, .open])
        #expect(calls.withLock { $0 } == 2)
    }
}
