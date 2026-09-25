//
//  QuizTimersController.swift
//  Hangs
//
//  The timer slice extracted from QuizViewModel (#113 T4): thinking-time,
//  answer-timer, auto-stop-recording, auto-advance and auto-confirm
//  start/cancel, plus the countdown state the views read.
//

import Combine
import Clocks
import Foundation
import os

/// The timer slice as its own child object (#113 T4): every countdown
/// start/cancel plus the countdown/pause state, all tasks registered in the
/// façade's shared `TaskBag` (so `resetState()`'s `cancelAll()` still tears
/// them down). The façade (QuizViewModel) owns this child, re-publishes its
/// `objectWillChange`, and re-exposes the slice via permanent forwarding
/// accessors (decision 2) — views never bind it directly. Cross-cluster
/// state (`quizState`, `settings`, `isAutoRecording`, `isRerecording`,
/// `showAnswerConfirmation`, `autoConfirmCountdown` — confirmation-semantic,
/// folds into `ConfirmationState` in T7) stays façade-resident and is
/// reached ONLY through the injected closures below (decision 4 — a child
/// never holds a back-pointer to the view model).
@MainActor
final class QuizTimersController: ObservableObject {
    // MARK: - Published timer state

    // Auto-advance countdown for ResultView binding (single source of truth)
    @Published var autoAdvanceCountdown: Int = 0
    // Answer timer countdown (visible on QuestionView)
    @Published var answerTimerCountdown: Int = 0
    // Thinking time countdown (visible on QuestionView before auto-recording)
    @Published var thinkingTimeCountdown: Int = 0
    /// #131 Track B: seconds left of the auto-stop recording window. The founder
    /// rule is "after the question is read the countdown NEVER stops until the
    /// answer is submitted or time expires" — so the hard recording cap, which
    /// used to be an invisible one-shot sleep, now ticks in public and the
    /// Record/Stop button keeps showing a number through the whole answer phase.
    @Published var recordingCountdown: Int = 0
    /// The window `recordingCountdown` drains from — the button's fill fraction.
    private(set) var recordingCountdownTotal: Int = 0
    /// #171 Track D: quiz-level pause. Two screens set it and both mean the
    /// same thing — nothing advances on its own until the driver says so: the
    /// result screen's STAY pill (#131 D, auto-advance only) and the answer
    /// confirmation sheet's Pause pill (auto-confirm + TTS + the command
    /// listener). Cleared on the next question, and by confirming/re-recording
    /// off the sheet — confirming IS a resume.
    @Published var isPaused: Bool = false

    /// The façade's shared task owner (decision 4 register/cancel handle).
    let taskBag: TaskBag

    /// The façade's clock (#180 track A): every countdown below ticks on it.
    let clock: AnyClock<Duration>

    /// #186 step 1: every countdown captures the attempt (or question) it was
    /// armed for and proves it still owns the quiz before it acts.
    let attemptLedger: AttemptLedger

    // MARK: - Injected façade closures (decision 4 — scoped reads/writes, never a vm ref)

    let settings: @MainActor () -> QuizSettings
    let quizState: @MainActor () -> QuizState
    let isRerecording: @MainActor () -> Bool
    let setIsAutoRecording: @MainActor (Bool) -> Void
    let showAnswerConfirmation: @MainActor () -> Bool
    let setAutoConfirmCountdown: @MainActor (Int) -> Void
    let startRecording: @MainActor () async -> Void
    /// #185 track A: the recording timers say which of them ended it.
    let stopRecordingAndSubmit: @MainActor (RecordingStopReason) async -> Void
    /// Auto-confirm fire, carrying the attempt the countdown was armed for.
    let confirmAnswer: @MainActor (AttemptID) async -> Void
    let proceedToNextQuestion: @MainActor () async -> Void

