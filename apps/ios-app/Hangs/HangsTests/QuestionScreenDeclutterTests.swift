//
//  QuestionScreenDeclutterTests.swift
//  HangsTests
//
//  TF build 90 (founder): the question screen was "full of nonsense". The
//  strip between the card and the buttons now appears only when it tells the
//  player something they need (think countdown, open mic, answer in flight);
//  it no longer says "Reading the question" over an audible read when nothing
//  listens (#243.6: a live command window shows it, with the words), and the retry and spelling
//  hints live in the open mic's bar instead of as free lines. Typing an
//  answer is one calm state above the keyboard, and the "End Quiz?" alert
//  holds the question like Settings does.
//

import Clocks
import Foundation
@testable import Hangs
import SwiftUI
import Testing
import ViewInspector

@Suite("TF build 90: the question screen shows only what the player needs")
@MainActor
struct QuestionScreenDeclutterTests {
    private func makeVM(clock: TestClock<Duration> = TestClock()) -> (QuizViewModel, MockAudioService, MockSilenceDetectionService) {
        let audio = MockAudioService()
        audio.playbackDurationNs = 0
        let silence = MockSilenceDetectionService()
        let vm = QuizViewModel(
            networkService: Fixtures.makeFullMockNetwork(),
            audioService: audio,
            persistenceStore: MockPersistenceStore(),
            silenceDetectionService: silence,
            clock: AnyClock(clock)
        )
        vm.currentSession = Fixtures.makeActiveSession()
        vm.currentQuestion = Question.preview
        vm.quizState = .askingQuestion
        vm.settings.thinkingTime = 10
        return (vm, audio, silence)
    }

    // MARK: - Which states the strip shows

    /// WHY: the founder's rule, as a table. Reading is audible and the idle
    /// command bar advertised words that are heard unreliably, so both are
    /// gone; the countdown, the open mic and the wait for a verdict stay.
    @Test("the strip keeps the countdown, the mic and the wait, and drops reading and the idle bar when nothing listens")
    func stripStates() {
        let strip = { (phase: QuestionListenPhase) in QuestionListenPhase.strip(phase, hasCommandsAccessory: false) }
        #expect(strip(.readingQuestion) == nil)
        #expect(strip(.thinking(remaining: 0, total: 0)) == nil)
        // #243.6: a live command window keeps the strip in both.
        let listening = { (phase: QuestionListenPhase) in
            QuestionListenPhase.strip(phase, hasCommandsAccessory: false, commandsListening: true)
        }
        #expect(listening(.readingQuestion) == .readingQuestion)
        #expect(listening(.thinking(remaining: 0, total: 0)) == .thinking(remaining: 0, total: 0))
        #expect(strip(.thinking(remaining: 6, total: 10)) == .thinking(remaining: 6, total: 10))
        #expect(strip(.listening(.open)) == .listening(.open))
        #expect(strip(.evaluating) == .evaluating)
        #expect(strip(.skipping) == .skipping)
        #expect(QuestionListenPhase.strip(nil, hasCommandsAccessory: true) == nil)
    }

