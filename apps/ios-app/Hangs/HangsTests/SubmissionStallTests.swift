//
//  SubmissionStallTests.swift
//  HangsTests
//
//  #179 (founder TF 2026-09-14, build 61), findings 3 + 4 — the two freezes:
//
//  3. MCQ answered by voice, confirmed → the screen went grey and stayed there:
//     `.processing` with the options disabled, the command bar gone and Skip
//     dead. The confirm goes through `resubmitAnswer`, which — unlike the MCQ
//     tap (#178) and the voice submit (#131 Track A) — had no user-facing bound.
//  4. Open question, "Preskoč" → the Skip spinner turned forever and Start went
//     dead: `skipQuestion` had the same gap, and `.skipping` is only left when
//     the awaited call returns.
//
//  Both states are spinners with every control disabled, so "no exit" reads to
//  the driver as a frozen app. These tests pin the three exits that now exist:
//  the per-request bound, the phase watchdog for a submission whose owner is
//  gone, and the foreground return that re-checks it.
//
//  Deterministic by construction: `submitTimeoutSeconds` / `stallWatchdogSeconds`
//  are the injected durations, so nothing here waits on the real 30 s / 35 s.
//

import Foundation
@testable import Hangs
import SwiftUI
import Testing

@Suite("A submission can never leave the quiz stuck in .processing/.skipping (#179)")
@MainActor
struct SubmissionStallTests {
    private func makeVM(configure: (MockNetworkService) -> Void = { _ in }) -> QuizViewModel {
        let vm = QuizViewModel(
            networkService: Fixtures.makeFullMockNetwork(configure: configure),
            audioService: MockAudioService(),
            persistenceStore: MockPersistenceStore()
        )
        vm.currentSession = Fixtures.makeActiveSession()
        vm.currentQuestion = Fixtures.makeQuestion(id: "q_001")
        vm.quizState = .askingQuestion
        return vm
    }