    init(
        taskBag: TaskBag,
        clock: AnyClock<Duration>,
        attemptLedger: AttemptLedger,
        settings: @escaping @MainActor () -> QuizSettings,
        quizState: @escaping @MainActor () -> QuizState,
        isRerecording: @escaping @MainActor () -> Bool,
        setIsAutoRecording: @escaping @MainActor (Bool) -> Void,
        showAnswerConfirmation: @escaping @MainActor () -> Bool,
        setAutoConfirmCountdown: @escaping @MainActor (Int) -> Void,
        startRecording: @escaping @MainActor () async -> Void,
        stopRecordingAndSubmit: @escaping @MainActor (RecordingStopReason) async -> Void,
        confirmAnswer: @escaping @MainActor (AttemptID) async -> Void,
        proceedToNextQuestion: @escaping @MainActor () async -> Void
    ) {
        self.taskBag = taskBag
        self.clock = clock
        self.attemptLedger = attemptLedger
        self.settings = settings
        self.quizState = quizState
        self.isRerecording = isRerecording
        self.setIsAutoRecording = setIsAutoRecording
        self.showAnswerConfirmation = showAnswerConfirmation
        self.setAutoConfirmCountdown = setAutoConfirmCountdown
        self.startRecording = startRecording
        self.stopRecordingAndSubmit = stopRecordingAndSubmit
        self.confirmAnswer = confirmAnswer
        self.proceedToNextQuestion = proceedToNextQuestion
    }

    /// T7 unified reset model: clears this child's own scoped state; task
    /// teardown stays with the façade's `taskBag.cancelAll()`. Not yet wired —
    /// the façade's `resetState`/`transition` invokes this once T7 (S6b) lands.
    func reset() {
        autoAdvanceCountdown = 0
        answerTimerCountdown = 0
        thinkingTimeCountdown = 0
        recordingCountdown = 0
        recordingCountdownTotal = 0
        isPaused = false
    }

    // MARK: - Thinking Time Countdown

    /// Countdown before auto-recording starts, giving user time to think.
    /// Creates a fire-and-forget Task stored in `taskBag` under `.thinkingTime` for cancellation.
    func startThinkingTimeCountdown() {
        // #173: paused means paused. The re-arm guard `startAutoConfirmIfEnabled`
        // has always had, applied to the window the QUESTION screen runs on —
        // without it a question-TTS tail resolved by the pause's own
        // `stopAnyPlayingAudio()` re-armed the countdown behind a paused UI
        // (AudioDeviceState+Playback's post-playback tail only checks the state).
        guard !isPaused else {
            thinkingTimeCountdown = 0
            return
        }

        let thinkingSeconds = settings().thinkingTime

        cancelThinkingTime()
        let owner = attemptLedger.current

        let task = Task { [weak self] in
            guard let self else { return }

            guard thinkingSeconds > 0 else {
                // No thinking time — start recording immediately (500ms delay like before)
                try? await self.clock.sleep(for: .milliseconds(Config.autoRecordDelayMs))
                if Task.isCancelled { return }
                guard self.quizState() == .askingQuestion,
                      self.attemptLedger.ownsQuestion(owner, "thinkingTime.fire") else { return }
                self.attemptLedger.record(.timer, "thinkingTime.fire")
                self.setIsAutoRecording(true)
                await self.startRecording()
                return
            }

            self.thinkingTimeCountdown = thinkingSeconds
            for i in stride(from: thinkingSeconds, through: 1, by: -1) {
                if Task.isCancelled {
                    self.thinkingTimeCountdown = 0
                    return
                }
                // #131 Track B: `.recording` must NOT zero the countdown. The
                // tick and the state flip race whenever recording starts (manual
                // tap, spoken "start", auto-record), and this guard used to win —
                // blanking the number for the frame before `cancelThinkingTime`
                // handed over to `recordingCountdown`. Only a state that has left
                // the answer phase entirely stops it.
                guard self.quizState() == .askingQuestion || self.quizState() == .recording else {
                    self.thinkingTimeCountdown = 0
                    return
                }
                self.thinkingTimeCountdown = i
                try? await self.clock.sleep(for: .seconds(1))
            }

            if Task.isCancelled {
                self.thinkingTimeCountdown = 0
                return
            }
            self.thinkingTimeCountdown = 0

            guard self.quizState() == .askingQuestion,
                  self.attemptLedger.ownsQuestion(owner, "thinkingTime.fire") else { return }
            self.attemptLedger.record(.timer, "thinkingTime.fire")
            self.setIsAutoRecording(true)
            await self.startRecording()
        }
        taskBag.add(task, key: .thinkingTime)
    }

