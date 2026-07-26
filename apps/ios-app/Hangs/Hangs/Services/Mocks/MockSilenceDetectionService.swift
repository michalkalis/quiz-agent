//
//  MockSilenceDetectionService.swift
//  Hangs
//
//  Mock SilenceDetectionService for DEBUG builds (SwiftUI previews, UI-test mode).
//

@preconcurrency import AVFoundation
import Foundation
import os

#if DEBUG
@MainActor
final class MockSilenceDetectionService: SilenceDetectionServiceProtocol {
    // Mirrors the real service's per-acquisition StreamChannel design (dead-
    // voice-commands fix): every make*Stream() call mints a fresh stream, so
    // tests that re-arm consumers exercise the same lifecycle as production.
    private let silenceChannel = StreamChannel<SilenceEvent>()
    private let bargeInChannel = StreamChannel<Void>()
    private let commandChannel = StreamChannel<CommandTranscript>()
    private let commandAvailabilityChannel = StreamChannel<VoiceCommandAvailability>()

    func makeSilenceEventStream() -> AsyncStream<SilenceEvent> { silenceChannel.makeStream() }
    func makeBargeInStream() -> AsyncStream<Void> { bargeInChannel.makeStream() }
    func makeCommandTranscriptStream() -> AsyncStream<CommandTranscript> { commandChannel.makeStream() }
    func makeCommandAvailabilityStream() -> AsyncStream<VoiceCommandAvailability> { commandAvailabilityChannel.makeStream() }

    /// Defaults to `.ready` so command-listener tests exercise the armed path;
    /// settable so #77 fail-loud tests can drive the unavailable state. Each
    /// assignment pushes to the availability stream (mirrors the real service),
    /// so a test that flips this mid-session drives the view-model's observable
    /// mirror. `didSet` does not fire for the initial `.ready` value.
    var commandAvailability: VoiceCommandAvailability = .ready {
        didSet { commandAvailabilityChannel.yield(commandAvailability) }
    }

    var isListening = false
    var ttsPlaybackActive = false
    var startListeningCallCount = 0
    var stopListeningCallCount = 0

    /// Simulate a recognizer/detector setup failure (CARQUIZ-3-class drift, empty
    /// supportedLocales, <iOS 26): `startListening()` leaves the service DOWN so
    /// #77 tests can assert the defensive degrade-to-buttons path (E-fallback).
    var shouldFailSetup = false

    /// Park the NEXT `startListening()` mid-flight (one-shot — cleared as it is
    /// consumed, so the caller's own re-arm isn't parked too).
    ///
    /// WHY the mock needs this at all: the real `startListening()` suspends at
    /// `SpeechAnalyzer.bestAvailableAudioFormat` while `audioEngine` is still nil,
    /// so a `stopListening()` that lands in that window has NOTHING to tear down
    /// and cannot cancel the start — the call resumes and puts the mic live
    /// anyway. Setting `isListening = true` below regardless of an interleaved
    /// `stopListening()` reproduces exactly that, which is what lets a test prove
    /// the `AudioDeviceState` choke point re-validates after it suspends.
    var onStartListeningSuspend: (@MainActor () async -> Void)?

    init() {}

    func startListening() async {
        startListeningCallCount += 1
        if let suspend = onStartListeningSuspend {
            onStartListeningSuspend = nil
            await suspend()
        }
        guard !shouldFailSetup else {
            isListening = false // degrade: setup failed, listener stays down
            return
        }
        isListening = true
    }

    func stopListening() {
        isListening = false
        stopListeningCallCount += 1
    }

    func setTTSPlaybackActive(_ active: Bool) {
        ttsPlaybackActive = active
    }

    func simulateSilenceEvent(_ event: SilenceEvent) {
        silenceChannel.yield(event)
    }

    func simulateBargeIn() {
        bargeInChannel.yield(())
    }

    /// Emit an English transcript to the command listener (77.5). Defaults to a
    /// FINAL result because that is what an existing test means by "the user said
    /// X". Pass `isFinal: false` to drive a volatile hypothesis — the mid-utterance
    /// results the real transcriber now emits so a one-word command fires before
    /// the end-of-speech endpoint (build-33 latency fix).
    func simulateCommandTranscript(_ transcript: String, isFinal: Bool = true) {
        commandChannel.yield(CommandTranscript(text: transcript, isFinal: isFinal))
    }

    func finishCommandTranscripts() {
        commandChannel.finish()
    }

    func finishSilenceEvents() {
        silenceChannel.finish()
    }

    func finishBargeInEvents() {
        bargeInChannel.finish()
    }

    func finishCommandAvailabilityUpdates() {
        commandAvailabilityChannel.finish()
    }
}
#endif
