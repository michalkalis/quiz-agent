//
//  SettingsHoldsQuestionTests.swift
//  HangsTests
//
//  #240 walkthrough (2/2): Settings opened from the quiz's ⋯ menu during a
//  question was torn away. The think countdown kept draining under the
//  sheet, the mic opened on its own, and when that recording ran out the
//  "Nothing heard" answer sheet replaced Settings while the player was
//  still changing something. Settings now holds the question with the
//  quiz's own pause and lets it go on when the player closes it.
//

import Clocks
import Foundation
@testable import Hangs
import SwiftUI
import Testing
import ViewInspector

@Suite("#240 Settings during a question holds the countdown and the mic")
@MainActor
struct SettingsHoldsQuestionTests {
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

    /// 4 s of the 10 s think window spent.
    private func thinkFourSeconds(_ vm: QuizViewModel, _ clock: TestClock<Duration>) async {
        vm.startRecordingOrTimer()
        await pumpUntil({ vm.thinkingTimeCountdown == 10 }, "the think window never started")
        await clock.advance(by: .seconds(4))
    }

    /// WHY: the player opened Settings to change something, and the screen
    /// they were editing vanished under them. Tapping Settings in the ⋯ menu
    /// must freeze the question, so no countdown runs out and no mic opens
    /// behind the sheet.
    @Test("tapping Settings in the ⋯ menu freezes the think window, and the mic never opens behind it")
    func settingsTapHoldsTheQuestion() async throws {
        let clock = TestClock()
        let vm = makeVM(clock: clock)
        await thinkFourSeconds(vm, clock)

        let view = QuestionView(viewModel: vm)
        try await ViewHosting.host(view) {
            try view.inspect().find(viewWithAccessibilityIdentifier: "question.settingsButton").button().tap()
            await pumpUntil({ vm.isPaused }, "opening Settings did not hold the question")

            await clock.advance(by: .seconds(60))
            #expect(vm.quizState == .askingQuestion, "the mic opened behind Settings")
            #expect(vm.showAnswerConfirmation == false, "an answer sheet replaced Settings")
        }
        vm.quizTimersController.cancelThinkingTime()
    }

    /// WHY: closing Settings is the player coming back to the question; it
    /// goes on with the seconds it had left, and then the mic opens on its
    /// own as it would have.
    @Test("closing Settings continues the think window from its remainder, then records")
    func closingSettingsResumes() async {
        let clock = TestClock()
        let vm = makeVM(clock: clock)
        await thinkFourSeconds(vm, clock)

        vm.holdQuestionForModal()
        await clock.advance(by: .seconds(60))
        vm.releaseQuestionAfterModal()

        #expect(!vm.isPaused)
        await pumpUntil({ vm.thinkingTimeCountdown == 6 }, "the think window must continue from 6 s")
        await clock.advance(by: .milliseconds(6100))
        await pumpUntil({ vm.quizState == .recording }, "the remainder ran out but the mic never opened")
        vm.quizTimersController.cancelAutoStopRecordingTimer()
    }

    /// WHY: a pause the player chose stays theirs. Opening and closing
    /// Settings must not un-pause a quiz they had paused themselves.
    @Test("a quiz the player had paused stays paused after Settings closes")
    func playerPauseSurvivesSettings() async {
        let clock = TestClock()
        let vm = makeVM(clock: clock)
        await thinkFourSeconds(vm, clock)
        vm.togglePause()

        vm.holdQuestionForModal()
        vm.releaseQuestionAfterModal()

        #expect(vm.isPaused, "closing Settings resumed a quiz the player had paused")
        vm.quizTimersController.cancelThinkingTime()
    }
}