    /// Cancel the thinking time countdown
    func cancelThinkingTime() {
        taskBag.cancel(.thinkingTime)
        thinkingTimeCountdown = 0
    }

    // MARK: - Answer Timer

    /// Start countdown timer that auto-starts recording when it expires.
    /// Skipped while `isRerecording` is true — re-record starts its own
    /// recording immediately (#108A) instead of going through this countdown.
    func startAnswerTimer() {
        // #173: same pause guard as `startThinkingTimeCountdown` — these two are
        // the one answer window, only ever one of them armed at a time.
        guard !isPaused else {
            answerTimerCountdown = 0
            return
        }

        let limit = settings().answerTimeLimit
        guard limit > 0, !isRerecording() else { return }

        cancelAnswerTimer()
        answerTimerCountdown = limit
        let owner = attemptLedger.current

        let task = Task { [weak self] in
            guard let self else { return }

            for remaining in (0 ... limit).reversed() {
                if Task.isCancelled { return }
                // Direct assignment is safe: Task inherits @MainActor isolation from QuizTimersController
                self.answerTimerCountdown = remaining

                if remaining > 0 {
                    try? await self.clock.sleep(for: .seconds(1))
                }
            }

            if Task.isCancelled { return }

            // Auto-start recording when timer expires
            guard self.quizState() == .askingQuestion,
                  self.attemptLedger.ownsQuestion(owner, "answerTimer.fire") else { return }
            self.attemptLedger.record(.timer, "answerTimer.fire")
            await self.startRecording()
        }
        taskBag.add(task, key: .answerTimer)
    }

    /// Cancel the answer countdown timer
    func cancelAnswerTimer() {
        taskBag.cancel(.answerTimer)
        answerTimerCountdown = 0
    }

    // MARK: - Auto-Stop Recording Timer

    /// Arm the recording window: a VISIBLE "time to start speaking" countdown
    /// (`duration`, 5 s) plus a HIDDEN dead-air cap (`hardCap`, 15 s). Always
    /// armed — including re-record attempts (#54 task 54.4): silence detection
    /// is disabled for re-records and never runs on the streaming path, so
    /// these are the only guarantee recording stops on dead air. Both are
    /// injectable for tests; production callers use the defaults.
    ///
    /// #131 Track B: the visible window PUBLISHES `recordingCountdown` once per
    /// second, so the Record→Stop button keeps a live number and draining fill.
    /// #173 (founder 2026-09-07): what it counts is the time to START speaking,
    /// not the whole answer — `speechDetectedDuringRecording()` hides it the
    /// moment the driver is heard and leaves the answer to VAD under the cap.
    /// That is why `duration` is the CALLER's choice: only a capture path with a
    /// speech signal (streaming partials, or auto-record's VAD) may pass the
    /// short window; a path with neither passes the cap itself, or the mic would
    /// close mid-sentence with nothing able to say the driver was speaking.
    /// Either expiry has the same consequence, the one that was already here:
    /// auto-stop + submit whatever was transcribed (nothing, on dead air, which
    /// #171 Track B funnels to the confirmation sheet with an empty field).
    func startAutoStopRecordingTimer(
        duration: TimeInterval = Config.speechStartWindow,
        hardCap: TimeInterval = Config.autoRecordingDuration
    ) {
        cancelAutoStopRecordingTimer()

        // Sub-second durations (tests) collapse to a single tick; production's 15s
        // ticks 15 times. Either way the total elapsed time equals `duration`.
        let ticks = max(1, Int(duration.rounded()))
        let tickInterval = duration / Double(ticks)
        recordingCountdownTotal = ticks
        recordingCountdown = ticks
        let owner = attemptLedger.current

        let task = Task { [weak self] in
            guard let self else { return }

            for remaining in stride(from: ticks - 1, through: 0, by: -1) {
                try? await self.clock.sleep(for: .seconds(tickInterval))
                if Task.isCancelled { return }
                self.recordingCountdown = remaining
            }

            guard self.quizState() == .recording,
                  self.attemptLedger.owns(owner, "recordingWindow.expired") else { return }
            self.attemptLedger.record(.timer, "recordingWindow.expired")
            // #185: ends the recording only if the detector can vouch for
            // the silence; otherwise the countdown hides and the cap decides.
            await self.stopRecordingAndSubmit(.noSpeechWindow)
        }
        taskBag.add(task, key: .autoStopRecording)

        armRecordingDeadAirCap(hardCap)
    }

