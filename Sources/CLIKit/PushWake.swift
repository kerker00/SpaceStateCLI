import Foundation
import Synchronization

/// Ends a watch's wait early when a push event arrives. A signal that arrives
/// while nobody waits is kept, so the next wait returns at once.
public final class PushWake: Sendable {
    private struct State {
        var pending = false
        var waiter: (id: Int, continuation: CheckedContinuation<Void, Never>)?
        var cancelled: Set<Int> = []
        var nextID = 0
    }

    private let state = Mutex(State())

    public init() {}

    public func signal() {
        let waiter = state.withLock { state in
            state.pending = true
            defer { state.waiter = nil }
            return state.waiter?.continuation
        }
        waiter?.resume()
    }

    /// Whether a signal arrived since the last call; clears it.
    public func consume() -> Bool {
        state.withLock { state in
            defer { state.pending = false }
            return state.pending
        }
    }

    /// Sleeps for `duration` or until a signal, whichever comes first.
    public func wait(_ duration: Duration) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await Task.sleep(for: duration) }
            group.addTask { await self.signalled() }
            defer { group.cancelAll() }
            try await group.next()
        }
        // A cancelled wait can end through the signal child; it must still report cancellation.
        try Task.checkCancellation()
    }

    private func signalled() async {
        let id = state.withLock { state in
            state.nextID += 1
            return state.nextID
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let resumeNow = state.withLock { state in
                    if state.pending || state.cancelled.remove(id) != nil { return true }
                    state.waiter = (id, continuation)
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        } onCancel: {
            let waiter = state.withLock { state -> CheckedContinuation<Void, Never>? in
                if let waiter = state.waiter, waiter.id == id {
                    state.waiter = nil
                    return waiter.continuation
                }
                state.cancelled.insert(id)
                return nil
            }
            waiter?.resume()
        }
    }
}
