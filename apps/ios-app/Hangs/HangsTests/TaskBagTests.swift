//
//  TaskBagTests.swift
//  HangsTests
//
//  Unit tests for the keyed-Task lifecycle helper.
//

import Foundation
import Testing
@testable import Hangs

@MainActor
struct TaskBagTests {

    // MARK: - Replace-on-same-key

    @Test("Adding under an existing key cancels the previous task")
    func addReplacesAndCancels() async {
        let bag = TaskBag()
        let firstStarted = AsyncFlag()
        let firstCancelled = AsyncFlag()

        let first = Task {
            await firstStarted.signal()
            // Park until cancelled
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            await firstCancelled.signal()
        }
        bag.add(first, key: .answerTimer)

        await firstStarted.wait()
        #expect(bag.contains(.answerTimer))

        // Replace under the same key — first should be cancelled.
        let second = Task { /* no-op */ }
        bag.add(second, key: .answerTimer)

        await firstCancelled.wait()
        await second.value
        #expect(first.isCancelled)
    }

    // MARK: - Cancel single key

    @Test("cancel(key) cancels only the targeted task")
    func cancelSingleKey() async {
        let bag = TaskBag()
        let aCancelled = AsyncFlag()
        let bRan = AsyncFlag()

        let a = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            await aCancelled.signal()
        }
        bag.add(a, key: .answerTimer)

        let b = Task {
            await bRan.signal()
        }
        bag.add(b, key: .autoAdvance)

        bag.cancel(.answerTimer)

        await aCancelled.wait()
        await bRan.wait()
        #expect(a.isCancelled)
        #expect(!bag.contains(.answerTimer))
        #expect(!b.isCancelled)
    }

    // MARK: - Cancel-all

    @Test("cancelAll() cancels every registered task and empties the bag")
    func cancelAllDrains() async {
        let bag = TaskBag()
        let cancellations = AsyncCounter(target: 3)

        for key in [TaskKey.answerTimer, .autoAdvance, .silenceDetection] {
            let t = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 5_000_000)
                }
                await cancellations.tick()
            }
            bag.add(t, key: key)
        }

        #expect(bag.count == 3)
        bag.cancelAll()

        await cancellations.waitForTarget()
        #expect(bag.count == 0)
        #expect(!bag.contains(.answerTimer))
        #expect(!bag.contains(.autoAdvance))
        #expect(!bag.contains(.silenceDetection))
    }

    // MARK: - Idempotency

    @Test("cancel on an absent key is a no-op")
    func cancelAbsentKeyIsNoOp() {
        let bag = TaskBag()
        bag.cancel(.bargeIn)
        #expect(bag.count == 0)
    }

    @Test("cancelAll on an empty bag is a no-op")
    func cancelAllEmptyIsNoOp() {
        let bag = TaskBag()
        bag.cancelAll()
        #expect(bag.count == 0)
    }
}

// MARK: - Test helpers

/// One-shot signal that lets the test wait for a Task to reach a specific point.
private actor AsyncFlag {
    private var continuation: CheckedContinuation<Void, Never>?
    private var signalled = false

    func signal() {
        signalled = true
        continuation?.resume()
        continuation = nil
    }

    func wait() async {
        if signalled { return }
        await withCheckedContinuation { cont in
            continuation = cont
        }
    }
}

/// Waits for `target` ticks to arrive — used when several tasks must each
/// observe cancellation before the assertion runs.
private actor AsyncCounter {
    private let target: Int
    private var current = 0
    private var continuation: CheckedContinuation<Void, Never>?

    init(target: Int) {
        self.target = target
    }

    func tick() {
        current += 1
        if current >= target {
            continuation?.resume()
            continuation = nil
        }
    }

    func waitForTarget() async {
        if current >= target { return }
        await withCheckedContinuation { cont in
            continuation = cont
        }
    }
}