    /// Spin until `predicate` holds, so the watchdog's own Task gets to run
    /// without betting on wall-clock ordering.
    private func waitUntil(_ predicate: @MainActor () -> Bool, timeoutMillis: Int = 5000) async {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(timeoutMillis))
        while ContinuousClock.now < deadline {
            if predicate() { return }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    // MARK: - Per-request bound (findings 3 + 4)

    /// Finding 3, the reproduction: a confirm whose request never comes back must
    /// end on the retryable error screen, not on a grey question forever.
    @Test("a wedged confirm/resubmit times out into the retry error screen")
    func resubmitTimesOut() async throws {
        let vm = makeVM { $0.submitTextInputDelay = .seconds(30) }
        vm.submitTimeoutSeconds = 1

        await vm.resubmitAnswer("Lichtenštajnsko")

        guard case let .error(message, context) = vm.quizState else {
            Issue.record("expected .error, got \(vm.quizState.label)")
            return
        }
        #expect(context == .submission)
        #expect(message.isEmpty == false)
        // The CTA matters as much as the state: the driver must be offered a retry.
        #expect(vm.activeErrorModel?.retryAction == .retryOperation)
    }

    /// Finding 4, the reproduction: same for the skip — `.skipping` had exactly
    /// one exit, the returning `await`.
    @Test("a wedged skip times out into the retry error screen")
    func skipTimesOut() async throws {
        let vm = makeVM { $0.submitTextInputDelay = .seconds(30) }
        vm.submitTimeoutSeconds = 1

        await vm.skipQuestion()

        guard case let .error(_, context) = vm.quizState else {
            Issue.record("expected .error, got \(vm.quizState.label)")
            return
        }
        #expect(context == .submission)
        #expect(vm.activeErrorModel?.retryAction == .retryOperation)
    }

    /// The bound is on the WHOLE submission, not on one attempt: `URLError.timedOut`
    /// is classified transient, so a per-attempt bound would silently stack to
    /// 3 × the budget — the freeze would just take three times longer to end.
    @Test("the timeout bounds the whole retry, not each attempt")
    func timeoutBoundsWholeRetry() async throws {
        let vm = makeVM { $0.submitTextInputDelay = .seconds(30) }
        vm.submitTimeoutSeconds = 1

        let startedAt = ContinuousClock.now
        await vm.skipQuestion()
        let elapsed = ContinuousClock.now - startedAt

        #expect(elapsed < .seconds(3), "one 1 s budget, not one per attempt (got \(elapsed))")
    }

    // MARK: - Phase watchdog (orphaned submissions)

    /// The bound above only helps while something is still awaiting the call. The
    /// founder's screenshots show the other shape too: nothing is awaiting any
    /// more (the sheet was dismissed, the Task was orphaned) and the phase simply
    /// never ends. The pair itself is therefore deadlined.
    @Test("a .processing phase that outlives its deadline fails with retry")
    func watchdogFiresInProcessing() async throws {
        let vm = makeVM()
        vm.stallWatchdogSeconds = 0.15

        #expect(vm.transition(to: .processing))
        await waitUntil { vm.quizState.isError }

        guard case let .error(_, context) = vm.quizState else {
            Issue.record("expected .error, got \(vm.quizState.label)")
            return
        }
        #expect(context == .submission)
        #expect(vm.activeErrorModel?.retryAction == .retryOperation)
    }

    /// Same deadline on the skip half of the pair.
    @Test("a .skipping phase that outlives its deadline fails with retry")
    func watchdogFiresInSkipping() async throws {
        let vm = makeVM()
        vm.stallWatchdogSeconds = 0.15

        #expect(vm.transition(to: .skipping))
        await waitUntil { vm.quizState.isError }

        #expect(vm.quizState.isError)
    }

    /// The guard that keeps the watchdog from becoming a bug of its own: the
    /// confirmation sheet IS a `.processing` screen (#173 C2) and a driver may sit
    /// on it as long as they like. A deadline that fired there would throw away a
    /// captured answer while the person was still reading it.
    @Test("the watchdog stays silent while the confirmation sheet is up")
    func watchdogIgnoresOpenConfirmationSheet() async throws {
        let vm = makeVM()
        vm.stallWatchdogSeconds = 0.15

        #expect(vm.transition(to: .processing))
        vm.showAnswerConfirmation = true

        try await Task.sleep(for: .milliseconds(400))

        #expect(vm.quizState == .processing, "a sheet the user is looking at is not a stall")
    }

    /// The other half of that rule (PR #156 review): deferring is not disarming.
    /// The guard above consumes the one-shot watchdog Task, and the whole confirm
    /// flow — sheet up, confirm, evaluate, response — stays inside `.processing`,
    /// which has no legal self-transition to re-arm on. So a sheet that outlives
    /// the deadline used to buy the phase permanent immunity: exactly the orphaned
    /// `.processing` of finding 3, now unbounded.
    @Test("a sheet outliving the deadline defers the watchdog; the phase is bounded again once it closes")
    func watchdogDefersWhileSheetIsUpThenFires() async throws {
        let vm = makeVM()
        vm.stallWatchdogSeconds = 0.15

        #expect(vm.transition(to: .processing))
        vm.showAnswerConfirmation = true

        // Several windows pass with the sheet up — the driver is reading it.
        try await Task.sleep(for: .milliseconds(500))
        #expect(vm.quizState == .processing, "a sheet the user is looking at is never a stall")

        // The sheet goes away with the submission still wedged: from here the
        // phase has nobody watching it, and must not outlive one more window.
        vm.showAnswerConfirmation = false
        await waitUntil { vm.quizState.isError }

        guard case let .error(_, context) = vm.quizState else {
            Issue.record("expected .error after the sheet closed, got \(vm.quizState.label)")
            return
        }
        #expect(context == .submission)
        #expect(vm.activeErrorModel?.retryAction == .retryOperation)
    }

    /// …and the same while the confirmed answer is being evaluated on that sheet.
    @Test("the watchdog stays silent while an answer is being evaluated")
    func watchdogIgnoresEvaluatingAnswer() async throws {
        let vm = makeVM()
        vm.stallWatchdogSeconds = 0.15

        #expect(vm.transition(to: .processing))
        vm.isEvaluatingAnswer = true

        try await Task.sleep(for: .milliseconds(400))

        #expect(vm.quizState == .processing)
    }

    /// A normal result must not be second-guessed: leaving the pair drops the
    /// deadline, so a question answered in time can never be failed afterwards.
    @Test("leaving .processing drops the deadline")
    func watchdogCancelledOnExit() async throws {
        let vm = makeVM()
        vm.stallWatchdogSeconds = 0.15

        #expect(vm.transition(to: .processing))
        #expect(vm.transition(to: .askingQuestion))

        try await Task.sleep(for: .milliseconds(400))

        #expect(vm.quizState == .askingQuestion)
    }

    // MARK: - Return from the background

    /// `handleScenePhase` did nothing at all for `.processing`: a submit that
    /// wedged while the app was backgrounded came back to the same dead screen.
    /// The deadline is absolute, so the whole window having elapsed out of sight
    /// resolves on return instead of granting a fresh one.
    @Test("returning from the background during .processing recovers the quiz")
    func foregroundReturnRecoversStalledProcessing() async throws {
        let vm = makeVM()
        #expect(vm.transition(to: .processing))
        // The window elapsed while the app was away.
        vm.stallEnteredAt = Date().addingTimeInterval(-vm.stallWatchdogSeconds - 5)

        vm.handleScenePhase(.background)
        vm.handleScenePhase(.active)
        await waitUntil { vm.quizState.isError }

        guard case let .error(_, context) = vm.quizState else {
            Issue.record("expected .error, got \(vm.quizState.label)")
            return
        }
        #expect(context == .submission)
        #expect(vm.activeErrorModel?.retryAction == .retryOperation)
    }

    /// The other half of that rule: a return part-way through the window must NOT
    /// fail a submission that still has time to land.
    @Test("returning from the background mid-window leaves the submission alone")
    func foregroundReturnKeepsFreshSubmission() async throws {
        let vm = makeVM()
        #expect(vm.transition(to: .processing))

        vm.handleScenePhase(.background)
        vm.handleScenePhase(.active)
        try await Task.sleep(for: .milliseconds(200))

        #expect(vm.quizState == .processing)
    }
}
