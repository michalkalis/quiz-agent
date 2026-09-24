//
//  NoSpeechWindowTests.swift
//  HangsTests
//
//  #185 track A (car test 2026-09-23): all 16 answers were cut by the 5 s
//  "time to start speaking" window because the detector never heard speech.
//  Founder 2026-09-24: that window may end a recording only when the detector
//  demonstrably works; otherwise the hidden cap does, and an answer is never
//  cut off. Plus: every recording opens its own detection session (H3), with
//  the lower blip bar for a multiple-choice answer.
//

import Clocks
import Foundation
@testable import Hangs
import Testing

@Suite("#185 no-speech window + per-recording detection session")
@MainActor
struct NoSpeechWindowTests {
    private func makeVM(
        clock: AnyClock<Duration> = .continuous,
        question: Question = Fixtures.makeQuestion()
    ) -> (QuizViewModel, MockSilenceDetectionService) {
        let silence = MockSilenceDetectionService()
        let vm = QuizViewModel(
            networkService: Fixtures.makeFullMockNetwork(),
            audioService: MockAudioService(),
            persistenceStore: MockPersistenceStore(),
            silenceDetectionService: silence,
            sttService: nil,
            clock: clock
        )
        vm.currentSession = Fixtures.makeActiveSession()
        vm.currentQuestion = question
        vm.quizState = .askingQuestion
        return (vm, silence)
    }

    /// WHY: the car bug itself. A detector that cannot vouch for the silence
    /// (no audio, still calibrating, maybe-speech) must not let a 5 s timer cut
    /// a late or quiet answer — the countdown goes away and the cap decides.
    @Test("a detector that cannot vouch for the silence leaves the answer to the cap, never the 5 s window")
    func unprovenDetectorDefersToCap() async {
        let clock = TestClock()
        let (vm, silence) = makeVM(clock: AnyClock(clock))
        silence.noSpeechWindowVerdict = .possibleSpeech

        await vm.recordingCoordinator.startRecording()
        #expect(vm.answerWindowTotal == Int(Config.speechStartWindow))

        await clock.advance(by: .seconds(Int(Config.speechStartWindow)))
        await pumpUntil({ vm.answerWindowTotal == 0 }, "the countdown should disappear at the deferral")
        #expect(vm.quizState == .recording, "the window cut an answer the detector could not vouch for")
        #expect(vm.recordingCoordinator.noSpeechWindowDeferral == .possibleSpeech)
        #expect(vm.taskBag.contains(.recordingHardCap), "the cap must still end the recording")

        await clock.advance(by: .seconds(Int(Config.autoRecordingDuration - Config.speechStartWindow) - 1))
        #expect(vm.quizState == .recording, "nothing may end it before the cap")
        await clock.advance(by: .seconds(1))
        await pumpUntil({ vm.quizState != .recording }, "the cap never ended the recording")
    }

    /// The contrast: a live detector that heard nothing still closes a silent
    /// recording at 5 s — the founder's window keeps its job on dead air.
    @Test("a live detector that heard nothing still closes the silent recording at the window")
    func quietDetectorClosesAtWindow() async {
        let clock = TestClock()
        let (vm, silence) = makeVM(clock: AnyClock(clock))
        silence.noSpeechWindowVerdict = .quiet

        await vm.recordingCoordinator.startRecording()
        await clock.advance(by: .seconds(Int(Config.speechStartWindow) - 1))
        #expect(vm.quizState == .recording)
        await clock.advance(by: .seconds(1))

        await pumpUntil({ vm.quizState != .recording }, "the window should end a silent recording")
        #expect(vm.recordingCoordinator.noSpeechWindowDeferral == nil)
        #expect(!silence.isAnswerDetectionActive, "the stop closes the detection session")
    }

    /// WHY (H3 + the MCQ blip): each recording starts its own session — nothing
    /// the command window's detector saw carries over — and a multiple-choice
    /// answer gets the bar a single "c" / "dva" can clear.
    @Test("every batch recording opens a fresh session; MCQ with the lower blip bar")
    func sessionPerRecordingWithMCQBar() async {
        let (openVM, openSilence) = makeVM()
        await openVM.recordingCoordinator.startRecording()
        #expect(openSilence.answerDetectionMinSpeechDurations == [VADTuning.minSpeechDurationSecs])
        #expect(openSilence.isAnswerDetectionActive)
        openSilence.simulateAnswerAudio(Data(count: 16000))
        await openVM.recordingCoordinator.stopRecordingAndSubmit()
        #expect(!openSilence.isAnswerDetectionActive)

        let (mcqVM, mcqSilence) = makeVM(question: Self.mcqQuestion)
        await mcqVM.recordingCoordinator.startRecording()
        #expect(mcqSilence.answerDetectionMinSpeechDurations == [VADTuning.mcqMinSpeechDurationSecs])
    }

    /// WHY: a session left open by an abandoned recording would be read as the
    /// next recording's evidence.
    @Test("an interrupted recording closes its detection session")
    func interruptionClosesSession() async {
        let (vm, silence) = makeVM()
        await vm.recordingCoordinator.startRecording()
        #expect(silence.isAnswerDetectionActive)

        vm.recordingCoordinator.handleAudioInterruption()

        #expect(!silence.isAnswerDetectionActive)
    }

    private static let mcqQuestion = Question(
        id: "q_mcq_185",
        question: "Largest planet?",
        type: .textMultichoice,
        possibleAnswers: ["a": "Mars", "b": "Jupiter", "c": "Venus", "d": "Saturn"],
        difficulty: "medium",
        topic: "Astronomy",
        category: "science",
        sourceUrl: nil,
        sourceExcerpt: nil,
        mediaUrl: nil,
        imageSubtype: nil,
        explanation: nil,
        generatedBy: nil
    )
}
