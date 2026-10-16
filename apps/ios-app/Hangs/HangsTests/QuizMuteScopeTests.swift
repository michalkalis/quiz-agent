//
//  QuizMuteScopeTests.swift
//  HangsTests
//
//  #208 (founder decision 2026-10-16): muting read-aloud from the quiz header
//  holds for the next quiz until the player changes it. This deliberately
//  reverses #173 Track A, where the header button wrote a per-quiz override
//  that quiz start dropped. The founder now mutes once (a passenger, a call)
//  and expects the app to stay quiet, and Settings to show the same switch.
//

import Foundation
@testable import Hangs
import Testing

@MainActor
private func makeMuteTestViewModel(store: MockPersistenceStore = MockPersistenceStore()) -> QuizViewModel {
    QuizViewModel(
        networkService: Fixtures.makeFullMockNetwork(),
        audioService: MockAudioService(),
        persistenceStore: store,
        silenceDetectionService: MockSilenceDetectionService()
    )
}

@Suite("Mute scope — header button is the persisted preference (#208)")
@MainActor
struct QuizMuteScopeTests {
    /// WHY: the founder decision itself. A mute that quietly turned itself back
    /// on at the next quiz start is what the TF test 2026-10-16 reported.
    @Test("a mute from the quiz header holds for the next quiz")
    func headerMuteSurvivesQuizStart() async throws {
        let viewModel = makeMuteTestViewModel()

        await viewModel.toggleMute() // what the quiz header button calls
        #expect(viewModel.isAudioMuted, "the button must silence the quiz it was tapped in")

        await viewModel.startNewQuiz()

        #expect(viewModel.isAudioMuted, "the next quiz must start muted until the player changes it")
    }

    /// WHY: Settings › Sound and the header are ONE switch now. If the header
    /// wrote anything else, Settings would show sound on while the quiz is mute.
    @Test("the header mute is what Settings shows, and it is saved")
    func headerMuteWritesPersistedSetting() async throws {
        let store = MockPersistenceStore()
        let viewModel = makeMuteTestViewModel(store: store)

        await viewModel.toggleMute()

        #expect(viewModel.settings.isMuted, "Settings › Sound must reflect the header mute")
        await pumpUntil({ store.loadSettings().isMuted }, "the header mute must reach the saved settings")
    }

    /// WHY: the way back has to work from the same button, or a player who
    /// muted once is stuck digging through Settings.
    @Test("the header button unmutes a quiz started under a saved mute, for good")
    func headerUnmuteClearsPersistedMute() async throws {
        let viewModel = makeMuteTestViewModel()
        viewModel.settings.isMuted = true
        await viewModel.startNewQuiz()

        await viewModel.toggleMute()

        #expect(viewModel.isAudioMuted == false)
        #expect(viewModel.settings.isMuted == false, "the next quiz is audible again too")
    }
}
