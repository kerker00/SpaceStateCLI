import Foundation
import Synchronization
import Testing
import SpaceAPI
import SpacePushClient
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

struct DesktopNotificationTests {
    private func change(_ kind: StateChange.Kind, to: String?) -> StateChange {
        StateChange(kind: kind, endpoint: URL(string: "https://a.example/")!, room: "space", name: "A\u{1B}[31m",
                    from: to == nil ? nil : "closed", to: to, at: Date(timeIntervalSince1970: 0))
    }

    @Test func describesChangesAndTests() {
        #expect(DesktopNotification.text(change(.change, to: "open")) == ("A [31m", "Open"))
        #expect(DesktopNotification.text(change(.change, to: "keyholder")).body == "Keyholder present")
        #expect(DesktopNotification.text(change(.test, to: nil)).body.hasPrefix("Test notification"))
        #expect(DesktopNotification.description("future_state") == "future_state")
    }

    @Test func buildsNotifySendArguments() {
        #expect(DesktopNotification.arguments(summary: "-A", body: "Open", replacing: nil)
            == ["--app-name=SpaceState", "--print-id", "--", "-A", "Open"])
        #expect(DesktopNotification.arguments(summary: "A", body: "Closed", replacing: 42)
            == ["--app-name=SpaceState", "--print-id", "--replace-id=42", "--", "A", "Closed"])
        #expect(DesktopNotification.id(fromOutput: "17\n") == 17)
        #expect(DesktopNotification.id(fromOutput: "") == nil)
    }

    @Test func subscribesToTheSpaceItself() {
        let target = Target(endpoint: URL(string: "https://a.example/")!, name: "A")
        #expect(DesktopNotification.subscriptions([target]) == [PushSubscription(endpoint: target.endpoint)])
    }
}