    /// WHY: "Turn on" exists nowhere else after onboarding, and "Settings" is
    /// how a refused microphone gets fixed. Hiding the reading and idle bars
    /// must not take that control with them.
    @Test("the commands permission control survives as the plain bar")
    func commandsControlSurvives() {
        #expect(QuestionListenPhase.strip(.readingQuestion, hasCommandsAccessory: true) == .thinking(remaining: 0, total: 0))
        #expect(QuestionListenPhase.strip(.thinking(remaining: 0, total: 0), hasCommandsAccessory: true)
            == .thinking(remaining: 0, total: 0))
    }

    @Test("while the question is read, no strip says so, on both question types",
          arguments: [Question.preview, Question.previewMCQ])
    func noReadingStrip(question: Question) async throws {
        let (vm, _, _) = makeVM()
        vm.currentQuestion = question
        vm.isPlayingQuestionTTS = true
        #expect(vm.listenPhase(for: question) == .readingQuestion, "precondition: the read is playing")

        let view = QuestionView(viewModel: vm)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: (any Error).self) { try tree.find(text: "Reading the question") }
            #expect(throws: (any Error).self) { try tree.find(viewWithAccessibilityIdentifier: "listen-bar") }
        }
    }

    /// WHY (#243.6, founder 2026-11-24, C4): after build 90 hid the strip the
    /// founder asked where it went: the app listened with nothing on screen
    /// saying so. Whenever a command window is live, the strip is there and
    /// names the words, on the countdown and without one.
    @Test("a live command window shows the strip with its words, with or without a countdown",
          arguments: [10, 0])
    func commandWordsWhileListening(thinkingTime: Int) async throws {
        let clock = TestClock()
        let (vm, _, _) = makeVM(clock: clock)
        vm.settings.thinkingTime = thinkingTime
        await vm.audioDeviceState.startSilenceDetectionListening()
        #expect(vm.commandListenerHint != nil, "precondition: a command window is armed")
        #expect(vm.showsVoiceHints, "precondition: the hints setting is on")
        vm.startRecordingOrTimer()
        if thinkingTime > 0 {
            await pumpUntil({ vm.thinkingTimeCountdown == 10 }, "the think window never started")
            // #243.3: „Think.“ is app speech, so it closes the window while it
            // plays; thinking listens again right after the line.
            await pumpUntil({ vm.commandListenerHint != nil }, "thinking never listened again after the think line")
        }

        let view = QuestionView(viewModel: vm)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) { try tree.find(viewWithAccessibilityIdentifier: "listen-bar") }
            #expect(throws: Never.self) { try tree.find(viewWithAccessibilityIdentifier: "listen-bar.commands") }
        }
        vm.quizTimersController.cancelThinkingTime()
    }

    /// WHY: a word on screen is a promise that it is heard. With the hints
    /// switched off in Settings, the strip stays but names nothing.
    @Test("the hints setting off keeps the strip but drops the words")
    func hintsOffDropsWords() async throws {
        let (vm, _, _) = makeVM()
        vm.settings.thinkingTime = 0
        vm.settings.voiceHintsEnabled = false
        await vm.audioDeviceState.startSilenceDetectionListening()
        #expect(vm.commandListenerHint != nil, "precondition: a command window is armed")

        #expect(vm.questionStripPhase(vm.listenPhase(for: try #require(vm.currentQuestion))) != nil)
        #expect(!vm.questionStripShowsWords)
    }

    // MARK: - Pause (problem 2)

    /// WHY (TF build 90, "pause states are odd"): paused during the read, the
    /// bar said "Reading the question" while the app was silent and nothing
    /// listened. A paused read now leaves the plain screen: the toolbar's play
    /// control says it is paused, nothing claims otherwise.
    @Test("a pause during the read leaves no strip claiming a read")
    func pausedReadShowsNoStrip() async throws {
        let (vm, audio, _) = makeVM()
        let question = try #require(vm.currentQuestion)
        audio.onPlaybackStarted = { [weak vm] in vm?.togglePause() }
        let readOut = Task { await vm.audioDeviceState.playQuestionAudio(from: "https://example.invalid/q.opus") }
        await pumpUntil({ vm.isPaused }, "the read never started")
        audio.onPlaybackStarted = nil

        #expect(vm.questionStripPhase(vm.listenPhase(for: question)) == nil)
        let view = QuestionView(viewModel: vm)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: (any Error).self) { try tree.find(text: "Reading the question") }
            #expect(throws: (any Error).self) { try tree.find(viewWithAccessibilityIdentifier: "listen-bar") }
        }
        vm.togglePause()
        await readOut.value
        vm.quizTimersController.cancelThinkingTime()
    }

    // MARK: - Hints in the open mic's bar

    /// WHY: the founder wants the spelling tip where the player is answering,
    /// not under the question. After a rejected transcript the retry's open
    /// mic carries it, and no free line remains on the screen.
    @Test("after a rejected transcript the open mic's bar offers spelling, and no free hint line remains")
    func spellingHintInRecordingBar() async throws {
        let (vm, _) = Fixtures.makeViewModelWithNetwork(clock: AnyClock(TestClock()))
        vm.currentSession = Fixtures.makeActiveSession()
        vm.currentQuestion = Fixtures.makeQuestion(id: "q_001")
        vm.quizState = .askingQuestion
        vm.settings.isMuted = true
        await vm.recordingCoordinator.submitVoiceAnswer(audioData: Data([0x1, 0x2]))
        vm.recordingCoordinator.rerecordAnswer()
        await pumpUntil({ vm.quizState != .processing }, "re-record never left the sheet")
        vm.quizState = .recording
        #expect(vm.answerBarNote == .spelling, "precondition: the transcript was rejected")

        let view = QuestionView(viewModel: vm)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            let bar = try tree.find(viewWithAccessibilityIdentifier: "listen-bar")
            #expect(throws: Never.self) { try bar.find(text: "Or spell it: P, A, R, I, S") }
            #expect(throws: (any Error).self) { try tree.find(viewWithAccessibilityIdentifier: "answer.spellingHint") }
            #expect(throws: (any Error).self) { try tree.find(viewWithAccessibilityIdentifier: "question.retryHint") }
        }
    }

    /// WHY: once the player speaks, the tip has done its job; the bar says
    /// how the recording ends instead, as on every other answer.
    @Test("the spelling tip gives way once speech is heard")
    func spellingTipYieldsToSpeech() throws {
        let bar = ListenBar(mode: .answer(.open), speechHeard: true, answerNote: .spelling)
        #expect(throws: Never.self) { try bar.inspect().find(text: "I'll stop when you go quiet") }
        #expect(throws: (any Error).self) { try bar.inspect().find(text: "Or spell it: P, A, R, I, S") }
    }

    // MARK: - Typing (problem 3)

    /// WHY (TF build 90): with the keyboard up the card was squeezed to a
    /// sliver under the strip, the Answer/Type/Skip row and the field. Typing
    /// is one state: the field, send and Skip sit on the keyboard. Skip stays
    /// (founder F2): a player stuck on the answer still moves on.
    @Test("while typing, only the field, send and Skip sit under the question")
    func typingIsOneCalmState() async throws {
        let (vm, _, _) = makeVM()
        let view = TypingFooterHost(viewModel: vm)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) { try tree.find(viewWithAccessibilityIdentifier: "question.textField") }
            #expect(throws: Never.self) { try tree.find(viewWithAccessibilityIdentifier: "question.textSubmit") }
            #expect(throws: (any Error).self, "the Answer button competes with the field") {
                try tree.find(viewWithAccessibilityIdentifier: "question.record")
            }
            #expect(throws: Never.self, "a player typing must still be able to skip") {
                try tree.find(viewWithAccessibilityIdentifier: "question.skip")
            }
        }
    }

    // MARK: - End Quiz? (problem 1)

    /// WHY (TF build 90): with "End Quiz?" open the think countdown ran on,
    /// and the mic could open behind the dialog. Asking whether to quit must
    /// hold the question, as Settings does (#240).
    @Test("the ✕ holds the think window while End Quiz? is open, and Continue goes on")
    func endQuizAlertHoldsTheQuestion() async throws {
        let clock = TestClock()
        let (vm, _, _) = makeVM(clock: clock)
        vm.startRecordingOrTimer()
        await pumpUntil({ vm.thinkingTimeCountdown == 10 }, "the think window never started")
        await clock.advance(by: .seconds(4))

        let view = QuestionView(viewModel: vm)
        try await ViewHosting.host(view) {
            try view.inspect().find(viewWithAccessibilityIdentifier: "question.closeButton").button().tap()
            await pumpUntil({ vm.isPaused }, "the ✕ did not hold the question")
            await clock.advance(by: .seconds(60))
            #expect(vm.quizState == .askingQuestion, "the mic opened behind the dialog")
        }

        vm.releaseQuestionAfterModal() // what Continue does
        #expect(!vm.isPaused)
        await pumpUntil({ vm.thinkingTimeCountdown == 6 }, "Continue must go on from the 6 s left")
        vm.quizTimersController.cancelThinkingTime()
    }
}

/// The voice footer with its answer field open, as `QuestionView` holds it
/// after the Type tap (that state is the screen's own `@State`).
private struct TypingFooterHost: View {
    @ObservedObject var viewModel: QuizViewModel
    @State private var showTextInput = true
    @State private var textAnswer = ""
    @State private var submittedAnswer = ""
    @FocusState private var focused: Bool

    var body: some View {
        QuestionVoiceFooter(
            viewModel: viewModel,
            showTextInput: $showTextInput,
            textAnswer: $textAnswer,
            submittedAnswer: $submittedAnswer,
            isTextFieldFocused: $focused
        )
    }
}
