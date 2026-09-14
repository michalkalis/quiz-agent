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
    private func makeVM() -> (QuizViewModel, MockAudioService) {
        let audio = MockAudioService()
        let network = Fixtures.makeFullMockNetwork()
        network.mockAudioData = Data("opus-bytes".utf8)
        let vm = QuizViewModel(
            networkService: network,
            audioService: audio,
            persistenceStore: MockPersistenceStore()
        )
        return (vm, audio)
    }

    /// Spin until `predicate` holds — the playback under test runs in its own Task.
    private func waitUntil(_ predicate: @MainActor () -> Bool, timeoutMillis: Int = 5000) async {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(timeoutMillis))
        while ContinuousClock.now < deadline {
            if predicate() { return }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

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
        await waitUntil { audio.playOpusCallCount > 0 }
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
        await waitUntil { vm.taskBag.contains(.questionReplay) }

        await vm.toggleMute()

        #expect(vm.taskBag.contains(.questionReplay) == false)
        #expect(audio.stopPlaybackCallCount >= 1)
        await replay.value
        #expect(vm.isPlayingQuestionTTS == false, "no leaked flag from the dropped run")
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
