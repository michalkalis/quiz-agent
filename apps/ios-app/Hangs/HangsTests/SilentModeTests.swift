//
//  SilentModeTests.swift
//  HangsTests
//
//  "No sound" (founder 2026-11-22): a switch on Home for playing where the
//  phone must stay quiet. With it on, nothing in the quiz makes a sound or
//  listens: no read aloud, no microphone (no permission prompt either), no
//  voice commands, no tones, no spoken result. A question has no time limit,
//  the typed field is open at once, and the player leaves it by sending or
//  skipping. Nothing in a silent quiz may use up a free voice answer.
//

import Clocks
import Foundation
@testable import Hangs
import SwiftUI
import Testing
import ViewInspector

@Suite("Silent mode: No sound (founder 2026-11-22)")
@MainActor
struct SilentModeTests {
    private struct Rig {
        let vm: QuizViewModel
        let network: MockNetworkService
        let audio: MockAudioService
        let silence: MockSilenceDetectionService
        let store: MockPersistenceStore
        let analytics: MockAnalyticsClient
        let clock: TestClock<Duration>
    }

    private static let questionAudio = "https://example.com/q.mp3"
    private static let spokenVerdict = AudioInfo(feedbackUrl: nil, feedbackAudioBase64: "AAAA", questionUrl: nil, format: "opus")

    private func makeRig(silent: Bool = true) -> Rig {
        let clock = TestClock()
        let network = Fixtures.makeFullMockNetwork { mock in
            // The start hands over a question with its read-aloud clip: the
            // path that speaks and then opens the mic in a normal quiz.
            mock.mockResponse = QuizResponse(
                success: true,
                message: "",
                session: Fixtures.makeQuizSession(),
                currentQuestion: Fixtures.makeQuestion(id: "q_001"),
                evaluation: nil,
                feedbackReceived: [],
                audio: AudioInfo(feedbackUrl: nil, feedbackAudioBase64: nil, questionUrl: Self.questionAudio, format: "opus")
            )
        }
        network.networkClock = AnyClock(clock)
        network.mockAudioData = Data("opus-bytes".utf8)
        let audio = MockAudioService()
        audio.playbackDurationNs = 0
        audio.micPermissionStatus = .undetermined
        let silence = MockSilenceDetectionService()
        let store = MockPersistenceStore()
        let analytics = MockAnalyticsClient()
        let vm = QuizViewModel(
            networkService: network,
            audioService: audio,
            persistenceStore: store,
            silenceDetectionService: silence,
            clock: AnyClock(clock),
            analytics: analytics
        )
        vm.settings.silentMode = silent
        return Rig(vm: vm, network: network, audio: audio, silence: silence, store: store, analytics: analytics, clock: clock)
    }

    /// The question is on screen, as after a start.
    private func onQuestion(_ rig: Rig, _ question: Question = Fixtures.makeQuestion(id: "q_001")) {
        rig.vm.currentSession = Fixtures.makeActiveSession()
        rig.vm.currentQuestion = question
        rig.vm.quizState = .askingQuestion
    }

    /// The answer to q_001 comes back graded, with its spoken verdict.
    private func gradedResponse() -> QuizResponse {
        QuizResponse(
            success: true,
            message: "",
            session: Fixtures.makeQuizSession(),
            currentQuestion: Fixtures.makeQuestion(id: "q_002"),
            evaluation: Evaluation(
                userAnswer: "4", result: .correct, points: 1, correctAnswer: "4",
                questionId: "q_001", explanation: "Two and two make four."
            ),
            feedbackReceived: [],
            audio: Self.spokenVerdict
        )
    }

    // MARK: - The question

    // WHY: the founder decision itself. A quiz started silent must not read
    // the question, ask for the microphone, open a command window or start
    // the countdown that opens the mic, however long the player takes.
    @Test("a silent question is never read, never listened to and has no time limit")
    func silentQuestionStaysSilent() async {
        let rig = makeRig()

        await rig.vm.startNewQuiz()
        #expect(rig.vm.quizState == .askingQuestion)
        await rig.clock.advance(by: .seconds(120))
        await pumpUntil { rig.vm.quizState == .askingQuestion }

        #expect(rig.audio.playOpusCallCount == 0, "the question was read aloud")
        #expect(rig.audio.micPermissionRequestCount == 0, "the microphone prompt came up")
        #expect(rig.audio.setupAudioSessionCallCount == 0, "the quiz took over the player's own audio")
        #expect(rig.silence.startListeningCallCount == 0, "a listener opened the mic")
        #expect(rig.vm.voiceCommandCoordinator.currentCommandScreen == nil, "a command window is armed")
        #expect(rig.vm.thinkingTimeCountdown == 0, "a countdown towards a mic that never opens")
        #expect(rig.vm.answerWindowTotal == 0)
        #expect(rig.vm.isAnswerCaptureActive == false)
        #expect(rig.network.submitVoiceAnswerCallCount == 0)
        #expect(rig.network.synthesizedTexts.isEmpty, "a spoken line was fetched")
    }

