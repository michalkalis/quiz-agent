//
//  VoiceFirstMinuteTests.swift
//  HangsTests
//
//  #240 — app quality from the subscription's spare capacity, task 240.9
//  (approved changes from the usability review). Build 90 opened the mic the
//  moment the question had been read; the founder tested it and rejected it
//  (2026-11-21): the question is read, the think time runs (10 s by default),
//  then the mic opens, as in build 89. What build 90 added and still stands:
//  the answer_captured measurement and the two #240 audit fixes in the same
//  answer path.
//

import Clocks
import Foundation
@testable import Hangs
import Testing

@Suite("#240.9 voice answer: think time, measurement, audit fixes")
@MainActor
struct VoiceFirstMinuteTests {
    private struct Rig {
        let vm: QuizViewModel
        let silence: MockSilenceDetectionService
        let network: MockNetworkService
        let analytics: MockAnalyticsClient
        let earcon: MockEarconPlayer
    }

    private func makeRig(clock: TestClock<Duration>, question: Question = Fixtures.makeQuestion(id: "q_001")) -> Rig {
        let audio = MockAudioService()
        audio.playbackDurationNs = 0
        audio.micPermissionStatus = .granted
        let silence = MockSilenceDetectionService()
        let network = Fixtures.makeFullMockNetwork()
        let analytics = MockAnalyticsClient()
        let vm = QuizViewModel(
            networkService: network,
            audioService: audio,
            persistenceStore: MockPersistenceStore(),
            silenceDetectionService: silence,
            clock: AnyClock(clock),
            analytics: analytics
        )
        let earcon = MockEarconPlayer()
        vm.earconPlayer = earcon
        vm.currentSession = Fixtures.makeActiveSession()
        vm.currentQuestion = question
        vm.quizState = .askingQuestion
        return Rig(vm: vm, silence: silence, network: network, analytics: analytics, earcon: earcon)
    }

    // MARK: - The think time comes before the mic

    /// WHY: the founder rejected the mic opening right after the question
    /// (build 90, 2026-11-21). With the default settings the read-out is
    /// followed by the full 10 s think time, and only then does the mic open,
    /// with the usual 5 s to start speaking.
    @Test("default: after the read the 10 s think time runs, then the mic opens with 5 s to start")
    func thinkTimeBeforeMic() async {
        let clock = TestClock()
        let rig = makeRig(clock: clock)
        #expect(rig.vm.settings.thinkingTime == 10)

        rig.vm.startRecordingOrTimer()
        await pumpUntil({ rig.vm.thinkingTimeCountdown == 10 }, "the think window never started")
        await clock.advance(by: .milliseconds(9999))
        for _ in 0 ..< 30 {
            await Task.yield()
        }
        #expect(rig.vm.quizState == .askingQuestion, "the mic opened before the think time ran out")
        #expect(!rig.silence.isAnswerCaptureActive)

        await advanceUntil(clock, step: .milliseconds(100), limit: .seconds(2), { rig.vm.quizState == .recording && rig.silence.isAnswerCaptureActive }, "the mic never opened after the think time")
        #expect(rig.vm.answerWindowTotal == Int(Config.speechStartWindow))
        rig.vm.quizTimersController.cancelAutoStopRecordingTimer()
    }

    // MARK: - Measurement

    /// WHY: the store numbers must say who opened the mic, how long after the
    /// question it opened, how loud the room was and whether the mic was
    /// allowed: the questions the 2026-11 data could not answer. A tap 3 s
    /// into the think time is a player who was ready early.
    @Test("answer_captured carries trigger, mic-open delay, peak level and mic permission")
    func answerCapturedMeasurement() async throws {
        let clock = TestClock()
        let rig = makeRig(clock: clock)
        rig.silence.answerDetectionReport.peakDb = -42.4

        rig.vm.startRecordingOrTimer()
        await pumpUntil({ rig.vm.thinkingTimeCountdown == 10 }, "the think window never started")
        await clock.advance(by: .seconds(3))
        await rig.vm.toggleRecording()
        await pumpUntil({ rig.vm.quizState == .recording && rig.silence.isAnswerCaptureActive }, "the tap never opened the mic")
        await advanceUntil(clock, limit: .seconds(Int(Config.autoRecordingDuration) + 5), { !rig.analytics.events(named: "answer_captured").isEmpty }, "the recording never ended")

        let captured = try #require(rig.analytics.events(named: "answer_captured").first)
        guard case let .answerCaptured(report) = captured else {
            Issue.record("not an answer_captured event")
            return
        }
        #expect(report.trigger == "tap")
        #expect(report.micOpenDelayMs == 3000, "the mic opened 3 s after the read")
        #expect(report.peakDb == -42)
        #expect(report.micPermission == "granted")
        #expect(report.isRetry == false)
        rig.vm.quizTimersController.cancelAutoStopRecordingTimer()
    }

    // MARK: - #240 audit findings

    /// WHY (audit 14): a typed answer sent while a skip was in flight took the
    /// skip's ownership. The skip's response was dropped and the quiz sat in
    /// `.skipping` until the 35 s watchdog showed "Failed to skip question",
    /// although the server had skipped it. The skip must land.
    @Test("a typed answer during an in-flight skip leaves the skip in charge")
    func typedAnswerDuringSkip() async {
        let rig = makeRig(clock: TestClock())
        let hold = rig.network.hold(.submitTextInput)

        let skip = Task { await rig.vm.skipQuestion() }
        await pumpUntil({ hold.heldCount == 1 }, "the skip never reached the server")
        #expect(rig.vm.quizState == .skipping)

        await rig.vm.resubmitAnswer("Paris")
        hold.release()
        await skip.value

        #expect(rig.vm.quizState != .skipping, "the quiz stayed stranded in .skipping")
        if case .error = rig.vm.quizState { Issue.record("a successful skip showed an error") }
        #expect(rig.network.submitTextInputCallCount == 1, "the typed answer went up after the skip")
        #expect(rig.vm.attemptLedger.invariantViolations.isEmpty)
    }

    /// WHY (audit 15): Skip on a multiple-choice question while the mic was
    /// open never ended the recording. With voice commands off the mic stayed
    /// live through the whole skip, the capture kept buffering, and the
    /// recording's detection session leaked into the next question.
    @Test("MCQ skip while the mic is open ends the recording")
    func mcqSkipWhileRecording() async {
        let rig = makeRig(clock: TestClock(), question: Self.mcqQuestion)
        rig.vm.settings.voiceCommandsEnabled = false
        let hold = rig.network.hold(.submitTextInput)

        await rig.vm.toggleRecording()
        await pumpUntil({ rig.vm.quizState == .recording && rig.silence.isAnswerCaptureActive }, "the mic never opened")
        #expect(rig.silence.isListening, "this recording started the engine itself")

        let skip = Task { await rig.vm.skipQuestion() }
        await pumpUntil({ hold.heldCount == 1 }, "the skip never reached the server")

        #expect(!rig.silence.isAnswerCaptureActive, "the capture kept buffering through the skip")
        #expect(!rig.silence.isAnswerDetectionActive, "the detection session leaked")
        #expect(!rig.silence.isListening, "the mic stayed live with voice commands off")

        hold.release()
        await skip.value
    }

    private static let mcqQuestion = Question(
        id: "q_mcq_240",
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
