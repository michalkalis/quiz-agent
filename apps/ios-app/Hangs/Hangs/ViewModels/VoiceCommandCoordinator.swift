//
//  VoiceCommandCoordinator.swift
//  Hangs
//
//  The voice-command slice: capture phase, recognizer availability, the
//  voice-start flags, and the skip undo-window state. The listening window +
//  consumer loop + command routing live in VoiceCommandCoordinator+Listening.swift;
//  the volatile-result policy (one command per utterance, final-only for
//  destructive commands, cooldown) lives in VoiceCommandCoordinator+Utterance.swift.
//

import Combine
import Foundation
import os

/// The windowed voice-command slice as its own child object (#113 T3).
/// Owns the capture-phase observable (77.4), the recognizer-availability
/// mirror (#96 S2), the recognized-command diagnostics (#96 P2), the
/// voice-start flags (P4a), and the skip undo-window (77.9).
///
/// The façade (QuizViewModel) owns this child, re-publishes its
/// `objectWillChange`, and re-exposes the view-facing slice via permanent
/// forwarding accessors (decision 2) — views never bind it directly.
/// Cross-cluster state (settings, quizState, isPlayingQuestionTTS…) stays
/// façade-resident and is reached ONLY through the injected closures below
/// (decision 4 — a child never holds a back-pointer to the view model).
@MainActor
final class VoiceCommandCoordinator: ObservableObject {
    // MARK: - Published State

    /// Additive capture-phase observable (E-state, 77.4) — the single source of
    /// truth for earcons and the deferred recording UI. SEPARATE axis from
    /// `quizState`; driven off injected audio-lifecycle events via
    /// `applyCaptureEvent(_:)`.
    @Published private(set) var commandCapturePhase: CommandCapturePhase = .idle

    /// Most recent screen-scoped command the listener recognized this session
    /// (#96 P2) — powers the release-visible Settings diagnostics row.
    @Published private(set) var lastRecognizedCommand: VoiceCommand?

    /// Observable mirror of the recognizer's command availability (#96 S2).
    /// Seeded from the service in `init` and kept in sync via
    /// `commandAvailabilityUpdates`, so `commandListenerHint` (and the Settings
    /// status row) react live to the async `.ready` flip when the en-US model
    /// finishes installing after launch.
    @Published private(set) var commandAvailability: VoiceCommandAvailability = .unknown

    /// Skip undo-window (77.9 / E-match): a recognized "skip" on the question
    /// screen opens a ~2.5 s window before the skip commits, so a tap or a
    /// spoken cancel word can abort it. `nil` = no pending skip.
    @Published private(set) var pendingSkipWindow: UndoWindow?

    /// #122 Track A — the ambient-glow feedback phase (Variant C). Written only
    /// through the helpers in VoiceCommandCoordinator+Feedback.swift; internal
    /// (not `private(set)`) because those helpers are a sibling-file extension.
    @Published var voiceFeedbackPhase: VoiceFeedbackPhase = .idle

    // MARK: - Glow Feedback State (#122 — policy lives in +Feedback)

    /// When the current `.matched` glow lit, or `nil` — input to the
    /// min/max-display window in `noteQuizStateChangedForFeedback()`.
    var matchedGlowStartedAt: Date?
    /// When the unmatched glow last lit — the 4 s cooldown's input.
    var lastUnmatchedGlowAt: Date?
    /// The last transcript the unmatched glow lit for — "never twice in a row
    /// for the same transcript" (locked variant-page answer).
    var lastUnmatchedGlowText: String?

    /// #122 glow durations (locked variant-page answers).
    var matchedGlowMinDisplay: TimeInterval = 0.6
    var matchedGlowMaxDisplay: TimeInterval = 2.0
    var unmatchedGlowDisplay: TimeInterval = 1.2
    var unmatchedGlowCooldown: TimeInterval = 4.0

    /// Injected sleep for the glow clear timer (`scheduleGlowClear`). Same
    /// rationale as `now`: the two display-window tests used to shrink the
    /// duration to 0.05 s and then wait it out for real, which flaked under
    /// full-suite load. With the sleep injected the test drives the timer
    /// instantly *and* asserts the window it was armed for — so the shipped
    /// 2.0 s / 1.2 s durations are what get pinned, not a test-only value.
    var glowSleep: @MainActor @Sendable (TimeInterval) async -> Void = { seconds in
        try? await Task.sleep(for: .seconds(seconds))
    }

    /// P4a founder-overridable flag: spoken "start" on QuestionView opens the
    /// mic. `false` disables ONLY that wiring — the rest of the command layer
    /// (and Home "start") stays intact.
    var voiceStartOnQuestionEnabled: Bool = Config.voiceStartCommandEnabled

