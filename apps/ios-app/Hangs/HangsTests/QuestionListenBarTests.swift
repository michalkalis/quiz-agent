//
//  QuestionListenBarTests.swift
//  HangsTests
//
//  #179 D1 (founder pick 2026-09-15, variant A). The question screen spoke four
//  different bar languages in TF build 61: on MCQ there was NO bar while the
//  question was being read, on an open question the countdown hid inside the
//  Start button, on both the bar VANISHED while the answer was graded (the
//  founder's "the screen froze"), and past five completed quizzes the words
//  silently expired into a bare "LISTENING FOR COMMANDS".
//
//  So these tests are about WHICH STATE SAYS WHAT, and they assert it for both
//  question types from one state model — that is the whole point of D1. They
//  fail on the pre-#179 screen: no bar during the read, no bar while evaluating,
//  no words after five quizzes, and a pink bar that disappeared mid-answer on the
//  open question.
//
//  The founder's hard condition is here too: the bar may grow a chip row, but the
//  bottom action row must stay on ONE line.
//

import Foundation
@testable import Hangs
import SwiftUI
import Testing
import ViewInspector

// MARK: - The state model

@MainActor
@Suite("QuestionListenPhase — one state model for MCQ and open (#179 D1)")
struct QuestionListenPhaseTests {
    /// The mapping IS the fix: both question types ask this one function, so a
    /// state can no longer render one way on MCQ and another way on an open
    /// question. Asserted for both answer kinds in one pass.
    @Test("every quiz state maps to the same bar state for both question types",
          arguments: [ListenBar.AnswerKind.mcq, .open])
    func mappingIsIdenticalForBothQuestionTypes(kind: ListenBar.AnswerKind) {
        func phase(_ state: QuizState, remaining: Int = 0, total: Int = 0) -> QuestionListenPhase? {
            QuestionListenPhase.current(
                quizState: state,
                answerWindowRemaining: remaining,
                answerWindowTotal: total,
                answerKind: kind
            )
        }

        // 1 — the question is being read: no window has started draining yet.
        #expect(phase(.askingQuestion) == .readingQuestion)
        // 2 — the think window drains (#132 B: as a fill inside the bar).
        #expect(phase(.askingQuestion, remaining: 12, total: 30) == .thinking(remaining: 12, total: 30))
        // 3 — the answer mic is open.
        #expect(phase(.recording) == .listening(kind))
        // 4 — something is in flight. `.skipping` counts: from the driver's seat
        // it is the same promise that the screen has not died.
        #expect(phase(.processing) == .evaluating)
        #expect(phase(.skipping) == .evaluating)

        // Not the driver's turn — no bar at all.
        #expect(phase(.idle) == nil)
        #expect(phase(.startingQuiz) == nil)
        #expect(phase(.finished) == nil)
    }

    /// A chip is a promise that the word will be heard, so every word offered
    /// must be one the QUESTION screen actually routes. #179 finding 1: the old
    /// hint named only two of the three and swallowed "repeat" entirely.
    @Test("every state only offers commands the question screen really routes")
    func chipsOnlyOfferRoutedCommands() {
        let routed = VoiceCommandLexicon.commands(on: .question)
        #expect(routed == [.start, .repeatQuestion, .skip], "the screen's real grammar")

        for phase in [QuestionListenPhase.readingQuestion,
                      .thinking(remaining: 5, total: 30),
                      .listening(.mcq),
                      .evaluating]
        {
            for command in phase.commands {
                #expect(routed.contains(command), "\(command) is not routed on the question screen")
            }
        }

        // "repeat" and "skip" work throughout; "start" is withheld during the
        // read on purpose — saying it there cuts the question off mid-sentence.
        #expect(QuestionListenPhase.readingQuestion.commands == [.repeatQuestion, .skip])
        #expect(QuestionListenPhase.thinking(remaining: 5, total: 30).commands
            == [.start, .repeatQuestion, .skip])

        // The 2026-07-28 rule: the app hears EITHER commands or the answer, never
        // both — so the two states where the mic is not on commands offer none.
        #expect(QuestionListenPhase.listening(.mcq).commands.isEmpty)
        #expect(QuestionListenPhase.listening(.open).commands.isEmpty)
        #expect(QuestionListenPhase.evaluating.commands.isEmpty)
    }

    /// The ✕ (#173 B1) belongs to the states the driver can still act in. While
    /// the answer is graded the bar is the only thing saying the app is alive.
    @Test("only the actionable states carry the dismiss ✕")
    func evaluatingCannotBeDismissed() {
        #expect(QuestionListenPhase.readingQuestion.isDismissable)
        #expect(QuestionListenPhase.thinking(remaining: 1, total: 30).isDismissable)
        #expect(QuestionListenPhase.listening(.open).isDismissable)
        #expect(!QuestionListenPhase.evaluating.isDismissable)
    }
}

// MARK: - What each state renders