    // WHY: the control for the test above. The same start without the switch
    // reads the question and asks for the mic, so the silent result is the
    // switch's doing and not the rig's.
    @Test("the same start with sound reads the question and asks for the mic")
    func soundQuizStillSpeaks() async {
        let rig = makeRig(silent: false)

        await rig.vm.startNewQuiz()

        #expect(rig.audio.playOpusCallCount == 1)
        #expect(rig.audio.micPermissionRequestCount == 1)
        rig.vm.quizTimersController.cancelThinkingTime()
    }

    // WHY: every other way to the mic (the Answer tap, a spoken "start", the
    // pause ending) must be closed too, or one stray path opens it.
    @Test("no way into the mic opens it in a silent quiz")
    func noPathOpensTheMic() async {
        let rig = makeRig()
        onQuestion(rig)

        await rig.vm.toggleRecording()
        await rig.vm.recordingCoordinator.startRecording(trigger: .voiceCommand)
        rig.vm.startRecordingOrTimer()
        rig.vm.togglePause()
        rig.vm.togglePause()

        #expect(rig.vm.quizState == .askingQuestion)
        #expect(rig.vm.isAnswerCaptureActive == false)
        #expect(rig.vm.thinkingTimeCountdown == 0)
        #expect(rig.audio.prepareForRecordingCallCount == 0)
    }

    // WHY: the voice answers are the free tier's scarce part. A typed answer
    // goes to the text endpoint and asks for no spoken audio.
    @Test("a silent typed answer never reaches the voice endpoint and asks for no audio")
    func typedAnswerIsNotVoice() async {
        let rig = makeRig()
        onQuestion(rig)
        rig.network.mockResponse = gradedResponse()

        await rig.vm.resubmitAnswer("4")

        #expect(rig.vm.quizState.isShowingResult)
        #expect(rig.network.submitVoiceAnswerCallCount == 0)
        #expect(rig.network.submitTextInputCallCount == 1)
        #expect(rig.network.capturedTextInputAudio == false, "the server made audio nobody hears")
        rig.vm.taskBag.cancel(.autoAdvance)
    }

    // WHY: with no time limit, Skip is one of the two ways out of a question.
    @Test("Skip leaves a silent question")
    func skipLeavesTheQuestion() async {
        let rig = makeRig()
        onQuestion(rig)
        rig.network.mockResponse = gradedResponse()

        await rig.vm.skipQuestion()

        #expect(rig.network.submitTextInputCallCount == 1)
        #expect(rig.network.capturedTextInputAudio == false)
        #expect(rig.vm.quizState.isShowingResult, "the skip did not leave the question")
        #expect(rig.audio.playOpusCallCount == 0)
        rig.vm.taskBag.cancel(.autoAdvance)
    }

    // MARK: - The result

    // WHY: the result keeps its pause and auto-advance, it only speaks
    // nothing, also when the server sent a verdict, and "hear it" is gone.
    @Test("the result speaks nothing and counts its usual pause")
    func resultSpeaksNothing() async {
        let rig = makeRig()
        onQuestion(rig)
        rig.vm.quizState = .processing

        await rig.vm.handleQuizResponse(gradedResponse())
        await pumpUntil({ rig.vm.autoAdvanceCountdown == rig.vm.settings.autoAdvanceDelay }, "the result did not count its pause")
        rig.vm.readExplanationAloud("Two and two make four.")
        await pumpUntil { true }

        #expect(rig.audio.playOpusCallCount == 0, "the verdict was spoken")
        #expect(rig.vm.isAwaitingSpokenVerdict == false)
        #expect(rig.network.synthesizedTexts.isEmpty, "the explanation was read")
        rig.vm.taskBag.cancel(.autoAdvance)
    }

    // MARK: - The screens

