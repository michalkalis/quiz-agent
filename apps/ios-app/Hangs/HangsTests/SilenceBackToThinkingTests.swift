//
//  SilenceBackToThinkingTests.swift
//  HangsTests
//
//  #243.4 (founder 2026-11-24, decision 2; TF 2026-11-22/23 B1, B2): "when I
//  can't think of an answer it keeps recording again and again". A window that
//  heard nothing is a player still thinking: back to thinking with "Think
//  more." and a fresh window, no spoken hint, the mic shut until that window
//  runs out. The spoken hint and the at-once retry stay for a player the app
//  heard but did not understand. The second miss offers "Repeat the question,
//  again, or next?" and listens for those words only after saying them;
//  "repeat" leads back to the question.
//

import Clocks
import Foundation
@testable import Hangs
import SwiftUI
import Testing
import ViewInspector

@Suite("#243.4 silence goes back to thinking; the no-answer sheet leads back to the question")
@MainActor
struct SilenceBackToThinkingTests {
    private static let questionURL = "https://example.com/q_001.mp3"

    private func makeVM(clock: TestClock<Duration>) -> (QuizViewModel, MockSilenceDetectionService, MockNetworkService, MockAudioService) {
        let silence = MockSilenceDetectionService()
        let audio = MockAudioService()
        audio.playbackDurationNs = 0
        let network = Fixtures.makeFullMockNetwork()
        let vm = QuizViewModel(
            networkService: network,
            audioService: audio,
            persistenceStore: MockPersistenceStore(),
            silenceDetectionService: silence,
            clock: AnyClock(clock)
        )
        vm.currentSession = Fixtures.makeActiveSession()
        vm.currentQuestion = Fixtures.makeQuestion(id: "q_001")
        vm.quizState = .askingQuestion
        vm.settings.thinkingTime = 10
        vm.recordingCoordinator.speechStartWindow = 60
        vm.recordingCoordinator.deadAirCap = 60
        return (vm, silence, network, audio)
    }

    private func clip(_ prompt: PhasePrompt) -> Data? {
        prompt.audio(language: .english)
    }

    /// A recording the server could not transcribe; `heard` = the voice
    /// detector heard the player.
    private func missAnswer(_ vm: QuizViewModel, _ silence: MockSilenceDetectionService, heard: Bool) async {
        await vm.toggleRecording()
        if heard { vm.recordingCoordinator.noteSpeechStarted() }
        silence.simulateAnswerAudio(Data(count: 16000))
        await vm.recordingCoordinator.stopRecordingAndSubmit()
    }

    /// The second-miss sheet with its offer line played and its window open.
    private func openNoAnswerSheet(_ vm: QuizViewModel) async {
        vm.recordingCoordinator.currentQuestionAudioUrl = Self.questionURL
        vm.quizState = .processing
        vm.recordingCoordinator.handleTranscriptionFailure(allowAutoRetry: false)
        await pumpUntil({ vm.commandListenerHint == VoiceCommandLexicon.hint(on: .noAnswer, language: .english) },
                        "the sheet never listened after its offer")
    }

    // MARK: - Silence

    /// WHY (decision 2): silence means "still thinking". No "didn't catch
    /// that", no hint on screen; "Think more." and a fresh window, and the mic
    /// opens only when that window runs out — never at once.
    @Test("silence: back to thinking with 'Think more.', no hint, the mic shut until the window ends")
    func silenceGoesBackToThinking() async throws {
        let clock = TestClock()
        let (vm, silence, network, audio) = makeVM(clock: clock)
        network.submitVoiceAnswerError = NetworkError.serverError(statusCode: 400, message: "speech not understood")
        let thinkMore = try #require(clip(.thinkMore))
        let answer = try #require(clip(.answer))

        await missAnswer(vm, silence, heard: false)

        await pumpUntil({ audio.lastPlayedData == thinkMore }, "'Think more.' never played")
        await pumpUntil({ vm.thinkingTimeCountdown == 10 }, "no fresh think window")
        #expect(vm.quizState == .askingQuestion)
        #expect(silence.isAnswerCaptureActive == false, "the mic reopened at once")
        #expect(network.synthesizedTexts.isEmpty, "silence got the spoken hint")
        #expect(vm.showsEmptyAnswerRetryHint == false, "silence got the hint on screen")
        #expect(vm.showAnswerConfirmation == false)

        await clock.advance(by: .milliseconds(9999))
        #expect(vm.quizState == .askingQuestion, "the mic opened before the window ran out")
        await clock.advance(by: .milliseconds(2))
        await pumpUntil({ audio.lastPlayedData == answer }, "'Answer.' never played")
        await pumpUntil({ vm.quizState == .recording && silence.isAnswerCaptureActive }, "the window's end never opened the mic")
        #expect(vm.attemptLedger.invariantViolations.isEmpty)
    }

