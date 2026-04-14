//
//  QuizViewModel+Timers.swift
//  CarQuiz
//
//  Timer management: thinking time, answer timer, auto-stop, auto-advance, auto-confirm
//

import Foundation
import os

// MARK: - Timer Management

extension QuizViewModel {

    // MARK: - Thinking Time Countdown

    /// Countdown before auto-recording starts, giving user time to think
    func startThinkingTimeCountdown() async {
        let thinkingSeconds = settings.thinkingTime
        guard thinkingSeconds > 0 else {
            // No thinking time — start recording immediately (500ms delay like before)
            try? await Task.sleep(nanoseconds: Config.autoRecordDelayMs * 1_000_000)
            guard quizState == .askingQuestion else { return }
            isAutoRecording = true
            await startRecording()
            return
        }

        thinkingTimeCountdown = thinkingSeconds
        for i in stride(from: thinkingSeconds, through: 1, by: -1) {
            guard quizState == .askingQuestion else { return }
            thinkingTimeCountdown = i
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
        }
        thinkingTimeCountdown = 0

        guard quizState == .askingQuestion else { return }
        isAutoRecording = true
        await startRecording()
    }

    /// Cancel the thinking time countdown
    func cancelThinkingTime() {
        thinkingTimeTask?.cancel()
        thinkingTimeTask = nil
        thinkingTimeCountdown = 0
    }

    // MARK: - Answer Timer

    /// Start countdown timer that auto-starts recording when it expires
    func startAnswerTimer() {
        let limit = settings.answerTimeLimit
        guard limit > 0, !isRerecording else { return }

        cancelAnswerTimer()
        answerTimerCountdown = limit

        answerTimerTask = Task { [weak self] in
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
            await self.startRecording()
        }
    }

    /// Cancel the answer countdown timer
    func cancelAnswerTimer() {
        answerTimerTask?.cancel()
        answerTimerTask = nil
        answerTimerCountdown = 0
    }

    // MARK: - Auto-Stop Recording Timer

    /// Start a timer that auto-stops recording after Config.autoRecordingDuration
    func startAutoStopRecordingTimer() {
        guard !isRerecording else { return }

        cancelAutoStopRecordingTimer()

        autoStopRecordingTask = Task { [weak self] in
            guard let self else { return }

            try? await Task.sleep(nanoseconds: UInt64(Config.autoRecordingDuration * 1_000_000_000))

            if Task.isCancelled { return }

            guard self.quizState == .recording else { return }
            await self.stopRecordingAndSubmit()
        }
    }

    /// Cancel the auto-stop recording timer
    func cancelAutoStopRecordingTimer() {
        autoStopRecordingTask?.cancel()
        autoStopRecordingTask = nil
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

        // Cancel any previous auto-advance task before starting a new one.
        // Without this, calling startAutoAdvanceCountdown twice would leave the first
        // task running without a reference to cancel it.
        autoAdvanceTask?.cancel()
        autoAdvanceCountdown = duration

        autoAdvanceTask = Task { [weak self] in
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
        autoConfirmTask?.cancel()
        autoConfirmTask = Task { [weak self] in
            for remaining in (0 ..< duration).reversed() {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                self.autoConfirmCountdown = remaining
            }
            guard let self, !Task.isCancelled else { return }
            guard self.showAnswerConfirmation else { return }
            await self.confirmAnswer()
        }
    }

    /// Cancel any pending auto-confirm timer
    func cancelAutoConfirm() {
        autoConfirmTask?.cancel()
        autoConfirmTask = nil
        autoConfirmCountdown = 0
    }
}