    /// Founder-overridable flag: arm the command listener on the idle Home
    /// screen so spoken "start" begins the quiz. Read by `HomeView.onAppear`.
    var voiceStartOnHomeEnabled: Bool = Config.voiceHomeStartEnabled

    /// Observation hook / test seam (77.5): fired when a screen-scoped command
    /// is recognized, BEFORE it is routed to an action.
    var onCommandRecognized: (@MainActor (VoiceCommand) -> Void)?

    /// Earcon seam (77.10): fired when the skip undo-window OPENS.
    var onSkipUndoWindowOpened: (@MainActor () -> Void)?

    // MARK: - Volatile-result Guards (#119 — state; policy lives in +Utterance)

    /// Suppression window for a REPEAT of the same command — the second layer
    /// behind the utterance latch, covering the case where one spoken word
    /// arrives as two utterances (the founder repeats himself when nothing
    /// seems to happen, build-33: "start start start start start").
    static let commandCooldown: TimeInterval = 1.5

    /// Injected clock so the cooldown is testable with a driven clock instead of
    /// real sleeps — the repo's three flaky async voice tests all came from
    /// `Task.sleep`. Mirrors `SilenceDetectionService(now:)`. `var` so a test can
    /// swap it after the façade has built this child.
    var now: @MainActor () -> Date

    /// Whether a command has ALREADY fired for the utterance in progress — the
    /// at-most-one-command-per-utterance latch (see +Utterance for the full
    /// rationale). Written only through the helpers in
    /// VoiceCommandCoordinator+Utterance.swift; internal (not `private`) because
    /// Swift scopes `private` to the file and those helpers are a sibling-file
    /// extension.
    var commandFiredThisUtterance = false

    /// The previous VOLATILE hypothesis of the utterance in progress, normalized
    /// — the input to the stability gate that keeps a growing sentence's 1-token
    /// prefix from firing (see `noteVolatileTranscript` in +Utterance). Cleared
    /// by `endUtterance()`.
    var lastVolatileText: String?

    /// How long an unchanged volatile hypothesis must stand before the SETTLE
    /// signal accepts it as stopped-growing (see `armVolatileSettle`). `var` and
    /// injected for the same reason as `now`: tests drive it to a negligible
    /// value instead of sleeping — the repo's three flaky async voice tests all
    /// came from real `Task.sleep`s.
    ///
    /// ⚠️ **MEASURED OFF-DEVICE, NOT YET CONFIRMED ON DEVICE.** It is squeezed
    /// between two bounds, and a probe of the shipped transcriber configuration
    /// (macOS 26.5, same Speech.framework, 12 runs / 8 utterances) put both of
    /// them where 0.35 s sits comfortably in between:
    ///
    ///   - it must be LONGER than the transcriber's interval between consecutive
    ///     volatile hypotheses, or a still-growing sentence's 1-token prefix fires
    ///     before the next hypothesis can supersede it (the prefix protection
    ///     `noteVolatileTranscript` exists for). During an actual GROWING sentence
    ///     new hypotheses track the speech itself — a 7.7 s sentence produced 33
    ///     results, each a strictly longer prefix, a ~233 ms MEAN interval. Note
    ///     what that does and does not say: 0.35 s clears the mean, but the MAX
    ///     gap is unmeasured, and a clause-initial discourse marker followed by a
    ///     breath ("Okay… tak to bolo dobré") is exactly where it would exceed
    ///     0.35 s and fire off the prefix. `sincePrevMs` p95 is what settles it;
    ///     until then this is a bounded bet, taken because every command a settle
    ///     can fire is benign by construction (`requiresFinalResult`). For
    ///     a lone word followed by silence the next (refinement-only) hypothesis
    ///     took ~1.07 s, which is precisely why waiting for a re-delivery instead
    ///     of a settle would be the slow path.
    ///   - it must be SHORTER than the remaining wait for the end-of-speech final,
    ///     or the settle buys no latency and #119 is a no-op. With `.fastResults`
    ///     the first hypothesis lands ~1.15 s in and the final ~2.29 s, so a
    ///     0.35 s settle fires roughly 0.8 s ahead of the final.
    ///
    /// The caveat that keeps this from being "validated": the probe ran on macOS,
    /// not on iPhone ANE hardware, and SpeechTranscriber cannot be exercised on
    /// the Simulator at all (`supportedLocales` is empty there —
    /// docs/research/voice-commands-handsfree-research-2026-07-02.md, C1). The
    /// `sincePrevMs` attribute on every command-path log is what confirms the
    /// cadence in the field (see `noteTranscriptArrival`); re-derive this value
    /// from one real drive before treating it as load-bearing.
    var volatileSettleDelay: TimeInterval = 0.35

