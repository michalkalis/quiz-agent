//
//  SpellingHintTests.swift
//  HangsTests
//
//  #208.6 (founder 2026-10-16): after the player rejected a transcript once
//  ("Again", "znova", "nie"), the screen says the answer can be spelled letter
//  by letter; the backend joins the letters into a word. Why these tests
//  matter:
//  - The hint is the way out of a name the recognizer keeps mishearing, so it
//    must show on the retry (question screen) and on the next sheet.
//  - It must not show on the first try (noise for every answer), on the next
//    question (a fresh start), or on MCQ (an option is named by its number).
//

import Clocks
import Foundation
@testable import Hangs
import SwiftUI
import Testing
import ViewInspector

@Suite("Spelling hint after a rejected transcript (#208.6)")
@MainActor
struct SpellingHintTests {
    /// A first upload for `q_001` whose transcript ("Test", the mock's) is now
    /// on the confirmation sheet.
    private func answerOnSheet() async -> QuizViewModel {
        let (vm, _) = Fixtures.makeViewModelWithNetwork(clock: AnyClock(TestClock()))
        vm.currentSession = Fixtures.makeActiveSession()
        vm.currentQuestion = Fixtures.makeQuestion(id: "q_001")
        vm.quizState = .askingQuestion
        vm.settings.isMuted = true
        await vm.recordingCoordinator.submitVoiceAnswer(audioData: Data([0x1, 0x2]))
        #expect(vm.transcribedAnswer == "Test")
        return vm
    }

    @Test("no hint on the first try")
    func noHintOnFirstTry() async {
        let vm = await answerOnSheet()
        #expect(vm.quizState == .processing)
        #expect(!vm.showsSpellingHint)
    }

    @Test("after Again the retry and the next sheet offer spelling")
    func hintAfterAgain() async {
        let vm = await answerOnSheet()

        vm.recordingCoordinator.rerecordAnswer()
        await pumpUntil({ vm.quizState != .processing }, "re-record never left the sheet")
        #expect(vm.showsSpellingHint, "the retry is where the player needs it")

        await vm.recordingCoordinator.submitVoiceAnswer(audioData: Data([0x3, 0x4]))
        #expect(vm.quizState == .processing)
        #expect(vm.showsSpellingHint, "the second sheet keeps it")
    }

    @Test("the next question starts without the hint")
    func nextQuestionStartsClean() async {
        let vm = await answerOnSheet()
        vm.recordingCoordinator.rerecordAnswer()
        await pumpUntil({ vm.quizState != .processing }, "re-record never left the sheet")

        vm.currentQuestion = Fixtures.makeQuestion(id: "q_002")

        #expect(!vm.showsSpellingHint)
    }

    @Test("never on a multiple-choice question")
    func neverOnMCQ() {
        let vm = Fixtures.makeViewModel()
        vm.currentSession = Fixtures.makeActiveSession()
        vm.quizState = .processing

        vm.currentQuestion = Question.preview
        vm.recordingCoordinator.rememberRejectedTranscript("Parish")
        #expect(vm.showsSpellingHint, "control: an open question shows it")

        vm.currentQuestion = Question.previewMCQ
        vm.recordingCoordinator.rememberRejectedTranscript("Kocka")
        #expect(!vm.showsSpellingHint, "an option is named by its number or letter, not spelled")
    }

    // MARK: - On the sheet

    private func sheet(hint: Bool, evaluating: String? = nil) -> AnswerConfirmationView {
        AnswerConfirmationView(
            isProcessing: false,
            transcribedAnswer: .constant("Parish"),
            autoConfirmCountdown: 4,
            autoConfirmEnabled: true,
            autoConfirmTotal: Config.autoConfirmDelaySecs,
            onConfirm: {},
            onReRecord: {},
            evaluatingAnswer: evaluating,
            showsSpellingHint: hint
        )
    }

    @Test("the sheet shows the hint only when asked, and not while grading")
    func sheetShowsHint() throws {
        #expect(throws: Never.self) {
            try sheet(hint: true).inspect().find(viewWithAccessibilityIdentifier: "answer.spellingHint")
        }
        #expect(throws: (any Error).self) {
            try sheet(hint: false).inspect().find(viewWithAccessibilityIdentifier: "answer.spellingHint")
        }
        #expect(throws: (any Error).self, "the answer is out of the player's hands") {
            try sheet(hint: true, evaluating: "Parish").inspect().find(viewWithAccessibilityIdentifier: "answer.spellingHint")
        }
    }
}
