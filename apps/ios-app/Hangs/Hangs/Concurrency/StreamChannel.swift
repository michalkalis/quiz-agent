//
//  StreamChannel.swift
//  Hangs
//
//  A re-acquirable single-consumer event channel built on `AsyncStream`.
//
//  WHY THIS TYPE EXISTS — the dead-voice-commands bug (P0, #77 saga):
//  The previous design stored ONE `AsyncStream` + its continuation for the
//  lifetime of the producer, and every consumer re-iterated that SAME stream on
//  each listening-window re-arm (TTS start, recording start, Home onAppear).
//  Cancelling a task that is suspended in `for await` over an `AsyncStream`
//  permanently finishes that stream's storage — so the FIRST re-arm (seconds
//  into any session) cancelled the prior consumer, which finished the one shared
//  stream, and every later consumer iterated a dead stream and received an
//  immediate `nil`. No transcript ever reached the matcher again: voice commands
//  silently did nothing for the rest of the session.
//
//  INVARIANT this type guarantees:
//  Consumers may re-acquire a stream arbitrarily often. Acquiring a new stream
//  finishes the previous one (a replaced/stale consumer must observe end-of-
//  stream, never linger), but cancelling that old consumer must NEVER affect a
//  newly acquired stream. Each `makeStream()` mints a FRESH `AsyncStream` with
//  its own storage, so the cancellation of an old consumer can only terminate
//  the old storage — the current consumer's stream is untouched. This is the
//  exact bug class that killed voice commands; any change here must keep it.
//

import Foundation
import os

/// Owns the current continuation for a re-acquirable `AsyncStream`. Lock-based
/// and `nonisolated` (the target defaults to MainActor isolation) so the
/// producer's nonisolated `deinit` can `finish()` it and audio-thread callers
/// could yield without an actor hop.
nonisolated final class StreamChannel<Element: Sendable>: Sendable {
    private let current = OSAllocatedUnfairLock<AsyncStream<Element>.Continuation?>(initialState: nil)

    init() {}

    /// Mint a FRESH stream for a new consumer, finishing the previous one first.
    ///
    /// Finishing the prior continuation guarantees a replaced consumer sees
    /// end-of-stream and its `for await` exits cleanly. Because the returned
    /// stream has its own storage, a later cancellation of an OLD consumer cannot
    /// starve this one — the property that the single-stored-stream design broke.
    func makeStream() -> AsyncStream<Element> {
        let (stream, continuation) = AsyncStream<Element>.makeStream()
        let previous = current.withLock { state in
            let prev = state
            state = continuation
            return prev
        }
        previous?.finish()
        return stream
    }

    /// Forward an element to the current consumer's stream. No-op when no stream
    /// has been acquired (or after `finish()`): a value produced with no live
    /// consumer is dropped rather than buffered into a stream nobody will drain.
    func yield(_ element: Element) {
        current.withLock { $0 }?.yield(element)
    }

    /// Finish the current stream and drop the continuation. Called from the
    /// producer's `deinit` so any in-flight consumer terminates.
    func finish() {
        let previous = current.withLock { state in
            let prev = state
            state = nil
            return prev
        }
        previous?.finish()
    }
}

/// Opaque in `dump`/Mirror-based snapshots: whether a continuation currently
/// exists is LIVE runtime state (it flips whenever a consumer re-arms), and the
/// `.dump` view-model baselines must not encode it — nor the OS lock internals.
extension StreamChannel: CustomReflectable {
    var customMirror: Mirror { Mirror(self, children: []) }
}
