//
//  EmptyAnswerRetryTests.swift
//  HangsTests
//
//  #185 track B — an empty answer never skips a question silently, and a
//  recording never opens under the question read-out unless the driver asked.
//
//  Car test 2026-09-23: an answer cut off at 5 s came back empty (Scribe 400),
//  the empty confirmation sheet's 5 s auto-confirm ran out, confirming an empty
//  field IS a skip, and the next question appeared with no result and no word;
//  0.86 s later the mic opened during that question's read-out and the repeated
//  answer to the previous one landed on it. Founder decisions 2026-09-24:
//  1.1 (prompt + one automatic re-record, then Again/Skip with no countdown)
//  and "a tap during the read-out stops it and records; the hands-free start
//  waits for the read-out to end".
//

import Clocks
import Foundation
@testable import Hangs
import SwiftUI
import Testing
import ViewInspector

@Suite("#185 empty answer — prompt, one retry, then Again/Skip")
@MainActor
struct EmptyAnswerRetryTests {
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
            sttService: nil,
            clock: AnyClock(clock)
        )
        vm.currentSession = Fixtures.makeActiveSession()
        vm.currentQuestion = Fixtures.makeQuestion(id: "q_001")
        vm.quizState = .askingQuestion
        return (vm, silence, network, audio)
    }

    /// Record something the backend cannot understand (the car-test 400).
    private func recordUnderstoodAsNothing(_ vm: QuizViewModel, _ silence: MockSilenceDetectionService) async {
        silence.simulateAnswerAudio(Data(count: 16000))
        await vm.recordingCoordinator.stopRecordingAndSubmit()
    }

    /// WHY (pinning test c — the whole 1.1 flow): the first empty answer is
    /// met with a spoken "didn't catch that" and the mic opens again for the
    /// SAME question; the second opens Again/Skip with nothing counting down,
    /// so the question can only be skipped by the driver. Time passing on that
    /// sheet must change nothing.
    @Test("empty → prompt → retry → second empty → Again/Skip sheet that never resolves itself")
    func emptyThenRetryThenSheetWithoutCountdown() async {
        let clock = TestClock()
        let (vm, silence, network, _) = makeVM(clock: clock)
        network.submitVoiceAnswerError = NetworkError.serverError(statusCode: 400, message: "speech not understood")

        await vm.toggleRecording()
        await recordUnderstoodAsNothing(vm, silence)

        await pumpUntil({ vm.quizState == .recording && silence.isAnswerCaptureActive }, "the retry never re-opened the mic")
        #expect(network.synthesizedTexts == [SpokenPrompt.didNotCatch.text(language: .english)])
        #expect(vm.currentQuestion?.id == "q_001", "the retry answers the same question")
        #expect(vm.currentAttempt.questionId == "q_001")
        #expect(vm.showAnswerConfirmation == false)

        await recordUnderstoodAsNothing(vm, silence)

        #expect(vm.showAnswerConfirmation)
        #expect(vm.noAnswerCaptured)
        #expect(vm.quizState == .processing)
        #expect(vm.taskBag.contains(.autoConfirm) == false)
        #expect(vm.autoConfirmCountdown == 0)
        #expect(network.synthesizedTexts.count == 1, "the sheet is not announced (1.2 rejected)")

        await clock.advance(by: .seconds(Config.autoConfirmDelaySecs * 3))
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        #expect(vm.showAnswerConfirmation, "the sheet waited for the driver")
        #expect(network.submitTextInputCallCount == 0, "nothing skipped the question on the driver's behalf")
        #expect(vm.attemptLedger.invariantViolations.isEmpty)
    }

    /// WHY (pinning test a): confirming an empty field IS a skip. Whatever route
    /// arms a countdown over an empty answer, the countdown firing must never
    /// skip — only a tap or a spoken command may.
    @Test("an auto-confirm firing over an empty answer never skips")
    func autoConfirmOfEmptyAnswerNeverSkips() async {
        let clock = TestClock()
        let (vm, _, network, _) = makeVM(clock: clock)
        vm.quizState = .processing
        vm.recordingCoordinator.handleTranscriptionFailure(allowAutoRetry: false)
        // Force the countdown the no-answer sheet deliberately does not arm.
        vm.quizTimersController.startAutoConfirmIfEnabled()

        await clock.advance(by: .seconds(Config.autoConfirmDelaySecs + 1))
        await pumpUntil({ vm.autoConfirmCountdown == 0 && !vm.taskBag.contains(.autoConfirm) || vm.quizState != .processing },
                        "the countdown never reached its end")
        for _ in 0 ..< 20 {
            await Task.yield()
        }

        #expect(network.submitTextInputCallCount == 0, "the countdown skipped the question")
        #expect(vm.quizState == .processing)
        #expect(vm.showAnswerConfirmation)
        #expect(vm.noAnswerCaptured, "the driver is left on Again / Skip")
    }

    /// WHY: mute silences the app, not the flow — a muted driver still gets
    /// the one automatic re-record, just without the spoken line.
    @Test("muted: the first miss re-records without speaking")
    func mutedFirstMissRetriesSilently() async {
        let (vm, silence, network, _) = makeVM(clock: TestClock())
        vm.quizMuteOverride = true
        network.submitVoiceAnswerError = NetworkError.serverError(statusCode: 400, message: "speech not understood")

        await vm.toggleRecording()
        await recordUnderstoodAsNothing(vm, silence)

        await pumpUntil({ vm.quizState == .recording && silence.isAnswerCaptureActive }, "muted retry never re-opened the mic")
        #expect(network.synthesizedTexts.isEmpty)
    }

    /// WHY: the prompt is spoken in the QUIZ language — the language the
    /// driver answers and says commands in — for every quiz language we serve,
    /// in the founder's wording (2026-09-24).
    @Test("the prompt exists in every quiz language")
    func promptInEveryQuizLanguage() {
        #expect(SpokenPrompt.didNotCatch.text(language: .slovak) == "Nezachytil som odpoveď, skús to znova.")
        #expect(SpokenPrompt.didNotCatch.text(language: .czech) == "Nezachytil jsem odpověď, zkus to znovu.")
        #expect(SpokenPrompt.didNotCatch.text(language: .english) == "I didn't catch your answer, please try again.")
    }

    /// WHY (founder 2026-09-24): the retry line is ALSO on screen, for the whole
    /// retry — while it is spoken and while the mic is open again — and gone
    /// once that recording ends; a stale line would claim a miss that is over.
    @Test("the retry line is shown during the prompt and the retry recording, then gone")
    func retryLineShownDuringRetryOnly() async {
        let (vm, silence, network, audio) = makeVM(clock: TestClock())
        network.submitVoiceAnswerError = NetworkError.serverError(statusCode: 400, message: "speech not understood")
        var shownWhileSpeaking = false
        audio.onPlaybackStarted = { shownWhileSpeaking = vm.showsEmptyAnswerRetryHint }
        #expect(vm.showsEmptyAnswerRetryHint == false)

        await vm.toggleRecording()
        await recordUnderstoodAsNothing(vm, silence)
        await pumpUntil({ vm.quizState == .recording && silence.isAnswerCaptureActive }, "the retry never re-opened the mic")

        #expect(shownWhileSpeaking, "the line is on screen while it is spoken")
        #expect(vm.showsEmptyAnswerRetryHint, "…and while the mic is open again")

        network.submitVoiceAnswerError = nil
        vm.quizMuteOverride = true // no read-back of the answer
        await recordUnderstoodAsNothing(vm, silence)

        #expect(vm.showAnswerConfirmation, "the retry's answer reached the sheet")
        #expect(vm.showsEmptyAnswerRetryHint == false, "the line is gone once the retry recording ends")
    }

    /// WHY: muted means no spoken line — which is exactly when the driver needs
    /// the written one to know why the mic opened again. It is on the question
    /// screen itself, next to the mic.
    @Test("muted: the retry line is on the question screen while the mic is open again")
    func mutedRetryLineOnQuestionScreen() async throws {
        let (vm, silence, network, _) = makeVM(clock: TestClock())
        vm.quizMuteOverride = true
        network.submitVoiceAnswerError = NetworkError.serverError(statusCode: 400, message: "speech not understood")

        await vm.toggleRecording()
        await recordUnderstoodAsNothing(vm, silence)
        await pumpUntil({ vm.quizState == .recording && silence.isAnswerCaptureActive }, "the retry never re-opened the mic")

        let view = QuestionView(viewModel: vm)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) { try tree.find(viewWithAccessibilityIdentifier: "question.retryHint") }
            #expect(throws: Never.self) { try tree.find(text: "I didn't catch your answer, please try again.") }
        }
    }
}