    /// Whether a VOLATILE hypothesis of the utterance in progress has already
    /// spent a Sentry event on one of the per-transcript DROP logs — the
    /// consumer-side twin of `loggedVolatileThisSegment` in
    /// SilenceDetectionService+Engine (see `shouldLogDroppedTranscript`). Cleared
    /// by `endUtterance()`.
    var loggedVolatileThisUtterance = false

    /// When the previous transcript of the utterance in progress arrived, or
    /// `nil` for its first — the input to the `sincePrevMs` field the command
    /// path logs (see `noteTranscriptArrival`). Cleared by `endUtterance()`.
    var lastTranscriptAt: Date?

    /// The matched-but-unproven volatile currently waiting out
    /// `volatileSettleDelay`, or `nil`. Written ONLY through
    /// `armVolatileSettle` / `cancelVolatileSettle` (+Utterance), which keep it
    /// in lockstep with the `.volatileSettle` task.
    var pendingVolatileSettle: PendingVolatileSettle?

    /// The last command actually routed, and when — the cooldown's input.
    var lastFiredCommand: (command: VoiceCommand, at: Date)?

    // MARK: - Dependencies (façade-owned service instances, shared)

    let silenceDetectionService: SilenceDetectionServiceProtocol
    /// Façade-owned task registry (decision 4 — a register/cancel handle), so
    /// `resetState()`'s blanket `cancelAll()` still covers the consumer loop
    /// and a pending skip exactly as before the extraction.
    let taskBag: TaskBag

    // MARK: - Injected façade closures (decision 4 — scoped reads/writes, never a vm ref)

    let settings: @MainActor () -> QuizSettings
    let isAppForeground: @MainActor () -> Bool
    /// ANY TTS playback — question OR feedback. Widened in #119: the flag used
    /// to be question-only, so the result screen armed the window and then
    /// played feedback TTS underneath a live input tap, and the app transcribed
    /// itself (field transcripts "you said proud answer proud", "he is proud of
    /// you"). Every TTS closes the window.
    let isPlayingTTS: @MainActor () -> Bool
    let quizState: @MainActor () -> QuizState
    /// The shared silence-detection choke points (AudioDeviceState, #113 T2).
    let startSilenceDetectionListening: @MainActor () async -> Void
    let stopSilenceDetectionListening: @MainActor () -> Void
    /// The façade's single earcon funnel (suppresses cues during question TTS).
    let emitEarcon: @MainActor (Earcon) -> Void
    // routeCommand fan-out targets — quiz flow / recording / timers stay
    // façade-resident until their own extracts (S4/S5) re-point these.
    let startNewQuiz: @MainActor () async -> Void
    let startRecording: @MainActor () async -> Void
    let repeatQuestion: @MainActor () async -> Void
    let skipQuestion: @MainActor () async -> Void
    let confirmAnswer: @MainActor () async -> Void
    let rerecordAnswer: @MainActor () -> Void
    let cancelProcessing: @MainActor () -> Void
    let continueToNext: @MainActor () -> Void
    let cancelAnswerTimer: @MainActor () -> Void
    let cancelThinkingTime: @MainActor () -> Void

    /// Long-lived observer of `commandAvailabilityUpdates`. Deliberately NOT in
    /// `taskBag` (quiz-scoped, cleared by `resetState`) — availability changes
    /// span the whole app lifetime. Cancelled in `deinit`.
    private var commandAvailabilityTask: Task<Void, Never>?

    // MARK: - Initialization