    /// Arm ONLY the hidden dead-air cap — the guarantee that a recording ends
    /// even when nothing is ever said and no VAD commit arrives.
    ///
    /// It is a task of its own because hiding the visible countdown once the
    /// driver speaks must NOT disarm the guarantee, and it is armed the moment
    /// the mic is asked for (`startRecording`), not when the engine finally
    /// comes up: between those two lines a hung handshake would otherwise leave
    /// a recording with no deadline at all.
    ///
    /// It TICKS once a second like the visible window instead of sleeping the
    /// whole cap in one go. That is the whole point of "hidden CAP": one long
    /// sleep resumes after a SINGLE main-actor round trip, a 15-tick loop after
    /// fifteen — so on a loaded main actor a one-shot cap overtakes the window
    /// it is supposed to sit behind and ends the recording while the button
    /// still shows time left. Ticking both the same way keeps
    /// `cap ≥ visible window` true under any scheduling latency (#173).
    func armRecordingDeadAirCap(_ hardCap: TimeInterval = Config.autoRecordingDuration) {
        let ticks = max(1, Int(hardCap.rounded()))
        let tickInterval = hardCap / Double(ticks)

        let clock = clock
        let owner = attemptLedger.current
        let cap = Task { [weak self] in
            for _ in 0 ..< ticks {
                try? await clock.sleep(for: .seconds(tickInterval))
                if Task.isCancelled { return }
            }
            guard let self, self.quizState() == .recording,
                  self.attemptLedger.owns(owner, "recordingCap.expired") else { return }
            self.attemptLedger.record(.timer, "recordingCap.expired")
            await self.stopRecordingAndSubmit(.cap)
        }
        taskBag.add(cap, key: .recordingHardCap)
    }

    /// The driver started speaking (#173): the "time to start speaking" question
    /// is answered, so the visible countdown stops and disappears
    /// (`recordingCountdownTotal == 0` is the button's "no countdown" contract).
    /// The hidden cap keeps running — a spoken answer still needs a backstop if
    /// no VAD commit ever arrives. Idempotent: every partial transcript calls it.
    func speechDetectedDuringRecording() {
        guard recordingCountdownTotal > 0 else { return }
        taskBag.cancel(.autoStopRecording)
        recordingCountdown = 0
        recordingCountdownTotal = 0
    }

    /// Cancel the recording window — both the visible countdown and the cap.
    func cancelAutoStopRecordingTimer() {
        taskBag.cancel(.autoStopRecording)
        taskBag.cancel(.recordingHardCap)
        recordingCountdown = 0
        recordingCountdownTotal = 0
    }

    // MARK: - Auto-Advance Countdown

