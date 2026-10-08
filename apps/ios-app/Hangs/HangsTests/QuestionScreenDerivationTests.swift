//
//  QuestionScreenDerivationTests.swift
//  HangsTests
//
//  #194 A1: the question screen's derived rules moved out of QuestionView
//  (`QuizViewModel+QuestionScreen`, `QuestionStemAutoScroll`, `QuizState.label`
//  as the state probe). The redesign restyles that screen; these pin the rules
//  so a new layout cannot quietly change which control is busy, when the sheet
//  is up, or what the counter says.
//

import Foundation
@testable import Hangs
import Testing

@MainActor
private func makeMCQ(optionLabels: [String: String]? = nil, answers: [String: String]? = nil) -> Question {
    Question(
        id: "q_mcq_1",
        question: "Largest planet?",
        type: .textMultichoice,
        possibleAnswers: answers ?? ["a": "Mars", "b": "Jupiter", "c": "Venus", "d": "Saturn"],
        difficulty: "medium",
        topic: "Astronomy",
        category: "science",
        sourceUrl: nil,
        sourceExcerpt: nil,
        mediaUrl: nil,
        imageSubtype: nil,
        explanation: nil,
        generatedBy: nil,
        optionLabels: optionLabels
    )
}

@Suite("Question screen derived rules (#194 A1)")
@MainActor
struct QuestionScreenDerivationTests {
    /// #173 C2: the sheet stays up while the confirmed answer is graded, even
    /// though `confirmAnswer()` already cleared `showAnswerConfirmation`.
    @Test("the answer sheet stays presented through evaluation")
    func sheetOutlivesConfirm() {
        let vm = Fixtures.makeViewModel()
        #expect(!vm.isAnswerSheetPresented)

        vm.showAnswerConfirmation = true
        #expect(vm.isAnswerSheetPresented)

        vm.showAnswerConfirmation = false
        vm.isEvaluatingAnswer = true
        #expect(vm.isAnswerSheetPresented, "Confirm tapped, result not in yet: the sheet must not drop")
    }

    /// The controls under the sheet must not look busy while the driver is still
    /// being asked to confirm; with no sheet, processing and skipping are busy.
    @Test("the question screen is busy only when no sheet covers it")
    func busyOnlyWithoutSheet() {
        let vm = Fixtures.makeViewModel()
        vm.quizState = .askingQuestion
        #expect(!vm.isQuestionScreenBusy)

        vm.quizState = .processing
        #expect(vm.isQuestionScreenBusy)
        vm.quizState = .skipping
        #expect(vm.isQuestionScreenBusy)

        vm.quizState = .processing
        vm.showAnswerConfirmation = true
        #expect(!vm.isQuestionScreenBusy)
        vm.showAnswerConfirmation = false
        vm.isEvaluatingAnswer = true
        #expect(!vm.isQuestionScreenBusy)
    }

    /// TF build 53 "dialog vanished" + #171 Track B: the Transcribing spinner
    /// only while a transcript is genuinely on its way.
    @Test("the sheet spinner shows only while a transcript is awaited")
    func sheetSpinnerRules() {
        let vm = Fixtures.makeViewModel()
        vm.quizState = .processing
        vm.transcribedAnswer = ""
        #expect(vm.isAnswerSheetTranscribing)

        vm.transcribedAnswer = "Jupiter"
        #expect(!vm.isAnswerSheetTranscribing)

        vm.transcribedAnswer = ""
        vm.noAnswerCaptured = true
        #expect(!vm.isAnswerSheetTranscribing, "the no-answer sheet must keep its Confirm CTA")

        vm.noAnswerCaptured = false
        vm.quizState = .askingQuestion
        #expect(!vm.isAnswerSheetTranscribing)
    }

    @Test("the counter is 1-based, follows the asked count and stays inside the set")
    func counterClamps() {
        let vm = Fixtures.makeViewModel()
        vm.currentSession = Fixtures.session(answered: 0, maxQuestions: 10)
        #expect(vm.questionScreenTotal == 10)
        #expect(vm.questionScreenNumber == 1, "no answers yet reads 1/10, never 0/10")

        vm.currentSession = Fixtures.session(answered: 2, maxQuestions: 10, askedCount: 4)
        #expect(vm.questionScreenNumber == 4, "a skip moves the counter (asked, not answered)")

        vm.currentSession = Fixtures.session(answered: 10, maxQuestions: 10, askedCount: 12)
        #expect(vm.questionScreenNumber == 10, "never past the set size")

        vm.currentSession = nil
        #expect(vm.questionScreenTotal == vm.settings.numberOfQuestions)
    }

    @Test("a spoken MCQ match reads as label · value, and nothing without a match")
    func matchedOptionLabel() {
        let vm = Fixtures.makeViewModel()
        vm.currentQuestion = makeMCQ()
        #expect(vm.matchedVoiceOptionLabel == nil)

        vm.mcqVoiceMatchedKey = "b"
        #expect(vm.matchedVoiceOptionLabel == "B · Jupiter")

        vm.currentQuestion = makeMCQ(optionLabels: ["a": "1", "b": "2", "c": "3", "d": "4"])
        #expect(vm.matchedVoiceOptionLabel == "2 · Jupiter")
    }

    @Test("the listen bar names the answer kind the question asks for")
    func listenPhaseAnswerKind() {
        let vm = Fixtures.makeViewModel()
        vm.quizState = .recording
        #expect(vm.listenPhase(for: makeMCQ()) == .listening(.mcqLetters))
        #expect(
            vm.listenPhase(for: makeMCQ(optionLabels: ["a": "1", "b": "2", "c": "3", "d": "4"])) == .listening(.mcq)
        )
        #expect(vm.listenPhase(for: makeMCQ(answers: ["a": "True", "b": "False"])) == .listening(.trueFalse))
    }

    /// The RS suite reads `question.state` (the DEBUG probe) by these exact names.
    @Test("the state probe names stay what the regression suite reads")
    func stateProbeNames() {
        let expected: [(QuizState, String)] = [
            (.idle, "idle"),
            (.startingQuiz, "startingQuiz"),
            (.askingQuestion, "askingQuestion"),
            (.awaitingQuestion, "awaitingQuestion"),
            (.recording, "recording"),
            (.processing, "processing"),
            (.skipping, "skipping"),
            (.showingResult(question: Question.preview, evaluation: .previewCorrect), "showingResult"),
            (.finished, "finished"),
        ]
        for (state, name) in expected {
            #expect(state.label == name)
        }
    }

    @Test("a long stem waits a 3 s beat, then drifts at reading pace, never under 2 s")
    func stemAutoScrollPacing() {
        #expect(QuestionStemAutoScroll.readingBeat == .seconds(3))
        #expect(QuestionStemAutoScroll.driftDuration(overflow: 28) == 2)
        #expect(QuestionStemAutoScroll.driftDuration(overflow: 140) == 5)
    }
}
