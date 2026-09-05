//
//  QuizAudioSessionStabilityTests.swift
//  HangsTests
//
//  #171 Track A — the two audio faults the founder hit on TestFlight 2026-09-05:
//
//  1. The FIRST question was silent. The Home command listener was never
//     stopped before `startNewQuiz` re-configured and re-activated the audio
//     session, so the first AVPlayer started under a live mic engine, stalled,
//     and the 5 s stall timer failed the playback into Sentry only — silence
//     with the countdown running. Questions 2+ worked because the advance path
//     stops audio and settles first.
//  2. Loudness jumped during a quiz, twice per question: the session category
//     was swapped `.playAndRecord` ↔ `.playback` per utterance (~6 dB).
//
//  Both fixes are orderings/invariants the call counts alone cannot express, so
//  these pin them at the choke points: WHEN the listener is down relative to the
//  session setup and the first read, and that NOTHING re-configures the session
//  once a quiz is running.
//

import Foundation
@testable import Hangs
import Testing

/// Records what was true at the moment a session/playback step happened.
/// A count read after the fact cannot tell "before" from "after".
@MainActor
private final class AudioOrderRecorder {
    var listenerLiveAtSessionSetup: Bool?
    var listenerLiveAtFirstPlayback: Bool?
}

@MainActor
private func makeStartingVM() -> (QuizViewModel, MockAudioService, MockSilenceDetectionService) {
    let audio = MockAudioService()
    let silence = MockSilenceDetectionService()
    let network = Fixtures.makeFullMockNetwork()
    network.mockAudioData = Data("opus-bytes".utf8)
    // The start response must carry question audio — the silent-first-question
    // path only exists when there is something to read.
    network.mockResponse = QuizResponse(
        success: true,
        message: "Quiz started",
        session: Fixtures.makeActiveSession(),
        currentQuestion: Fixtures.makeQuestion(),
        evaluation: nil,
        feedbackReceived: [],
        audio: AudioInfo(
            feedbackUrl: nil,
            feedbackAudioBase64: nil,
            questionUrl: "https://example.com/q1.mp3",
            format: "opus"
        )
    )
    let vm = QuizViewModel(
        networkService: network,
        audioService: audio,
        persistenceStore: MockPersistenceStore(),
        silenceDetectionService: silence,
        sttService: nil
    )
    return (vm, audio, silence)
}

@Suite("Quiz audio session stability (#171 Track A)")
@MainActor
struct QuizAudioSessionStabilityTests {
    @Test("startNewQuiz stops the command listener before configuring the session and before the first read")
    func listenerIsDownBeforeSessionSetupAndFirstRead() async {
        let (vm, audio, silence) = makeStartingVM()
        let recorder = AudioOrderRecorder()

        // Home is listening for "start" when the quiz begins — exactly the state
        // the founder's first question started from.
        vm.quizState = .idle
        await vm.voiceCommandCoordinator.syncCommandListenerWindow()
        #expect(silence.isListening, "precondition: the Home command listener is live")

        audio.onSetupAudioSession = { recorder.listenerLiveAtSessionSetup = silence.isListening }
        audio.onPlaybackStarted = {
            if recorder.listenerLiveAtFirstPlayback == nil {
                recorder.listenerLiveAtFirstPlayback = silence.isListening
            }
        }

        await vm.startNewQuiz()

        // The bug: the mic engine still owned the input hardware while the
        // session was re-configured + re-activated under it.
        #expect(
            recorder.listenerLiveAtSessionSetup == false,
            "the command listener must be torn down BEFORE the quiz session is configured"
        )
        #expect(
            recorder.listenerLiveAtFirstPlayback == false,
            "the first question must not be read while the mic engine is live"
        )
        #expect(audio.playOpusCallCount == 1, "the first question is read exactly once")

        vm.quizTimersController.cancelThinkingTime()
        vm.quizTimersController.cancelAnswerTimer()
    }

    @Test("the audio session is configured once and never touched again during the quiz")
    func sessionConfigurationIsStableAcrossAQuestionCycle() async {
        let (vm, audio, _) = makeStartingVM()

        await vm.startNewQuiz() // question read
        #expect(audio.setupAudioSessionCallCount == 1)
        vm.quizTimersController.cancelThinkingTime()
        vm.quizTimersController.cancelAnswerTimer()

        // Listening for commands on the question screen.
        await vm.voiceCommandCoordinator.syncCommandListenerWindow()

        // Answer recording: the listener goes down, the session must not move.
        vm.quizState = .recording
        await vm.voiceCommandCoordinator.syncCommandListenerWindow()

        // Feedback read + the result-screen listening window.
        vm.quizState = .showingResult(
            question: Fixtures.makeQuestion(),
            evaluation: Evaluation(
                userAnswer: "4",
                result: .correct,
                points: 1.0,
                correctAnswer: "4",
                questionId: "q_001",
                explanation: nil
            )
        )
        _ = await vm.audioDeviceState.playFeedbackAudio(from: "https://example.com/f1.mp3")
        await vm.voiceCommandCoordinator.syncCommandListenerWindow()

        // ONE configuration for the whole quiz (#171): every re-configuration is
        // a gain/route change the founder hears, and re-activating under a live
        // engine is what silenced the first question.
        #expect(audio.setupAudioSessionCallCount == 1, "no phase may re-configure the quiz session")
        #expect(
            audio.setupQuietListeningSessionCallCount == 0,
            "the quiet Home session (#136) must never downgrade a running quiz"
        )
        #expect(audio.deactivateSessionCallCount == 0, "the session is released at quiz end, not between phases")
    }
}
