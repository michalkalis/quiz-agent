//
//  VoiceCommandCoordinator+Listening.swift
//  Hangs
//
//  The windowed native-English command listener (#77, task 77.5): the WINDOW
//  (which screen, if any, is currently listening — armed on Home /
//  Question-after-TTS / Confirmation / Result; torn down during TTS and NEVER
//  during recording), the CONSUMER loop feeding each transcript — volatile
//  hypothesis or final, see +Utterance for the policy that makes volatile
//  results safe — to the screen-scoped `VoiceCommandMatcher`, and the
//  per-screen command ROUTING
//  (77.8–77.9). Defensive degrade (E-fallback): no recognizer / a failed setup
//  simply means no transcripts flow — the manual mic-button flow is untouched.
//

import Foundation
import os

extension VoiceCommandCoordinator {
    // MARK: - Window

    /// The command screen active for the current quiz state, or `nil` when the
    /// listener must be torn down. Recording, TTS playback, and non-interactive
    /// states all map to `nil` (windowed lifecycle, 77.5). This is the single
    /// source of truth for both arming and for scoping the matcher.
    var currentCommandScreen: VoiceCommandScreen? {
        // Master switch (#96 P2): the founder-facing Settings toggle. OFF → the
        // command window never arms on any screen and the listening indicator
        // is suppressed; buttons stay the untouched fallback.
        if !settings().voiceCommandsEnabled { return nil }

        // Backgrounded → no window: the mic input must never be (re-)armed
        // while the app is in the background, even by a refreshCommandWindow()
        // racing the scene-phase teardown (mic-in-background fix).
        if !isAppForeground() { return nil }

        // Torn down during ANY TTS (the recognizer must never transcribe the
        // app's own playback — #110 widened this from question-only to feedback
        // too) and during any recording (the answer window is the Slovak
        // ElevenLabs stream — time-disjoint from command listening).
        if isPlayingTTS() || isRecordingActive { return nil }

        switch quizState() {
        case .idle: return .home
        case .askingQuestion: return .question
        case .processing: return .confirmation
        case .showingResult: return .result
        default: return nil // startingQuiz / skipping / finished / error / recording
        }
    }

    /// Whether an answer recording (batch or streaming) is live. The command
    /// listener is NEVER armed while this is true.
    var isRecordingActive: Bool { quizState() == .recording }

    /// Hint for the on-screen "LISTENING FOR COMMANDS" indicator (77.12), or
    /// `nil` when the cue must be hidden. A view shows `CmdListenBar` iff this
    /// is non-nil. Gated on the recognizer being `.ready`: if the on-device
    /// assets failed to install, the cue must NOT claim to be listening.
    var commandListenerHint: String? {
        guard commandCapturePhase == .listening,
              let screen = currentCommandScreen,
              commandAvailability == .ready else { return nil }
        return VoiceCommandLexicon.hint(on: screen)
    }

    /// Arm or tear down the command/VAD listener to match the current window.
    /// Idempotent (the underlying choke points are).
    func syncCommandListenerWindow() async {
        if currentCommandScreen != nil {
            await startSilenceDetectionListening()
        } else {
            stopSilenceDetectionListening()
        }
    }

    /// Fire-and-forget window refresh for synchronous call sites (state
    /// transitions). Kept off the hot transition path so a state change is
    /// never blocked on audio-engine setup.
    func refreshCommandWindow() {
        Task { [weak self] in await self?.syncCommandListenerWindow() }
    }

    // MARK: - Consumer

