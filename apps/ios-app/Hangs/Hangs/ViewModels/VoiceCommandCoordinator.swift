//
//  VoiceCommandCoordinator.swift
//  Hangs
//
//  The voice-command slice: capture phase, recognizer availability, the
//  voice-start flags, and the skip undo-window state. The listening window +
//  consumer loop + command routing live in VoiceCommandCoordinator+Listening.swift.
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

    // MARK: - Dependencies (façade-owned service instances, shared)

    let silenceDetectionService: SilenceDetectionServiceProtocol
    /// Façade-owned task registry (decision 4 — a register/cancel handle), so
    /// `resetState()`'s blanket `cancelAll()` still covers the consumer loop
    /// and a pending skip exactly as before the extraction.
    let taskBag: TaskBag

    // MARK: - Injected façade closures (decision 4 — scoped reads/writes, never a vm ref)

    let settings: @MainActor () -> QuizSettings
    let isAppForeground: @MainActor () -> Bool
    let isPlayingQuestionTTS: @MainActor () -> Bool
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
        isPlayingQuestionTTS: @escaping @MainActor () -> Bool,
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
        cancelThinkingTime: @escaping @MainActor () -> Void
    ) {
        self.silenceDetectionService = silenceDetectionService
        self.taskBag = taskBag
        self.settings = settings
        self.isAppForeground = isAppForeground
        self.isPlayingQuestionTTS = isPlayingQuestionTTS
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
