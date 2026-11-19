//
//  QuizViewModel+RoundReward.swift
//  Hangs
//
//  #240.9 (founder 2026-11-18): a round had no reward beyond the score. The
//  app counted runs of right answers and never showed them, and the end of
//  the round was only a list. Now the result says "3 in a row" from the third
//  right answer in a row, and the end-of-round screen opens with one line
//  worth remembering.
//

import Foundation

/// The one line the end-of-round screen opens with.
enum RoundHighlight: Equatable {
    /// The longest run of right answers in a row this round (3 or more).
    case bestRun(Int)
    /// The hardest question answered right: its answer.
    case hardestRight(answer: String)
    /// Nothing was right this round.
    case noneRight
}

extension QuizViewModel {
    /// The minimum run the result and the end of the round call out.
    static let streakCallout = 3

    /// "N in a row" on a right result, counted over this round's questions
    /// (a miss or a skip ends the run). Nil below `streakCallout`.
    var resultStreak: Int? {
        guard resultEvaluation?.isCorrect == true else { return nil }
        let run = recapEntries.reversed().prefix { $0.isCorrect }.count
        return run >= Self.streakCallout ? run : nil
    }

    /// Nil before any question was answered.
    var roundHighlight: RoundHighlight? {
        guard !recapEntries.isEmpty else { return nil }
        let bestRun = Self.longestRun(recapEntries)
        if bestRun >= Self.streakCallout { return .bestRun(bestRun) }
        // Newest first, so a tie goes to the later question (`max` keeps the
        // first of equals).
        let hardest = recapEntries.reversed().filter(\.isCorrect).max { lhs, rhs in
            Self.hardness(lhs.difficulty) < Self.hardness(rhs.difficulty)
        }
        guard let hardest else { return .noneRight }
        return .hardestRight(answer: hardest.correctAnswerDisplay)
    }

    private static func longestRun(_ entries: [RecapEntry]) -> Int {
        var best = 0
        var run = 0
        for entry in entries {
            run = entry.isCorrect ? run + 1 : 0
            best = max(best, run)
        }
        return best
    }

    private static func hardness(_ difficulty: String) -> Int {
        switch Question.Difficulty(rawValue: difficulty) {
        case .hard: 3
        case .medium: 2
        case .easy: 1
        case .random, nil: 0
        }
    }
}
