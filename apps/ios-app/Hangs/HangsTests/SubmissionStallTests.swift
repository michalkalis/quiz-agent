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
//  Deterministic by construction (#180 track A): the 30 s request bound and the
//  35 s phase watchdog both run on the view model's injected clock, so every test
//  below drives a `TestClock` to the SHIPPED boundary — just before it (nothing
//  fired) and past it (it did) — instead of shrinking the durations and sleeping.
//

import Clocks
import Foundation
@testable import Hangs
import SwiftUI
import Testing

@Suite("A submission can never leave the quiz stuck in .processing/.skipping (#179)")
@MainActor
struct SubmissionStallTests {
    private func makeVM(
        clock: TestClock<Duration> = TestClock(),
        configure: (MockNetworkService) -> Void = { _ in }
    ) -> QuizViewModel {
        let vm = QuizViewModel(
            networkService: Fixtures.makeFullMockNetwork(configure: configure),
            audioService: MockAudioService(),
            persistenceStore: MockPersistenceStore(),
            silenceDetectionService: MockSilenceDetectionService(),
            clock: AnyClock(clock)
        )
        vm.currentSession = Fixtures.makeActiveSession()
        vm.currentQuestion = Fixtures.makeQuestion(id: "q_001")
        vm.quizState = .askingQuestion
        return vm
    }

    // MARK: - Per-request bound (findings 3 + 4)

    /// Finding 3, the reproduction: a confirm whose request never comes back must
    /// end on the retryable error screen, not on a grey question forever.
    @Test("a wedged confirm/resubmit times out into the retry error screen")
    func resubmitTimesOut() async throws {
        let clock = TestClock()
        // A request that never comes back: the mock's delay is real time the
        // driven clock will never reach, so only the bound can end this submit.
        let vm = makeVM(clock: clock) { $0.submitTextInputDelay = .seconds(600) }

        let submission = Task { await vm.resubmitAnswer("Lichtenštajnsko") }
        await pumpUntil { vm.quizState == .processing }
        await clock.advance(by: .seconds(vm.submitTimeoutSeconds))
        await submission.value

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
        let clock = TestClock()
        let vm = makeVM(clock: clock) { $0.submitTextInputDelay = .seconds(600) }

        let submission = Task { await vm.skipQuestion() }
        await pumpUntil { vm.quizState == .skipping }
        await clock.advance(by: .seconds(vm.submitTimeoutSeconds))
        await submission.value

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
        let clock = TestClock()
        let vm = makeVM(clock: clock) { $0.submitTextInputDelay = .seconds(600) }

        let submission = Task { await vm.skipQuestion() }
        await pumpUntil { vm.quizState == .skipping }

        // ONE budget, spent once: at the boundary the driver is already out. A
        // per-attempt bound would still be inside attempt 2's fresh budget here
        // (`URLError.timedOut` is itself classified transient) and the spinner
        // would turn for 3 × 30 s.
        await clock.advance(by: .seconds(vm.submitTimeoutSeconds))
        await submission.value

        #expect(vm.quizState.isError, "one budget for the whole retry, not one per attempt")
        #expect(vm.activeErrorModel?.retryAction == .retryOperation)
    }

    // MARK: - Phase watchdog (orphaned submissions)

    /// The bound above only helps while something is still awaiting the call. The
    /// founder's screenshots show the other shape too: nothing is awaiting any
    /// more (the sheet was dismissed, the Task was orphaned) and the phase simply
    /// never ends. The pair itself is therefore deadlined.
    @Test("a .processing phase that outlives its deadline fails with retry")
    func watchdogFiresInProcessing() async throws {
        let clock = TestClock()
        let vm = makeVM(clock: clock)

        #expect(vm.transition(to: .processing))
        await clock.advance(by: .seconds(vm.stallWatchdogSeconds - 1))
        #expect(vm.quizState == .processing, "the window is the SHIPPED 35 s — not a second less")
        await clock.advance(by: .seconds(1))
        await pumpUntil { vm.quizState.isError }

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
        let clock = TestClock()
        let vm = makeVM(clock: clock)

        #expect(vm.transition(to: .skipping))
        await clock.advance(by: .seconds(vm.stallWatchdogSeconds - 1))
        #expect(vm.quizState == .skipping, "the window is the SHIPPED 35 s — not a second less")
        await clock.advance(by: .seconds(1))
        await pumpUntil { vm.quizState.isError }

        #expect(vm.quizState.isError)
    }

    /// The guard that keeps the watchdog from becoming a bug of its own: the
    /// confirmation sheet IS a `.processing` screen (#173 C2) and a driver may sit
    /// on it as long as they like. A deadline that fired there would throw away a
    /// captured answer while the person was still reading it.
    @Test("the watchdog stays silent while the confirmation sheet is up")
    func watchdogIgnoresOpenConfirmationSheet() async throws {
        let clock = TestClock()
        let vm = makeVM(clock: clock)

        #expect(vm.transition(to: .processing))
        vm.showAnswerConfirmation = true

        // Three whole windows pass with the sheet up.
        await clock.advance(by: .seconds(vm.stallWatchdogSeconds * 3))

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
        let clock = TestClock()
        let vm = makeVM(clock: clock)

        #expect(vm.transition(to: .processing))
        vm.showAnswerConfirmation = true

        // Several windows pass with the sheet up — the driver is reading it.
        await clock.advance(by: .seconds(vm.stallWatchdogSeconds * 3))
        #expect(vm.quizState == .processing, "a sheet the user is looking at is never a stall")

        // The sheet goes away with the submission still wedged: from here the
        // phase has nobody watching it, and must not outlive one more window.
        vm.showAnswerConfirmation = false
        await clock.advance(by: .seconds(vm.stallWatchdogSeconds))
        await pumpUntil { vm.quizState.isError }

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
        let clock = TestClock()
        let vm = makeVM(clock: clock)

        #expect(vm.transition(to: .processing))
        vm.isEvaluatingAnswer = true

        await clock.advance(by: .seconds(vm.stallWatchdogSeconds * 3))

        #expect(vm.quizState == .processing)
    }

    /// A normal result must not be second-guessed: leaving the pair drops the
    /// deadline, so a question answered in time can never be failed afterwards.
    @Test("leaving .processing drops the deadline")
    func watchdogCancelledOnExit() async throws {
        let clock = TestClock()
        let vm = makeVM(clock: clock)

        #expect(vm.transition(to: .processing))
        #expect(vm.transition(to: .askingQuestion))

        await clock.advance(by: .seconds(vm.stallWatchdogSeconds * 3))

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
        // The window elapsed while the app was away. The instant comes from the
        // model's own clock (#180 track A), so the absolute deadline is already
        // past and the re-armed watchdog fires without time moving at all.
        vm.stallEnteredAt = vm.clock.now.advanced(by: .seconds(-vm.stallWatchdogSeconds - 5))

        vm.handleScenePhase(.background)
        vm.handleScenePhase(.active)
        await pumpUntil { vm.quizState.isError }

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
        let clock = TestClock()
        let vm = makeVM(clock: clock)
        #expect(vm.transition(to: .processing))

        vm.handleScenePhase(.background)
        vm.handleScenePhase(.active)
        // Still inside the original window: re-arming keeps the ABSOLUTE
        // deadline, and it has not arrived.
        await clock.advance(by: .seconds(vm.stallWatchdogSeconds - 1))

        #expect(vm.quizState == .processing)
    }
}
