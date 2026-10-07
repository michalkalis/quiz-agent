//
//  MockNetworkService+Scoring.swift
//  Hangs
//
//  Backend-like session scoring for the UI-test mock (#188 G14). A fixed
//  response froze the session at "1 point, 1 answered" while every reply,
//  the skip included, carried a correct verdict, so the end-of-set screen
//  showed a score of 1 next to "3 correct, 30 %". The real backend adds each
//  verdict's points to the session and counts a skip as neither answered
//  nor scored (`flow.py` `_update_participant_score`, answered delta 0 for a
//  skip); this mirrors that so every number on the screen comes from the
//  same verdicts.
//

import Foundation

#if DEBUG
    extension MockNetworkService {
        /// The reply to one text input with the session totals moved on by
        /// its verdict. "skip" turns the template's verdict into a skip.
        func scoredTextInputResponse(input: String, template: QuizResponse) -> QuizResponse {
            let isSkip = input == "skip"
            let evaluation = template.evaluation.map { verdict in
                isSkip
                    ? Evaluation(
                        userAnswer: "",
                        result: .skipped,
                        points: 0,
                        correctAnswer: verdict.correctAnswer,
                        questionId: verdict.questionId,
                        explanation: verdict.explanation,
                        headlineAnswer: verdict.headlineAnswer
                    )
                    : verdict
            }
            if let evaluation {
                trackedScore += evaluation.points
                if !isSkip { trackedAnswered += 1 }
                if evaluation.result == .correct { trackedCorrect += 1 }
            }
            let session = template.session
            let participants = session.participants.enumerated().map { index, participant in
                guard index == 0 else { return participant }
                return Participant(
                    id: participant.id,
                    userId: participant.userId,
                    displayName: participant.displayName,
                    score: trackedScore,
                    answeredCount: trackedAnswered,
                    correctCount: trackedCorrect,
                    lastAnswer: evaluation?.userAnswer,
                    lastResult: evaluation?.result.rawValue,
                    isHost: participant.isHost,
                    isReady: participant.isReady,
                    joinedAt: participant.joinedAt
                )
            }
            return QuizResponse(
                success: template.success,
                message: template.message,
                session: QuizSession(
                    id: session.id,
                    mode: session.mode,
                    phase: session.phase,
                    maxQuestions: session.maxQuestions,
                    currentDifficulty: session.currentDifficulty,
                    category: session.category,
                    language: session.language,
                    participants: participants,
                    expiresAt: session.expiresAt,
                    createdAt: session.createdAt
                ),
                currentQuestion: template.currentQuestion,
                evaluation: evaluation,
                feedbackReceived: template.feedbackReceived,
                audio: template.audio,
                awaitingQuestion: template.awaitingQuestion
            )
        }
    }
#endif
