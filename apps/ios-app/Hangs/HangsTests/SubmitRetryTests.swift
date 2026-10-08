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

import Clocks
import Foundation
@testable import Hangs
import Testing

@Suite("Submit / skip transient retry (#131 Track A)")
@MainActor
struct SubmitRetryTests {
    /// #180 track A: the 1 s/2 s backoff runs on the model's injected clock, so
    /// the suite drives it instead of sleeping. A `TestClock` — not an
    /// `ImmediateClock` — because the same clock carries the submit's 30 s
    /// `withUserFacingTimeout`: collapsing every wait would let that timeout win
    /// the race and fail the submission the retry is supposed to rescue.
    private func makeViewModel() -> (QuizViewModel, MockNetworkService, TestClock<Duration>) {
        let clock = TestClock()
        let (vm, network) = Fixtures.makeViewModelWithNetwork(clock: AnyClock(clock))
        vm.currentSession = Fixtures.makeActiveSession()
        vm.currentQuestion = Fixtures.makeQuestion()
        vm.quizState = .askingQuestion
        return (vm, network, clock)
    }

    /// Lets `failures` attempts fail, advancing the test clock by the SHIPPED
    /// backoff after each one so the next attempt can fire.
    private func driveFailures(_ failures: Int, calls: @escaping @MainActor () -> Int, clock: TestClock<Duration>) async {
        for attempt in 1 ... failures {
            await pumpUntil({ calls() == attempt }, "attempt \(attempt) never fired")
            await clock.advance(by: TransientRetry.delay(afterAttempt: attempt))
        }
    }

    // MARK: - Skip

    @Test("skip survives a single cold-wake 503 — no OOPS, question advances")
    func skipRetriesTransient503() async throws {
        let (vm, network, clock) = makeViewModel()
        network.textInputFailuresBeforeSuccess = 1 // one waking machine

        let submission = Task { await vm.skipQuestion() }
        await pumpUntil { network.submitTextInputCallCount == 1 } // the cold wake
        await clock.advance(by: .seconds(1)) // the SHIPPED first backoff
        await submission.value

        #expect(network.submitTextInputCallCount == 2, "one failure + one successful retry")
        if case .error = vm.quizState {
            Issue.record("skip surfaced the OOPS error state after a single retryable 503")
        }
    }

    /// #193 task 193.12: the retry is bounded by a time window, not a count —
    /// and the window must end inside the 30 s user-facing submit bound, or the
    /// driver waits longer than the screen tolerates. Attempts at 0, 1, 3, 6, 9,
    /// 12, 15, 18, 21 and 24 s; the next would start at 27 s, past the window.
    @Test("skip still fails loudly when the backend stays down past the retry window")
    func skipStopsAfterRetryWindow() async throws {
        let (vm, network, clock) = makeViewModel()
        network.textInputFailuresBeforeSuccess = 99 // never recovers

        let submission = Task { await vm.skipQuestion() }
        await driveFailures(9, calls: { network.submitTextInputCallCount }, clock: clock)
        await pumpUntil { network.submitTextInputCallCount == 10 }
        await submission.value

        #expect(network.submitTextInputCallCount == 10,
                "bounded: 10 attempts within 24 s, then surface — never an unbounded loop")
        if case .error = vm.quizState {} else {
            Issue.record("a persistent backend failure must reach the user")
        }
    }

    // MARK: - Deploy restart (#193 task 193.12)

    /// Prod `quiz-agent-api` is a single machine: a deploy restarts it for ~18 s.
    /// A tapped answer mid-drive must ride that out and land on the result — the
    /// MCQ tap had no retry at all before this, so one 502 cost the answer.
    @Test("an MCQ tap survives an ~18 s deploy restart — same question, no OOPS")
    func mcqTapRidesOutDeployRestart() async throws {
        let (vm, network, clock) = makeViewModel()
        let questionId = vm.currentQuestion?.id
        network.textInputFailuresBeforeSuccess = 7 // fails at 0…15 s, back at 18 s

        let submission = Task { await vm.submitMCQAnswer(key: "a", value: "Bratislava") }
        await driveFailures(7, calls: { network.submitTextInputCallCount }, clock: clock)
        await submission.value

        #expect(network.submitTextInputCallCount == 8, "7 failures during the restart + 1 success")
        #expect(network.capturedTextInputQuestionId == questionId,
                "every retry answers the SAME question — the server replays, never double-grades")
        if case .error = vm.quizState {
            Issue.record("an MCQ tap surfaced the OOPS screen during a deploy restart")
        }
    }

    // MARK: - Typed answer

    @Test("typed answer survives a single cold-wake 503")
    func typedAnswerRetriesTransient503() async throws {
        let (vm, network, clock) = makeViewModel()
        network.textInputFailuresBeforeSuccess = 1

        let submission = Task { await vm.resubmitAnswer("Bratislava") }
        await pumpUntil { network.submitTextInputCallCount == 1 }
        await clock.advance(by: .seconds(1))
        await submission.value

        #expect(network.submitTextInputCallCount == 2)
        #expect(network.capturedTextInputInput == "Bratislava", "the retry re-sends the same answer")
        if case .error = vm.quizState {
            Issue.record("typed submit surfaced an error state after a retryable 503")
        }
    }

    // MARK: - Voice answer

    @Test("voice submit survives a single cold-wake 503 and still reaches confirmation")
    func voiceSubmitRetriesTransient503() async throws {
        let (vm, network, clock) = makeViewModel()
        network.submitVoiceAnswerFailuresBeforeSuccess = 1

        let submission = Task { await vm.recordingCoordinator.submitVoiceAnswer(audioData: Data([0x1, 0x2])) }
        await pumpUntil { network.submitVoiceAnswerCallCount == 1 }
        await clock.advance(by: .seconds(1))
        await submission.value

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
    @Test("only connection-level and 502/503/504 failures are retryable")
    func onlyTransientErrorsRetry() {
        #expect(TransientRetry.isTransient(URLError(.cannotConnectToHost)))
        // #193 task 193.12: a tunnel (no signal) and a proxy gateway timeout
        // during a deploy are the same "never answered" class.
        #expect(TransientRetry.isTransient(URLError(.notConnectedToInternet)))
        #expect(TransientRetry.isTransient(NetworkError.serverError(statusCode: 504, message: "gateway")))
        #expect(TransientRetry.isTransient(NetworkError.serverError(statusCode: 503, message: "waking")))
        #expect(TransientRetry.isTransient(NetworkError.serverError(statusCode: 502, message: "proxy")))
        #expect(!TransientRetry.isTransient(NetworkError.serverError(statusCode: 500, message: "bug")))
        #expect(!TransientRetry.isTransient(NetworkError.serverError(statusCode: 429, message: "quota")))
        #expect(!TransientRetry.isTransient(NetworkError.invalidResponse))
        #expect(!TransientRetry.isTransient(URLError(.cancelled)))
        // #133 1a: a 409 question_mismatch is the server telling us it saw the
        // request and refused it — re-sending the same stale id fails identically.
        #expect(!TransientRetry.isTransient(NetworkError.questionMismatch(currentQuestionId: "q_042")))
    }
}
