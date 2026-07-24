//
//  StreamChannelTests.swift
//  HangsTests
//
//  Regression tests for `StreamChannel` — the fix for the dead-voice-commands
//  P0 (#77 saga). See `StreamChannel.swift` for the full bug write-up.
//
//  WHY: voice commands silently stopped working seconds into every session
//  because consumers re-iterated ONE stored `AsyncStream`, and cancelling a
//  prior consumer suspended in `for await` finished that single shared stream —
//  starving every later consumer. The canonical test below (`replacedConsumer…`)
//  encodes exactly that scenario: it FAILS against the old single-stored-stream
//  design and PASSES with `StreamChannel`, which mints a fresh stream per
//  acquisition. `legacySharedStream…` permanently pins the buggy behaviour for
//  contrast so the regression can never quietly return.
//

import Foundation
@testable import Hangs
import Testing

// MARK: - Pump helper

/// Spin the main serial executor until `predicate` holds or the deadline passes.
/// Pumps the producer → AsyncStream → consumer-task hops deterministically
/// enough for assertions without a real clock.
@MainActor
private func waitUntil(
    _ predicate: @MainActor () -> Bool,
    timeoutMillis: Int = 2000,
    _ comment: Comment? = nil,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    let deadline = ContinuousClock.now.advanced(by: .milliseconds(timeoutMillis))
    while ContinuousClock.now < deadline {
        if predicate() { return }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(1))
    }
    if predicate() { return }
    Issue.record(comment ?? "waitUntil timed out after \(timeoutMillis)ms", sourceLocation: sourceLocation)
}

// MARK: - Legacy (buggy) model — reproduces the exact starvation

/// Models the OLD design: a single `AsyncStream` + continuation created once and
/// re-handed to every consumer. Used ONLY to pin the bug in a permanent test so
/// the contrast with `StreamChannel` is explicit and can't silently regress.
@MainActor
private final class LegacySharedStream<Element: Sendable> {
    let stream: AsyncStream<Element>
    private let continuation: AsyncStream<Element>.Continuation

    init() {
        var cont: AsyncStream<Element>.Continuation!
        stream = AsyncStream { cont = $0 }
        continuation = cont
    }

    /// The bug: hands back the SAME stored stream every time.
    func acquire() -> AsyncStream<Element> { stream }
    func yield(_ element: Element) { continuation.yield(element) }
    func finish() { continuation.finish() }
}

// MARK: - Tests

@Suite("StreamChannel — re-acquirable stream (dead-voice-commands fix)")
@MainActor
struct StreamChannelTests {
    /// THE fix: a consumer that acquires a stream AFTER a prior consumer was
    /// cancelled mid-`for await` must still receive yielded values. This is the
    /// dead-voice-commands scenario: the command consumer is re-armed on every
    /// listening window, cancelling the previous one; with the old shared stream
    /// the newly-armed consumer got a dead stream and no transcript ever landed.
    @Test("a consumer acquired after a prior consumer is cancelled still receives yields")
    func replacedConsumerReceivesAfterPriorConsumerCancelled() async {
        let channel = StreamChannel<Int>()

        // Consumer A acquires and suspends in `for await`.
        let streamA = channel.makeStream()
        var aReceived: [Int] = []
        let consumerA = Task { @MainActor in
            for await value in streamA { aReceived.append(value) }
        }
        await Task.yield()

        // Cancel A mid-await — the exact trigger that finished the old shared stream.
        consumerA.cancel()
        _ = await consumerA.value

        // Consumer B acquires a FRESH stream (finishing A's).
        let streamB = channel.makeStream()
        var bReceived: [Int] = []
        let consumerB = Task { @MainActor in
            for await value in streamB { bReceived.append(value) }
        }
        await Task.yield()

        // The value B MUST receive — starved under the old design.
        channel.yield(42)
        await waitUntil({ !bReceived.isEmpty }, "consumer B never received the yield (starved stream = the P0 bug)")

        channel.finish()
        _ = await consumerB.value
        #expect(bReceived == [42])
    }

    /// Permanent proof of the bug the fix removes: the single-stored-stream model
    /// starves consumer B under the identical sequence. If this ever stops
    /// failing to deliver to B, the shared-stream footgun is back in the codebase.
    @Test("legacy single-stored-stream STARVES a consumer acquired after a cancellation (the bug)")
    func legacySharedStreamStarvesReplacedConsumer() async {
        let legacy = LegacySharedStream<Int>()

        let streamA = legacy.acquire()
        let consumerA = Task { @MainActor in
            for await _ in streamA {}
        }
        await Task.yield()
        consumerA.cancel() // finishes the ONE shared stream
        _ = await consumerA.value

        let streamB = legacy.acquire() // same dead stream
        var bReceived: [Int] = []
        let consumerB = Task { @MainActor in
            for await value in streamB { bReceived.append(value) }
        }
        await Task.yield()

        legacy.yield(42)
        // Give B every chance to (not) receive it.
        for _ in 0 ..< 50 { await Task.yield() }
        legacy.finish()
        _ = await consumerB.value

        #expect(bReceived.isEmpty, "legacy shared stream must starve B — that is the dead-voice-commands bug")
    }

    /// A value produced with no live consumer is dropped, never buffered into a
    /// dead stream — and never crashes. Guards the "yield before first acquire"
    /// and "yield after finish" paths.
    @Test("yield with no consumer is a no-op (no crash, no buffering into a dead stream)")
    func yieldWithNoConsumerIsNoOp() async {
        let channel = StreamChannel<Int>()

        channel.yield(1) // before any makeStream() — continuation is nil
        channel.finish()
        channel.yield(2) // after finish() — continuation is nil again

        // Now acquire and confirm the pre-acquisition yields did NOT buffer.
        let stream = channel.makeStream()
        var received: [Int] = []
        let consumer = Task { @MainActor in
            for await value in stream { received.append(value) }
        }
        await Task.yield()
        channel.yield(3)
        await waitUntil({ received == [3] }, "only the post-acquisition value should arrive")
        channel.finish()
        _ = await consumer.value
        #expect(received == [3])
    }

    /// Acquiring a new stream must terminate the previously handed-out stream so
    /// a replaced consumer's `for await` exits cleanly (no lingering listener).
    @Test("acquiring a new stream terminates the prior consumer's stream")
    func acquiringNewStreamTerminatesPriorStream() async {
        let channel = StreamChannel<Int>()

        let first = channel.makeStream()
        var firstExited = false
        let firstConsumer = Task { @MainActor in
            for await _ in first {}
            firstExited = true
        }
        await Task.yield()

        _ = channel.makeStream() // must finish `first`
        await waitUntil({ firstExited }, "prior stream did not terminate on re-acquisition")
        _ = await firstConsumer.value
        #expect(firstExited)
    }
}
