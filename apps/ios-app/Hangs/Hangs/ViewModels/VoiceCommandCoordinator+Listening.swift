//
//  VoiceCommandCoordinator+Listening.swift
//  Hangs
//
//  The windowed native-English command listener (#77, task 77.5): the WINDOW
//  (which screen, if any, is currently listening — armed on Home /
//  Question-after-TTS / Confirmation / Result; torn down during TTS and NEVER
//  during recording) and the CONSUMER loop that pumps each transcript —
//  volatile hypothesis or final — into `handleCommandTranscript`. What a
//  transcript then MEANS lives in +Routing.swift, split out past the ~300-line
//  cap along that same seam; the policy that makes volatile results safe lives
//  in +Utterance.swift. Defensive degrade (E-fallback): no recognizer / a failed
//  setup simply means no transcripts flow — the manual mic-button flow is
//  untouched.
//

import Foundation

extension VoiceCommandCoordinator {
    // MARK: - Window

    /// CAPTURE policy (#149): may the audio engine / input tap be live at all
    /// right now? This — not the command screen below — is what every arming
    /// path must consult. It governs the ENGINE and barge-in; the window below
    /// governs only whether the command consumer is armed and how the matcher
    /// is scoped. Keeping them as two named predicates is the point: a future
    /// change to *which screens accept which commands* must never be able to
    /// take the microphone (or barge-in) with it, and vice versa.
    var mayCaptureAudio: Bool {
        // Master switch (#96 P2): the founder-facing Settings toggle. It is a
        // CAPTURE switch, not a routing filter (#149 F3) — with it off the mic
        // must stay down for the rest of the session, not merely stop matching
        // commands. Before this, flipping it off tore the listener down once
        // and the next question's TTS tail put the mic straight back up.
        if !settings().voiceCommandsEnabled { return false }

        // Backgrounded → never armed: the mic input must never be (re-)armed
        // while the app is in the background, even by a refreshCommandWindow()
        // racing the scene-phase teardown (mic-in-background fix).
        if !isAppForeground() { return false }

        // Down during ANY TTS (the recognizer must never transcribe the app's
        // own playback — #119 widened this from question-only to feedback too)
        // and during any recording (the answer window is the Slovak ElevenLabs
        // stream — time-disjoint from command listening).
        if isPlayingTTS() || isRecordingActive { return false }

        return isCaptureSafeQuizState
    }

    /// Quiz states whose audio session is live enough to run the engine.
    /// `.finished` is the one that bites (#149 F4): `endQuizWithResults()`
    /// deactivates the session, and a question-TTS tail resuming afterwards
    /// used to start the engine on top of it. Structural, so the fix does not
    /// depend on each tail remembering its own `Task.isCancelled` guard.
    private var isCaptureSafeQuizState: Bool {
        switch quizState() {
        case .idle, .askingQuestion, .processing, .showingResult: true
        default: false // startingQuiz / skipping / finished / error / recording
        }
    }

    /// The command screen active for the current quiz state, or `nil` when the
    /// command consumer must be torn down. Capture policy plus the screen map:
    /// this is the single source of truth for SCOPING the matcher, and for
    /// whether the consumer is armed at all.
    var currentCommandScreen: VoiceCommandScreen? {
        guard mayCaptureAudio else { return nil }

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
    /// `nil` when the cue must be hidden. A view shows a `ListenBar` iff this
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
        if let screen = currentCommandScreen {
            // #136 (founder decision B): Home listening runs under the QUIET
            // mixable session — external audio keeps playing while the app
            // waits for "start". In-quiz windows keep whatever session
            // startNewQuiz configured (ducking included).
            if screen == .home {
                configureQuietListeningSession()
            }
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
        // ended the utterance, so the latch must not survive it (#119).
        endUtterance()
    }
}
