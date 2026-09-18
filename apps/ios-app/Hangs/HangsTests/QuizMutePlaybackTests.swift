//
//  QuizMutePlaybackTests.swift
//  HangsTests
//
//  #179 (founder TF 2026-09-14, build 61), finding 7: the toolbar mute did not
//  stop what the app was saying. `toggleMute()` only stopped playback when
//  `isPlayingQuestionTTS()` was true — the initial question read — so a mute
//  tapped during the options read, a replay or the result feedback flipped the
//  icon and changed nothing audible. In a car that is the whole point of the
//  button: mute means silence NOW, whichever playback happens to be running.
//
//  Mute scope itself (per-quiz override vs. the persisted Settings preference)
//  is pinned by QuizMuteScopeTests and is deliberately untouched here.
//

import Foundation
@testable import Hangs
import Testing

@Suite("Mute silences whatever is playing (#179)")
@MainActor
struct QuizMutePlaybackTests {
    private func makeVM(
        silence: MockSilenceDetectionService = MockSilenceDetectionService()
    ) -> (QuizViewModel, MockAudioService) {
        let audio = MockAudioService()
        let network = Fixtures.makeFullMockNetwork()
        network.mockAudioData = Data("opus-bytes".utf8)
        let vm = QuizViewModel(
            networkService: network,
            audioService: audio,
            persistenceStore: MockPersistenceStore(),
            silenceDetectionService: silence,
            sttService: nil
        )
        return (vm, audio)
    }

    // #180 track A: the playback under test runs in its own Task and reaches
    // the audio mock with no production sleep in between, so every wait here is
    // `pumpUntil` — scheduler turns, not a wall-clock deadline that parallel
    // suites can starve (the old local spin timed out SILENTLY, which is how
    // `muteDuringReplayRestartsListening` failed under load).

    /// The bug in one line: the question read is NOT playing, something else is,
    /// and the old condition therefore let it carry on talking.
    @Test("muting stops playback that is not the question read")
    func muteStopsNonQuestionPlayback() async {
        let (vm, audio) = makeVM()
        #expect(vm.isPlayingQuestionTTS == false)

        await vm.toggleMute()

        #expect(vm.isAudioMuted)
        #expect(audio.stopPlaybackCallCount == 1, "mute must silence any playback, not only the question read")
    }

    /// The same thing against real in-flight playback: result feedback runs
    /// through `playFeedbackAudio`, which never sets `isPlayingQuestionTTS`.
    @Test("muting during result feedback playback silences it")
    func muteDuringFeedbackPlayback() async {
        let (vm, audio) = makeVM()
        let playback = Task { _ = await vm.audioDeviceState.playFeedbackAudio(from: "https://example.com/f.mp3") }
        await pumpUntil({ audio.playOpusCallCount > 0 }, "the feedback playback never started")
        #expect(vm.isPlayingQuestionTTS == false, "exactly the state the old condition missed")

        await vm.toggleMute()
        await playback.value

        #expect(audio.stopPlaybackCallCount >= 1)
    }

    /// A replay that has been started but has not reached its playback yet would
    /// otherwise begin speaking a moment AFTER the mute — the run is dropped too.
    @Test("muting drops an in-flight question replay")
    func muteCancelsQuestionReplay() async {
        let (vm, audio) = makeVM()
        vm.recordingCoordinator.currentQuestionAudioUrl = "https://example.com/q.mp3"
        let replay = Task { await vm.replayQuestionAudio() }
        await pumpUntil({ vm.taskBag.contains(.questionReplay) }, "the replay run was never registered")

        await vm.toggleMute()

        #expect(vm.taskBag.contains(.questionReplay) == false)
        #expect(audio.stopPlaybackCallCount >= 1)
        await replay.value
        #expect(vm.isPlayingQuestionTTS == false, "no leaked flag from the dropped run")
    }

    /// Mute is OUTPUT-only: `mayCaptureAudio` never reads it, and the muted branch
    /// of `playQuestionAudio` arms listening itself — a silent quiz is still a
    /// hands-free one. But the replay run tears the command listener down on its
    /// way in and its cancelled branch re-arms nothing (it assumes a newer playback
    /// owner took over), so the canceller has to own the restart or voice commands
    /// die for the rest of the question (PR #156 review).
    @Test("muting during a replay keeps voice-command listening alive")
    func muteDuringReplayRestartsListening() async {
        let silence = MockSilenceDetectionService()
        let (vm, audio) = makeVM(silence: silence)
        vm.recordingCoordinator.currentQuestionAudioUrl = "https://example.com/q.mp3"

        let replay = Task { await vm.replayQuestionAudio() }
        await pumpUntil({ audio.playOpusCallCount > 0 }, "the replay never reached playback")
        #expect(silence.isListening == false, "the replay run takes the listener down on its way in")

        await vm.toggleMute()

        #expect(audio.stopPlaybackCallCount >= 1, "the replay is silenced")
        #expect(vm.isPlayingQuestionTTS == false)
        #expect(silence.isListening, "…and mute restarts the capture the cancelled run no longer owns")
        await replay.value
    }

    /// The inverse must stay true: UNmuting is not a stop command. Stopping
    /// playback there would cut off the very read the user just asked to hear.
    @Test("unmuting never stops playback")
    func unmuteDoesNotStopPlayback() async {
        let (vm, audio) = makeVM()
        await vm.toggleMute() // into mute
        let stopsAfterMute = audio.stopPlaybackCallCount

        await vm.toggleMute() // back out

        #expect(vm.isAudioMuted == false)
        #expect(audio.stopPlaybackCallCount == stopsAfterMute)
    }
}