@Suite("#185 recording start vs the question read-out")
@MainActor
struct RecordingDuringReadOutTests {
    private func makeReadingVM(clock: TestClock<Duration>) -> (QuizViewModel, MockSilenceDetectionService, MockAudioService) {
        let silence = MockSilenceDetectionService()
        let audio = MockAudioService()
        let vm = QuizViewModel(
            networkService: Fixtures.makeFullMockNetwork(),
            audioService: audio,
            persistenceStore: MockPersistenceStore(),
            silenceDetectionService: silence,
            sttService: nil,
            clock: AnyClock(clock)
        )
        vm.currentSession = Fixtures.makeActiveSession()
        vm.currentQuestion = Fixtures.makeQuestion(id: "q_002")
        vm.quizState = .askingQuestion
        // Question 2 is being read out.
        vm.isPlayingQuestionTTS = true
        audio.isPlaying = true
        return (vm, silence, audio)
    }

    /// WHY (founder 2026-09-24): a tap on record during the read-out is an
    /// explicit "I'm answering now" — stop reading and record at once. The
    /// recording must belong to the question on screen: a new attempt of it.
    @Test("a tap during the read-out stops it and records for this question")
    func tapStopsReadOutAndRecords() async {
        let (vm, silence, audio) = makeReadingVM(clock: TestClock())
        let before = vm.currentAttempt

        await vm.toggleRecording()

        #expect(audio.stopPlaybackCallCount >= 1, "the read-out must stop before the mic opens")
        #expect(vm.isPlayingQuestionTTS == false)
        #expect(vm.quizState == .recording)
        #expect(silence.isAnswerCaptureActive)
        #expect(vm.currentAttempt.questionId == "q_002", "the recording answers the question on screen")
        #expect(vm.currentAttempt.sequence > before.sequence, "…as a new attempt of it")
    }

