//
//  QuizTimersController.swift
//  Hangs
//
//  The timer slice extracted from QuizViewModel (#113 T4): thinking-time,
//  answer-timer, auto-stop-recording, auto-advance and auto-confirm
//  start/cancel, plus the countdown state the views read.
//

import Combine
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
    // Per-question pause state (resets on next question)
    @Published var currentQuestionPaused: Bool = false

    /// The façade's shared task owner (decision 4 register/cancel handle).
    let taskBag: TaskBag

    // MARK: - Injected façade closures (decision 4 — scoped reads/writes, never a vm ref)

    let settings: @MainActor () -> QuizSettings
    let quizState: @MainActor () -> QuizState
    let isRerecording: @MainActor () -> Bool
    let setIsAutoRecording: @MainActor (Bool) -> Void
    let showAnswerConfirmation: @MainActor () -> Bool
    let setAutoConfirmCountdown: @MainActor (Int) -> Void
    let startRecording: @MainActor () async -> Void
    let stopRecordingAndSubmit: @MainActor () async -> Void
    let confirmAnswer: @MainActor () async -> Void
    let proceedToNextQuestion: @MainActor () async -> Void

    init(
        taskBag: TaskBag,
        settings: @escaping @MainActor () -> QuizSettings,
        quizState: @escaping @MainActor () -> QuizState,
        isRerecording: @escaping @MainActor () -> Bool,
        setIsAutoRecording: @escaping @MainActor (Bool) -> Void,
        showAnswerConfirmation: @escaping @MainActor () -> Bool,
        setAutoConfirmCountdown: @escaping @MainActor (Int) -> Void,
        startRecording: @escaping @MainActor () async -> Void,
        stopRecordingAndSubmit: @escaping @MainActor () async -> Void,
        confirmAnswer: @escaping @MainActor () async -> Void,
        proceedToNextQuestion: @escaping @MainActor () async -> Void
    ) {
        self.taskBag = taskBag
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
        currentQuestionPaused = false
    }

    // MARK: - Thinking Time Countdown

    /// Countdown before auto-recording starts, giving user time to think.
    /// Creates a fire-and-forget Task stored in `taskBag` under `.thinkingTime` for cancellation.
    func startThinkingTimeCountdown() {
        let thinkingSeconds = settings().thinkingTime

        cancelThinkingTime()

        let task = Task { [weak self] in
            guard let self else { return }

            guard thinkingSeconds > 0 else {
                // No thinking time — start recording immediately (500ms delay like before)
                try? await Task.sleep(nanoseconds: Config.autoRecordDelayMs * 1_000_000)
                if Task.isCancelled { return }
                guard self.quizState() == .askingQuestion else { return }
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
                guard self.quizState() == .askingQuestion else {
                    self.thinkingTimeCountdown = 0
                    return
                }
                self.thinkingTimeCountdown = i
                try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
            }

            if Task.isCancelled {
                self.thinkingTimeCountdown = 0
                return
            }
            self.thinkingTimeCountdown = 0

            guard self.quizState() == .askingQuestion else { return }
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
        let limit = settings().answerTimeLimit
        guard limit > 0, !isRerecording() else { return }

        cancelAnswerTimer()
        answerTimerCountdown = limit

        let task = Task { [weak self] in
            guard let self else { return }

            for remaining in (0 ... limit).reversed() {
                if Task.isCancelled { return }
                // Direct assignment is safe: Task inherits @MainActor isolation from QuizTimersController
                self.answerTimerCountdown = remaining

                if remaining > 0 {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }

            if Task.isCancelled { return }

            // Auto-start recording when timer expires
            guard self.quizState() == .askingQuestion else { return }
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

    /// Start a timer that auto-stops recording after `duration`.
    /// Always armed — including re-record attempts (#54 task 54.4): silence
    /// detection is disabled for re-records and never runs on the streaming
    /// path, so this hard cap is the only guarantee recording stops on dead air.
    /// `duration` is injectable for tests; production callers use the default.
    func startAutoStopRecordingTimer(duration: TimeInterval = Config.autoRecordingDuration) {
        cancelAutoStopRecordingTimer()

        let task = Task { [weak self] in
            guard let self else { return }

            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))

            if Task.isCancelled { return }

            guard self.quizState() == .recording else { return }
            await self.stopRecordingAndSubmit()
        }
        taskBag.add(task, key: .autoStopRecording)
    }

    /// Cancel the auto-stop recording timer
    func cancelAutoStopRecordingTimer() {
        taskBag.cancel(.autoStopRecording)
    }

    // MARK: - Auto-Advance Countdown

    /// Starts the auto-advance countdown loop with real-time UI updates
    func startAutoAdvanceCountdown(duration: Int, audioDuration: TimeInterval) async {
        // Skip auto-advance if the current question is paused
        guard !currentQuestionPaused else {
            Logger.quiz.debug("⏱️ Auto-advance skipped (paused for current question)")
            autoAdvanceCountdown = 0
            return
        }

        Logger.quiz.debug("⏱️ Auto-advancing in \(duration, privacy: .public)s (audio: \(String(format: "%.1f", audioDuration), privacy: .public)s, reading time + buffer)")

        // `taskBag.add` cancels any previous task under .autoAdvance before
        // installing the new one, so double-fires can't leak a runner.
        autoAdvanceCountdown = duration

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
                    try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
                }
            }

            // Auto-advance after countdown completes
            if Task.isCancelled { return }

            guard self.quizState().isShowingResult else {
                Logger.quiz.debug("⏱️ Auto-advance aborted - not in showingResult state")
                return
            }

            await self.proceedToNextQuestion()
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
        guard settings().autoConfirmEnabled else {
            setAutoConfirmCountdown(0)
            return
        }
        setAutoConfirmCountdown(duration)
        let task = Task { [weak self] in
            for remaining in (0 ..< duration).reversed() {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                self.setAutoConfirmCountdown(remaining)
            }
            guard let self, !Task.isCancelled else { return }
            guard self.showAnswerConfirmation() else { return }
            // Hand off to a fresh task: confirmAnswer() cancels the auto-confirm
            // task (this one), and the streaming-path submit inside it is
            // cancellation-aware — awaiting it here would throw
            // URLError.cancelled mid-submit and surface the OOPS screen (54.5).
            Task { await self.confirmAnswer() }
        }
        taskBag.add(task, key: .autoConfirm)
    }

    /// Cancel any pending auto-confirm timer
    func cancelAutoConfirm() {
        taskBag.cancel(.autoConfirm)
        setAutoConfirmCountdown(0)
    }
}
