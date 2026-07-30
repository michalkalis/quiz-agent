//
//  RecapEntry.swift
//  Hangs
//
//  #132 Track E (founder pick 2026-07-29, recap variant C "Zoznam s rozbalením"):
//  one answered (or skipped) question of the running set, captured at result
//  time for the end-of-set recap. Display-ready — the strings are frozen the
//  moment the evaluation arrives (already translated by the backend since
//  #132 D), so the recap can never drift from what the result screen would
//  have shown. Sessions are in-memory on the backend by design; the client is
//  the only place this history can live.
//

import Foundation

struct RecapEntry: Identifiable, Equatable, Sendable {
    /// 1-based question number in the set — doubles as the stable identity.
    let id: Int
    let questionText: String
    let category: String
    let result: Evaluation.EvaluationResult
    /// What the driver answered, nil on a skip (nothing was said, #131 D).
    let userAnswerDisplay: String?
    /// The revealed answer: the short `headlineAnswer` gist when the evaluator
    /// scored against one, else the full correct answer — the same reveal rule
    /// as ResultView (46.B9); MCQ pairs letter and text ("B — Pyramída").
    let correctAnswerDisplay: String
    let explanation: String?

    var wasSkipped: Bool { result == .skipped }
    /// The recap's ✓ bucket — mirrors `Evaluation.isCorrect` (only a full
    /// `.correct`; partials read as "vedľa" exactly like the result screen).
    var isCorrect: Bool { result == .correct }

    /// Captures the just-evaluated question. `number` is 1-based.
    init(number: Int, question: Question, evaluation: Evaluation) {
        id = number
        questionText = question.question
        category = question.category
        result = evaluation.result
        let said = evaluation.userAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
        userAnswerDisplay = (evaluation.wasSkipped || said.isEmpty)
            ? nil : question.labelledAnswer(said)
        correctAnswerDisplay = question.labelledAnswer(
            evaluation.headlineAnswer ?? evaluation.correctAnswer
        )
        explanation = evaluation.explanation?.trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
