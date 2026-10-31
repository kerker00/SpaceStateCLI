import Foundation
import Synchronization
import Testing
import SpaceAPI
@testable import CLIKit

struct PushWatchTests {
    private let target = Target(endpoint: URL(string: "https://a.example/spaceapi.json")!, name: "A")

    @Test func pushEventChecksBeforeTheIntervalEnds() async throws {
        let calls = Mutex(0)
        let waits = Mutex<[Duration]>([])
        let wake = PushWake()
        let target = self.target
        try await WatchLoop.run(interval: 3600, count: 2, fetch: {
            calls.withLock { $0 += 1 }
            return [Snapshot(target, info: nil, error: "offline", now: Date(timeIntervalSince1970: 0))]
        }, now: { Date(timeIntervalSince1970: 0) }, wait: { duration in
            waits.withLock { $0.append(duration) }
            wake.signal()
        }, pollNow: { wake.consume() }, emit: { _, _ in })
        #expect(calls.withLock { $0 } == 2)
        // One wait, ended by the push event, instead of an hour of time passing.
        #expect(waits.withLock { $0 } == [.seconds(3600)])
    }

    @Test func signalBeforeWaitReturnsAtOnce() async throws {
        let wake = PushWake()
        wake.signal()
        let clock = ContinuousClock()
        let start = clock.now
        try await wake.wait(.seconds(60))
        #expect(clock.now - start < .seconds(5))
        #expect(wake.consume())
        #expect(!wake.consume())
    }

    @Test func signalEndsARunningWait() async throws {
        let wake = PushWake()
        let waiting = Task { try await wake.wait(.seconds(60)) }
        try await Task.sleep(for: .milliseconds(50))
        wake.signal()
        try await waiting.value
        #expect(wake.consume())
    }

    @Test func waitWithoutSignalSleepsAndCancelStopsIt() async throws {
        let wake = PushWake()
        try await wake.wait(.milliseconds(10))
        #expect(!wake.consume())
        let waiting = Task { try await wake.wait(.seconds(60)) }
        waiting.cancel()
        await #expect(throws: CancellationError.self) { try await waiting.value }
    }
}
