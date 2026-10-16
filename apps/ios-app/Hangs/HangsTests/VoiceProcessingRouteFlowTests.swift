//
//  VoiceProcessingRouteFlowTests.swift
//  HangsTests
//
//  #185 track C — the quiz-flow half of the route-aware voice processing
//  (the pure policy is in VoiceProcessingRouteTests.swift). Car test
//  2026-09-23: the implicit `.voiceChat` of voice processing moved every sound
//  of the quiz from the car's Bluetooth to the iPhone speaker. Why these
//  tests matter:
//  - A listener whose voice processing hides the car must be re-armed when a
//    device arrives, but never mid-answer (the engine IS the recorder) and at
//    most once per listening window.
//  - The session must be restored with the old engine already gone and
//    BEFORE the next sound plays, or the whole quiz stays on the iPhone.
//  - The founder reads the route and flips the car-audio switch in Settings;
//    losing either row makes the next car test blind.
//

@preconcurrency import AVFoundation
import Clocks
import Foundation
@testable import Hangs
import SwiftUI
import Testing
import ViewInspector

// MARK: - The owner on a route change / teardown

@MainActor
private func makeRouteVM() -> (QuizViewModel, MockSilenceDetectionService, MockAudioService) {
    let audio = MockAudioService()
    audio.playbackDurationNs = 0
    let silence = MockSilenceDetectionService()
    let vm = QuizViewModel(
        networkService: Fixtures.makeFullMockNetwork(),
        audioService: audio,
        persistenceStore: MockPersistenceStore(),
        silenceDetectionService: silence,
        clock: AnyClock(TestClock())
    )
    vm.currentSession = Fixtures.makeActiveSession()
    vm.currentQuestion = Fixtures.makeQuestion()
    vm.quizState = .askingQuestion
    return (vm, silence, audio)
}

private let speakerArmed = VoiceProcessingStatus(mode: .on, armed: true, outputPort: "Speaker")
private let carOff = VoiceProcessingStatus(mode: .offOutput, armed: false, outputPort: "BluetoothA2DPOutput")

private func change(_ reason: AVAudioSession.RouteChangeReason, _ mode: VoiceProcessingMode) -> AudioRouteChange {
    AudioRouteChange(reason: reason, outputPort: "Speaker", previousOutputPort: "Speaker", voiceProcessingMode: mode)
}

@Suite("Route change and teardown in the quiz (#185 C)")
@MainActor
struct VoiceProcessingRouteFlowTests {
    @Test("the car connecting under a voice-processing listener re-arms it without voice processing")
    func carConnectsUnderVoiceProcessing() async {
        let (vm, silence, audio) = makeRouteVM()
        silence.voiceProcessingOnStart = speakerArmed
        await vm.voiceCommandCoordinator.syncCommandListenerWindow()
        #expect(silence.voiceProcessingStatus == speakerArmed)

        // The restart must restore the session with the old engine already
        // gone, before the new one asks the policy again.
        var listeningAtRestores: [Bool] = []
        audio.onRestoreSession = { listeningAtRestores.append(silence.isListening) }
        silence.voiceProcessingOnStart = carOff

        await vm.audioDeviceState.handleAudioRouteChange(change(.newDeviceAvailable, .on))

        #expect(silence.stopListeningCallCount == 1)
        #expect(silence.startListeningCallCount == 2)
        #expect(!listeningAtRestores.isEmpty)
        #expect(!listeningAtRestores.contains(true), "restore under a live voice-processing unit would fight it")
        #expect(silence.voiceProcessingStatus == carOff)
        #expect(vm.voiceCommandCoordinator.commandCapturePhase == .listening, "voice commands must survive the re-arm")
    }

    @Test("a listener already off voice processing in the car is left alone")
    func carListenerLeftAlone() async {
        let (vm, silence, _) = makeRouteVM()
        silence.voiceProcessingOnStart = carOff
        await vm.voiceCommandCoordinator.syncCommandListenerWindow()

        await vm.audioDeviceState.handleAudioRouteChange(change(.newDeviceAvailable, .offOutput))

        #expect(silence.stopListeningCallCount == 0)
        #expect(silence.startListeningCallCount == 1)
    }