    /// Starts the auto-advance countdown loop with real-time UI updates
    func startAutoAdvanceCountdown(duration: Int, audioDuration: TimeInterval) async {
        // Skip auto-advance if the current question is paused
        guard !isPaused else {
            Logger.quiz.debug("⏱️ Auto-advance skipped (paused for current question)")
            autoAdvanceCountdown = 0
            return
        }

        Logger.quiz.debug("⏱️ Auto-advancing in \(duration, privacy: .public)s (audio: \(String(format: "%.1f", audioDuration), privacy: .public)s, reading time + buffer)")

        // `taskBag.add` cancels any previous task under .autoAdvance before
        // installing the new one, so double-fires can't leak a runner.
        autoAdvanceCountdown = duration
        let owner = attemptLedger.current

        let task = Task { [weak self] in
            guard let self else { return }

            // Countdown loop
            for remaining in (0 ... duration).reversed() {
                // Check for cancellation
                if Task.isCancelled {
                    Logger.quiz.debug("⏱️ Auto-advance countdown cancelled")
                    return
                }
                // Direct assignment is safe: Task inherits @MainActor isolation from QuizTimersController
                self.autoAdvanceCountdown = remaining

                if remaining > 0 {
                    try? await self.clock.sleep(for: .seconds(1))
                }
            }

            // Auto-advance after countdown completes
            if Task.isCancelled { return }

            guard self.quizState().isShowingResult else {
                Logger.quiz.debug("⏱️ Auto-advance aborted - not in showingResult state")
                return
            }
            guard self.attemptLedger.ownsQuestion(owner, "autoAdvance.fire") else { return }
            self.attemptLedger.record(.timer, "autoAdvance.fire")

            // #186 step 2 (found by the sequence harness): hand off to a fresh
            // task, as auto-confirm does. The advance cancels `.autoAdvance` —
            // THIS task — so running it here ran the whole advance cancelled:
            // the next question's read-out ended the instant it began and a
            // hands-free driver never heard it. The hand-off still answers to
            // the same question ticket.
            Task { [weak self] in
                guard let self, self.attemptLedger.ownsQuestion(owner, "autoAdvance.handoff") else { return }
                await self.proceedToNextQuestion()
            }
        }
        taskBag.add(task, key: .autoAdvance)
    }

    // MARK: - Auto-Confirm Timer

    /// Start a ticking auto-confirm countdown if enabled.
    /// Cancelled by rerecordAnswer() or cancelProcessing().
    /// `duration` is injectable for tests; production callers use the default.
    /// The countdown field itself is façade-resident (confirmation-semantic,
    /// T7 moves it into `ConfirmationState`) — written via the injected closure.
    func startAutoConfirmIfEnabled(duration: Int = Config.autoConfirmDelaySecs) {
        // #171 Track D: paused means paused. This is the re-arm guard, not just
        // a cosmetic one — every path that would restart the window while the
        // sheet is frozen (a foreground return, a late TTS tail) lands here.
        guard !isPaused else {
            setAutoConfirmCountdown(0)
            return
        }
        guard settings().autoConfirmEnabled else {
            setAutoConfirmCountdown(0)
            return
        }
        setAutoConfirmCountdown(duration)
        let clock = clock
        let owner = attemptLedger.current
        let task = Task { [weak self] in
            for remaining in (0 ..< duration).reversed() {
                try? await clock.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                // A pause that races this tick: stop counting rather than let
                // the loop reach zero and auto-confirm behind the frozen sheet.
                guard !self.isPaused else {
                    self.setAutoConfirmCountdown(0)
                    return
                }
                self.setAutoConfirmCountdown(remaining)
            }
            guard let self, !Task.isCancelled else { return }
            guard self.showAnswerConfirmation() else { return }
            // Hand off to a fresh task: confirmAnswer() cancels the auto-confirm
            // task (this one), and the streaming-path submit inside it is
            // cancellation-aware — awaiting it here would throw
            // URLError.cancelled mid-submit and surface the OOPS screen (54.5).
            Task { await self.confirmAnswer(owner) }
        }
        taskBag.add(task, key: .autoConfirm)
    }

    /// Cancel any pending auto-confirm timer
    func cancelAutoConfirm() {
        taskBag.cancel(.autoConfirm)
        setAutoConfirmCountdown(0)
    }
}
