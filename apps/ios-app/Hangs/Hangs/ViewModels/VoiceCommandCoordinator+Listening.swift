//
//  VoiceCommandCoordinator+Listening.swift
//  Hangs
//
//  The windowed native-English command listener (#77, task 77.5): the WINDOW
//  (which screen, if any, is currently listening — armed on Home /
//  Question-after-TTS / Confirmation / Result; torn down during TTS and NEVER
//  during recording), the CONSUMER loop feeding each finalized transcript to
//  the screen-scoped `VoiceCommandMatcher`, and the per-screen command ROUTING
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

        // Torn down during TTS (the recognizer must never transcribe its own
        // question playback) and during any recording (the answer window is the
        // Slovak ElevenLabs stream — time-disjoint from command listening).
        if isPlayingQuestionTTS() || isRecordingActive { return nil }

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

    /// Start consuming finalized English transcripts and routing them through
    /// the screen-scoped matcher. Called when the listener arms; idempotent
    /// (re-adding under the same TaskKey cancels the previous consumer). Drives
    /// the capture phase to `.armed → .listening`.
    func startCommandConsumer() {
        let service = silenceDetectionService
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
        // Release diagnostics: the command hot path was invisible in Sentry, so
        // "commands don't work" on-device could not be triaged remotely (only
        // availability was logged). One log per finalized transcript, at every
        // exit, so Sentry distinguishes: window closed vs no vocab match vs
        // matched. TEMPORARY EXCEPTION to the no-raw-speech rule in Logging.swift:
        // "text" carries the normalized transcript while the founder is the only
        // prod user — remove before GA (tracked in docs/todo/TODO.md).
        let normalized = VoiceCommandMatcher.normalize(transcript)
        guard let screen = currentCommandScreen else {
            SentryLog.info(
                "voice cmd transcript dropped — window closed",
                category: .voice,
                attributes: ["len": normalized.count, "text": normalized]
            )
            return
        }

        // Spoken-cancel path (77.10 carry-over): while a skip undo-window is
        // open on the question screen, a spoken cancel word ("stop"/"no")
        // aborts the pending skip — the spoken twin of the tap-abort. "stop" is
        // NOT in the question screen's normal command set, so this must be
        // checked BEFORE the matcher (which would otherwise drop it).
        if pendingSkipWindow != nil {
            let tokens = VoiceCommandMatcher.normalize(transcript).split(separator: " ").map(String.init)
            if tokens.contains(where: VoiceCommandLexicon.isCancelWord) {
                emitEarcon(.commandAck) // acknowledge the recognized cancel
                abortSkipUndoWindow()
                return
            }
        }

        guard let command = VoiceCommandMatcher.match(transcript: transcript, on: screen) else {
            SentryLog.info(
                "voice cmd transcript unmatched",
                category: .voice,
                attributes: ["screen": String(describing: screen), "len": normalized.count, "text": normalized]
            )
            return
        }

        SentryLog.info(
            "voice cmd matched",
            category: .voice,
            attributes: ["screen": String(describing: screen), "command": command.rawValue]
        )
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
