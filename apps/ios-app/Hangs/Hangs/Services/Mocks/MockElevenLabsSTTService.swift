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
    // Mirrors the real service's per-acquisition StreamChannel design: a single
    // stored stream here would hide the dead-event-pipe defect from every test.
    private nonisolated let eventChannel = StreamChannel<STTEvent>()

    nonisolated func makeEventStream() -> AsyncStream<STTEvent> { eventChannel.makeStream() }

    var mockCommittedText = "Paris"
    var shouldFail = false
    /// Test seam (54.4): simulate ElevenLabs never answering a forced commit.
    var commitEmitsNothing = false

    /// Test seam (#79): when enabled, `disconnect()` suspends until
    /// `releaseDisconnect()` is called, so a test can park the committed-transcript
    /// handler mid-teardown and interleave a typed submission. Default off keeps
    /// the original synchronous no-op, so every existing test stays green.
    private var gateDisconnect = false
    private var disconnectContinuations: [CheckedContinuation<Void, Never>] = []
    /// Poll this to know the handler has reached (and is parked at) disconnect().
    var isSuspendedInDisconnect: Bool { !disconnectContinuations.isEmpty }

    func connect(token: String, languageCode: String) async throws {
        if shouldFail {
            throw ElevenLabsSTTError.notConnected
        }
        eventChannel.yield(.connected)
    }

    func sendAudioChunk(_ pcmData: Data) async throws {
        // Simulate partial transcript after a few chunks
        eventChannel.yield(.partialTranscript("Par..."))
    }

    func commitAndClose() async throws {
        guard !commitEmitsNothing else { return }
        eventChannel.yield(.committedTranscript(mockCommittedText))
    }

    func disconnect() async {
        guard gateDisconnect else { return }
        // Multiple disconnects can be in flight (the handler's own + the typed
        // path's cleanupStreamingSTT); park them all and resume together.
        await withCheckedContinuation { disconnectContinuations.append($0) }
    }

    /// Actor-isolated setter for the test seam above.
    func setCommitEmitsNothing(_ value: Bool) {
        commitEmitsNothing = value
    }

    /// Actor-isolated setter for the forced-commit transcript (#109 feedback
    /// dictation tests set this to "" so a stop doesn't append surprise text).
    func setMockCommittedText(_ value: String) {
        mockCommittedText = value
    }

    /// #79 test seam: arm/disarm the `disconnect()` suspension gate.
    func setGateDisconnect(_ value: Bool) {
        gateDisconnect = value
    }

    /// #79 test seam: disarm the gate and release every parked `disconnect()`.
    /// Disarming first ensures a late disconnect (e.g. the typed path's
    /// cleanupStreamingSTT fires its own) no-ops instead of re-parking forever.
    func releaseDisconnect() {
        gateDisconnect = false
        let continuations = disconnectContinuations
        disconnectContinuations.removeAll()
        for continuation in continuations { continuation.resume() }
    }

    /// Drive an arbitrary STTEvent into the stream from outside (UI test seam).
    /// The default mock paths emit fixed events on `sendAudioChunk` and `commitAndClose`;
    /// this lets a UI test runner pump events deterministically without an audio chunk arriving.
    func injectEvent(_ event: STTEvent) {
        eventChannel.yield(event)
        Logger.stt.info("🎙️ MockSTT injected event")
    }
}
#endif