@MainActor
@Suite("QuestionListenBar — caption and chips per state (#179 D1)")
struct QuestionListenBarRenderTests {
    private func host(
        _ phase: QuestionListenPhase,
        language: CommandLanguage = .english,
        showsWords: Bool = true,
        _ assertions: (InspectableView<ViewType.ClassifiedView>) throws -> Void
    ) async throws {
        let view = QuestionListenBar(phase: phase, showsWords: showsWords, language: language)
        try await ViewHosting.host(view) {
            try assertions(view.inspect())
        }
    }

    /// State 1 — the bar that did not exist. It must name what the app is doing
    /// and the two commands that work while a question is being read.
    @Test("state 1 reads the question and offers repeat + skip")
    func readingQuestionState() async throws {
        try await host(.readingQuestion, language: .slovak) { tree in
            #expect(throws: Never.self) { try tree.find(text: "Reading the question") }
            let chips = try tree.find(viewWithAccessibilityIdentifier: "listen-bar.commands")
            #expect(throws: Never.self) { try chips.find(text: "„zopakuj“") }
            #expect(throws: Never.self) { try chips.find(text: "„preskoč“") }
            #expect(throws: (any Error).self, "start would cut the read off mid-sentence") {
                try chips.find(text: "„štart“")
            }
        }
    }

    /// State 2 — the #132 B countdown, plus all three words.
    @Test("state 2 counts the think window down and offers all three words")
    func thinkingState() async throws {
        try await host(.thinking(remaining: 32, total: 45), language: .slovak) { tree in
            #expect(throws: Never.self) { try tree.find(text: "THINK — LISTENING IN 32 S") }
            let chips = try tree.find(viewWithAccessibilityIdentifier: "listen-bar.commands")
            for word in ["„štart“", "„zopakuj“", "„preskoč“"] {
                #expect(throws: Never.self, "\(word) missing") { try chips.find(text: word) }
            }
        }
    }

    /// State 3 — the ONE difference between the two columns of the founder's
    /// board: the answer prompt. And no chips in either, by the 2026-07-28 rule.
    @Test("state 3 prompts for the answer form and shows no command chips",
          arguments: [(ListenBar.AnswerKind.mcq, "Listening — say A–D or the answer"),
                      (ListenBar.AnswerKind.open, "LISTENING — SAY YOUR ANSWER")])
    func listeningState(kind: ListenBar.AnswerKind, caption: String) async throws {
        try await host(.listening(kind)) { tree in
            #expect(throws: Never.self) { try tree.find(text: caption) }
            #expect(throws: (any Error).self, "a command spoken here is not heard") {
                try tree.find(viewWithAccessibilityIdentifier: "listen-bar.commands")
            }
        }
    }

    /// State 4 — the founder read the empty slot as a frozen screen. The bar must
    /// say it is working AND that speaking will not help, and it must spin.
    @Test("state 4 says the answer is being evaluated and that nothing need be said")
    func evaluatingState() async throws {
        try await host(.evaluating) { tree in
            #expect(throws: Never.self) { try tree.find(text: "Evaluating your answer") }
            #expect(throws: Never.self) {
                try tree.find(text: "This will take a moment, no need to say anything")
            }
            #expect(throws: Never.self, "a still bar would read as frozen too") {
                try tree.find(viewWithAccessibilityIdentifier: "listen-bar.spinner")
            }
            #expect(throws: (any Error).self, "nothing is listening, so no words are on offer") {
                try tree.find(viewWithAccessibilityIdentifier: "listen-bar.commands")
            }
        }
    }

    /// The words follow the COMMAND language (#120), not the app locale — a
    /// Slovak driver must be offered words a Slovak matcher accepts.
    @Test("chips are spelled in the command language")
    func chipsFollowCommandLanguage() async throws {
        try await host(.thinking(remaining: 5, total: 30), language: .english) { tree in
            let chips = try tree.find(viewWithAccessibilityIdentifier: "listen-bar.commands")
            #expect(throws: Never.self) { try chips.find(text: "“start”") }
            #expect(throws: (any Error).self) { try chips.find(text: "„štart“") }
        }
    }

    /// Turning the words off in Settings leaves the STATE — that was the #174
    /// rule and D1 keeps it. Only the chips go.
    @Test("hiding the words keeps the bar and its caption")
    func wordsOffKeepsTheBar() async throws {
        try await host(.thinking(remaining: 9, total: 30), showsWords: false) { tree in
            #expect(throws: Never.self) { try tree.find(viewWithAccessibilityIdentifier: "listen-bar") }
            #expect(throws: Never.self) { try tree.find(text: "THINK — LISTENING IN 9 S") }
            #expect(throws: (any Error).self) {
                try tree.find(viewWithAccessibilityIdentifier: "listen-bar.commands")
            }
        }
    }
}

// MARK: - On the question screen