    @Test("never restarted during an answer — the engine is the recorder")
    func noRestartWhileRecording() async {
        let (vm, silence, _) = makeRouteVM()
        silence.voiceProcessingOnStart = speakerArmed
        await vm.voiceCommandCoordinator.syncCommandListenerWindow()
        vm.quizState = .recording

        await vm.audioDeviceState.handleAudioRouteChange(change(.newDeviceAvailable, .offOutput))

        #expect(silence.stopListeningCallCount == 0, "a restart here would cut the answer off mid-sentence")
        #expect(silence.isListening)
    }

    @Test("at most one restart per listening window, so a restart cannot loop")
    func oneRestartPerWindow() async {
        let (vm, silence, _) = makeRouteVM()
        silence.voiceProcessingOnStart = speakerArmed
        await vm.voiceCommandCoordinator.syncCommandListenerWindow()

        await vm.audioDeviceState.handleAudioRouteChange(change(.newDeviceAvailable, .on))
        await vm.audioDeviceState.handleAudioRouteChange(change(.newDeviceAvailable, .on))

        #expect(silence.stopListeningCallCount == 1)
        #expect(silence.startListeningCallCount == 2)
    }

    @Test("a route change posted by the service reaches the listener through the view model")
    func wiredThroughViewModel() async {
        let (vm, silence, audio) = makeRouteVM()
        silence.voiceProcessingOnStart = speakerArmed
        await vm.voiceCommandCoordinator.syncCommandListenerWindow()

        audio.onRouteChange?(change(.newDeviceAvailable, .offOutput))
        await pumpUntil({ silence.startListeningCallCount == 2 }, "the owner must re-arm the listener")
    }

    @Test("a fresh listener start restores the session before the policy decides, never under a live one")
    func restoreBeforeFreshStartOnly() async {
        // An engine torn down outside the stop choke point (realtime answer,
        // feedback dictation) can leave `.voiceChat` behind; deciding on that
        // route would read "speaker" and arm voice processing in the car.
        let (vm, silence, audio) = makeRouteVM()
        var startsAtRestore: [Int] = []
        audio.onRestoreSession = { startsAtRestore.append(silence.startListeningCallCount) }

        await vm.voiceCommandCoordinator.syncCommandListenerWindow()
        #expect(startsAtRestore == [0], "restore first, then the engine")

        // Idempotent re-arm with the engine up: re-configuring the session now
        // would pull the rug from under its voice-processing unit.
        await vm.voiceCommandCoordinator.syncCommandListenerWindow()
        #expect(startsAtRestore == [0])
    }

    @Test("the question read restores the session after the listener is down and before it plays")
    func restoreBeforeQuestionPlays() async {
        let (vm, silence, audio) = makeRouteVM()
        silence.voiceProcessingOnStart = speakerArmed
        await vm.voiceCommandCoordinator.syncCommandListenerWindow()
        let restoresBefore = audio.restoreSessionCallCount

        var restoredBeforePlayback = false
        var listeningDuringPlayback: Bool?
        audio.onPlaybackStarted = {
            restoredBeforePlayback = audio.restoreSessionCallCount > restoresBefore
            listeningDuringPlayback = silence.isListening
        }

        await vm.audioDeviceState.playQuestionAudio(from: "https://example.invalid/q.opus")

        #expect(audio.playOpusCallCount == 1)
        #expect(listeningDuringPlayback == false)
        #expect(restoredBeforePlayback, "a .voiceChat left behind would play the question from the iPhone")
    }
}

// MARK: - #208.5 Home listens without voice processing

/// WHY (TF 2026-10-16): arming voice processing for the Home command listener
/// switched iOS to `.voiceChat` right at launch, and with it to the call
/// volume, so the volume the player raised snapped back. Home must listen on
/// the raw mic (commands still recognised); the quiz keeps voice processing.
@Suite("Home command listener without voice processing (#208.5)")
@MainActor
struct HomeListenerVoiceProcessingTests {
    private func makeHomeVM() -> (QuizViewModel, MockSilenceDetectionService, MockAudioService) {
        let (vm, silence, audio) = makeRouteVM()
        vm.currentSession = nil
        vm.currentQuestion = nil
        vm.quizState = .idle
        silence.voiceProcessingOnStart = speakerArmed
        return (vm, silence, audio)
    }

