//
//  MicPermissionAtFirstQuestionTests.swift
//  HangsTests
//
//  #188 G7: onboarding's "Maybe later" leaves microphone access undecided, so
//  the quiz start is where it gets asked (before any mic user). These pin the decision: ask
//  only while undetermined, never again once the user has decided.
//

@testable import Hangs
import Testing

@Suite("Microphone permission at the first question")
struct MicPermissionAtFirstQuestionTests {
    @Test("undetermined: the quiz start asks once, before any mic user")
    @MainActor
    func undeterminedAsksOnce() async throws {
        let (viewModel, mockAudio) = Fixtures.makeViewModelWithAudio()
        mockAudio.micPermissionStatus = .undetermined

        await viewModel.startNewQuiz(maxQuestions: 10)

        #expect(mockAudio.micPermissionRequestCount == 1)
        #expect(viewModel.quizState == .askingQuestion)
    }

    @Test("granted: recording starts without asking")
    @MainActor
    func grantedDoesNotAsk() async throws {
        let (viewModel, mockAudio) = Fixtures.makeViewModelWithAudio()
        mockAudio.micPermissionStatus = .granted

        await viewModel.startNewQuiz(maxQuestions: 10)

        #expect(mockAudio.micPermissionRequestCount == 0)
    }

    @Test("denied: not asked again, the quiz carries on as it does today")
    @MainActor
    func deniedDoesNotAsk() async throws {
        let (viewModel, mockAudio) = Fixtures.makeViewModelWithAudio()
        mockAudio.micPermissionStatus = .denied

        await viewModel.startNewQuiz(maxQuestions: 10)

        #expect(mockAudio.micPermissionRequestCount == 0)
        #expect(viewModel.quizState == .askingQuestion)
    }
}
