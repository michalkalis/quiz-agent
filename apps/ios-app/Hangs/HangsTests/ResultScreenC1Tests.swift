//
//  ResultScreenC1Tests.swift
//  HangsTests
//
//  TF build 90 (founder pick C1, docs/artifacts/tf90-layouts.html): the result
//  card shows the question's own answer (an accepted "solo" was printed as the
//  answer to "soľ"), says what was heard only when it differs, keeps the
//  question one tap away in a sheet that holds the auto-advance, and drops
//  the STAY pill the toolbar's pause already covers.
//

@testable import Hangs
import SwiftUI
import Testing
import ViewInspector

@Suite("TF build 90 (C1): the result shows the question's answer, the question one tap away")
@MainActor
struct ResultScreenC1Tests {
    private static let openQuestion = Question(
        id: "q_salt", question: "Which mineral did Roman soldiers get part of their pay in?", type: .text,
        possibleAnswers: nil, difficulty: "medium", topic: "History", category: "history",
        sourceUrl: "https://en.wikipedia.org/wiki/Salt", sourceExcerpt: nil, mediaUrl: nil,
        imageSubtype: nil, explanation: "The word salary comes from it.", generatedBy: nil
    )

    private static let mcqQuestion = Question(
        id: "q_mcq", question: "Which structure is in Giza?", type: .textMultichoice,
        possibleAnswers: ["a": "Colosseum", "b": "Pyramid", "c": "Parthenon", "d": "Stonehenge"],
        difficulty: "easy", topic: "History", category: "history",
        sourceUrl: nil, sourceExcerpt: nil, mediaUrl: nil, imageSubtype: nil,
        explanation: nil, generatedBy: nil
    )

    private func makeViewModel(
        _ evaluation: Evaluation,
        question: Question = openQuestion,
        analytics: MockAnalyticsClient = MockAnalyticsClient()
    ) -> QuizViewModel {
        let vm = QuizViewModel(
            networkService: MockNetworkService(),
            audioService: MockAudioService(),
            persistenceStore: MockPersistenceStore(),
            silenceDetectionService: MockSilenceDetectionService(),
            analytics: analytics
        )
        vm.currentSession = Fixtures.makeActiveSession()
        vm.quizState = .showingResult(question: question, evaluation: evaluation)
        return vm
    }

    private func accepted(_ said: String, correct: String) -> Evaluation {
        Evaluation(userAnswer: said, result: .correct, points: 1.0, correctAnswer: correct, questionId: "q", explanation: nil)
    }

    // MARK: - The answer on the card

