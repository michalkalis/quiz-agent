//
//  QuizViewModelDailyChallengeTests.swift
//  HangsTests
//
//  #205 — the daily challenge plays through the ordinary quiz flow. Why each
//  rule matters:
//  - the server owns the day's set, so the app must not create its own
//    session (it would play a random set, and burn free quota the challenge
//    is exempt from), and must not exclude anything (the set is fixed);
//  - a day already played opens its result, never a second attempt;
//  - the crowd strip lives on the result card, so the round reveals every
//    answer even when the player set "reveal at the end";
//  - one challenge a day: no Play Again path, no spoken "again" at the end.
//

import Clocks
import Foundation
@testable import Hangs
import Testing

@MainActor
private func makeDailyViewModel(
    configure: (MockNetworkService) -> Void = { _ in }
) -> (QuizViewModel, MockNetworkService) {
    // A parked TestClock: no quiz timer may move the state under an assertion.
    Fixtures.makeViewModelWithNetwork(clock: AnyClock(TestClock()), configure: configure)
}

private let day = DailyChallengeDay(year: 2026, month: 10, day: 15)

@MainActor
private func playedState() -> DailyChallengeState {
    DailyChallengeFixtures.playedState(date: day.isoDate, language: "sk", marks: DailyChallengeFixtures.goodMarks)
}

@MainActor
private func answer(
    questionId: String,
    result: Evaluation.EvaluationResult,
    crowd: CrowdStrip?,
    finished: Bool = false
) -> QuizResponse {
    QuizResponse(
        success: true,
        message: "Input processed",
        session: Fixtures.makeQuizSession(phase: finished ? "finished" : "asking", maxQuestions: 5),
        currentQuestion: finished ? nil : Fixtures.makeQuestion(id: "q_next", text: "Next?"),
        evaluation: Evaluation(
            userAnswer: "Libanon", result: result, points: result == .correct ? 1 : 0,
            correctAnswer: "Libanon", questionId: questionId, explanation: nil
        ),
        feedbackReceived: [],
        audio: nil,
        crowd: crowd
    )
}

@Suite("Daily challenge round (#205)")
@MainActor
struct QuizViewModelDailyChallengeTests {
    @Test("a start with a session plays it: no session of its own, nothing excluded")
    func startPlaysServerSession() async {
        let (vm, network) = makeDailyViewModel()
        vm.settings.language = "sk"
        vm.persistenceStore.addQuestionId("seen_before")

        await vm.startNewQuiz(daily: day)

        #expect(network.startDailyChallengeCallCount == 1)
        #expect(network.capturedDailyStartDate == "2026-10-15")
        #expect(network.capturedDailyStartLanguage == "sk")
        #expect(network.createSessionCallCount == 0, "the server owns the daily set; a session of our own plays a random one")
        #expect(network.capturedStartQuizExcludedIds == [], "the daily set is fixed; history must not reach it")
        #expect(network.questionAvailabilityCallCount == 0)
        #expect(vm.quizState == .askingQuestion)
        #expect(vm.activeDaily?.day == day)
        #expect(vm.activeDaily?.language == "sk")
        vm.taskBag.cancelAll()
    }

    @Test("already played today: the start opens the round end, no quiz")
    func playedOpensRoundEnd() async {
        let (vm, network) = makeDailyViewModel { $0.stubbedDailyStart = DailyStartResult(state: playedState(), session: nil) }

        await vm.beginDailyChallenge(day: day).value

        #expect(vm.quizState == .finished)
        #expect(vm.quizScreen == .dailyEnd)
        #expect(vm.activeDaily?.state?.summary?.score == 4)
        #expect(network.capturedStartQuizExcludedIds == nil, "nothing may be played twice")
        #expect(network.createSessionCallCount == 0)
    }

    @Test("the round reveals every answer even with reveal-at-end set")
    func revealIsPerQuestion() async {
        let (vm, _) = makeDailyViewModel()
        vm.settings.answerRevealMode = .endOfSet
        vm.activeDaily = DailyRound(day: day, language: "sk")
        vm.currentSession = Fixtures.makeQuizSession(maxQuestions: 5)
        vm.currentQuestion = Fixtures.makeQuestion(id: "q_001")
        vm.quizState = .processing

        await vm.handleQuizResponse(answer(questionId: "q_001", result: .correct, crowd: DailyChallengeFixtures.rare))

        #expect(vm.quizState.isShowingResult, "the crowd strip lives on the result card")
        #expect(vm.answerRevealMode == .perQuestion)
        #expect(vm.settings.answerRevealMode == .endOfSet, "the player's own setting is untouched")
        vm.taskBag.cancelAll()
    }

