//
//  MicPermissionAtFirstQuestionTests.swift
//  HangsTests
//
//  #188 G7: onboarding's "Maybe later" leaves microphone access undecided, so
//  the first recording is where it gets asked. These pin the decision: ask
//  only while undetermined, never again once the user has decided.
//

@testable import Hangs
import Testing

@Suite("Microphone permission at the first question")
struct MicPermissionAtFirstQuestionTests {
    @Test("undetermined: the first recording asks once, before the mic opens")
    @MainActor
    func undeterminedAsksOnce() async throws {
        let (viewModel, mockAudio) = Fixtures.makeViewModelWithAudio()
        mockAudio.micPermissionStatus = .undetermined
        viewModel.quizState = .askingQuestion

        await viewModel.toggleRecording()

        #expect(mockAudio.micPermissionRequestCount == 1)
        #expect(viewModel.quizState == .recording)
    }

    @Test("a later recording does not ask again once the user answered")
    @MainActor
    func answeredOnceIsNotAskedAgain() async throws {
        let (viewModel, mockAudio) = Fixtures.makeViewModelWithAudio()
        mockAudio.micPermissionStatus = .undetermined
        viewModel.quizState = .askingQuestion
        await viewModel.toggleRecording()

        viewModel.quizState = .askingQuestion
        await viewModel.toggleRecording()

        #expect(mockAudio.micPermissionRequestCount == 1)
    }

    @Test("granted: recording starts without asking")
    @MainActor
    func grantedDoesNotAsk() async throws {
        let (viewModel, mockAudio) = Fixtures.makeViewModelWithAudio()
        mockAudio.micPermissionStatus = .granted
        viewModel.quizState = .askingQuestion

        await viewModel.toggleRecording()

        #expect(mockAudio.micPermissionRequestCount == 0)
    }

    @Test("denied: not asked again, the quiz carries on as it does today")
    @MainActor
    func deniedDoesNotAsk() async throws {
        let (viewModel, mockAudio) = Fixtures.makeViewModelWithAudio()
        mockAudio.micPermissionStatus = .denied
        viewModel.quizState = .askingQuestion

        await viewModel.toggleRecording()

        #expect(mockAudio.micPermissionRequestCount == 0)
        #expect(viewModel.quizState == .recording)
    }
}
