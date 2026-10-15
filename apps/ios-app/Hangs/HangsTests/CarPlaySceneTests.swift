//
//  CarPlaySceneTests.swift
//  HangsTests
//
//  #97 — CarPlay support. The car's screen keeps a round alive while the phone
//  is locked, and it must never become a way to leave the mic on with nobody
//  looking at the quiz:
//    • the phone locking under a live CarPlay screen tears nothing down;
//    • the CarPlay screen leaving (Maps, disconnect) with the phone also away
//      tears input down exactly like the phone going to the background;
//    • the car screen maps every quiz moment to a state Apple allows: voice
//      template states only, no question/answer text, the paywall wins.
//

@testable import Hangs
import SwiftUI
import Testing

@MainActor
private func makeCarPlayVM() -> (QuizViewModel, MockSilenceDetectionService, MockAudioService) {
    let audio = MockAudioService()
    let silence = MockSilenceDetectionService()
    let vm = QuizViewModel(
        networkService: Fixtures.makeFullMockNetwork(),
        audioService: audio,
        persistenceStore: MockPersistenceStore(),
        silenceDetectionService: silence,
        sttService: nil
    )
    vm.currentSession = Fixtures.makeActiveSession()
    vm.currentQuestion = Fixtures.makeQuestion()
    return (vm, silence, audio)
}

@Suite("CarPlay scene — the car screen keeps the quiz, never a hidden hot mic")
@MainActor
struct CarPlaySceneTests {
    @Test("phone locking while the CarPlay screen is up keeps the listener and the recording")
    func phoneLockUnderCarPlayKeepsInput() async {
        let (vm, silence, _) = makeCarPlayVM()
        vm.quizState = .askingQuestion
        vm.handleCarPlayScene(foreground: true)
        await vm.audioDeviceState.startSilenceDetectionListening()

        vm.handleScenePhase(.background)

        #expect(vm.isAppForeground, "the driver is still in the quiz, on the car's screen")
        #expect(silence.isListening, "a locked phone must not deafen the CarPlay quiz")
        #expect(vm.quizState == .askingQuestion)
    }

    @Test("CarPlay screen leaving while the phone is locked tears input down")
    func carPlayLeavingWithPhoneAwayTearsDown() async {
        let (vm, silence, audio) = makeCarPlayVM()
        vm.quizState = .idle
        vm.handleCarPlayScene(foreground: true)
        vm.handleScenePhase(.background)
        await vm.audioDeviceState.startSilenceDetectionListening()

        vm.handleCarPlayScene(foreground: false)

        #expect(!vm.isAppForeground)
        #expect(!silence.isListening, "no screen shows the quiz → the mic must be off")
        #expect(audio.deactivateSessionCallCount == 1, "idle and silent → session released")
    }

    @Test("CarPlay screen leaving while the phone is in front changes nothing")
    func carPlayLeavingWithPhoneInFrontKeepsInput() async {
        let (vm, silence, _) = makeCarPlayVM()
        vm.quizState = .askingQuestion
        vm.handleCarPlayScene(foreground: true)
        await vm.audioDeviceState.startSilenceDetectionListening()

        vm.handleCarPlayScene(foreground: false)

        #expect(vm.isAppForeground)
        #expect(silence.isListening, "the phone still shows the quiz")
    }

    @Test("without CarPlay, the phone going to the background still tears input down")
    func phoneOnlyBackgroundUnchanged() async {
        let (vm, silence, _) = makeCarPlayVM()
        vm.quizState = .askingQuestion
        await vm.audioDeviceState.startSilenceDetectionListening()

        vm.handleScenePhase(.background)

        #expect(!vm.isAppForeground)
        #expect(!silence.isListening)
    }
}

#if CARPLAY
    @Suite("CarPlay screen mapping — what the car shows for each quiz moment")
    struct CarPlayScreenTests {
        private func screen(
            _ state: QuizState,
            paused: Bool = false,
            confirming: Bool = false,
            paywall: Bool = false
        ) -> CarPlayScreen {
            CarPlayScreen(.init(quizState: state, isPaused: paused, showAnswerConfirmation: confirming, showPaywall: paywall))
        }

        @Test("between rounds the car shows the home template")
        func homeStates() {
            #expect(screen(.idle) == .home(.ready))
            #expect(screen(.finished) == .home(.finished))
            #expect(screen(.error(message: "x", context: .general)) == .home(.failed))
        }

        @Test("the paywall wins over any quiz moment: it can only be answered on the phone")
        func paywallWins() {
            #expect(screen(.idle, paywall: true) == .home(.limitReached))
            #expect(screen(.askingQuestion, paywall: true) == .home(.limitReached))
        }

        @Test("a running round maps to the quiz template's voice states")
        func quizStates() {
            #expect(screen(.askingQuestion) == .quiz(.speaking))
            #expect(screen(.recording) == .quiz(.listening))
            #expect(screen(.processing) == .quiz(.thinking))
            #expect(screen(.processing, confirming: true) == .quiz(.confirming))
            #expect(screen(.startingQuiz) == .quiz(.thinking))
            #expect(screen(.awaitingQuestion) == .quiz(.thinking))
            #expect(screen(.skipping) == .quiz(.thinking))
        }

        @Test("the spoken result is a speaking moment, its STAY hold shows as paused")
        func resultStates() {
            let result = QuizState.showingResult(
                question: Fixtures.makeQuestion(),
                evaluation: Evaluation(userAnswer: "x", result: .correct, points: 1, correctAnswer: "x", questionId: "q", explanation: nil)
            )
            #expect(screen(result) == .quiz(.speaking))
            #expect(screen(result, paused: true) == .quiz(.paused))
        }

        @Test("a pause shows as paused wherever the phone can pause")
        func pausedStates() {
            #expect(screen(.askingQuestion, paused: true) == .quiz(.paused))
            #expect(screen(.recording, paused: true) == .quiz(.paused))
            #expect(screen(.processing, paused: true, confirming: true) == .quiz(.paused))
            // Nothing to freeze while Trubbo is checking — the pause flag can't strand it.
            #expect(screen(.processing, paused: true) == .quiz(.thinking))
        }

        @Test("each voice template stays within Apple's 5-state limit")
        func stateLimits() {
            #expect(CarPlayScreen.Home.allCases.count <= 5)
            #expect(CarPlayScreen.Quiz.allCases.count <= 5)
        }
    }
#endif
