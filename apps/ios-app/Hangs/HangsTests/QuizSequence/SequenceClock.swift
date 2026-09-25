//
//  SequenceClock.swift
//  HangsTests
//
//  #186 step 2 — `TestClock` semantics at a price thousands of sequences can
//  pay. `TestClock.advance` runs `Task.megaYield()` (twenty detached tasks)
//  around every sleeper it wakes, and a sequence wakes thousands of them (every
//  countdown ticks once a second), which cost ~0.5 s per sequence. Here every
//  job already runs on the one main serial executor (MainSerialExecutorBootstrap),
//  so the owner's `settle` (plain `Task.yield()`s until nothing moves) lets
//  each woken chain run to its next wait, in deadline order, before time moves
//  on. Still deterministic: the serial executor makes every yield's outcome a
//  function of the inputs alone.
//

import Foundation
import os

nonisolated final class SequenceClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration

        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private struct Sleeper {
        let id: Int
        let deadline: Instant
        let continuation: CheckedContinuation<Void, Error>
    }

    private struct State {
        var now = Instant(offset: .zero)
        var nextId = 0
        var sleepers: [Sleeper] = []
        var cancelledEarly: Set<Int> = []
        var ended = 0
    }

    private let state = OSAllocatedUnfairLock<State>(uncheckedState: State())

    /// Run after each wake-up until the woken chain has parked again. The
    /// default is a fixed handful of turns; the sequence run installs one that
    /// stops as soon as nothing moves.
    @MainActor var settle: @MainActor () async -> Void = {
        for _ in 0 ..< 12 {
            await Task.yield()
        }
    }

    /// Sleeps started + sleeps that ended (woken, cancelled or already due) —
    /// part of the run's "did anything move" fingerprint.
    var sleepCount: Int { state.withLockUnchecked { $0.nextId + $0.ended } }

    init() {}

    var now: Instant { state.withLockUnchecked { $0.now } }
    var minimumResolution: Duration { .zero }

    func sleep(until deadline: Instant, tolerance _: Duration?) async throws {
        try Task.checkCancellation()
        let id = state.withLockUnchecked { state in
            state.nextId += 1
            return state.nextId
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let outcome: Result<Void, Error>? = state.withLockUnchecked { state in
                    if state.cancelledEarly.remove(id) != nil { state.ended += 1; return .failure(CancellationError()) }
                    if deadline <= state.now { state.ended += 1; return .success(()) }
                    state.sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
                    return nil
                }
                if let outcome { continuation.resume(with: outcome) }
            }
        } onCancel: {
            let continuation: CheckedContinuation<Void, Error>? = state.withLockUnchecked { state in
                guard let index = state.sleepers.firstIndex(where: { $0.id == id }) else {
                    state.cancelledEarly.insert(id)
                    return nil
                }
                state.ended += 1
                return state.sleepers.remove(at: index).continuation
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    /// Move time forward, waking every sleeper due by then in deadline order
    /// (ties in the order they went to sleep), each one settled before the
    /// next. The caller has let everything before this moment settle already.
    @MainActor
    func advance(by duration: Duration) async {
        let target = now.advanced(by: duration)
        while true {
            let due: Sleeper? = state.withLockUnchecked { state in
                guard let index = state.sleepers.indices.min(by: { lhs, rhs in
                    let a = state.sleepers[lhs], b = state.sleepers[rhs]
                    return a.deadline == b.deadline ? a.id < b.id : a.deadline < b.deadline
                }), state.sleepers[index].deadline <= target else {
                    state.now = target
                    return nil
                }
                let sleeper = state.sleepers.remove(at: index)
                state.ended += 1
                if state.now < sleeper.deadline { state.now = sleeper.deadline }
                return sleeper
            }
            guard let due else { break }
            due.continuation.resume()
            await settle()
        }
    }
}