    /// The founder's TF build 90 bug: the evaluator accepted the transcript
    /// "solo" for "soľ", and the card printed "solo" in large type as if it
    /// were the answer. The card's answer is the question's, always.
    @Test("an accepted answer heard differently shows the question's answer, and what was heard")
    func acceptedTranscriptShowsCanonicalAnswer() async throws {
        let view = ResultView(viewModel: makeViewModel(accepted("solo", correct: "Soľ")))
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            let answer = try tree.find(viewWithAccessibilityIdentifier: "result.answer")
            #expect(try answer.text().string() == "Soľ")
            #expect(throws: Never.self) { try tree.find(text: "the answer") }
            #expect(throws: (any Error).self, "\"your answer\" labelled the transcript") { try tree.find(text: "your answer") }
            #expect(throws: Never.self, "what was heard stays visible, quietly") {
                try tree.find(viewWithAccessibilityIdentifier: "result.heard")
            }
            #expect(throws: (any Error).self, "an accepted answer is never struck through") {
                try tree.find(viewWithAccessibilityIdentifier: "result.said")
            }
        }
    }

    @Test("an accepted answer that only differs in case, accents or spaces gets no heard line")
    func sameAnswerHasNoHeardLine() async throws {
        let view = ResultView(viewModel: makeViewModel(accepted(" sol ", correct: "Soľ")))
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: (any Error).self) { try tree.find(viewWithAccessibilityIdentifier: "result.heard") }
        }
    }

    /// On MCQ the transcript is often the key or the option text; both name
    /// the answer on the card, so neither earns a "heard" line.
    @Test("an MCQ answer given by key is the same answer as its option text", arguments: ["b", "pyramid"])
    func mcqKeyIsTheSameAnswer(said: String) async throws {
        let view = ResultView(viewModel: makeViewModel(accepted(said, correct: "Pyramid"), question: Self.mcqQuestion))
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) { try tree.find(text: "B — Pyramid") }
            #expect(throws: (any Error).self) { try tree.find(viewWithAccessibilityIdentifier: "result.heard") }
        }
    }

    // MARK: - The question, one tap away

    @Test("the card no longer prints the question; Show question opens it")
    func questionIsBehindShowQuestion() async throws {
        let view = ResultView(viewModel: makeViewModel(accepted("salt", correct: "Salt")))
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: (any Error).self) { try tree.find(text: Self.openQuestion.question) }
            #expect(throws: (any Error).self) { try tree.find(viewWithAccessibilityIdentifier: "result.question") }
            #expect(throws: Never.self) { try tree.find(viewWithAccessibilityIdentifier: "result.showQuestion") }
            #expect(throws: Never.self, "the source keeps its place in the same row") {
                try tree.find(viewWithAccessibilityIdentifier: "result.source")
            }
        }
    }

    /// With no evaluation the question IS the card's text, so there is nothing to open.
    @Test("the recap fallback offers no question sheet")
    func recapHasNoShowQuestion() async throws {
        let vm = Fixtures.makeViewModel()
        vm.currentSession = Fixtures.makeActiveSession()
        vm.currentQuestion = Fixtures.makeQuestion()
        let view = ResultView(viewModel: vm)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: (any Error).self) { try tree.find(viewWithAccessibilityIdentifier: "result.showQuestion") }
        }
    }

    /// Reading the question must not be cut short by the next one arriving.
    @Test("opening the question holds the auto-advance and is counted once")
    func openingTheQuestionHoldsAutoAdvance() {
        let analytics = MockAnalyticsClient()
        let vm = makeViewModel(
            Evaluation(userAnswer: "a", result: .incorrect, points: 0, correctAnswer: "b", questionId: "q_mcq", explanation: nil),
            question: Self.mcqQuestion,
            analytics: analytics
        )
        vm.autoAdvanceCountdown = 6
        vm.isPaused = false

        vm.openResultQuestion()

        #expect(vm.isPaused)
        #expect(vm.quizState.isShowingResult)
        #expect(analytics.events == [.resultQuestionOpened(kind: .mcq, verdict: .incorrect)])
    }

    // MARK: - The sheet

    @Test("the sheet shows the question with its correct answer")
    func sheetShowsOpenQuestion() throws {
        let sheet = ResultQuestionSheet(
            question: Self.openQuestion,
            identity: DeckIdentity(category: "history", packId: nil),
            correctAnswer: "Salt"
        )
        let tree = try sheet.inspect()
        #expect(try tree.find(viewWithAccessibilityIdentifier: "resultQuestion.text").text().string() == Self.openQuestion.question)
        #expect(try tree.find(viewWithAccessibilityIdentifier: "resultQuestion.answer").text().string() == "Salt")
    }

    /// On MCQ the player needs to see which option was right and which one
    /// they picked; nothing in the sheet answers again.
    @Test("on MCQ the sheet marks the correct and the chosen option, read-only")
    func sheetMarksMCQOptions() throws {
        let sheet = ResultQuestionSheet(
            question: Self.mcqQuestion,
            identity: DeckIdentity(category: "history", packId: nil),
            correctAnswer: "B — Pyramid",
            reveal: MCQOptionPicker.Reveal(correctKey: "b", chosenKey: "a")
        )
        let tiles = try sheet.inspect().findAll(AnswerTile.self).map { try $0.actualView() }
        let states = Dictionary(uniqueKeysWithValues: tiles.map { ($0.key, $0.state) })
        #expect(states == ["a": .incorrect, "b": .correct, "c": .default, "d": .default])
        #expect(tiles.allSatisfy { $0.action == nil }, "a reveal takes no taps")
    }

    // MARK: - One pause

    /// The toolbar's pause holds and resumes the countdown (same calls), so
    /// the footer's STAY/RESUME pill said the same thing twice.
    @Test("the footer is Next alone; the toolbar pause is the only pause", arguments: [false, true])
    func footerHasNoStayPill(paused: Bool) async throws {
        let vm = makeViewModel(accepted("salt", correct: "Salt"))
        vm.autoAdvanceCountdown = 6
        vm.isPaused = paused
        let view = ResultView(viewModel: vm)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) { try tree.find(viewWithAccessibilityIdentifier: "result.continue") }
            #expect(throws: (any Error).self) { try tree.find(viewWithAccessibilityIdentifier: "result.stayHere") }
            #expect(throws: (any Error).self) { try tree.find(text: paused ? "RESUME" : "STAY") }
            #expect(QuizToolbarInspection.hasToolbar(view), "the pause lives in the quiz toolbar")
        }
    }
}
