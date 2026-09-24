//
//  ScreenAwakeController.swift
//  Hangs
//
//  Issue #108C: keep the screen awake for the duration of an active quiz —
//  the founder reported the display dimming/locking mid-drive, including on
//  the result screen. `UIApplication.shared.isIdleTimerDisabled` was set
//  nowhere in the app before this.
//

import Foundation
import UIKit

/// Pure decision seam: should the idle timer be disabled for this
/// `(quizState, isMinimized, isNarratingRecap)` triple? Kept free of
/// `UIApplication` so it is trivially unit-testable across every `QuizState`
/// case.
enum ScreenAwakeController {
    /// Awake for every state except `.idle` (home) and `.finished`
    /// (completion) — and never while the quiz is minimized, since
    /// QuestionView/ResultView aren't the visible screen at that point.
    /// `.showingResult` counts as active on purpose (the founder's report was
    /// specifically about the result screen dimming).
    ///
    /// `.finished` is the exception: #185 finding 7 — in end-of-set reveal
    /// mode, `SetRecapView` plays the recap narration (score + every
    /// question's verdict/answer/explanation, `QuizViewModel+Recap.swift`)
    /// while `quizState` stays `.finished` the whole time. The screen must
    /// stay awake for that narration and only sleep once it stops (playback
    /// ends, or the user leaves the recap).
    nonisolated static func shouldKeepScreenAwake(state: QuizState, isMinimized: Bool, isNarratingRecap: Bool) -> Bool {
        guard !isMinimized else { return false }
        switch state {
        case .idle:
            return false
        case .finished:
            return isNarratingRecap
        default:
            return true
        }
    }
}

/// Thin, injectable wrapper around `UIApplication.shared.isIdleTimerDisabled`
/// so tests can assert against a spy instead of the real singleton. ContentView
/// owns one instance and calls `apply` from `.onChange`/`.onAppear` and `reset`
/// from `.onDisappear` — the only two write paths, so the singleton write stays
/// in this one place.
@MainActor
struct ScreenAwakeWriter {
    var setIdleTimerDisabled: (Bool) -> Void = { UIApplication.shared.isIdleTimerDisabled = $0 }

    /// Recompute and apply the idle-timer flag for the given quiz state.
    func apply(state: QuizState, isMinimized: Bool, isNarratingRecap: Bool = false) {
        setIdleTimerDisabled(ScreenAwakeController.shouldKeepScreenAwake(
            state: state, isMinimized: isMinimized, isNarratingRecap: isNarratingRecap
        ))
    }

    /// Force the idle timer back on. Called on teardown so the flag never
    /// leaks past this view's lifetime (e.g. if the app is killed mid-quiz).
    func reset() {
        setIdleTimerDisabled(false)
    }
}