    // WHY: typing is the way to answer, so the field is there from the start,
    // with send and Skip; Answer (the mic), Type and the mute are not.
    @Test("the open question shows the typed field and no voice controls")
    func questionScreenIsTyped() async throws {
        let rig = makeRig()
        onQuestion(rig)

        let view = QuestionView(viewModel: rig.vm)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            for id in ["question.textField", "question.textSubmit", "question.skip"] {
                #expect(throws: Never.self, "\(id) is missing") { try tree.find(viewWithAccessibilityIdentifier: id) }
            }
            for id in ["question.record", "question.textInputToggle", "listen-bar", "question.replayGlyph"] {
                #expect(throws: (any Error).self, "\(id) is on a silent question") { try tree.find(viewWithAccessibilityIdentifier: id) }
            }
        }
    }

    // WHY: multiple choice is answered by a tap; no countdown bar or mic.
    @Test("a silent multiple-choice question has its options and no listen bar")
    func mcqIsTapOnly() async throws {
        let rig = makeRig()
        onQuestion(rig, Question.previewMCQ)

        let view = QuestionView(viewModel: rig.vm)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) { try tree.find(viewWithAccessibilityIdentifier: "question.skip") }
            #expect(throws: (any Error).self) { try tree.find(viewWithAccessibilityIdentifier: "listen-bar") }
        }
    }

    @Test("the result offers no \"hear it\"")
    func resultHasNoHearIt() async throws {
        let rig = makeRig()
        let evaluation = Evaluation(
            userAnswer: "Paris", result: .correct, points: 1, correctAnswer: "Paris",
            questionId: Question.preview.id, explanation: "Capital since the 10th century."
        )
        rig.vm.currentSession = Fixtures.makeActiveSession()
        rig.vm.quizState = .showingResult(question: Question.preview, evaluation: evaluation)

        let view = ResultView(viewModel: rig.vm)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: (any Error).self) { try tree.find(viewWithAccessibilityIdentifier: "result.hearIt") }
        }
    }

    // WHY: nothing to mute in a silent quiz; the pause stays.
    @Test("the quiz bar has pause and no mute")
    func toolbarHasNoMute() async throws {
        let pill = QuizControlPill(isMuted: true, isPaused: false, isPauseEnabled: true, onMute: nil, onPause: {})
        try await ViewHosting.host(pill) {
            let tree = try pill.inspect()
            #expect(throws: Never.self) { try tree.find(viewWithAccessibilityIdentifier: "question.pause") }
            #expect(throws: (any Error).self) { try tree.find(viewWithAccessibilityIdentifier: "question.mute") }
        }
    }

    // WHY: the switch must be findable where the round is set up, also in the
    // family list, whose rounds play on the same question screen.
    @Test("Home shows the No sound row, also with kids")
    func homeRow() async throws {
        let rig = makeRig(silent: false)
        let view = HomeView(viewModel: rig.vm)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) { try tree.find(viewWithAccessibilityIdentifier: "home.silentMode") }
            #expect(throws: Never.self) { try tree.find(text: "No sound") }
            #expect(throws: Never.self) { try tree.find(text: "Read the questions, type the answers") }
        }
    }

    // MARK: - The switch

    // WHY: a setting the player flips once and expects to hold, across
    // launches; an older saved blob without it means sound on.
    @Test("the switch is saved, and an older save means sound on")
    func switchPersists() async throws {
        let rig = makeRig(silent: false)

        rig.vm.setSilentMode(true)

        await pumpUntil({ rig.store.loadSettings().silentMode }, "the switch was not saved")
        let legacy = try JSONEncoder().encode(QuizSettings.default)
        var blob = try #require(JSONSerialization.jsonObject(with: legacy) as? [String: Any])
        blob.removeValue(forKey: "silentMode")
        let decoded = try JSONDecoder().decode(QuizSettings.self, from: JSONSerialization.data(withJSONObject: blob))
        #expect(decoded.silentMode == false)
    }

    // WHY: the switch never rewrites the player's own sound settings, so
    // turning it off brings back exactly the quiz they had.
    @Test("the switch leaves read aloud, commands and the mic tone as the player set them")
    func switchKeepsOwnSettings() {
        let rig = makeRig()

        #expect(rig.vm.isAudioMuted)
        #expect(rig.vm.settings.isMuted == false)
        #expect(rig.vm.settings.voiceCommandsEnabled)
        #expect(rig.vm.settings.recordingSoundsEnabled)

        rig.vm.setSilentMode(false)
        #expect(rig.vm.isAudioMuted == false)
    }

    // WHY: CarPlay is left as it is: the car has no keyboard, so a round
    // played there keeps its voice.
    @Test("CarPlay keeps its voice")
    func carPlayIsNotSilent() {
        let rig = makeRig()
        rig.vm.isCarPlaySceneForeground = true

        #expect(rig.vm.isSilentMode == false)
        #expect(rig.vm.isAudioMuted == false)
    }

    // MARK: - Analytics

    // WHY: how many players turn sound off, and how many quizzes run silent.
    @Test("flipping the switch and a silent start are both tracked")
    func analytics() async {
        let rig = makeRig(silent: false)
        rig.vm.setSilentMode(true)
        rig.vm.setSilentMode(true)
        #expect(rig.analytics.events(named: "silent_mode_changed") == [.silentModeChanged(enabled: true)])

        await rig.vm.startNewQuiz()

        let context = rig.analytics.events(named: "quiz_context").first
        #expect(context?.properties["silent_mode"] == .bool(true))
    }
}