@MainActor
@Suite("QuestionView — the D1 bar never leaves the screen (#179)")
struct QuestionViewListenBarPresenceTests {
    /// Arms the command listener the way `QuestionViewInspectorTests` does, so
    /// `commandListenerHint` is non-nil and the chips are allowed to render.
    private func makeArmedViewModel(question: Question) async -> QuizViewModel {
        let vm = QuizViewModel(
            networkService: MockNetworkService(),
            audioService: MockAudioService(),
            persistenceStore: MockPersistenceStore(),
            silenceDetectionService: MockSilenceDetectionService(),
            sttService: nil
        )
        vm.currentSession = Fixtures.makeActiveSession()
        vm.currentQuestion = question
        vm.quizState = .askingQuestion
        await vm.audioDeviceState.startSilenceDetectionListening()
        return vm
    }

    /// Finding 6 / screenshot 9: on MCQ the bar was simply absent while the
    /// question was read aloud — the driver's first look at the screen showed no
    /// hint, no countdown and nothing to say.
    @Test("the bar is on screen while the question is being read, on both question types",
          arguments: [Question.previewMCQ, Question.preview])
    func barIsPresentWhileTheQuestionIsRead(question: Question) async throws {
        let vm = await makeArmedViewModel(question: question)
        #expect(vm.answerWindowRemaining == 0, "precondition: the read is still running")

        let view = QuestionView(viewModel: vm)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) { try tree.find(viewWithAccessibilityIdentifier: "listen-bar") }
            #expect(throws: Never.self) { try tree.find(text: "Reading the question") }
        }
    }

    /// Finding 1 / screenshot 3: while the answer was graded the bar disappeared
    /// (MCQ hid it on `isProcessing`, the open question footer on its command
    /// window), and the greyed-out screen read as frozen.
    @Test("the bar is on screen while the answer is evaluated, on both question types",
          arguments: [Question.previewMCQ, Question.preview])
    func barIsPresentWhileEvaluating(question: Question) async throws {
        let vm = await makeArmedViewModel(question: question)
        vm.quizState = .processing

        let view = QuestionView(viewModel: vm)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) { try tree.find(viewWithAccessibilityIdentifier: "listen-bar") }
            #expect(throws: Never.self) { try tree.find(text: "Evaluating your answer") }
        }
    }

    /// #174's five-quiz expiry is reversed (D1): the founder is well past five
    /// and it had left him with a caption naming nothing he could say.
    @Test("the command words are still there after more than five completed quizzes",
          arguments: [Question.previewMCQ, Question.preview])
    func wordsSurviveTheFifthQuiz(question: Question) async throws {
        let vm = await makeArmedViewModel(question: question)
        vm.quizStats.totalQuizzes = 12 // well past the retired gate
        vm.answerTimerCountdown = 12
        #expect(vm.showsVoiceHints, "the words must not expire with use")

        let view = QuestionView(viewModel: vm)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            let chips = try tree.find(viewWithAccessibilityIdentifier: "listen-bar.commands")
            #expect(throws: Never.self) { try chips.find(text: "“start”") }
            #expect(throws: Never.self) { try chips.find(text: "“skip”") }
        }
    }

    /// The founder's hard condition on D1: the rest of the screen must not move,
    /// and the bottom action row stays on ONE line. Structural, so it fails if
    /// the chip row ever pushes the footer into wrapping: all three controls must
    /// live in the SAME HStack, and the bar must not be inside it.
    @Test("the open question's Start · Type · Skip row stays one row with the chips on screen")
    func openQuestionFooterStaysOneRow() async throws {
        let vm = await makeArmedViewModel(question: .preview)
        vm.answerTimerCountdown = 12

        let view = QuestionView(viewModel: vm)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self, "precondition: the chip row is on screen") {
                try tree.find(viewWithAccessibilityIdentifier: "listen-bar.commands")
            }

            let row = try tree.find(ViewType.HStack.self, where: { stack in
                (try? stack.find(viewWithAccessibilityIdentifier: "question.record")) != nil
                    && (try? stack.find(viewWithAccessibilityIdentifier: "question.skip")) != nil
            })
            #expect((try? row.find(viewWithAccessibilityIdentifier: "question.textInputToggle")) != nil,
                    "Type must share the row, not drop to a second line")
            #expect((try? row.find(viewWithAccessibilityIdentifier: "listen-bar")) == nil,
                    "the bar belongs above the row, never inside it")
        }
    }

    /// The MCQ side of the same condition: T5 pinned the footer as a bottom
    /// safe-area inset, and a taller bar must not un-pin it.
    @Test("the MCQ skip chip stays in the pinned bottom inset with the chips on screen")
    func mcqFooterStaysPinned() async throws {
        let vm = await makeArmedViewModel(question: .previewMCQLongOptions)
        vm.answerTimerCountdown = 12

        let view = QuestionView(viewModel: vm)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self, "precondition: the chip row is on screen") {
                try tree.find(viewWithAccessibilityIdentifier: "listen-bar.commands")
            }
            let footer = try tree.find(ViewType.SafeAreaInset.self)
            #expect(try footer.edge() == .bottom)
            #expect(throws: Never.self) {
                try footer.find(viewWithAccessibilityIdentifier: "question.skip")
            }
        }
    }
}
