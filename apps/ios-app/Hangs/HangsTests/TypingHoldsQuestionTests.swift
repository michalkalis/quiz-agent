//
//  TypingHoldsQuestionTests.swift
//  HangsTests
//
//  Founder F3 + C2 (TF build 90 review): a sim check found the think window
//  running out while the player typed, and the mic opened ("Listening…") on
//  top of the typed answer. While typing is on, the think countdown stands
//  still and the mic never opens by itself. Typing ends with the question:
//  send grades the typed answer, Skip moves on as usual, and the next
//  question arms its own window.
//

import Clocks
import Foundation
@testable import Hangs
import SwiftUI
import Testing
import ViewInspector

@Suite("F3 typing an answer holds the think countdown and the mic")
@MainActor
struct TypingHoldsQuestionTests {
    private func makeVM(clock: TestClock<Duration>) -> QuizViewModel {
        let audio = MockAudioService()
        audio.playbackDurationNs = 0
        let vm = QuizViewModel(
            networkService: Fixtures.makeFullMockNetwork(),
            audioService: audio,
            persistenceStore: MockPersistenceStore(),
            silenceDetectionService: MockSilenceDetectionService(),
            clock: AnyClock(clock)
        )
        vm.currentSession = Fixtures.makeActiveSession()
        vm.currentQuestion = Question.preview
        vm.quizState = .askingQuestion
        vm.settings.thinkingTime = 10
        return vm
    }

    /// WHY: the bug itself. The player tapped Type with 6 s left; the window
    /// ran out under the field and the mic opened over the typed answer.
    @Test("tapping Type freezes the think window, and the mic never opens past its end")
    func typeTapHoldsTheQuestion() async throws {
        let clock = TestClock()
        let vm = makeVM(clock: clock)
        vm.startRecordingOrTimer()
        await pumpUntil({ vm.thinkingTimeCountdown == 10 }, "the think window never started")
        await clock.advance(by: .seconds(4))
        #expect(vm.answerWindowRemaining == 6)

        let view = QuestionView(viewModel: vm)
        try await ViewHosting.host(view) {
            try view.inspect().find(viewWithAccessibilityIdentifier: "question.textInputToggle").button().tap()
            await clock.advance(by: .seconds(60))
            #expect(vm.quizState == .askingQuestion, "the mic opened on top of the typed answer")
            #expect(vm.answerWindowRemaining == 6, "the countdown must stand still while typing")
        }
    }

    /// WHY: a player can tap Type while the question is still being read. The
    /// read's tail arms the window, which must stand still at full, not drain
    /// and open the mic.
    @Test("typing during the read: the window the read arms stands still at full")
    func typingDuringTheReadHoldsTheWindow() async {
        let clock = TestClock()
        let vm = makeVM(clock: clock)
        vm.beginTypingAnswer()

        vm.startRecordingOrTimer() // what the read's tail calls
        await clock.advance(by: .seconds(60))
        #expect(vm.quizState == .askingQuestion, "the mic opened while the player was typing")
        #expect(vm.answerWindowRemaining == 10, "the full window must stand still while typing")
    }

    /// WHY: pausing (or Settings) while typing must not hand back a fresh
    /// window or lose the held seconds; play keeps the countdown where it stood.
    @Test("pause and play while typing keep the countdown where it stood")
    func pauseWhileTypingKeepsTheHold() async {
        let clock = TestClock()
        let vm = makeVM(clock: clock)
        vm.startRecordingOrTimer()
        await pumpUntil({ vm.thinkingTimeCountdown == 10 }, "the think window never started")
        await clock.advance(by: .seconds(4))
        vm.beginTypingAnswer()

        vm.togglePause()
        vm.togglePause()
        await clock.advance(by: .seconds(60))
        #expect(vm.quizState == .askingQuestion, "play opened the mic while the player was typing")
        #expect(vm.answerWindowRemaining == 6)
    }

    /// WHY: typing ends with the question. A skip from the field moves on as
    /// usual, and the next question's window drains and opens the mic again;
    /// a hold left behind would leave every later question frozen.
    @Test("a skip from the field moves on, and the next question's window runs as usual")
    func skipEndsTheHold() async {
        let clock = TestClock()
        let vm = makeVM(clock: clock)
        vm.startRecordingOrTimer()
        await pumpUntil({ vm.thinkingTimeCountdown == 10 }, "the think window never started")
        vm.beginTypingAnswer()

        await vm.skipQuestion()
        await pumpUntil({ vm.quizState != .askingQuestion && vm.quizState != .skipping }, "the skip never landed")

        vm.currentQuestion = Question.previewHard
        vm.quizState = .askingQuestion
        vm.startRecordingOrTimer()
        await pumpUntil({ vm.thinkingTimeCountdown == 10 }, "the next question's window never started")
        await clock.advance(by: .milliseconds(10100))
        await pumpUntil({ vm.quizState == .recording }, "the next question stayed frozen after a skip from typing")
        vm.quizTimersController.cancelAutoStopRecordingTimer()
    }
}
