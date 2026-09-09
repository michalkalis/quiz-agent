//
//  QuizMuteScopeTests.swift
//  HangsTests
//
//  #173 Track A: mute has two scopes and they must not be the same flag.
//  The in-quiz button silences the RUNNING quiz (`quizMuteOverride`, dropped at
//  quiz start); the Settings "Sound" toggle is a persisted preference
//  (`settings.isMuted`). Sharing one flag is what let a mute tapped mid-drive
//  silence the first question of the next quiz — the founder's TF screenshot,
//  2026-09-06, where the opening question played mute under a live countdown.
//

import Foundation
@testable import Hangs
import Testing

@MainActor
private func makeMuteTestViewModel() -> QuizViewModel {
    QuizViewModel(
        networkService: Fixtures.makeFullMockNetwork(),
        audioService: MockAudioService(),
        persistenceStore: MockPersistenceStore()
    )
}

@Suite("Mute scope — in-quiz button vs Settings preference (#173)")
@MainActor
struct QuizMuteScopeTests {
    /// The bug itself: the in-quiz button is a per-quiz decision, so starting a
    /// quiz must clear it. The first question is the one a driver is least able
    /// to recover from if it is silent — the countdown runs either way.
    @Test("starting a quiz clears a mute left over from the previous one")
    func quizStartClearsInQuizMute() async throws {
        let viewModel = makeMuteTestViewModel()

        await viewModel.toggleMute() // what the in-quiz mute button calls
        #expect(viewModel.isAudioMuted, "the button must silence the quiz it was tapped in")
        #expect(viewModel.settings.isMuted == false, "…without writing the persisted preference")

        await viewModel.startNewQuiz()

        #expect(viewModel.isAudioMuted == false, "the next quiz must start audible")
    }

    /// The other half of the founder decision (2026-09-07): the Settings "Sound"
    /// toggle is a PREFERENCE. If quiz start cleared that too, a user who turned
    /// sound off would have it turned back on for them at every single quiz.
    @Test("a mute chosen in Settings survives quiz start")
    func settingsMuteSurvivesQuizStart() async throws {
        let viewModel = makeMuteTestViewModel()
        viewModel.settings.isMuted = true // what the Settings toggle writes

        await viewModel.startNewQuiz()

        #expect(viewModel.isAudioMuted, "Settings outlives the quiz that started under it")
    }

    /// The override — not the persisted flag — is what the playback guards read:
    /// an in-quiz UNmute has to beat a persisted mute, or the button would look
    /// dead on a device whose Settings toggle is off.
    @Test("the in-quiz button can unmute a quiz started under a persisted mute")
    func inQuizUnmuteBeatsPersistedMute() async throws {
        let viewModel = makeMuteTestViewModel()
        viewModel.settings.isMuted = true
        await viewModel.startNewQuiz()

        await viewModel.toggleMute()

        #expect(viewModel.isAudioMuted == false)
        #expect(viewModel.settings.isMuted, "the preference is untouched — the next quiz is quiet again")
    }
}