    /// Start consuming English transcripts (volatile hypotheses AND finals) and
    /// routing them through the screen-scoped matcher. Called when the listener
    /// arms; idempotent
    /// (re-adding under the same TaskKey cancels the previous consumer). Drives
    /// the capture phase to `.armed → .listening`.
    func startCommandConsumer() {
        let service = silenceDetectionService
        applyCaptureEvent(.arm)
        applyCaptureEvent(.listen)

        // Fresh stream per arm (StreamChannel): a cancelled predecessor can no
        // longer starve this consumer — the dead-voice-commands P0. Acquired
        // SYNCHRONOUSLY before the task so a transcript yielded right after this
        // call buffers into the new stream instead of racing the task's startup.
        let stream = service.makeCommandTranscriptStream()
        let task = Task { [weak self] in
            SentryLog.info("voice cmd consumer started", category: .voice)
            var transcriptsSeen = 0
            for await transcript in stream {
                guard let self, !Task.isCancelled else { break }
                transcriptsSeen += 1
                await self.handleCommandTranscript(transcript)
            }
            // Field-proof of the fix: the old bug showed as an immediate exit
            // with transcriptsSeen=0 right after every start.
            SentryLog.info(
                "voice cmd consumer exited",
                category: .voice,
                attributes: ["transcriptsSeen": transcriptsSeen, "cancelled": Task.isCancelled]
            )
        }
        taskBag.add(task, key: .commandListener)
    }

    /// Stop the consumer loop and reset the capture phase to idle.
    func stopCommandConsumer() {
        taskBag.cancel(.commandListener)
        applyCaptureEvent(.reset)
        // A torn-down listener will never deliver the final that would have
        // ended the utterance, so the latch must not survive it (#110).
        endUtterance()
    }

    /// Map one transcript — a volatile hypothesis OR a final — to a
    /// screen-scoped command (or ignore it). Guards on `currentCommandScreen` so
    /// a transcript that lands after the window closed (e.g. mid-transition into
    /// recording, or while feedback TTS plays) is dropped.
    ///
    /// **AT MOST ONE COMMAND PER UTTERANCE (#110).** This is the load-bearing
    /// invariant that makes volatile results safe. The transcriber emits a
    /// GROWING hypothesis and then one final, so a single spoken "start" reaches
    /// this method several times: the first transcript that resolves to a
    /// command AND clears `suppressionReason` fires it, and EVERY later
    /// transcript of that utterance — volatile or final — is suppressed until
    /// the final ends the utterance. Without the latch a single "ok … again"
    /// utterance would submit the answer from an early hypothesis and then
    /// discard it from a later one.
    func handleCommandTranscript(_ transcript: CommandTranscript) async {
        // The final result IS the utterance boundary, whatever happens below
        // (window closed / unmatched / suppressed) — the latch must never
        // outlive the utterance it belongs to.
        defer { if transcript.isFinal { endUtterance() } }

        // Release diagnostics: the command hot path was invisible in Sentry, so
        // "commands don't work" on-device could not be triaged remotely (only
        // availability was logged). One log per transcript, at every exit, so
        // Sentry distinguishes: window closed vs no vocab match vs suppressed vs
        // matched — and, since #110, whether the source was a volatile
        // hypothesis or a final, plus the token count that the matcher's content
        // cap keys off. TEMPORARY EXCEPTION to the no-raw-speech rule in
        // Logging.swift: "text" carries the normalized transcript while the
        // founder is the only prod user — remove before GA (tracked in
        // docs/todo/TODO.md).
        let normalized = VoiceCommandMatcher.normalize(transcript.text)
        let tokens = normalized.split(separator: " ").count

        // #110 volatile stability (see `noteVolatileTranscript`): recorded for
        // EVERY volatile, including the ones dropped below, so the baseline is
        // what the transcriber emitted rather than what happened to match.
        let isStableVolatile = transcript.isFinal || noteVolatileTranscript(normalized)

        guard let screen = currentCommandScreen else {
            SentryLog.info(
                "voice cmd transcript dropped — window closed",
                category: .voice,
                attributes: [
                    "len": normalized.count, "text": normalized,
                    "final": transcript.isFinal, "tokens": tokens,
                ]
            )
            return
        }

        // Spoken-cancel path (77.10 carry-over): while a skip undo-window is
        // open on the question screen, a spoken cancel word ("stop"/"no")
        // aborts the pending skip — the spoken twin of the tap-abort. "stop" is
        // NOT in the question screen's normal command set, so this must be
        // checked BEFORE the matcher (which would otherwise drop it).
        if pendingSkipWindow != nil {
            let cancelTokens = VoiceCommandMatcher.normalize(transcript.text).split(separator: " ").map(String.init)
            if cancelTokens.contains(where: VoiceCommandLexicon.isCancelWord) {
                emitEarcon(.commandAck) // acknowledge the recognized cancel
                abortSkipUndoWindow()
                return
            }
        }

        guard let command = VoiceCommandMatcher.match(
            transcript: transcript.text, on: screen, isFinal: transcript.isFinal
        ) else {
            SentryLog.info(
                "voice cmd transcript unmatched",
                category: .voice,
                attributes: [
                    "screen": String(describing: screen), "len": normalized.count, "text": normalized,
                    "final": transcript.isFinal, "tokens": tokens,
                ]
            )
            return
        }

        if let suppression = suppressionReason(
            for: command, on: screen, isFinal: transcript.isFinal, isStableVolatile: isStableVolatile
        ) {
            SentryLog.info(
                "voice cmd suppressed",
                category: .voice,
                attributes: [
                    "screen": String(describing: screen), "command": command.rawValue,
                    "reason": suppression.rawValue, "final": transcript.isFinal, "tokens": tokens,
                ]
            )
            return
        }

        SentryLog.info(
            "voice cmd matched",
            category: .voice,
            attributes: [
                "screen": String(describing: screen), "command": command.rawValue,
                "final": transcript.isFinal, "tokens": tokens,
            ]
        )
        noteCommandFired(command) // latch the utterance + start the cooldown
        applyCaptureEvent(.recognize) // ack (no phase change) — earcon seam for 77.10
        handleRecognizedCommand(command)
    }

