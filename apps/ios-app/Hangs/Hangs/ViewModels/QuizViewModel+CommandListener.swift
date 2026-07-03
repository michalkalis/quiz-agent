//
//  QuizViewModel+CommandListener.swift
//  Hangs
//
//  Issue #77 (voice commands hands-free), task 77.5 — the windowed native-English
//  command listener. The English recognizer lives inside SilenceDetectionService
//  (the paired transcriber, re-localed to English) and surfaces finalized
//  transcripts via `commandTranscripts`. This extension owns:
//    • the WINDOW — which screen (if any) is currently listening, and the arm /
//      tear-down rule (armed on Home / Question-after-TTS / Confirmation / Result;
//      torn down during TTS and NEVER during recording);
//    • the CONSUMER loop that feeds each transcript to the screen-scoped
//      `VoiceCommandMatcher` and drives the additive capture-phase (77.4);
//    • the DEFENSIVE degrade (E-fallback): no recognizer / a failed setup simply
//      means no transcripts flow — the manual mic-button + tap flow is untouched.
//
//  Command → action ROUTING is Session 4's job. Session 3 recognizes commands and
//  acknowledges them (capture-phase `.recognize`), but `handleRecognizedCommand`
//  is a deliberate no-op seam that Session 4 fills in.
//

import Foundation
import os

extension QuizViewModel {

    // MARK: - Window

    /// The command screen active for the current quiz state, or `nil` when the
    /// listener must be torn down. Recording, TTS playback, and non-interactive
    /// states all map to `nil` (windowed lifecycle, 77.5). This is the single
    /// source of truth for both arming and for scoping the matcher.
    var currentCommandScreen: VoiceCommandScreen? {
        // Torn down during TTS (the recognizer must never transcribe its own
        // question playback) and during any recording (the answer window is the
        // Slovak ElevenLabs stream — time-disjoint from command listening).
        if isPlayingQuestionTTS || isRecordingActive { return nil }

        switch quizState {
        case .idle: return .home
        case .askingQuestion: return .question
        case .processing: return .confirmation
        case .showingResult: return .result
        default: return nil // startingQuiz / skipping / finished / error / recording
        }
    }

    /// Whether an answer recording (batch or streaming) is live. The command
    /// listener is NEVER armed while this is true.
    var isRecordingActive: Bool { quizState == .recording }

    /// Arm or tear down the command/VAD listener to match the current window.
    /// Idempotent (the underlying `start/stopListening` are). A `nil` service
    /// (pre-iOS-26 / no recognizer) is a no-op — the app stays button-only.
    func syncCommandListenerWindow() async {
        guard silenceDetectionService != nil else { return } // degrade to buttons
        if currentCommandScreen != nil {
            await startSilenceDetectionListening()
        } else {
            stopSilenceDetectionListening()
        }
    }

    /// Fire-and-forget window refresh for synchronous call sites (state
    /// transitions). Kept off the hot transition path so a state change is never
    /// blocked on audio-engine setup.
    func refreshCommandWindow() {
        Task { [weak self] in await self?.syncCommandListenerWindow() }
    }

    // MARK: - Consumer

    /// Start consuming finalized English transcripts and routing them through the
    /// screen-scoped matcher. Called when the listener arms; idempotent (re-adding
    /// under the same TaskKey cancels the previous consumer). Drives the capture
    /// phase to `.armed → .listening`.
    func startCommandConsumer() {
        guard let service = silenceDetectionService else { return }
        applyCaptureEvent(.arm)
        applyCaptureEvent(.listen)

        let task = Task { [weak self] in
            for await transcript in service.commandTranscripts {
                guard let self, !Task.isCancelled else { break }
                await self.handleCommandTranscript(transcript)
            }
        }
        taskBag.add(task, key: .commandListener)
    }

    /// Stop the consumer loop and reset the capture phase to idle.
    func stopCommandConsumer() {
        taskBag.cancel(.commandListener)
        applyCaptureEvent(.reset)
    }

    /// Map one finalized transcript to a screen-scoped command (or ignore it).
    /// Guards on `currentCommandScreen` so a transcript that lands after the
    /// window closed (e.g. mid-transition into recording) is dropped.
    func handleCommandTranscript(_ transcript: String) async {
        guard let screen = currentCommandScreen else { return }
        guard let command = VoiceCommandMatcher.match(transcript: transcript, on: screen) else { return }

        applyCaptureEvent(.recognize) // ack (no phase change) — earcon seam for 77.10
        handleRecognizedCommand(command)
    }

    /// Session 3 seam: a command was recognized on the current screen. Routing to
    /// an actual action (start / ok / next / repeat / skip) is Session 4's task
    /// (77.8–77.9). Session 3 only logs + fires the `onCommandRecognized` hook,
    /// which Session 4 (and the tests) bind to observe recognized commands.
    func handleRecognizedCommand(_ command: VoiceCommand) {
        Logger.voice.info("🎙️ Command recognized (unrouted — Session 3): \(command.rawValue, privacy: .public)")
        onCommandRecognized?(command)
    }
}
