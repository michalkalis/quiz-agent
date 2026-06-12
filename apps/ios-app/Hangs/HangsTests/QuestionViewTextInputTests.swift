//
//  QuestionViewTextInputTests.swift
//  HangsTests
//
//  #54 task 54.18 — restored typed-answer fallback in the voice body.
//
//  Why these tests matter:
//  - Onboarding promises a keyboard fallback (OnboardingView "Type answers
//    instead" finishes onboarding mic-less), but 52.10 removed the TextField
//    from QuestionView — a mic-denied user couldn't answer voice questions at
//    all. The structural test pins the affordance so it can't be silently
//    dropped again (same failure class as 54.17).
//  - The behavioural test encodes the recovery contract: with a failing mic,
//    a typed answer submitted through resubmitAnswer must still reach the
//    result screen.
//

import Foundation
@testable import Hangs
import SwiftUI
import Testing
import ViewInspector

// MARK: - Structural: typed-input affordance renders in the voice body

@MainActor
@Suite("QuestionView — typed-answer fallback (54.18)")
struct QuestionViewTextInputTests {
    private func makeVoiceViewModel() -> QuizViewModel {
        let vm = QuizViewModel(
            networkService: MockNetworkService(),
            audioService: MockAudioService(),
            persistenceStore: MockPersistenceStore()
        )
        vm.currentQuestion = Question.preview // .text → voice body
        vm.quizState = .askingQuestion
        return vm
    }

    @Test("Voice body offers the 'Type answer instead' toggle in resting state")
    func voiceBodyShowsTextInputToggle() async throws {
        let vm = makeVoiceViewModel()
        let view = QuestionView(viewModel: vm)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) {
                try tree.find(viewWithAccessibilityIdentifier: "question.textInputToggle")
            }
        }
    }
}

// MARK: - Behavioural: mic-denied user reaches the result via typed answer

@MainActor
@Suite("QuizViewModel — typed answer with failing mic (54.18)")
struct QuizViewModelTypedAnswerTests {
    @Test("typed answer reaches showingResult when recording is unavailable")
    func typedAnswerReachesResultWithFailingMic() async throws {
        // Mic denied ≙ recording can never start; the keyboard is the only path.
        let (vm, _) = Fixtures.makeViewModelWithAudio(shouldFailRecording: true)
        vm.currentSession = Fixtures.makeActiveSession()
        vm.currentQuestion = Question.preview
        vm.quizState = .askingQuestion

        // This is what QuestionView.submitTypedAnswer calls.
        await vm.resubmitAnswer("Paris")

        #expect(vm.quizState.isShowingResult,
                "typed answer ended in \(vm.quizState) instead of showingResult")
    }
}
