//
//  MockNetworkService+Family.swift
//  Hangs
//
//  #236 on the UI-test mock: a scripted family round that plays like the
//  server's: as many questions as the app asked for (6 for 4–6, 10 otherwise),
//  the session echoes the band, the start says whether it repeats played
//  questions, each answer is graded against the script, and the session
//  finishes after the last question.
//

import Foundation

#if DEBUG
    /// One scripted family round (UI-test mock graph). The questions follow
    /// the band the round was started with: 4–6 a choice of two, else voice;
    /// the script's questions repeat to fill the round.
    final class FamilyMockScript {
        static let sessionId = "family_session_ui"

        private let repeats: Bool
        private var band: String?
        private var size = 0
        private var index = 0
        private var correct = 0

        init(repeats: Bool) {
            self.repeats = repeats
        }

        /// The round's question number `position` (0-based).
        private func scripted(_ position: Int) -> (question: Question, answer: String) {
            FamilyModeFixtures.roundQuestion(choice: band == FamilyBand.kids4to6.rawValue, number: position + 1)
        }

        /// `createSession` with an `age_band`: a fresh round of `size` questions.
        func session(band: String, size: Int) -> QuizSession {
            self.band = band
            self.size = size
            index = 0
            correct = 0
            return session(asked: 1, finished: false)
        }

        func startResponse(sessionId: String) -> QuizResponse? {
            guard sessionId == Self.sessionId, band != nil else { return nil }
            return response(question: scripted(0).question, evaluation: nil, asked: 1, finished: false, repeats: repeats)
        }

        /// The answer to the current question; "skip" is a skip.
        func answer(sessionId: String, input: String) -> QuizResponse? {
            guard sessionId == Self.sessionId, band != nil, index < size else { return nil }
            let current = scripted(index)
            let isSkip = input == "skip"
            let isRight = !isSkip && input.caseInsensitiveCompare(current.answer) == .orderedSame
            if isRight { correct += 1 }
            let evaluation = Evaluation(
                userAnswer: isSkip ? "" : input,
                result: isSkip ? .skipped : (isRight ? .correct : .incorrect),
                points: isRight ? 1 : 0,
                correctAnswer: current.answer,
                questionId: current.question.id,
                explanation: current.question.explanation
            )
            index += 1
            let finished = index == size
            return response(
                question: finished ? nil : scripted(index).question,
                evaluation: evaluation,
                asked: min(index + 1, size),
                finished: finished,
                repeats: nil
            )
        }

        private func session(asked: Int, finished: Bool) -> QuizSession {
            var session = QuizSession(
                id: Self.sessionId,
                mode: "single",
                phase: finished ? "finished" : "asking",
                maxQuestions: size,
                currentDifficulty: "random",
                category: scripted(0).question.category,
                language: "sk",
                participants: [
                    Participant(
                        id: "p_family", userId: nil, displayName: "Player",
                        score: Double(correct), answeredCount: index, correctCount: correct,
                        lastAnswer: nil, lastResult: nil, isHost: true, isReady: true, joinedAt: Date()
                    ),
                ],
                expiresAt: Date().addingTimeInterval(30 * 60),
                createdAt: Date()
            )
            session.askedCount = asked
            session.ageBand = band
            return session
        }

        private func response(
            question: Question?, evaluation: Evaluation?, asked: Int, finished: Bool, repeats: Bool?
        ) -> QuizResponse {
            QuizResponse(
                success: true,
                message: evaluation == nil ? "Quiz started" : "Input processed",
                session: session(asked: asked, finished: finished),
                currentQuestion: question,
                evaluation: evaluation,
                feedbackReceived: [],
                audio: nil,
                repeats: repeats
            )
        }
    }
#endif
