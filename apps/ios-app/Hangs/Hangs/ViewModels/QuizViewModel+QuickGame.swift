//
//  QuizViewModel+QuickGame.swift
//  Hangs
//
//  #224.8 — "Quick quiz" (canvas D2 + D4). With the setting on, a skipped
//  question lands straight on the next one: no result screen, no explanation,
//  just a short note of the right answer. The skip request itself is the
//  unchanged one (quota, stats and the recap row are written in
//  `handleQuizResponse`); only what the player sees after it differs, and the
//  state moves through the same `.skipping` → `.askingQuestion` transition the
//  deferred-reveal flow already uses. Answered questions still show results.
//

import Foundation

extension QuizViewModel {
    /// How long the "Skipped, correct: X" note stays on the next question.
    static let quickSkipNoteDuration: Duration = .seconds(4)

    /// Whether this evaluation is a skip the quick quiz answers with the note.
    /// The daily challenge keeps its result card (its crowd strip lives there).
    func quickGameSkips(_ evaluation: Evaluation) -> Bool {
        settings.quickGame && activeDaily == nil && evaluation.result == .skipped
    }

    func showQuickSkipNote(_ correctAnswer: String) {
        let answer = correctAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { return }
        quickSkipNote = answer
        taskBag.add(Task { [weak self] in
            guard let self else { return }
            try? await clock.sleep(for: Self.quickSkipNoteDuration)
            guard !Task.isCancelled else { return }
            quickSkipNote = nil
        }, key: .quickSkipNote)
    }

    /// The Home "Quick quiz" row.
    func setQuickGame(_ on: Bool) {
        guard settings.quickGame != on else { return }
        settings.quickGame = on
        trackAnalytics(.quickGameChanged(enabled: on))
    }
}
