//
//  QuestionRatingViewModel+Dictation.swift
//  Hangs
//
//  Spoken justification for the #155 rating panel. Deliberately the same shape
//  as the #109 feedback dictation — SHARED `AudioService` + `ElevenLabsSTT`
//  instances passed in via `FeedbackVoiceServices`, never fresh ones, because a
//  second AVAudioEngine is the #64/#77 crash class.
//
//  Differences from the feedback sheet: no PCM tee / WAV attachment (a rating
//  stores text only), so a dropped socket costs the tail of a sentence, not an
//  audio artefact.
//

@preconcurrency import AVFoundation
import Foundation
import os

@MainActor
extension QuestionRatingViewModel {
    /// Toggle dictation: start if idle/denied-retry, stop if recording.
    func toggleDictation() async {
        switch micState {
        case .dictating:
            await stopDictation()
        case .idle, .denied:
            await startDictation()
        }
    }

    /// Begin streaming dictation on the SHARED audio + STT services.
    func startDictation() async {
        guard let voice, let sttService = voice.sttService else { return }
        // Single-engine guard: never open the mic while the quiz holds it.
        guard !voice.isQuizRecording() else { return }
        guard micState != .dictating else { return }

        // Permission: typing always works, so a denial flips the mic to its
        // denied state rather than failing the panel.
        let granted = await voice.audioService.requestMicrophonePermission()
        guard granted else {
            micState = .denied
            Logger.audio.info("🎙️ Rating dictation blocked — mic permission denied")
            return
        }

        partialTranscript = ""
        didHitDictationCap = false

        do {
            let token = try await networkService.fetchElevenLabsToken()
            try await sttService.connect(token: token, languageCode: voice.languageCode)
            startEventListener(sttService)

            await voice.audioService.prepareForRecording()

            // Re-check the guard after the awaits above: a quiz auto-record or
            // thinking-time timer ticking under the modal sheet could have taken
            // the shared mic in that window.
            guard !voice.isQuizRecording() else {
                eventListenerTask?.cancel()
                eventListenerTask = nil
                await sttService.disconnect()
                partialTranscript = ""
                micState = .idle
                Logger.stt.info("🎙️ Rating dictation aborted — quiz took the mic during setup")
                return
            }

            let stt = sttService
            try await voice.audioService.startStreamingRecording { pcmData in
                Task { try? await stt.sendAudioChunk(pcmData) }
            }

            micState = .dictating
            startCapTimer()
            registerInterruptionObserver()
            Logger.stt.info("🎙️ Rating dictation started")
        } catch {
            // Teardown on any setup failure; typing stays available.
            eventListenerTask?.cancel()
            eventListenerTask = nil
            voice.audioService.stopStreamingRecording()
            await sttService.disconnect()
            partialTranscript = ""
            micState = .idle
            Logger.stt.warning("⚠️ Rating dictation failed to start: \(error, privacy: .public)")
        }
    }

    /// Stop dictation: force a final commit, drain it into the justification,
    /// then tear the stream down and release the shared mic.
    func stopDictation() async {
        guard let voice, micState == .dictating else { return }

        capTask?.cancel()
        capTask = nil
        removeInterruptionObserver()

        voice.audioService.stopStreamingRecording()
        try? await voice.sttService?.commitAndClose()
        await drainFinalCommit()

        eventListenerTask?.cancel()
        eventListenerTask = nil
        await voice.sttService?.disconnect()

        partialTranscript = ""
        micState = .idle
        Logger.stt.info("🎙️ Rating dictation stopped")
    }

    /// Each VAD-committed segment appends to the editable justification and
    /// dictation continues — a commit never ends the session (unlike the quiz
    /// answer flow).
    private func startEventListener(_ sttService: ElevenLabsSTTServiceProtocol) {
        eventListenerTask?.cancel()
        // Fresh stream per dictation (StreamChannel): the service is shared with
        // the quiz flow, so a single stored stream would let one dictation kill
        // every later voice answer.
        let stream = sttService.makeEventStream()
        eventListenerTask = Task { [weak self] in
            for await event in stream {
                guard let self, !Task.isCancelled else { break }
                switch event {
                case let .partialTranscript(text):
                    self.partialTranscript = text
                case let .committedTranscript(text):
                    self.appendCommitted(text)
                    self.partialTranscript = ""
                case .connected:
                    break
                case .disconnected:
                    // Socket drop mid-dictation: without a teardown the shared
                    // mic keeps recording into a dead socket and micState stays
                    // stuck `.dictating` (the #54 stuck-state class).
                    self.abortDictation()
                    return
                }
            }
        }
    }

    private func appendCommitted(_ text: String) {
        let segment = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !segment.isEmpty else { return }
        if justification.isEmpty {
            justification = segment
        } else if justification.last == " " || justification.last == "\n" {
            justification += segment
        } else {
            justification += " " + segment
        }
    }

    /// Bounded wait for the forced-commit segment after `commitAndClose`, so the
    /// last spoken words land before the listener is cancelled.
    private func drainFinalCommit() async {
        let deadline = Date().addingTimeInterval(1.0)
        while Date() < deadline {
            if partialTranscript.isEmpty { return }
            try? await Task.sleep(nanoseconds: 20_000_000) // 20 ms
        }
    }

    private func startCapTimer() {
        capTask?.cancel()
        capTask = Task { [weak self] in
            guard let self else { return }
            let seconds = self.maxDictationSeconds
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, self.micState == .dictating else { return }
            self.didHitDictationCap = true
            await self.stopDictation()
            Logger.stt.info("🎙️ Rating dictation hit the \(Int(seconds), privacy: .public)s cap")
        }
    }

    /// Tear down WITHOUT the graceful drain — for a dropped socket or an audio
    /// interruption that yanks the mic away. Never awaits: it runs from the
    /// event-listener / notification callbacks that trigger it.
    private func abortDictation() {
        guard micState == .dictating else { return }
        capTask?.cancel()
        capTask = nil
        eventListenerTask?.cancel()
        eventListenerTask = nil
        removeInterruptionObserver()
        voice?.audioService.stopStreamingRecording()
        partialTranscript = ""
        micState = .idle
        Logger.stt.warning("⚠️ Rating dictation torn down (socket drop / interruption)")
    }

    /// The shared `AudioService` tears its engine down on an interruption but
    /// notifies only `QuizViewModel`; without our own observer `micState` would
    /// be stranded `.dictating`.
    private func registerInterruptionObserver() {
        guard interruptionObserver == nil else { return }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            // Read the primitive out here (Notification isn't Sendable) before
            // hopping to the main actor. Only `.began` matters — the mic is gone.
            let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard typeValue == AVAudioSession.InterruptionType.began.rawValue else { return }
            Task { @MainActor in
                self?.abortDictation()
            }
        }
    }

    private func removeInterruptionObserver() {
        if let observer = interruptionObserver {
            NotificationCenter.default.removeObserver(observer)
            interruptionObserver = nil
        }
    }
}
