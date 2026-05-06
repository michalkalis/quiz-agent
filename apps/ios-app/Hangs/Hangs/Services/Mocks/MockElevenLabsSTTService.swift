//
//  MockElevenLabsSTTService.swift
//  Hangs
//
//  Mock ElevenLabsSTTService for DEBUG builds (SwiftUI previews, UI-test mode).
//

@preconcurrency import Foundation
import os
import Sentry

#if DEBUG
actor MockElevenLabsSTTService: ElevenLabsSTTServiceProtocol {
    private var eventContinuation: AsyncStream<STTEvent>.Continuation?
    nonisolated let events: AsyncStream<STTEvent>

    var mockCommittedText = "Paris"
    var shouldFail = false

    init() {
        var continuation: AsyncStream<STTEvent>.Continuation!
        self.events = AsyncStream { continuation = $0 }
        self.eventContinuation = continuation
    }

    func connect(token: String, languageCode: String) async throws {
        if shouldFail {
            throw ElevenLabsSTTError.notConnected
        }
        eventContinuation?.yield(.connected)
    }

    func sendAudioChunk(_ pcmData: Data) async throws {
        // Simulate partial transcript after a few chunks
        eventContinuation?.yield(.partialTranscript("Par..."))
    }

    func commitAndClose() async throws {
        eventContinuation?.yield(.committedTranscript(mockCommittedText))
    }

    func disconnect() async {}

    /// Drive an arbitrary STTEvent into the stream from outside (UI test seam).
    /// The default mock paths emit fixed events on `sendAudioChunk` and `commitAndClose`;
    /// this lets a UI test runner pump events deterministically without an audio chunk arriving.
    func injectEvent(_ event: STTEvent) {
        eventContinuation?.yield(event)
        Logger.stt.info("🎙️ MockSTT injected event")
    }
}
#endif