    /// WHY (founder 2026-09-24): the hands-free start (think/answer countdown)
    /// must not cut the question off — it waits for the read-out to end, and
    /// only then opens the mic.
    @Test("the hands-free start waits for the read-out to end")
    func autoStartWaitsForReadOut() async {
        let clock = TestClock()
        let (vm, silence, audio) = makeReadingVM(clock: clock)

        let start = Task { await vm.recordingCoordinator.startRecording(trigger: .autoRecord) }
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        await clock.advance(by: .milliseconds(300))
        #expect(vm.quizState == .askingQuestion, "the mic opened under the read-out")
        #expect(audio.stopPlaybackCallCount == 0, "the hands-free start cut the question off")

        vm.isPlayingQuestionTTS = false // the read-out ends
        await clock.advance(by: .milliseconds(100))
        await start.value

        #expect(vm.quizState == .recording)
        #expect(silence.isAnswerCaptureActive)
    }

    /// WHY: a wait that outlives its question must not open the mic on the next
    /// one — the wait is question-scoped like every other countdown (#186).
    @Test("a hands-free start whose question moved on while waiting never records")
    func autoStartAbandonedWhenQuestionMovesOn() async {
        let clock = TestClock()
        let (vm, silence, _) = makeReadingVM(clock: clock)

        let start = Task { await vm.recordingCoordinator.startRecording(trigger: .autoRecord) }
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        vm.currentQuestion = Fixtures.makeQuestion(id: "q_003")
        await clock.advance(by: .milliseconds(100))
        await start.value

        #expect(vm.quizState == .askingQuestion)
        #expect(silence.isAnswerCaptureActive == false)
    }
}

@Suite("#185 no-answer sheet: Again / Skip")
@MainActor
struct NoAnswerSheetViewTests {
    private func makeView(noAnswer: Bool) -> AnswerConfirmationView {
        AnswerConfirmationView(
            isProcessing: false,
            transcribedAnswer: .constant(""),
            autoConfirmCountdown: 0,
            autoConfirmEnabled: true,
            autoConfirmTotal: Config.autoConfirmDelaySecs,
            onConfirm: {},
            onReRecord: {},
            noAnswerCaptured: noAnswer
        )
    }

    /// WHY: after the second miss the driver chooses — Again or Skip, the
    /// founder's two words (they are also the voice words) — and nothing on the
    /// sheet counts down. A Confirm there would read as "submit my answer".
    @Test("the second-miss sheet offers Again and Skip, no Confirm and no countdown")
    func offersAgainAndSkip() throws {
        let tree = try makeView(noAnswer: true).inspect()
        #expect(throws: Never.self) { try tree.find(text: "Nothing heard") }
        #expect(throws: Never.self) { try tree.find(viewWithAccessibilityIdentifier: "confirmation.reRecord") }
        #expect(throws: Never.self) { try tree.find(viewWithAccessibilityIdentifier: "confirmation.skip") }
        #expect(try tree.find(viewWithAccessibilityIdentifier: "confirmation.reRecord").isDisabled() == false,
                "Again must work with no countdown running")
        #expect(throws: (any Error).self) { try tree.find(viewWithAccessibilityIdentifier: "confirmation.confirm") }
    }

    /// WHY: an empty field the driver cleared while editing is not a miss —
    /// it keeps the ordinary Confirm sheet (#171 Track B contract).
    @Test("an emptied transcript keeps the ordinary Confirm sheet")
    func emptiedTranscriptKeepsConfirm() throws {
        let tree = try makeView(noAnswer: false).inspect()
        #expect(throws: Never.self) { try tree.find(viewWithAccessibilityIdentifier: "confirmation.confirm") }
        #expect(throws: (any Error).self) { try tree.find(viewWithAccessibilityIdentifier: "confirmation.skip") }
    }
}
