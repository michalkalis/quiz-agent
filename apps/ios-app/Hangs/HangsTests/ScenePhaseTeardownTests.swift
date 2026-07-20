//
//  ScenePhaseTeardownTests.swift
//  HangsTests
//
//  Mic-in-background fix: UIBackgroundModes audio (kept on purpose — TTS must
//  keep playing while driving) also kept the live mic INPUT running after the
//  app was backgrounded, because nothing observed the scene phase. These tests
//  pin the teardown routing in QuizViewModel.handleScenePhase(_:):
//    • .background stops the command/VAD listener on every screen;
//    • an in-flight recording aborts via the EXISTING #67 interruption path
//      (single state-reset — same contract as QuizViewModelInterruptionTests);
//    • the audio session is released ONLY when the quiz is idle and no TTS is
//      playing — in-flight background TTS must never be killed;
//    • .active re-arms via the existing syncCommandListenerWindow();
//    • isAppForeground == false closes the command window so a racing
//      refreshCommandWindow() / post-TTS re-arm cannot re-open the mic.
//

import ConcurrencyExtras
import Foundation
@testable import Hangs
import SwiftUI
import Testing

@MainActor
private func makeScenePhaseVM(
    silence: MockSilenceDetectionService = MockSilenceDetectionService()
) -> (QuizViewModel, MockSilenceDetectionService, MockAudioService) {
    let audio = MockAudioService()
    let vm = QuizViewModel(
        networkService: Fixtures.makeFullMockNetwork(),
        audioService: audio,
        persistenceStore: MockPersistenceStore(),
        silenceDetectionService: silence,
        sttService: nil
    )
    vm.currentSession = Fixtures.makeActiveSession()
    vm.currentQuestion = Fixtures.makeQuestion()
    return (vm, silence, audio)
}

/// Spin the main serial executor until `predicate` holds or the deadline passes.
@MainActor
private func waitUntil(
    _ predicate: @MainActor () -> Bool,
    timeoutMillis: Int = 5000,
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

@Suite("Scene-phase mic teardown — background kills input, never playback")
@MainActor
struct ScenePhaseTeardownTests {
    // MARK: - .background on non-recording screens

    @Test("background on idle Home stops the listener AND releases the audio session")
    func backgroundOnIdleStopsListenerAndDeactivates() async {
        let (vm, silence, audio) = makeScenePhaseVM()
        let mock = silence

        vm.quizState = .idle
        await vm.startSilenceDetectionListening() // Home window armed
        #expect(mock.isListening == true)

        vm.handleScenePhase(.background)

        #expect(mock.isListening == false, "input tap must not survive backgrounding")
        #expect(audio.deactivateSessionCallCount == 1, "idle + no TTS → session released")
    }

    @Test("background mid-question stops the listener but keeps the session (quiz not idle)")
    func backgroundMidQuestionKeepsSession() async {
        let (vm, silence, audio) = makeScenePhaseVM()
        let mock = silence

        vm.quizState = .askingQuestion
        await vm.startSilenceDetectionListening()
        #expect(mock.isListening == true)

        vm.handleScenePhase(.background)

        #expect(mock.isListening == false)
        #expect(vm.quizState == .askingQuestion, "non-recording state is untouched")
        #expect(audio.deactivateSessionCallCount == 0, "mid-quiz session stays for background TTS")
    }

    @Test("background never kills in-flight TTS: session stays active while audio plays")
    func backgroundNeverKillsInFlightTTS() {
        let (vm, _, audio) = makeScenePhaseVM()

        vm.quizState = .idle
        audio.isPlaying = true // TTS still playing (driving use case)

        vm.handleScenePhase(.background)

        #expect(audio.deactivateSessionCallCount == 0, "deactivating would cut background TTS")
    }

    // MARK: - .background during recording → #67 interruption path

    @Test("background during STREAMING recording aborts via the #67 interruption path")
    func backgroundDuringStreamingRecordingAborts() async throws {
        let (vm, _, audio) = makeScenePhaseVM()

        vm.quizState = .recording
        vm.isStreamingSTT = true
        try await audio.startStreamingRecording { _ in }
        #expect(audio.isRecording == true)

        vm.handleScenePhase(.background)

        // Same end-state as QuizViewModelInterruptionTests (one reset path).
        #expect(vm.quizState == .askingQuestion)
        #expect(vm.isStreamingSTT == false)
        #expect(audio.isRecording == false)
        #expect(audio.audioEngineActive == false)
        #expect(vm.errorMessage != nil, "the #67 'recording interrupted' message is reused")
        #expect(audio.deactivateSessionCallCount == 0, "mid-quiz session stays alive")
    }

    @Test("background during BATCH recording stops the recorder and exits .recording")
    func backgroundDuringBatchRecordingStopsRecorder() async throws {
        let (vm, _, audio) = makeScenePhaseVM()

        vm.quizState = .recording
        try audio.startRecording()
        #expect(audio.isRecording == true)

        vm.handleScenePhase(.background)

        #expect(vm.quizState == .askingQuestion)
        // The batch stop is async (stopRecording() is async throws).
        await waitUntil({ audio.isRecording == false }, "batch recorder never stopped")
    }

    // MARK: - .active re-arms

    @Test(".active re-arms the listener via the existing window sync")
    func activeReArmsListener() async {
        await withMainSerialExecutor {
            let (vm, silence, _) = makeScenePhaseVM()
            let mock = silence

            vm.quizState = .askingQuestion
            await vm.startSilenceDetectionListening()
            vm.handleScenePhase(.background)
            #expect(mock.isListening == false)

            vm.handleScenePhase(.active)
            await waitUntil({ mock.isListening }, "listener never re-armed on .active")
        }
    }

    // MARK: - isAppForeground closes the window (re-arm race guard)

    @Test("backgrounded: the command window is nil and no arming path can re-open the mic")
    func backgroundBlocksReArm() async {
        let (vm, silence, _) = makeScenePhaseVM()
        let mock = silence

        vm.quizState = .askingQuestion
        vm.handleScenePhase(.background)
        #expect(vm.voiceCommandCoordinator.currentCommandScreen == nil, "window must be closed while backgrounded")

        // A racing window refresh must not re-arm…
        await vm.voiceCommandCoordinator.syncCommandListenerWindow()
        #expect(mock.isListening == false)

        // …and neither may a direct re-arm (e.g. the post-TTS tail).
        await vm.startSilenceDetectionListening()
        #expect(mock.isListening == false, "direct arm bypassed the foreground guard")

        // Foregrounding restores the window.
        vm.handleScenePhase(.active)
        #expect(vm.voiceCommandCoordinator.currentCommandScreen == .question)
    }

    @Test("backgrounded: startRecording is suppressed (auto-record can fire after background TTS)")
    func backgroundSuppressesRecordingStart() async {
        let (vm, _, audio) = makeScenePhaseVM()

        vm.quizState = .askingQuestion
        vm.handleScenePhase(.background)

        await vm.startRecording()

        #expect(vm.quizState == .askingQuestion, "must not enter .recording while backgrounded")
        #expect(audio.isRecording == false, "mic must not open in the background")
    }
}
