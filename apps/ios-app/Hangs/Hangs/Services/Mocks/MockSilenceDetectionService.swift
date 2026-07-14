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
    let silenceEvents: AsyncStream<SilenceEvent>
    let bargeInEvents: AsyncStream<Void>
    let commandTranscripts: AsyncStream<String>
    let commandAvailabilityUpdates: AsyncStream<VoiceCommandAvailability>
    private let silenceContinuation: AsyncStream<SilenceEvent>.Continuation
    private let bargeInContinuation: AsyncStream<Void>.Continuation
    private let commandContinuation: AsyncStream<String>.Continuation
    private let commandAvailabilityContinuation: AsyncStream<VoiceCommandAvailability>.Continuation

    /// Defaults to `.ready` so command-listener tests exercise the armed path;
    /// settable so #77 fail-loud tests can drive the unavailable state. Each
    /// assignment pushes to `commandAvailabilityUpdates` (mirrors the real
    /// service), so a test that flips this mid-session drives the view-model's
    /// observable mirror. `didSet` does not fire for the initial `.ready` value.
    var commandAvailability: VoiceCommandAvailability = .ready {
        didSet { commandAvailabilityContinuation.yield(commandAvailability) }
    }

    var isListening = false
    var ttsPlaybackActive = false
    var startListeningCallCount = 0
    var stopListeningCallCount = 0

    /// Simulate a recognizer/detector setup failure (CARQUIZ-3-class drift, empty
    /// supportedLocales, <iOS 26): `startListening()` leaves the service DOWN so
    /// #77 tests can assert the defensive degrade-to-buttons path (E-fallback).
    var shouldFailSetup = false

    init() {
        var silenceCont: AsyncStream<SilenceEvent>.Continuation!
        self.silenceEvents = AsyncStream { silenceCont = $0 }
        self.silenceContinuation = silenceCont

        var bargeCont: AsyncStream<Void>.Continuation!
        self.bargeInEvents = AsyncStream { bargeCont = $0 }
        self.bargeInContinuation = bargeCont

        var commandCont: AsyncStream<String>.Continuation!
        self.commandTranscripts = AsyncStream { commandCont = $0 }
        self.commandContinuation = commandCont

        var availabilityCont: AsyncStream<VoiceCommandAvailability>.Continuation!
        self.commandAvailabilityUpdates = AsyncStream { availabilityCont = $0 }
        self.commandAvailabilityContinuation = availabilityCont
    }

    func startListening() async {
        startListeningCallCount += 1
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
        silenceContinuation.yield(event)
    }

    func simulateBargeIn() {
        bargeInContinuation.yield(())
    }

    /// Emit a finalized English transcript to the command listener (77.5).
    func simulateCommandTranscript(_ transcript: String) {
        commandContinuation.yield(transcript)
    }

    func finishCommandTranscripts() {
        commandContinuation.finish()
    }

    func finishSilenceEvents() {
        silenceContinuation.finish()
    }

    func finishBargeInEvents() {
        bargeInContinuation.finish()
    }

    func finishCommandAvailabilityUpdates() {
        commandAvailabilityContinuation.finish()
    }
}
#endif
