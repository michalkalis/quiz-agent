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

import Foundation
@testable import Hangs
import Testing

@Suite("MCQ tap submit interrupts the read and is bounded (#178)")
@MainActor
struct MCQSubmitInterruptTests {
    private func makeVM(configure: (MockNetworkService) -> Void = { _ in }) -> (QuizViewModel, MockAudioService) {
        let audio = MockAudioService()
        let vm = QuizViewModel(
            networkService: Fixtures.makeFullMockNetwork(configure: configure),
            audioService: audio,
            persistenceStore: MockPersistenceStore()
        )
        vm.recordingCoordinator.transientBackoffOverride = { _ in .zero }
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
        let (vm, _) = makeVM { $0.submitTextInputDelay = .seconds(30) }
        vm.submitTimeoutSeconds = 1

        await vm.submitMCQAnswer(key: "a", value: "Paris")

        guard case let .error(message, context) = vm.quizState else {
            Issue.record("expected .error, got \(vm.quizState.label)")
            return
        }
        #expect(context == .submission)
        #expect(message.isEmpty == false)
    }
}