    @Test("each answer's crowd strip is kept for its own result card")
    func crowdStoredPerQuestion() async {
        let (vm, _) = makeDailyViewModel()
        vm.activeDaily = DailyRound(day: day, language: "sk")
        vm.currentSession = Fixtures.makeQuizSession(maxQuestions: 5)

        vm.currentQuestion = Fixtures.makeQuestion(id: "q_001")
        vm.quizState = .processing
        await vm.handleQuizResponse(answer(questionId: "q_001", result: .correct, crowd: DailyChallengeFixtures.rare))
        #expect(vm.resultCrowd == DailyChallengeFixtures.rare)

        vm.taskBag.cancelAll()
        vm.currentQuestion = Fixtures.makeQuestion(id: "q_002")
        vm.quizState = .processing
        await vm.handleQuizResponse(answer(questionId: "q_002", result: .incorrect, crowd: nil))

        #expect(vm.resultCrowd == nil, "a wrong answer most others knew has no strip")
        #expect(vm.activeDaily?.crowds["q_001"] == DailyChallengeFixtures.rare)
        #expect(vm.activeDaily?.crowds["q_002"] == nil)
        vm.taskBag.cancelAll()
    }

    @Test("outside a daily round there is never a strip")
    func noStripOutsideDaily() async {
        let (vm, _) = makeDailyViewModel()
        vm.currentSession = Fixtures.makeQuizSession()
        vm.currentQuestion = Fixtures.makeQuestion(id: "q_001")
        vm.quizState = .processing

        await vm.handleQuizResponse(answer(questionId: "q_001", result: .correct, crowd: DailyChallengeFixtures.rare))

        #expect(vm.resultCrowd == nil)
        vm.taskBag.cancelAll()
    }

    @Test("the last answer ends on the daily round end, silently, with no 'again' armed")
    func lastAnswerEndsOnDailyRoundEnd() async {
        let (vm, network) = makeDailyViewModel()
        vm.activeDaily = DailyRound(day: day, language: "sk")
        vm.currentSession = Fixtures.makeQuizSession(maxQuestions: 5)
        vm.currentQuestion = Fixtures.makeQuestion(id: "q_005")
        vm.quizState = .processing
        await vm.handleQuizResponse(answer(questionId: "q_005", result: .correct, crowd: nil, finished: true))

        await vm.proceedToNextQuestion()

        #expect(vm.quizState == .finished)
        #expect(vm.quizScreen == .dailyEnd, "never the score screen with its Play Again and upsell")
        // A set-end line would be on its way by now.
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        #expect(network.synthesizedTexts.isEmpty, "the regular set-end line names 'again'")
        #expect(!vm.quizEndCommandsArmed, "a spoken 'again' must not start a second attempt")
        vm.taskBag.cancelAll()
    }

    @Test("a failed daily start retries the daily challenge, not a regular quiz")
    func retryAfterFailedStart() async {
        let (vm, network) = makeDailyViewModel {
            $0.startDailyChallengeError = NetworkError.serverError(statusCode: 500, message: "boom")
        }
        await vm.startNewQuiz(daily: day)
        #expect(vm.quizState.isError)

        network.startDailyChallengeError = nil
        network.stubbedDailyStart = DailyStartResult(state: playedState(), session: nil)
        await vm.retryFromErrorScreen().value

        #expect(network.startDailyChallengeCallCount == 2)
        #expect(network.createSessionCallCount == 0)
        #expect(vm.quizScreen == .dailyEnd)
    }

    @Test("Home and the next regular start leave the daily round behind")
    func dailyMarkerIsCleared() async {
        let (vm, _) = makeDailyViewModel { $0.stubbedDailyStart = DailyStartResult(state: playedState(), session: nil) }
        await vm.startNewQuiz(daily: day)
        vm.resetToHome()
        #expect(vm.activeDaily == nil)

        await vm.startNewQuiz(daily: day)
        #expect(vm.quizState == .finished)
        await vm.startNewQuiz()
        #expect(vm.activeDaily == nil, "a regular quiz after the daily one must reveal and end as usual")
        vm.taskBag.cancelAll()
    }

    @Test("the round end's fallback marks are the round as this phone saw it")
    func localMarks() async {
        let (vm, _) = makeDailyViewModel()
        vm.activeDaily = DailyRound(day: day, language: "sk")
        vm.currentSession = Fixtures.makeQuizSession(maxQuestions: 5)
        vm.currentQuestion = Fixtures.makeQuestion(id: "q_001")
        vm.quizState = .processing
        await vm.handleQuizResponse(answer(questionId: "q_001", result: .correct, crowd: nil))
        vm.taskBag.cancelAll()

        let content = DailyRoundEndContent(state: nil, localMarks: vm.localDailyMarks, round: vm.activeDaily!)
        #expect(content.marks == [true, nil, nil, nil, nil])
        #expect(content.score == 1)
        #expect(content.comparison == nil, "no crowd line before the server's")
    }
}
