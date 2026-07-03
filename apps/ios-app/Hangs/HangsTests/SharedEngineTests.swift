//
//  SharedEngineTests.swift
//  HangsTests
//
//  Issue #77 (voice commands hands-free), task 77.7 / E-topology — the single
//  audio-engine convergence. The app must NEVER run two AVAudioEngines at once
//  (the #64 crash config): the shared VAD/command-listener engine
//  (SilenceDetectionService) and the ElevenLabs streaming engine (AudioService)
//  are TIME-DISJOINT. The listener is torn down before the answer stream spins
//  up and re-armed after.
//
//  The real engines can't run headlessly, so the invariant is asserted at the
//  mock level: `MockSilenceDetectionService.isListening` (the shared listener
//  engine) and `MockAudioService.audioEngineActive` (the streaming engine) are
//  never both true across a full ask → record → confirm cycle.
//

import Foundation
import Testing
import ConcurrencyExtras
@testable import Hangs

@MainActor
private func makeStreamingVM()
    -> (QuizViewModel, MockSilenceDetectionService, MockAudioService, MockElevenLabsSTTService) {
    let audio = MockAudioService()
    let silence = MockSilenceDetectionService()
    let stt = MockElevenLabsSTTService()
    let vm = QuizViewModel(
        networkService: Fixtures.makeFullMockNetwork(),
        audioService: audio,
        persistenceStore: MockPersistenceStore(),
        silenceDetectionService: silence,
        sttService: stt
    )
    vm.currentSession = Fixtures.makeActiveSession()
    vm.currentQuestion = Fixtures.makeQuestion()
    vm.quizState = .askingQuestion
    return (vm, silence, audio, stt)
}

@MainActor
private func waitUntil(
    _ predicate: @MainActor () -> Bool,
    timeoutMillis: Int = 5_000,
    _ comment: Comment? = nil,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    let deadline = ContinuousClock.now.advanced(by: .milliseconds(timeoutMillis))
    while ContinuousClock.now < deadline {
        if predicate() { return }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(1))
    }
    if predicate() { return }
    Issue.record(comment ?? "waitUntil timed out after \(timeoutMillis)ms", sourceLocation: sourceLocation)
}

@Suite("Single audio engine — command-listen and answer-stream are never both live")
@MainActor
struct SharedEngineTests {

    /// The core invariant: at no observed instant is the shared listener engine
    /// and the streaming engine both live.
    private func assertNeverBothLive(
        _ silence: MockSilenceDetectionService,
        _ audio: MockAudioService,
        _ label: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(
            !(silence.isListening && audio.audioEngineActive),
            "two concurrent engines at \(label)",
            sourceLocation: sourceLocation
        )
    }

    @Test("streaming recording tears down the listener engine before spinning its own")
    func streamingTearsDownListenerFirst() async {
        await withMainSerialExecutor {
            let (vm, silence, audio, _) = makeStreamingVM()

            // Phase 1 — asking: listener engine live, streaming engine down.
            await vm.startSilenceDetectionListening()
            #expect(silence.isListening == true)
            #expect(audio.audioEngineActive == false)
            assertNeverBothLive(silence, audio, "asking")

            // Phase 2 — record: startRecording routes to the streaming path, which
            // must stop the listener BEFORE the streaming engine starts.
            await vm.startRecording()
            await waitUntil({ audio.audioEngineActive }, "streaming engine never started")
            #expect(silence.isListening == false, "listener must be torn down during the answer stream")
            #expect(audio.audioEngineActive == true)
            assertNeverBothLive(silence, audio, "recording")
        }
    }

    @Test("the invariant holds across a full ask → record → confirm cycle")
    func invariantAcrossFullCycle() async {
        await withMainSerialExecutor {
            let (vm, silence, audio, _) = makeStreamingVM()

            // ask (listening)
            await vm.startSilenceDetectionListening()
            assertNeverBothLive(silence, audio, "ask")

            // record (streaming)
            await vm.startRecording()
            await waitUntil({ audio.audioEngineActive }, "streaming engine never started")
            assertNeverBothLive(silence, audio, "record")

            // stop the answer stream + move to the confirmation sheet, then re-arm
            // the command listener for that window.
            audio.stopStreamingRecording()
            vm.isStreamingSTT = false
            vm.quizState = .processing
            await vm.syncCommandListenerWindow()
            #expect(audio.audioEngineActive == false)
            #expect(silence.isListening == true, "listener re-arms on the confirmation window")
            assertNeverBothLive(silence, audio, "confirm")
        }
    }

    @Test("batch recording spins NO second engine (AVAudioRecorder, not AVAudioEngine)")
    func batchPathSpinsNoSecondEngine() async {
        await withMainSerialExecutor {
            let audio = MockAudioService()
            let silence = MockSilenceDetectionService()
            // No STT service → startRecording uses the batch path.
            let vm = QuizViewModel(
                networkService: Fixtures.makeFullMockNetwork(),
                audioService: audio,
                persistenceStore: MockPersistenceStore(),
                silenceDetectionService: silence,
                sttService: nil
            )
            vm.currentQuestion = Fixtures.makeQuestion()
            vm.quizState = .askingQuestion

            await vm.startSilenceDetectionListening()
            await vm.startRecording()

            // Batch uses AVAudioRecorder — the streaming engine is never created,
            // so there is no two-engine condition even though VAD may still run.
            #expect(audio.audioEngineActive == false)
            #expect(audio.isRecording == true)
        }
    }
}
