//
//  MockNetworkService+Daily.swift
//  Hangs
//
//  #205 daily challenge on the mock: the two endpoints, and (UI-test mode)
//  a scripted challenge that plays like the backend — five fixed questions,
//  a crowd strip on each answer, the session finished after the fifth, and
//  from then on the played result for both the Home card and a new start.
//

import Foundation

#if DEBUG
    extension MockNetworkService {
        func fetchDailyChallenge(date: String, language: String) async throws -> DailyChallengeState {
            fetchDailyChallengeCallCount += 1
            capturedDailyFetchDate = date
            capturedDailyFetchLanguage = language
            if let fetchDailyChallengeError { throw fetchDailyChallengeError }
            if let stubbedDailyState { return stubbedDailyState }
            if let dailyScript { return dailyScript.state(date: date, language: language) }
            return DailyChallengeState(date: date, language: language, status: .notPlayed, total: 5, summary: nil)
        }

        func startDailyChallenge(date: String, language: String) async throws -> DailyStartResult {
            startDailyChallengeCallCount += 1
            capturedDailyStartDate = date
            capturedDailyStartLanguage = language
            if let startDailyChallengeError { throw startDailyChallengeError }
            if let stubbedDailyStart { return stubbedDailyStart }
            if let dailyScript { return dailyScript.start(date: date, language: language) }
            guard let session = mockSession else { throw NetworkError.invalidResponse }
            return DailyStartResult(
                state: DailyChallengeState(date: date, language: language, status: .inProgress, total: 5, summary: nil),
                session: session
            )
        }
    }

    /// One scripted daily challenge (UI-test mock graph). `playedMarks` set =
    /// today is already played with these outcomes.
    final class DailyMockScript {
        static let sessionId = "daily_session_ui"

        private let questions = DailyChallengeFixtures.questions
        private var index = 0
        private(set) var marks: [Bool?]
        private var played: Bool

        init(playedMarks: [Bool?]? = nil) {
            marks = playedMarks ?? []
            played = playedMarks != nil
        }

        func state(date: String, language: String) -> DailyChallengeState {
            guard played else {
                let status: DailyChallengeState.Status = marks.isEmpty ? .notPlayed : .inProgress
                return DailyChallengeState(date: date, language: language, status: status, total: questions.count, summary: nil)
            }
            return DailyChallengeFixtures.playedState(date: date, language: language, marks: marks)
        }

        func start(date: String, language: String) -> DailyStartResult {
            if played { return DailyStartResult(state: state(date: date, language: language), session: nil) }
            index = 0
            marks = []
            return DailyStartResult(state: state(date: date, language: language), session: session(asked: 1, finished: false))
        }

        func startResponse(sessionId: String) -> QuizResponse? {
            guard sessionId == Self.sessionId, !played else { return nil }
            return response(question: questions[0], evaluation: nil, crowd: nil, asked: 1, finished: false)
        }

        /// The answer to the current question; a skip is a miss.
        func answer(sessionId: String, input: String) -> QuizResponse? {
            guard sessionId == Self.sessionId, !played, index < questions.count else { return nil }
            let scripted = questions[index]
            let isSkip = input == "skip"
            let correct = !isSkip && scripted.knows
            let evaluation = Evaluation(
                userAnswer: isSkip ? "" : (correct ? scripted.answer : input),
                result: isSkip ? .skipped : (correct ? .correct : .incorrect),
                points: correct ? 1 : 0,
                correctAnswer: scripted.answer,
                questionId: scripted.question.id,
                explanation: scripted.question.explanation
            )
            marks.append(correct)
            index += 1
            let finished = index == questions.count
            if finished { played = true }
            return response(
                question: finished ? nil : questions[index],
                evaluation: evaluation,
                crowd: correct ? scripted.crowdIfKnown : scripted.crowdIfMissed,
                asked: min(index + 1, questions.count),
                finished: finished
            )
        }

        private func session(asked: Int, finished: Bool) -> QuizSession {
            let correct = marks.count { $0 == true }
            var session = QuizSession(
                id: Self.sessionId,
                mode: "single",
                phase: finished ? "finished" : "asking",
                maxQuestions: questions.count,
                currentDifficulty: "random",
                category: nil,
                language: "sk",
                participants: [
                    Participant(
                        id: "p_daily", userId: nil, displayName: "Player",
                        score: Double(correct), answeredCount: marks.count, correctCount: correct,
                        lastAnswer: nil, lastResult: nil, isHost: true, isReady: true, joinedAt: Date()
                    ),
                ],
                expiresAt: Date().addingTimeInterval(30 * 60),
                createdAt: Date()
            )
            session.askedCount = asked
            return session
        }

        private func response(
            question: DailyChallengeFixtures.ScriptedQuestion?,
            evaluation: Evaluation?,
            crowd: CrowdStrip?,
            asked: Int,
            finished: Bool
        ) -> QuizResponse {
            QuizResponse(
                success: true,
                message: evaluation == nil ? "Quiz started" : "Input processed",
                session: session(asked: asked, finished: finished),
                currentQuestion: question?.question,
                evaluation: evaluation,
                feedbackReceived: [],
                audio: nil,
                crowd: crowd
            )
        }
    }
#endif
