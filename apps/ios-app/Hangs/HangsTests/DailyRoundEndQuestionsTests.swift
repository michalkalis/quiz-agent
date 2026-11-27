//
//  DailyRoundEndQuestionsTests.swift
//  HangsTests
//
//  #251 (founder, TF 1.3 b94, 2026-11-27): "po dohraní dennej výzvy by som
//  chcel vidieť aj zoznam otázok s odpoveďami, aby som si pozrel, čo som
//  dobre a čo zle odpovedal."
//

import Clocks
import Foundation
@testable import Hangs
import SwiftUI
import Testing
import ViewInspector

@Suite("#251 the daily round end lists the questions")
@MainActor
struct DailyRoundEndQuestionsTests {
    private let day = DailyChallengeDay(year: 2026, month: 10, day: 15)

    private typealias Round = (question: String, said: String, answer: String, right: Bool)

    /// The answers go in through the real capture path (`handleQuizResponse`),
    /// as in a played round (`recapEntries` is `private(set)`).
    private func makeView(rounds: [Round]) async -> DailyRoundEndView {
        let state = DailyChallengeFixtures.playedState(date: day.isoDate, language: "sk", marks: [true, false])
        let vm = Fixtures.makeViewModel(clock: AnyClock(TestClock()))
        vm.settings.answerRevealMode = .endOfSet
        vm.currentSession = Fixtures.makeQuizSession()
        for (index, round) in rounds.enumerated() {
            let id = "q_\(index + 1)"
            vm.currentQuestion = Fixtures.makeQuestion(id: id, text: round.question)
            vm.quizState = .processing
            await vm.handleQuizResponse(QuizResponse(
                success: true,
                message: "ok",
                session: Fixtures.makeQuizSession(),
                currentQuestion: Fixtures.makeQuestion(id: "q_next"),
                evaluation: Evaluation(
                    userAnswer: round.said, result: round.right ? .correct : .incorrect, points: round.right ? 1 : 0,
                    correctAnswer: round.answer, questionId: id, explanation: nil
                ),
                feedbackReceived: [],
                audio: nil
            ))
            vm.taskBag.cancel(.deferredAdvance)
        }
        #expect(vm.recapEntries.count == rounds.count)
        vm.activeDaily = DailyRound(day: day, language: "sk", state: state)
        vm.quizState = .finished
        vm.taskBag.cancelAll()
        let network = MockNetworkService()
        network.stubbedDailyState = state
        return DailyRoundEndView(viewModel: vm, daily: DailyChallengeViewModel(network: network, day: day, state: state))
    }

    /// WHY: the tiles say how many were right, not which. The player looks
    /// back at each question and the right answer, the one they missed too.
    @Test("each question shows with its right answer, a missed one included")
    func listsEveryQuestion() async throws {
        let view = await makeView(rounds: [
            ("Hlavné mesto Kanady?", "Ottawa", "Ottawa", true),
            ("Najdlhšia rieka Afriky?", "Kongo", "Níl", false),
        ])
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) { try tree.find(viewWithAccessibilityIdentifier: "daily.questions") }
            let shown = tree.findAll(ViewType.Text.self).compactMap { try? $0.string() }
            for text in ["Hlavné mesto Kanady?", "Ottawa", "Najdlhšia rieka Afriky?", "Níl"] {
                #expect(shown.contains(text), "\(text) missing from \(shown)")
            }
        }
    }

    /// WHY: a challenge played on another phone (or before this launch) has
    /// no answers here; an empty card would look broken.
    @Test("no list without this phone's answers")
    func noListWithoutAnswers() async throws {
        let view = await makeView(rounds: [])
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: (any Error).self) { try tree.find(viewWithAccessibilityIdentifier: "daily.questions") }
        }
    }
}
