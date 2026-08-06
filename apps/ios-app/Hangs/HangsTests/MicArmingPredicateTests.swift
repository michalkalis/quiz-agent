//
//  MicArmingPredicateTests.swift
//  HangsTests
//
//  #149 — mic arming had two paths and only one honoured the command window.
//  Why these tests matter:
//  - The Settings "Voice commands" toggle is a CAPTURE switch, not a routing
//    filter. Flipping it off tore the listener down exactly once; the next
//    question's TTS tail re-armed the input tap and the mic stayed live for the
//    rest of the session. For a hands-free driving app that is a trust problem,
//    not a leak — the user turned the microphone off and it came back.
//  - Barge-in must survive the fix: it is armed by the same choke point but is
//    NOT scoped to a command screen, so gating the engine on
//    `currentCommandScreen` would have silently killed it (F5).
//  - A question-TTS tail that resumes after `endQuizWithResults()` used to
//    start the audio engine on a session that had just been deactivated (F4).
//    The capture predicate now refuses torn-down quiz states, so the fix is
//    structural rather than one `Task.isCancelled` guard per tail.
//

import Foundation
@testable import Hangs
import Testing

@MainActor
private func makeMicVM() -> (QuizViewModel, MockSilenceDetectionService, MockAudioService) {
    let audio = MockAudioService()
    let silence = MockSilenceDetectionService()
    let vm = QuizViewModel(
        networkService: Fixtures.makeFullMockNetwork(),
        audioService: audio,
        persistenceStore: MockPersistenceStore(),
        silenceDetectionService: silence,
        sttService: nil
    )
    vm.currentSession = Fixtures.makeActiveSession()
    vm.currentQuestion = Fixtures.makeQuestion()
    vm.quizState = .askingQuestion
    return (vm, silence, audio)
}

@Suite("Mic arming — single capture predicate (#149)")
@MainActor
struct MicArmingPredicateTests {

    // MARK: F3 — the master switch stays off

    // WHY: this is the reported defect. `playQuestionAudio`'s tail is the path
    // that used to re-arm: it calls the choke point unconditionally after the
    // read, and the choke point only checked foreground + not-playing-TTS.
    @Test("voice commands off: the question TTS cycle leaves the mic down and the consumer unarmed")
    func audioPathDoesNotRearmWithCommandsOff() async {
        let (vm, silence, _) = makeMicVM()
        vm.settings.voiceCommandsEnabled = false

        await vm.audioDeviceState.playQuestionAudio(from: "https://example.invalid/q.opus")

        #expect(silence.startListeningCallCount == 0, "the TTS tail must not put the input tap back up")
        #expect(!silence.isListening)
        #expect(vm.voiceCommandCoordinator.commandCapturePhase == .idle, "the command consumer must stay unarmed")
    }

    // WHY: the mute path skips TTS entirely and arms the listener straight
    // away, so it is a second, independent way back to a live mic.
    @Test("voice commands off: the muted question path never arms the mic either")
    func mutePathDoesNotArmWithCommandsOff() async {
        let (vm, silence, _) = makeMicVM()
        vm.settings.voiceCommandsEnabled = false
        vm.settings.isMuted = true

        await vm.audioDeviceState.playQuestionAudio(from: "https://example.invalid/q.opus")

        #expect(silence.startListeningCallCount == 0)
        #expect(!silence.isListening)
        #expect(vm.voiceCommandCoordinator.commandCapturePhase == .idle)
    }

    // WHY: the feedback tail is the third re-arm path (it re-armed inside
    // `withCommandWindowClosed`, guarded only by its own question-TTS check).
    @Test("voice commands off: the feedback playback tail does not arm the mic")
    func feedbackTailDoesNotArmWithCommandsOff() async {
        let (vm, silence, _) = makeMicVM()
        vm.settings.voiceCommandsEnabled = false

        _ = await vm.audioDeviceState.playFeedbackAudio(from: "https://example.invalid/f.opus")

        #expect(silence.startListeningCallCount == 0)
        #expect(!silence.isListening)
    }

    // MARK: F5 — barge-in still works

    // WHY: barge-in rides the same choke point but is not scoped to a command
    // screen. The fix gates the ENGINE on the capture predicate and only the
    // CONSUMER on the window, so a normal question cycle must still arm
    // barge-in — and a barge-in event must still reach the view model.
    @Test("barge-in still arms on the question tail and fires")
    func bargeInStillArmsAndFires() async {
        let (vm, silence, audio) = makeMicVM()

        await vm.audioDeviceState.playQuestionAudio(from: "https://example.invalid/q.opus")
        #expect(silence.isListening, "the question tail must still arm capture when commands are on")

        let stopsBefore = audio.stopPlaybackCallCount
        silence.simulateBargeIn()

        var fired = false
        for _ in 0..<200 {
            if audio.stopPlaybackCallCount > stopsBefore { fired = true; break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(fired, "a barge-in event must still stop playback — gating the engine on the command screen would have killed this")
    }

    // MARK: F4 — no engine after the quiz is torn down

    // WHY: `endQuizWithResults()` cancels tasks, stops the listener and
    // DEACTIVATES the audio session. A question-TTS tail suspended across that
    // teardown then resumed and started the engine on the dead session.
    @Test("a playback tail resuming after the quiz ended does not start the engine")
    func tailAfterEndQuizDoesNotStartEngine() async {
        let (vm, silence, audio) = makeMicVM()

        await vm.endQuizWithResults()
        #expect(vm.quizState == .finished)
        #expect(audio.deactivateSessionCallCount == 1, "the session teardown under test must actually have happened")
        let startsBefore = silence.startListeningCallCount

        // Exactly what the suspended tail does when it resumes.
        await vm.audioDeviceState.startSilenceDetectionListening()

        #expect(silence.startListeningCallCount == startsBefore, "no engine may start on a deactivated session")
        #expect(!silence.isListening)
    }

    // MARK: The predicate itself

    // WHY: one predicate, one enforcement point. These pin the two halves so a
    // later change to the screen map cannot quietly take the microphone with
    // it, and vice versa.
    @Test("capture and the command window are separate predicates over the same state")
    func capturePredicateAndWindowAgree() {
        let (vm, _, _) = makeMicVM()
        let coordinator = vm.voiceCommandCoordinator

        #expect(coordinator.mayCaptureAudio)
        #expect(coordinator.currentCommandScreen == .question)

        // The master switch closes BOTH — it is a capture switch (F3).
        vm.settings.voiceCommandsEnabled = false
        #expect(!coordinator.mayCaptureAudio)
        #expect(coordinator.currentCommandScreen == nil)
        vm.settings.voiceCommandsEnabled = true

        // A torn-down quiz closes capture regardless of the screen map (F4).
        vm.quizState = .finished
        #expect(!coordinator.mayCaptureAudio)
        #expect(coordinator.currentCommandScreen == nil)
    }
}