    init(
        silenceDetectionService: SilenceDetectionServiceProtocol,
        taskBag: TaskBag,
        settings: @escaping @MainActor () -> QuizSettings,
        isAppForeground: @escaping @MainActor () -> Bool,
        isPlayingTTS: @escaping @MainActor () -> Bool,
        quizState: @escaping @MainActor () -> QuizState,
        startSilenceDetectionListening: @escaping @MainActor () async -> Void,
        stopSilenceDetectionListening: @escaping @MainActor () -> Void,
        emitEarcon: @escaping @MainActor (Earcon) -> Void,
        startNewQuiz: @escaping @MainActor () async -> Void,
        startRecording: @escaping @MainActor () async -> Void,
        repeatQuestion: @escaping @MainActor () async -> Void,
        skipQuestion: @escaping @MainActor () async -> Void,
        confirmAnswer: @escaping @MainActor () async -> Void,
        rerecordAnswer: @escaping @MainActor () -> Void,
        cancelProcessing: @escaping @MainActor () -> Void,
        continueToNext: @escaping @MainActor () -> Void,
        cancelAnswerTimer: @escaping @MainActor () -> Void,
        cancelThinkingTime: @escaping @MainActor () -> Void,
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.silenceDetectionService = silenceDetectionService
        self.taskBag = taskBag
        self.settings = settings
        self.isAppForeground = isAppForeground
        self.isPlayingTTS = isPlayingTTS
        self.quizState = quizState
        self.startSilenceDetectionListening = startSilenceDetectionListening
        self.stopSilenceDetectionListening = stopSilenceDetectionListening
        self.emitEarcon = emitEarcon
        self.startNewQuiz = startNewQuiz
        self.startRecording = startRecording
        self.repeatQuestion = repeatQuestion
        self.skipQuestion = skipQuestion
        self.confirmAnswer = confirmAnswer
        self.rerecordAnswer = rerecordAnswer
        self.cancelProcessing = cancelProcessing
        self.continueToNext = continueToNext
        self.cancelAnswerTimer = cancelAnswerTimer
        self.cancelThinkingTime = cancelThinkingTime
        self.now = now

        // Seed + observe recognizer availability (see `commandAvailability`).
        // Seeding catches whatever the service resolved before this object
        // existed; the stream then keeps it in sync.
        commandAvailability = silenceDetectionService.commandAvailability
        // Acquired synchronously so an availability flip right after init buffers
        // into the stream instead of racing the observer task's startup.
        let availabilityStream = silenceDetectionService.makeCommandAvailabilityStream()
        commandAvailabilityTask = Task { [weak self] in
            for await availability in availabilityStream {
                guard let self, !Task.isCancelled else { break }
                self.commandAvailability = availability
            }
        }
    }

    deinit {
        // Availability observer lives outside `taskBag`; end it explicitly.
        commandAvailabilityTask?.cancel()
    }

    /// T7 unified reset model: clears this child's own scoped state
    /// (capture phase + pending skip). Not yet wired — the façade's
    /// `resetState`/`transition` invokes this once T7 (S6b) wires the
    /// per-child `reset()` calls.
    func reset() {
        applyCaptureEvent(.reset)
        abortSkipUndoWindow()
        endUtterance() // no utterance survives a reset (#119)
        resetFeedbackGlow() // #122: no glow survives a reset either
    }

    // MARK: - Capture Phase

    /// Apply an injected capture-lifecycle event. Illegal transitions are a
    /// no-op (phase unchanged) and return `false` so a caller can detect a bad
    /// sequence.
    @discardableResult
    func applyCaptureEvent(_ event: CaptureLifecycleEvent) -> Bool {
        guard let next = commandCapturePhase.applying(event) else { return false }
        commandCapturePhase = next
        return true
    }

    /// Record the most recently recognized command for the release diagnostics
    /// row (#96 P2). Lives in this file so `lastRecognizedCommand`'s private
    /// setter is honored (+Listening is a separate file).
    func noteRecognizedCommand(_ command: VoiceCommand) {
        lastRecognizedCommand = command
    }

    // MARK: - Skip Undo-Window

    /// Open the skip undo-window (77.9). A recognized "skip" on the question
    /// screen does NOT commit immediately: it opens a ~2.5 s window that a tap
    /// (or a spoken cancel word) can abort. On expiry the skip commits via the
    /// injected `skipQuestion`. Idempotent while a window is already open.
    /// `duration` is injectable so tests don't wait the full 2.5 s.
    func beginSkipUndoWindow(duration: TimeInterval = UndoWindow.defaultDuration) {
        guard quizState() == .askingQuestion, pendingSkipWindow == nil else { return }
        cancelAnswerTimer()
        cancelThinkingTime()
        pendingSkipWindow = UndoWindow(duration: duration)
        emitEarcon(.skipConfirm) // 77.10 skip-confirm tone — undo-window opened
        onSkipUndoWindowOpened?() // observation seam (deferred UI / tests)

        let task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard let self, !Task.isCancelled else { return }
            guard self.pendingSkipWindow != nil else { return } // aborted
            // #110 Bug 2: a pending skip is only ever committed while the quiz
            // is still asking the question — starting an answer (voice or tap)
            // supersedes it. Without this recheck, expiry could commit
            // skipQuestion() mid-recording, leaving the streaming mic live.
            guard self.quizState() == .askingQuestion else {
                self.pendingSkipWindow = nil
                return
            }
            self.pendingSkipWindow = nil
            await self.skipQuestion()
        }
        taskBag.add(task, key: .skipUndo)
        Logger.voice.info("⏭️ Skip undo-window opened (\(duration, privacy: .public)s)")
    }

    /// Abort a pending skip (tap on the undo affordance, a spoken cancel word,
    /// or starting an answer). No-op if none is open.
    func abortSkipUndoWindow() {
        guard pendingSkipWindow != nil else { return }
        pendingSkipWindow = nil
        taskBag.cancel(.skipUndo)
        Logger.voice.info("↩️ Skip undo-window aborted")
    }
}
