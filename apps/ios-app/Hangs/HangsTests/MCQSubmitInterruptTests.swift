//
//  MCQSubmitInterruptTests.swift
//  HangsTests
//
//  #178 (founder TF 2026-09-13, Slovak MCQ quiz). Two failures of the tapped
//  answer path, both invisible to the state machine:
//
//  1. A tap while the question is still being read did not stop the read —
//     the driver had answered, the host kept talking.
//  2. The submit had no bound: a wedged request left the option spinner up
//     and every control disabled, with no error and no way out. The voice
//     submit has had a 30 s user-facing bound since #131; the tap path must
//     behave the same.
//

import Clocks
import Foundation
@testable import Hangs
import Testing

@Suite("MCQ tap submit interrupts the read and is bounded (#178)")
@MainActor
struct MCQSubmitInterruptTests {
    /// #180 track A: the submit's 30 s bound and its retry backoff both run on
    /// this clock. A `TestClock` that is never advanced therefore holds the bound
    /// open for the two interrupt tests, and the bound test drives the SHIPPED
    /// 30 s instead of shortening it.
    private func makeVM(
        clock: TestClock<Duration> = TestClock(),
        configure: (MockNetworkService) -> Void = { _ in }
    ) -> (QuizViewModel, MockAudioService) {
        let audio = MockAudioService()
        let vm = QuizViewModel(
            networkService: Fixtures.makeFullMockNetwork(configure: configure),
            audioService: audio,
            persistenceStore: MockPersistenceStore(),
            silenceDetectionService: MockSilenceDetectionService(),
            clock: AnyClock(clock)
        )
        vm.currentSession = Fixtures.makeActiveSession()
        vm.currentQuestion = Fixtures.makeQuestion(id: "q_001")
        vm.quizState = .askingQuestion
        return (vm, audio)
    }

    @Test("tap mid-read stops the question TTS before submitting")
    func tapStopsInFlightRead() async throws {
        let (vm, audio) = makeVM()
        vm.isPlayingQuestionTTS = true

        await vm.submitMCQAnswer(key: "a", value: "Paris")

        #expect(audio.stopPlaybackCallCount == 1)
    }

    @Test("tap after the read finished does not touch playback")
    func tapAfterReadLeavesPlaybackAlone() async throws {
        let (vm, audio) = makeVM()
        vm.isPlayingQuestionTTS = false

        await vm.submitMCQAnswer(key: "a", value: "Paris")

        #expect(audio.stopPlaybackCallCount == 0)
    }

    @Test("a wedged submit surfaces a timeout error instead of a spinner forever")
    func wedgedSubmitTimesOut() async throws {
        let clock = TestClock()
        // A request that never comes back: the mock's delay is real time the
        // driven clock will never reach, so only the bound can end this submit.
        let (vm, _) = makeVM(clock: clock) { $0.submitTextInputDelay = .seconds(600) }

        let submission = Task { await vm.submitMCQAnswer(key: "a", value: "Paris") }
        await pumpUntil { vm.quizState == .processing }
        await clock.advance(by: .seconds(vm.submitTimeoutSeconds - 1))
        #expect(vm.quizState == .processing, "the spinner gets its full shipped budget, not a millisecond less")
        await clock.advance(by: .seconds(1))
        await submission.value

        guard case let .error(message, context) = vm.quizState else {
            Issue.record("expected .error, got \(vm.quizState.label)")
            return
        }
        #expect(context == .submission)
        #expect(message.isEmpty == false)
    }

    /// WHY (#186 step 2, found by the sequence harness): a tap that answers
    /// while the mic is open ends that recording. The answer capture used to
    /// stay armed through the whole evaluation — and with voice commands off,
    /// the recording had started the mic engine itself, so the mic stayed live
    /// while nothing was listening for an answer (#149: the switch means OFF).
    @Test("a tap during a recording ends the answer capture")
    func tapDuringRecordingEndsCapture() async throws {
        let silence = MockSilenceDetectionService()
        let vm = QuizViewModel(
            networkService: Fixtures.makeFullMockNetwork(),
            audioService: MockAudioService(),
            persistenceStore: MockPersistenceStore(),
            silenceDetectionService: silence,
            clock: AnyClock(TestClock())
        )
        vm.settings.voiceCommandsEnabled = false
        vm.currentSession = Fixtures.makeActiveSession()
        vm.currentQuestion = Fixtures.makeQuestion(id: "q_001")
        vm.quizState = .askingQuestion
        await vm.toggleRecording()
        #expect(silence.isAnswerCaptureActive && silence.isListening, "the recording opened the mic itself")

        let submission = Task { await vm.submitMCQAnswer(key: "a", value: "Paris") }
        await pumpUntil { vm.quizState != .recording }

        #expect(silence.isAnswerCaptureActive == false, "the tapped answer left the recording's capture armed")
        #expect(silence.isListening == false, "voice commands are off — nothing may keep the mic live")
        submission.cancel()
    }
}
