//
//  ThinkCommandHintsTests.swift
//  HangsTests
//
//  #251 (founder, TF 1.3 b94, 2026-11-27): during "Premýšľaj" the command
//  words were nowhere to be seen. They now show as in the other phases, from
//  the start of the think window, on the first 3 questions of the first
//  quizzes and then ever more rarely (quiz 10, 20, 40…).
//

import Clocks
import Foundation
@testable import Hangs
import Testing

@Suite("#251 command words during Think")
@MainActor
struct ThinkCommandHintsTests {
    private func makeVM() -> QuizViewModel {
        let audio = MockAudioService()
        audio.playbackDurationNs = 0
        let vm = QuizViewModel(
            networkService: Fixtures.makeFullMockNetwork(),
            audioService: audio,
            persistenceStore: MockPersistenceStore(),
            silenceDetectionService: MockSilenceDetectionService(),
            clock: AnyClock(TestClock())
        )
        vm.currentSession = Fixtures.makeActiveSession()
        vm.currentQuestion = Question.preview
        vm.quizState = .askingQuestion
        vm.settings.thinkingTime = 10
        return vm
    }

    private let thinking = QuestionListenPhase.thinking(remaining: 8, total: 10)

    /// WHY: teach first, then fade. A player sees the words while learning
    /// and meets them again now and then, instead of on every question forever.
    @Test("quizzes 1 to 3, then 10, 20, 40, 80 teach; the rest do not")
    func schedule() {
        let teaching = (1 ... 100).filter(ThinkCommandHints.isTeachingQuiz)
        #expect(teaching == [1, 2, 3, 10, 20, 40, 80])
        #expect(!ThinkCommandHints.isTeachingQuiz(0))
        #expect(ThinkCommandHints.isTeachingQuiz(160))
    }

    @Test("only the first 3 questions of a teaching quiz name the words")
    func firstThreeQuestions() {
        #expect((1 ... 3).allSatisfy { ThinkCommandHints.showsWords(quizOrdinal: 1, questionNumber: $0) })
        #expect(!ThinkCommandHints.showsWords(quizOrdinal: 1, questionNumber: 4))
        #expect(!ThinkCommandHints.showsWords(quizOrdinal: 5, questionNumber: 1))
    }

    /// WHY: the founder never saw the words while thinking. The mic comes up
    /// only after the spoken "Premýšľaj" and the recognizer's start-up, so
    /// waiting for it hid them for most of a 10 s window.
    @Test("in a teaching quiz the words show while thinking, before the mic is live")
    func showsBeforeTheMicIsLive() async {
        let vm = makeVM()
        await pumpUntil({ vm.voiceCommandCoordinator.commandAvailability == .ready }, "commands never became available")
        vm.thinkHintQuizOrdinal = 1
        #expect(vm.commandListenerHint == nil, "precondition: no live command window yet")

        #expect(vm.questionStripShowsWords(for: thinking))
        #expect(vm.questionStripPhase(thinking) != nil)
    }

    @Test("a quiz off the schedule shows no words while thinking")
    func offScheduleShowsNone() async {
        let vm = makeVM()
        await pumpUntil({ vm.voiceCommandCoordinator.commandAvailability == .ready }, "commands never became available")
        vm.thinkHintQuizOrdinal = 7
        #expect(!vm.questionStripShowsWords(for: thinking))
    }

    /// WHY: a word on screen promises it is heard. Commands off, or the hints
    /// switched off in Settings, name nothing.
    @Test("commands off or hints off name no words", arguments: ["commands", "hints"])
    func switchedOff(what: String) async {
        let vm = makeVM()
        await pumpUntil({ vm.voiceCommandCoordinator.commandAvailability == .ready }, "commands never became available")
        vm.thinkHintQuizOrdinal = 1
        if what == "commands" { vm.settings.voiceCommandsEnabled = false } else { vm.settings.voiceHintsEnabled = false }
        #expect(!vm.questionStripShowsWords(for: thinking))
    }
}