    @Test("Home's listener comes up on the quiet session without voice processing, commands still live")
    func homeListenerSkipsVoiceProcessing() async {
        let (vm, silence, audio) = makeHomeVM()

        await vm.voiceCommandCoordinator.syncCommandListenerWindow()

        #expect(audio.setupQuietListeningSessionCallCount == 1)
        #expect(silence.voiceProcessingStatus?.mode == .offQuietSession)
        #expect(silence.voiceProcessingStatus?.armed == false, "armed here = call volume at launch")
        #expect(vm.voiceCommandCoordinator.commandCapturePhase == .listening, "\"start\" must still be heard on Home")
    }

    @Test("an in-quiz listener still up when Home arms is restarted without voice processing")
    func quizEngineLeftOnHomeIsRestarted() async {
        let (vm, silence, _) = makeRouteVM()
        silence.voiceProcessingOnStart = speakerArmed
        await vm.voiceCommandCoordinator.syncCommandListenerWindow()
        #expect(silence.voiceProcessingStatus == speakerArmed)

        vm.quizState = .idle
        await vm.voiceCommandCoordinator.syncCommandListenerWindow()

        #expect(silence.stopListeningCallCount == 1)
        #expect(silence.startListeningCallCount == 2)
        #expect(silence.voiceProcessingStatus?.armed == false)
    }

    @Test("a re-sync on Home leaves its listener up: no extra mode flap")
    func homeListenerNotFlapped() async {
        let (vm, silence, _) = makeHomeVM()
        await vm.voiceCommandCoordinator.syncCommandListenerWindow()
        await vm.voiceCommandCoordinator.syncCommandListenerWindow()

        #expect(silence.stopListeningCallCount == 0, "every teardown re-routes other apps' audio")
        #expect(silence.voiceProcessingStatus?.armed == false)
    }

    @Test("a device arriving on Home does not restart the listener for voice processing")
    func routeChangeOnHomeLeavesListener() async {
        let (vm, silence, _) = makeHomeVM()
        await vm.voiceCommandCoordinator.syncCommandListenerWindow()

        await vm.audioDeviceState.handleAudioRouteChange(change(.newDeviceAvailable, .on))

        #expect(silence.stopListeningCallCount == 0)
    }

    @Test("starting a quiz gives the quiz session its voice processing back")
    func quizStartReenablesVoiceProcessing() async {
        let (vm, silence, _) = makeHomeVM()
        await vm.voiceCommandCoordinator.syncCommandListenerWindow()
        #expect(!silence.voiceProcessingAllowed)

        await vm.startNewQuiz()

        #expect(silence.voiceProcessingAllowed, "the quiz answers need echo cancellation and noise suppression")
    }
}

// MARK: - Settings › voice diagnostics

@MainActor
@Suite("Settings voice diagnostics — route line and car-audio switch (#185 C)")
struct VoiceDiagnosticsRouteSettingsTests {
    @Test("the car-audio switch and the live route line render in voice diagnostics")
    func routeControlsRender() async throws {
        // The founder compares voice processing on/off in the car without a new
        // build and reads the route off this screen; losing either row makes
        // the next car test blind.
        let appState = AppState(
            networkService: MockNetworkService(),
            audioService: MockAudioService(),
            persistenceStore: MockPersistenceStore()
        )
        let view = SettingsView(viewModel: .preview)
            .environmentObject(appState)
            .environmentObject(NavigationModel())
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) {
                try tree.find(viewWithAccessibilityIdentifier: "settings.voiceProcessingExternalOutputToggle")
            }
            let route = try tree.find(viewWithAccessibilityIdentifier: "settings.audioRoute")
            let line = try route.find(ViewType.Text.self, where: { try $0.string().contains(" · VP ") }).string()
            #expect(line.hasSuffix(VoiceProcessingPolicy.currentMode().rawValue), "the line must show the mode a mic engine would get now")
        }
    }
}