    /// A command was recognized on the current screen. Fires the
    /// `onCommandRecognized` observation hook (tests + future earcons), then
    /// routes it to an action (77.8–77.9). Routing is screen-scoped a second
    /// time via `routeCommand` so a transcript that lands as the window closes
    /// can't fire the wrong action.
    func handleRecognizedCommand(_ command: VoiceCommand) {
        Logger.voice.info("🎙️ Command recognized: \(command.rawValue, privacy: .public)")
        noteRecognizedCommand(command) // release diagnostics (#96 P2)
        emitEarcon(.commandAck) // 77.10 command-ack tone
        onCommandRecognized?(command)
        routeCommand(command)
    }

    /// Map a recognized command to its per-screen action (77.8 / 77.9). Buttons
    /// + the 10 s auto-confirm + auto-advance remain the untouched fallbacks;
    /// this is additive. Async actions hop to a Task so the @MainActor-sync
    /// consumer path is never blocked on network/audio. Every fan-out target is
    /// an injected façade closure (decision 4).
    func routeCommand(_ command: VoiceCommand) {
        guard let screen = currentCommandScreen else {
            SentryLog.info(
                "voice cmd not routed — window closed after match",
                category: .voice,
                attributes: ["command": command.rawValue]
            )
            return
        }
        switch (screen, command) {
        // Home — spoken "start" begins the quiz.
        case (.home, .start):
            Task { [weak self] in await self?.startNewQuiz() }

        // Question — hands-free START recovery (P4a, founder-overridable flag).
        case (.question, .start):
            guard voiceStartOnQuestionEnabled else { return }
            cancelAnswerTimer()
            cancelThinkingTime()
            Task { [weak self] in await self?.startRecording() }

        // Question — replay the question audio + re-arm the listener via
        // repeatQuestion(). playQuestionAudio re-arms after TTS.
        case (.question, .repeatQuestion):
            Task { [weak self] in await self?.repeatQuestion() }

        // Question — skip via the ~2.5 s undo-window (commit / abort).
        case (.question, .skip):
            beginSkipUndoWindow()

        // Confirmation sheet — on top of the 10 s auto-confirm + buttons.
        case (.confirmation, .ok):
            Task { [weak self] in await self?.confirmAnswer() }

        case (.confirmation, .again):
            rerecordAnswer()

        case (.confirmation, .stop):
            cancelProcessing()

        // Result — advance (on top of auto-advance + button).
        case (.result, .next), (.result, .ok):
            continueToNext()

        default:
            // Command not valid on this screen — inert. Logged so a matched
            // command that silently does nothing is visible in Sentry.
            SentryLog.info(
                "voice cmd inert on screen",
                category: .voice,
                attributes: ["screen": String(describing: screen), "command": command.rawValue]
            )
        }
    }
}
