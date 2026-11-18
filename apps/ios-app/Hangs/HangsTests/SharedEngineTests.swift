//
//  SharedEngineTests.swift
//  HangsTests
//
//  Issue #77 (voice commands hands-free), task 77.7 / E-topology — the single
//  audio-engine convergence. The app must NEVER run two AVAudioEngines at once
//  (the #64 crash config). Since #184 the answer is captured off the shared
//  VAD/command-listener engine (SilenceDetectionService) itself, and since
//  #208.8 there is no streaming engine for answers at all — so a recording
//  must spin no second engine (`MockAudioService.audioEngineActive` stays
//  false) and no AVAudioRecorder either.
//

import Foundation
import Testing
import ConcurrencyExtras
@testable import Hangs

@Suite("Single audio engine — command-listen and answer-stream are never both live")
@MainActor
struct SharedEngineTests {

    @Test("batch recording spins NO second engine (AVAudioRecorder, not AVAudioEngine)")
    func batchPathSpinsNoSecondEngine() async {
        await withMainSerialExecutor {
            let audio = MockAudioService()
            let silence = MockSilenceDetectionService()
            let vm = QuizViewModel(
                networkService: Fixtures.makeFullMockNetwork(),
                audioService: audio,
                persistenceStore: MockPersistenceStore(),
                silenceDetectionService: silence
            )
            vm.currentQuestion = Fixtures.makeQuestion()
            vm.quizState = .askingQuestion

            await vm.audioDeviceState.startSilenceDetectionListening()
            await vm.recordingCoordinator.startRecording()

            // #184: batch captures off the LISTENER's engine — the streaming engine
            // is never created and there is no AVAudioRecorder either: one mic
            // client, full stop.
            #expect(audio.audioEngineActive == false)
            #expect(audio.isRecording == false)
            #expect(silence.isAnswerCaptureActive == true)
        }
    }
}
