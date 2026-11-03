//
//  QuietListeningWindowTests.swift
//  HangsTests
//
//  #136 founder decision B: opening the app must not pause external audio.
//  The eager launch-time setupAudioSession was removed from AppState; instead,
//  arming the command window on HOME applies the quiet mixable session
//  (setupQuietListeningSession), and the full ducking session is applied only
//  by the startNewQuiz path. These pin that call routing headlessly via
//  MockAudioService's per-path call counts.
//

import Foundation
@testable import Hangs
import Testing

@MainActor
private func makeQuietWindowVM() -> (QuizViewModel, MockSilenceDetectionService, MockAudioService) {
    let audio = MockAudioService()
    let silence = MockSilenceDetectionService()
    let vm = QuizViewModel(
        networkService: Fixtures.makeFullMockNetwork(),
        audioService: audio,
        persistenceStore: MockPersistenceStore(),
        silenceDetectionService: silence
    )
    return (vm, silence, audio)
}

@Suite("Quiet listening window (#136) — Home arms mixable, quiz keeps ducking")
@MainActor
struct QuietListeningWindowTests {
    @Test("constructing the view model configures no audio session at all")
    func noSessionConfigurationAtLaunch() {
        let (_, _, audio) = makeQuietWindowVM()

        // The launch-time interruption of external audio WAS an eager session
        // setup during app init — nothing may configure a session before either
        // the Home window arms (quiet) or a quiz starts (full).
        #expect(audio.setupAudioSessionCallCount == 0)
        #expect(audio.setupQuietListeningSessionCallCount == 0)
    }

    /// WHY (#224): Home has buttons only — it must not open the mic or touch the
    /// audio session, so other apps' audio is never interrupted by opening Trubbo.
    @Test("Home opens no window: no listener, no session")
    func homeOpensNoWindow() async {
        let (vm, silence, audio) = makeQuietWindowVM()
        vm.quizState = .idle

        await vm.voiceCommandCoordinator.syncCommandListenerWindow()

        #expect(audio.setupQuietListeningSessionCallCount == 0)
        #expect(audio.setupAudioSessionCallCount == 0)
        #expect(!silence.isListening)
    }

    @Test("arming the set-end window applies the quiet session, never the quiz session")
    func setEndWindowArmsQuietSession() async {
        let (vm, silence, audio) = makeQuietWindowVM()
        vm.quizState = .finished
        vm.quizEndCommandsArmed = true

        await vm.voiceCommandCoordinator.syncCommandListenerWindow()

        #expect(audio.setupQuietListeningSessionCallCount == 1, "set-end listening must run under the mixable session")
        #expect(audio.setupAudioSessionCallCount == 0, "the ducking quiz session on Home is the #136 bug")
        #expect(silence.isListening, "quiet session must not cost the set end its voice commands (decision B, not fallback A)")
    }

    @Test("arming an in-quiz window leaves the session untouched")
    func inQuizWindowDoesNotReconfigureSession() async {
        let (vm, silence, audio) = makeQuietWindowVM()
        vm.currentSession = Fixtures.makeActiveSession()
        vm.currentQuestion = Fixtures.makeQuestion()
        vm.quizState = .askingQuestion

        await vm.voiceCommandCoordinator.syncCommandListenerWindow()

        #expect(audio.setupQuietListeningSessionCallCount == 0, "mid-quiz re-arms must not downgrade the ducking session startNewQuiz configured")
        #expect(silence.isListening)
    }

    @Test("voice commands disabled → no window, no session configuration")
    func disabledCommandsConfigureNothing() async {
        let (vm, silence, audio) = makeQuietWindowVM()
        vm.quizState = .idle
        vm.settings.voiceCommandsEnabled = false

        await vm.voiceCommandCoordinator.syncCommandListenerWindow()

        #expect(audio.setupQuietListeningSessionCallCount == 0, "with the listener off, launch/Home must not touch the audio session at all")
        #expect(!silence.isListening)
    }
}
