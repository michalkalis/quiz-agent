//
//  QuizViewModel+Timers.swift
//  Hangs
//
//  Timer management: thinking time, answer timer, auto-stop, auto-advance, auto-confirm
//

import Foundation
import os

// MARK: - Timer Management

extension QuizViewModel {

    // MARK: - Thinking Time Countdown

    /// Countdown before auto-recording starts, giving user time to think.
    /// Creates a fire-and-forget Task stored in `taskBag` under `.thinkingTime` for cancellation.
    func startThinkingTimeCountdown() {
        let thinkingSeconds = settings.thinkingTime

        cancelThinkingTime()

        let task = Task { [weak self] in
            guard let self else { return }

            guard thinkingSeconds > 0 else {
                // No thinking time — start recording immediately (500ms delay like before)
                try? await Task.sleep(nanoseconds: Config.autoRecordDelayMs * 1_000_000)
                if Task.isCancelled { return }
                guard self.quizState == .askingQuestion else { return }
                self.isAutoRecording = true
                await self.startRecording()
                return
            }

            self.thinkingTimeCountdown = thinkingSeconds
            for i in stride(from: thinkingSeconds, through: 1, by: -1) {
                if Task.isCancelled {
                    self.thinkingTimeCountdown = 0
                    return
                }
                guard self.quizState == .askingQuestion else {
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

            guard self.quizState == .askingQuestion else { return }
            self.isAutoRecording = true
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
    ///
    /// - Parameters:
    ///   - extraSeconds: Bonus time added on top of `settings.answerTimeLimit`
    ///     (used by re-record to give the user a fair retry window).
    ///   - bypassRerecord: Allow the timer to run even when `isRerecording` is
    ///     true. Re-record explicitly wants the countdown to keep ticking.
    func startAnswerTimer(extraSeconds: Int = 0, bypassRerecord: Bool = false) {
        let limit = settings.answerTimeLimit + extraSeconds
        guard limit > 0, bypassRerecord || !isRerecording else { return }

        cancelAnswerTimer()
        answerTimerCountdown = limit

        let task = Task { [weak self] in
            guard let self else { return }

            for remaining in (0...limit).reversed() {
                if Task.isCancelled { return }
                // Direct assignment is safe: Task inherits @MainActor isolation from QuizViewModel
                self.answerTimerCountdown = remaining

                if remaining > 0 {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }

            if Task.isCancelled { return }

            // Auto-start recording when timer expires
            guard self.quizState == .askingQuestion else { return }
            // Clear re-record flag so the auto-stop timer fires normally for this attempt
            self.isRerecording = false
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

    /// Start a timer that auto-stops recording after Config.autoRecordingDuration
    func startAutoStopRecordingTimer() {
        guard !isRerecording else { return }

        cancelAutoStopRecordingTimer()

        let task = Task { [weak self] in
            guard let self else { return }

            try? await Task.sleep(nanoseconds: UInt64(Config.autoRecordingDuration * 1_000_000_000))

            if Task.isCancelled { return }

            guard self.quizState == .recording else { return }
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
        // Skip auto-advance if disabled globally OR if current question is paused
        guard autoAdvanceEnabled && !currentQuestionPaused else {
            let reason = !autoAdvanceEnabled ? "disabled globally" : "paused for current question"
            Logger.quiz.debug("⏱️ Auto-advance skipped (\(reason, privacy: .public))")
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
            for remaining in (0...duration).reversed() {
                // Check for cancellation
                if Task.isCancelled {
                    Logger.quiz.debug("⏱️ Auto-advance countdown cancelled")
                    return
                }
                // Direct assignment is safe: Task inherits @MainActor isolation from QuizViewModel
                self.autoAdvanceCountdown = remaining

                if remaining > 0 {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)  // 1 second
                }
            }

            // Auto-advance after countdown completes
            if Task.isCancelled { return }

            guard self.quizState.isShowingResult else {
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
    func startAutoConfirmIfEnabled() {
        guard settings.autoConfirmEnabled else {
            autoConfirmCountdown = 0
            return
        }
        let duration = Config.autoConfirmDelaySecs
        autoConfirmCountdown = duration
        let task = Task { [weak self] in
            for remaining in (0 ..< duration).reversed() {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                self.autoConfirmCountdown = remaining
            }
            guard let self, !Task.isCancelled else { return }
            guard self.showAnswerConfirmation else { return }
            await self.confirmAnswer()
        }
        taskBag.add(task, key: .autoConfirm)
    }

    /// Cancel any pending auto-confirm timer
    func cancelAutoConfirm() {
        taskBag.cancel(.autoConfirm)
        autoConfirmCountdown = 0
    }
}
