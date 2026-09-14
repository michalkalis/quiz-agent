//
//  QuizViewModel+StallWatchdog.swift
//  Hangs
//
//  #179 (founder TF 2026-09-14, findings 3 + 4). Every submit path is now bounded
//  by `withUserFacingTimeout`, but a bound only helps while someone is still
//  awaiting the call. The two freezes the founder hit had no awaiter left: the
//  screen sat in `.processing` (options grey, command bar gone, Skip dead) and in
//  `.skipping` (Skip spinner turning forever), with no transition and no error.
//
//  So the PAIR itself is bounded, not just the requests inside it: entering
//  `.processing`/`.skipping` starts a deadline, leaving it drops the deadline, and
//  a phase that outlives its deadline fails into the ordinary retryable error
//  screen — the same one the MCQ tap timeout produces.
//
//  Deliberately silent while the confirmation sheet is up or an answer is being
//  evaluated on it (#173 C2): those are `.processing` states a person is looking
//  at and acting on, not stalls.
//

import Foundation
import os

extension QuizViewModel {
    /// Arm (or re-arm) the watchdog for the current `.processing`/`.skipping`
    /// phase. The deadline is absolute — measured from `stallEnteredAt` — so
    /// re-arming never hands an already-stuck submission another full window.
    func armStallWatchdog() {
        guard let enteredAt = stallEnteredAt else { return }
        let deadline = enteredAt.addingTimeInterval(stallWatchdogSeconds)
        taskBag.add(Task { [weak self] in
            let remaining = deadline.timeIntervalSinceNow
            if remaining > 0 {
                try? await Task.sleep(for: .seconds(remaining))
            }
            guard !Task.isCancelled else { return }
            await self?.failStalledSubmission()
        }, key: .stallWatchdog)
    }

    /// Re-evaluate the watchdog on a foreground return. `handleScenePhase` did
    /// nothing for `.processing`, so a submission that wedged while the app was
    /// backgrounded had no live owner at all; here a window that fully elapsed out
    /// of sight fails immediately instead of granting a fresh 35 s.
    func rearmStallWatchdog() {
        guard quizState == .processing || quizState == .skipping else { return }
        armStallWatchdog()
    }

    /// Fail a submission that never came back, through the ordinary error path so
    /// the user gets the familiar "Request timed out" screen with Try Again
    /// (`AppErrorModel.from` maps `URLError.timedOut` to `.retryOperation`).
    private func failStalledSubmission() async {
        guard quizState == .processing || quizState == .skipping else { return }
        guard !showAnswerConfirmation, !isEvaluatingAnswer else { return }

        let isSkip = quizState == .skipping
        let state = quizState.label
        Logger.quiz.error("⏱️ Submission stalled in \(state, privacy: .public) — failing with retry")
        SentryLog.error("submission stalled", category: .quiz, attributes: [
            "state": state, "seconds": Int(stallWatchdogSeconds),
        ])

        await handleError(
            URLError(.timedOut),
            context: .submission,
            fallbackMessage: isSkip
                ? String(localized: "Failed to skip question", comment: "Error prefix when skipping a question fails; error detail is appended")
                : String(localized: "Failed to submit answer", comment: "Error prefix when submitting an answer fails; error detail is appended")
        )
    }
}
