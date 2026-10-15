//
//  QuizViewModel+DailyChallenge.swift
//  Hangs
//
//  #205 — daily challenge: player vs the crowd. The round plays through the
//  ordinary quiz flow (same screens, same voice flow); the start and the
//  round's rules live in `startNewQuiz(daily:)` and on `DailyRound`.
//

import Foundation

extension QuizViewModel {
    /// The Home card's play control, played or not: the server either hands
    /// back a session to play or, already played today, the result, which
    /// opens the daily round end. Cancellable like every other start.
    @discardableResult
    func beginDailyChallenge(day: DailyChallengeDay) -> Task<Void, Never> {
        beginQuizStart(daily: day)
    }

    /// A daily challenge start is in flight (the card's control spins).
    var isStartingDailyChallenge: Bool {
        quizState == .startingQuiz && activeDaily != nil
    }

    /// The crowd strip of the result on screen; nil outside a daily round.
    var resultCrowd: CrowdStrip? {
        guard let id = resultQuestion?.id else { return nil }
        return activeDaily?.crowds[id]
    }

    /// The round's marks as this phone saw them, for the round end before the
    /// server's summary arrives: knew it or not (a skip did not know it).
    var localDailyMarks: [Bool?] {
        recapEntries.map { $0.isCorrect }
    }
}
