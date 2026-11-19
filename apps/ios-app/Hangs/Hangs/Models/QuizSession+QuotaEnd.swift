//
//  QuizSession+QuotaEnd.swift
//  Hangs
//
//  #240.9 (founder 2026-11-18): the monthly limit reached mid-round. The
//  server graded the last answer, scored it and finished the session, but its
//  429 carries only the verdict, not the session. This is the session as the
//  server left it, so the result and the end of the round count that answer.
//

import Foundation

extension QuizSession {
    func finishedByQuota(scoring evaluation: Evaluation) -> QuizSession {
        let answered = evaluation.wasSkipped ? 0 : 1
        let scored = participants.enumerated().map { index, participant in
            guard index == 0 else { return participant }
            return Participant(
                id: participant.id,
                userId: participant.userId,
                displayName: participant.displayName,
                score: participant.score + evaluation.points,
                answeredCount: participant.answeredCount + answered,
                correctCount: participant.correctCount + (evaluation.isCorrect ? 1 : 0),
                lastAnswer: participant.lastAnswer,
                lastResult: evaluation.result.rawValue,
                isHost: participant.isHost,
                isReady: participant.isReady,
                joinedAt: participant.joinedAt
            )
        }
        return QuizSession(
            id: id,
            mode: mode,
            phase: Phase.finished.rawValue,
            maxQuestions: maxQuestions,
            currentDifficulty: currentDifficulty,
            category: category,
            language: language,
            participants: scored,
            expiresAt: expiresAt,
            createdAt: createdAt,
            askedCount: askedCount,
            ageBand: ageBand
        )
    }
}
