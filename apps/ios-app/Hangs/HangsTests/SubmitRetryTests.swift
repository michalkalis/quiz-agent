//
//  SubmitRetryTests.swift
//  HangsTests
//
//  #131 Track A. The founder's TestFlight session on 2026-07-29 showed
//  "Couldn't submit your answer" after a voice submit AND after Skip; Sentry
//  traced it to a staging `auto_stop_machines` cold wake. Quiz start already
//  retried transient failures and recovered; the submit paths did not, so ONE
//  waking machine cost the user their answer and their next question.
//
//  These tests encode the user-visible contract: a single transient failure on a
//  submit path is invisible — no error state, no OOPS screen, the flow continues.
//  A permanent failure must still surface immediately (a retry loop that hides
//  real breakage is worse than the bug it fixes).
//

import Foundation
@testable import Hangs
import Testing

@Suite("Submit / skip transient retry (#131 Track A)")
@MainActor
struct SubmitRetryTests {
    /// Collapses the 1s/2s backoff so the suite doesn't sleep for real.
    private func makeViewModel() -> (QuizViewModel, MockNetworkService) {
        let (vm, network) = Fixtures.makeViewModelWithNetwork()
        vm.transientStartBackoffOverride = { _ in .zero }
        vm.recordingCoordinator.transientBackoffOverride = { _ in .zero }
        vm.currentSession = Fixtures.makeActiveSession()
        vm.currentQuestion = Fixtures.makeQuestion()
        vm.quizState = .askingQuestion
        return (vm, network)
    }

    // MARK: - Skip

    @Test("skip survives a single cold-wake 503 — no OOPS, question advances")
    func skipRetriesTransient503() async throws {
        let (vm, network) = makeViewModel()
        network.textInputFailuresBeforeSuccess = 1 // one waking machine

        await vm.skipQuestion()

        #expect(network.submitTextInputCallCount == 2, "one failure + one successful retry")
        if case .error = vm.quizState {
            Issue.record("skip surfaced the OOPS error state after a single retryable 503")
        }
    }

    @Test("skip still fails loudly when the backend keeps returning 503")
    func skipStopsAfterAttemptsExhausted() async throws {
        let (vm, network) = makeViewModel()
        network.textInputFailuresBeforeSuccess = 99 // never recovers

        await vm.skipQuestion()

        #expect(network.submitTextInputCallCount == TransientRetry.maxAttempts,
                "bounded: 3 attempts, then surface — never an unbounded loop")
        if case .error = vm.quizState {} else {
            Issue.record("a persistent backend failure must reach the user")
        }
    }

    // MARK: - Typed answer

    @Test("typed answer survives a single cold-wake 503")
    func typedAnswerRetriesTransient503() async throws {
        let (vm, network) = makeViewModel()
        network.textInputFailuresBeforeSuccess = 1

        await vm.resubmitAnswer("Bratislava")

        #expect(network.submitTextInputCallCount == 2)
        #expect(network.capturedTextInputInput == "Bratislava", "the retry re-sends the same answer")
        if case .error = vm.quizState {
            Issue.record("typed submit surfaced an error state after a retryable 503")
        }
    }

    // MARK: - Voice answer

    @Test("voice submit survives a single cold-wake 503 and still reaches confirmation")
    func voiceSubmitRetriesTransient503() async throws {
        let (vm, network) = makeViewModel()
        network.submitVoiceAnswerFailuresBeforeSuccess = 1

        await vm.recordingCoordinator.submitVoiceAnswer(audioData: Data([0x1, 0x2]))

        #expect(network.submitVoiceAnswerCallCount == 2, "one failure + one successful retry")
        #expect(vm.showAnswerConfirmation == true, "the recovered submit lands on the confirmation sheet")
        if case .error = vm.quizState {
            Issue.record("voice submit surfaced an error state after a retryable 503")
        }
    }

    // MARK: - Classification

    /// The retry must never fire on an error that proves the request DID reach
    /// application code — re-sending an answer that was already counted is worse
    /// than showing the failure.
    @Test("only connection-level and 502/503 failures are retryable")
    func onlyTransientErrorsRetry() {
        #expect(TransientRetry.isTransient(URLError(.cannotConnectToHost)))
        #expect(TransientRetry.isTransient(NetworkError.serverError(statusCode: 503, message: "waking")))
        #expect(TransientRetry.isTransient(NetworkError.serverError(statusCode: 502, message: "proxy")))
        #expect(!TransientRetry.isTransient(NetworkError.serverError(statusCode: 500, message: "bug")))
        #expect(!TransientRetry.isTransient(NetworkError.serverError(statusCode: 429, message: "quota")))
        #expect(!TransientRetry.isTransient(NetworkError.invalidResponse))
        #expect(!TransientRetry.isTransient(URLError(.cancelled)))
    }
}