    /// WHY: "Think more." belongs to that one window. A later window of the
    /// same question (a repeat, say) says the ordinary line again.
    @Test("'Think more.' is said once, then the ordinary think line")
    func thinkMoreIsOneShot() async throws {
        let clock = TestClock()
        let (vm, silence, network, audio) = makeVM(clock: clock)
        network.submitVoiceAnswerError = NetworkError.serverError(statusCode: 400, message: "speech not understood")
        await missAnswer(vm, silence, heard: false)
        await pumpUntil({ vm.thinkingTimeCountdown == 10 }, "no fresh think window")

        vm.quizTimersController.cancelThinkingTime()
        vm.startRecordingOrTimer()
        await pumpUntil({ vm.thinkingTimeCountdown == 10 }, "no second window")
        #expect(audio.lastPlayedData == clip(.think(seconds: 10)))
        #expect(audio.playedData.count { $0 == clip(.thinkMore) } == 1)
        vm.quizTimersController.cancelThinkingTime()
    }

    // MARK: - Heard but not understood

    /// WHY (founder 2026-11-24): a spoken hint only when the app heard the
    /// player but did not understand — then the line and the at-once retry
    /// stay as they were.
    @Test("speech heard but not understood: the spoken hint and an at-once re-record")
    func heardMissKeepsHintAndRetry() async {
        let (vm, silence, network, audio) = makeVM(clock: TestClock())
        network.submitVoiceAnswerError = NetworkError.serverError(statusCode: 400, message: "speech not understood")

        await missAnswer(vm, silence, heard: true)

        await pumpUntil({ vm.quizState == .recording && silence.isAnswerCaptureActive }, "the retry never re-opened the mic")
        #expect(network.synthesizedTexts == [SpokenPrompt.didNotCatch.text(language: .english)])
        #expect(!audio.playedData.contains(clip(.thinkMore) ?? Data()), "a heard miss went back to thinking")
    }

    /// WHY: an MCQ answer naming no option was heard by the server whatever
    /// the voice detector said; it keeps its own line and the retry.
    @Test("an MCQ answer matching no option keeps its line even without detected speech")
    func mcqUnmatchedKeepsHint() async {
        let (vm, _, network, _) = makeVM(clock: TestClock())
        vm.quizState = .recording

        vm.recordingCoordinator.handleTranscriptionFailure(prompt: .mcqUnmatchedLetter, heardSpeech: false)

        await pumpUntil({ vm.quizState == .recording }, "the retry never re-opened the mic")
        #expect(network.synthesizedTexts == [SpokenPrompt.mcqUnmatchedLetter.text(language: .english)])
    }

    // MARK: - The second miss

    /// WHY (founder principle 2026-11-24): commands are listened for only
    /// after a spoken line that names them. The offer plays with the window
    /// shut; the sheet listens for repeat · again · next only once it ends.
    @Test("second miss: the offer line plays before the command window opens")
    func offerBeforeWindow() async throws {
        let (vm, _, _, audio) = makeVM(clock: TestClock())
        let offer = try #require(clip(.noAnswerOffer))
        await vm.audioDeviceState.startSilenceDetectionListening()
        var screenDuringOffer: VoiceCommandScreen?? = .none
        audio.onPlaybackStarted = { [weak vm] in
            screenDuringOffer = .some(vm?.voiceCommandCoordinator.currentCommandScreen)
        }

        await openNoAnswerSheet(vm)

        #expect(audio.playedData == [offer])
        #expect(screenDuringOffer == .some(nil), "the window was open while the offer played")
        #expect(vm.voiceCommandCoordinator.currentCommandScreen == .noAnswer)
        #expect(vm.noAnswerCaptured && vm.showAnswerConfirmation)
        #expect(vm.taskBag.contains(.autoConfirm) == false, "the sheet waits for the player")
    }

    /// WHY: read-aloud off says nothing, and the sheet must still listen.
    @Test("second miss with read-aloud off: no offer line, the window opens at once")
    func mutedOfferIsSilent() async {
        let (vm, _, _, audio) = makeVM(clock: TestClock())
        vm.settings.isMuted = true
        await openNoAnswerSheet(vm)
        #expect(audio.playedData.isEmpty)
    }

    /// WHY (decision 2): a paused quiz stays paused — the sheet neither speaks
    /// nor opens a mic on its own.
    @Test("paused: the sheet says nothing and no mic opens")
    func pausedSheetStaysQuiet() async {
        let clock = TestClock()
        let (vm, silence, _, audio) = makeVM(clock: clock)
        vm.quizState = .processing
        vm.isPaused = true

        vm.recordingCoordinator.handleTranscriptionFailure()
        await clock.advance(by: .seconds(30))
        for _ in 0 ..< 20 {
            await Task.yield()
        }

        #expect(vm.showAnswerConfirmation && vm.noAnswerCaptured, "a paused miss lands on the sheet, as before")
        #expect(audio.playedData.isEmpty, "the offer spoke into a paused quiz")
        #expect(vm.quizState == .processing)
        #expect(silence.isAnswerCaptureActive == false)
        #expect(vm.voiceCommandCoordinator.currentCommandScreen == nil, "the window opened under the pause")
    }

