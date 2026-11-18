//
//  MicDeniedAnswerTests.swift
//  HangsTests
//
//  #240 (production, App Store build 84): a player who declined the
//  microphone was never told. iOS hands an app without mic access silence,
//  so every answer went up empty, the server said "no speech", and the
//  player heard "didn't catch that" twice per question while speaking into
//  nothing. These pin the rule: with the mic denied nothing is recorded or
//  uploaded, the listen bar says the mic is off with a way into iOS
//  Settings, and the question stays answerable by tapping or typing.
//

import Clocks
import Foundation
@testable import Hangs
import Testing

@Suite("#240 microphone denied: no recording, a clear way out")
@MainActor
struct MicDeniedAnswerTests {
    private struct Rig {
        let vm: QuizViewModel
        let audio: MockAudioService
        let silence: MockSilenceDetectionService
        let network: MockNetworkService
        let analytics: MockAnalyticsClient
    }

    private func makeRig(clock: TestClock<Duration>, mic: MicrophonePermissionStatus = .denied) -> Rig {
        let audio = MockAudioService()
        audio.playbackDurationNs = 0
        audio.micPermissionStatus = mic
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
        vm.currentSession = Fixtures.makeActiveSession()
        vm.currentQuestion = Fixtures.makeQuestion(id: "q_001")
        vm.quizState = .askingQuestion
        vm.settings.thinkingTime = 10
        return Rig(vm: vm, audio: audio, silence: silence, network: network, analytics: analytics)
    }

    /// WHY: tapping the mic with the mic denied used to open a recording of
    /// pure silence and upload it. Nothing may be recorded or sent, the quiz
    /// stays on the question (tap or type still answer it), and the bar says
    /// why instead of "didn't catch that".
    @Test("a tap on the mic records and uploads nothing, and the bar says the mic is off")
    func tapRecordsNothing() async throws {
        let rig = makeRig(clock: TestClock())
        let question = try #require(rig.vm.currentQuestion)

        await rig.vm.toggleRecording()
        for _ in 0 ..< 20 {
            await Task.yield()
        }

        #expect(rig.vm.quizState == .askingQuestion, "the question must stay answerable by tapping or typing")
        #expect(!rig.silence.isAnswerCaptureActive, "a recording opened on a denied mic")
        #expect(rig.network.submitVoiceAnswerCallCount == 0, "silence was uploaded as an answer")
        let phase = try #require(rig.vm.listenPhase(for: question))
        #expect(rig.vm.commandsAccessory(for: phase) == .micOff, "the player must be told the mic is off, with Settings")
        let reasons = rig.analytics.events(named: "voice_capture_failed").compactMap { event -> String? in
            guard case let .voiceCaptureFailed(reason, _) = event else { return nil }
            return reason.rawValue
        }
        #expect(reasons == ["mic_denied"], "the refused capture must be visible in analytics")
    }

    /// WHY: the hands-free path is where the store players lost their
    /// answers: the think window ran out, the mic "opened" on silence, the
    /// empty answer was retried once and then the Again/Skip sheet came up.
    /// With the mic denied none of that may happen, however long they wait.
    @Test("the think window running out opens no recording, no retry and no empty-answer sheet")
    func autoRecordDoesNothing() async {
        let clock = TestClock()
        let rig = makeRig(clock: clock)

        rig.vm.startRecordingOrTimer()
        await pumpUntil({ rig.vm.thinkingTimeCountdown == 10 }, "the think window never started")
        await clock.advance(by: .seconds(10 + Int(Config.autoRecordingDuration) + 30))
        for _ in 0 ..< 30 {
            await Task.yield()
        }

        #expect(rig.vm.quizState == .askingQuestion)
        #expect(!rig.silence.isAnswerCaptureActive)
        #expect(rig.network.submitVoiceAnswerCallCount == 0)
        #expect(rig.vm.showAnswerConfirmation == false, "no \"Nothing heard\" sheet for a mic that never listened")
        #expect(rig.network.synthesizedTexts.isEmpty, "no spoken \"didn't catch that\"")
    }

    /// WHY: the mic-off note is the only thing telling the player, so it
    /// must not hang on the voice-command switches: a player who turned
    /// commands or their hints off still needs to know their answers can't
    /// be heard.
    @Test("the mic-off note shows whatever the command switches say")
    func noteIgnoresCommandSwitches() {
        for enabled in [true, false] {
            for hints in [true, false] {
                let accessory = VoiceCommandCoordinator.commandsBarAccessory(
                    availability: .permissionNeeded, voiceCommandsEnabled: enabled,
                    showsHints: hints, micDenied: true, phaseHasCommands: true
                )
                #expect(accessory == .micOff, "enabled=\(enabled) hints=\(hints)")
            }
        }
    }

    /// WHY: the guard must only bite on a refusal. A granted mic records as
    /// before, so the fix cannot cost a working player their voice answer.
    @Test("a granted mic still records")
    func grantedStillRecords() async {
        let rig = makeRig(clock: TestClock(), mic: .granted)

        await rig.vm.toggleRecording()

        await pumpUntil({ rig.vm.quizState == .recording && rig.silence.isAnswerCaptureActive }, "the granted mic never opened")
        rig.vm.quizTimersController.cancelAutoStopRecordingTimer()
    }
}
