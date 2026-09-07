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
//      refreshCommandWindow() / post-TTS re-arm cannot re-open the mic;
//    • #171 Track H: .active also finishes what the background suppressed —
//      the countdowns keep running there, so a think window that expired out
//      of sight must open the mic on return, and an answer window that fully
//      elapsed must land on the no-answer confirmation sheet.
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
        await vm.audioDeviceState.startSilenceDetectionListening() // Home window armed
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
        await vm.audioDeviceState.startSilenceDetectionListening()
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
            await vm.audioDeviceState.startSilenceDetectionListening()
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
        await vm.audioDeviceState.startSilenceDetectionListening()
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

        await vm.recordingCoordinator.startRecording()

        #expect(vm.quizState == .askingQuestion, "must not enter .recording while backgrounded")
        #expect(audio.isRecording == false, "mic must not open in the background")
    }

    // MARK: - #171 Track H: foregrounding finishes what the background suppressed

    /// WHY: the countdowns keep running in the background (founder decision), but
    /// the mic cannot open there — so the think window expired, `startRecording`
    /// bailed, and NOTHING re-triggered it. The driver came back to a question
    /// with every countdown at zero and no way to answer but a manual tap. On
    /// return we must do what should have happened: open the mic.
    @Test(".active opens the answer window the background suppressed")
    func activeResumesSuppressedRecording() async {
        await withMainSerialExecutor {
            let (vm, _, audio) = makeScenePhaseVM()

            vm.quizState = .askingQuestion
            vm.handleScenePhase(.background)
            await vm.recordingCoordinator.startRecording() // suppressed, marker armed
            #expect(vm.quizState == .askingQuestion)

            vm.handleScenePhase(.active)

            await waitUntil({ vm.quizState == .recording }, "the suppressed answer window never opened on return")
            #expect(audio.isRecording == true, "the mic must open on return, not wait for a tap")
        }
    }

    /// WHY: if the user stayed away longer than the whole recording window would
    /// have lasted, re-opening the mic would be answering a question whose time
    /// ran out minutes ago. That case takes the #171 Track B exit instead — the
    /// confirmation sheet with an empty field — so the quiz always moves on.
    @Test(".active hands over to the no-answer sheet when the whole window elapsed")
    func activeOpensNoAnswerSheetWhenWindowElapsed() async {
        let (vm, _, audio) = makeScenePhaseVM()

        vm.quizState = .askingQuestion
        vm.handleScenePhase(.background)
        await vm.recordingCoordinator.startRecording()
        // Backdate the suppression past the full recording window.
        vm.recordingCoordinator.backgroundSuppressedRecordingAt =
            Date().addingTimeInterval(-(Config.autoRecordingDuration + 1))

        vm.handleScenePhase(.active)

        #expect(vm.showAnswerConfirmation == true)
        #expect(vm.transcribedAnswer.isEmpty)
        #expect(vm.noAnswerCaptured == true)
        #expect(audio.isRecording == false, "a window that already expired must not re-open the mic")
    }

    /// WHY: the marker is one-shot. A second foreground event (app switcher,
    /// notification banner) must not re-open a window that was already resolved,
    /// or a driver flicking between apps would restart recording each time.
    @Test(".active resumes the suppressed window exactly once")
    func activeResumesOnlyOnce() async {
        await withMainSerialExecutor {
            let (vm, _, _) = makeScenePhaseVM()

            vm.quizState = .askingQuestion
            vm.handleScenePhase(.background)
            await vm.recordingCoordinator.startRecording()

            vm.handleScenePhase(.active)
            await waitUntil({ vm.quizState == .recording }, "first resume never opened the window")
            #expect(vm.recordingCoordinator.backgroundSuppressedRecordingAt == nil, "marker must be consumed")

            // Second foreground with no fresh suppression: nothing to redo.
            vm.handleScenePhase(.active)
            #expect(vm.quizState == .recording)
            #expect(vm.showAnswerConfirmation == false)
        }
    }
}