    // MARK: - The sheet's three ways out

    /// WHY (B2): from the sheet there was no way back to the question. "Repeat"
    /// closes it, reads the question again, and only then the think window.
    @Test("'repeat' on the sheet reads the question again, then a fresh think window")
    func repeatByVoice() async {
        let (vm, silence, network, audio) = makeVM(clock: TestClock())
        await openNoAnswerSheet(vm)
        var countdownDuringRead: Int?
        audio.onPlaybackStarted = { [weak vm] in
            guard let vm, vm.isPlayingQuestionTTS else { return }
            countdownDuringRead = vm.thinkingTimeCountdown
        }

        silence.simulateCommandTranscript("repeat")

        await pumpUntil({ network.downloadedAudioPaths == [Self.questionURL] }, "the question was not read again")
        await pumpUntil({ vm.thinkingTimeCountdown == 10 }, "no think window after the read")
        #expect(countdownDuringRead == 0, "the think window ran during the read")
        #expect(vm.quizState == .askingQuestion)
        #expect(vm.showAnswerConfirmation == false && vm.noAnswerCaptured == false)
        #expect(silence.isAnswerCaptureActive == false)
        #expect(vm.attemptLedger.invariantViolations.isEmpty)
        vm.quizTimersController.cancelThinkingTime()
    }

    /// WHY (B2): the button does the same; a question without audio (or read
    /// off the screen) gets its silent reading pause before the window.
    @Test("the Repeat question button reopens the question without audio too")
    func repeatByButtonWithoutAudio() async {
        let (vm, silence, network, _) = makeVM(clock: TestClock())
        await openNoAnswerSheet(vm)
        vm.recordingCoordinator.currentQuestionAudioUrl = nil

        await vm.repeatQuestion()

        #expect(vm.quizState == .askingQuestion)
        #expect(vm.showAnswerConfirmation == false)
        #expect(vm.taskBag.contains(.thinkingTime), "no think window")
        #expect(vm.thinkingTimeCountdown == 10, "the reading pause holds the full window")
        #expect(network.downloadedAudioPaths.isEmpty)
        #expect(silence.isAnswerCaptureActive == false)
        vm.quizTimersController.cancelThinkingTime()
    }

    /// WHY: "again" still records again at once — the player asked for it.
    @Test("'again' on the sheet records at once")
    func againRecords() async {
        let (vm, silence, _, _) = makeVM(clock: TestClock())
        await openNoAnswerSheet(vm)
        silence.simulateCommandTranscript("again")
        await pumpUntil({ vm.quizState == .recording && silence.isAnswerCaptureActive }, "'again' did not record")
    }

    /// WHY: "next" moves on — the backend's skip.
    @Test("'next' on the sheet skips the question")
    func nextSkips() async {
        let (vm, silence, network, _) = makeVM(clock: TestClock())
        await openNoAnswerSheet(vm)
        silence.simulateCommandTranscript("next")
        await pumpUntil({ network.submitTextInputCallCount == 1 }, "'next' did not skip")
        #expect(network.capturedTextInputInput == "skip")
    }

    /// WHY (decision 2): "next" while thinking means "I don't know" — the
    /// player must still learn the answer, so the skip lands on a result that
    /// shows it.
    @Test("'next' while thinking reveals the correct answer")
    func nextWhileThinkingRevealsAnswer() async throws {
        let (vm, _, network, _) = makeVM(clock: TestClock())
        network.mockTextInputResponse = QuizResponse(
            success: true,
            message: "Skipped",
            session: Fixtures.makeQuizSession(id: "test_session_123", phase: "asking"),
            currentQuestion: Fixtures.makeQuestion(id: "q_002", text: "Next?", source: "Next"),
            evaluation: Evaluation(
                userAnswer: "", result: .skipped, points: 0, correctAnswer: "Uranus",
                questionId: "q_001", explanation: nil
            ),
            feedbackReceived: [],
            audio: nil
        )
        vm.startRecordingOrTimer()
        await pumpUntil({ vm.thinkingTimeCountdown == 10 }, "no think window")

        await vm.voiceCommandCoordinator.handleCommandTranscript(CommandTranscript(text: "next", isFinal: true))

        await pumpUntil({ vm.quizState.isShowingResult }, "'next' never reached a result")
        #expect(network.capturedTextInputInput == "skip")
        #expect(vm.resultEvaluation?.result == .skipped)
        let view = ResultView(viewModel: vm)
        try await ViewHosting.host(view) {
            #expect(throws: Never.self, "the skipped result hides the answer") { try view.inspect().find(text: "Uranus") }
        }
    }
}
