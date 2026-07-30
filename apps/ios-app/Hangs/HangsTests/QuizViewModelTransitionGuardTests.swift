//
//  QuizViewModelTransitionGuardTests.swift
//  HangsTests
//
//  `transition(to:caller:)` is the single gate every quiz-flow state write goes
//  through, and its whole reason to exist is REJECTING a move the legal table
//  (`QuizState.validTransitions`) does not allow — "crash-correct over
//  crash-safe". That half had no test (#133 audit named gap): every existing
//  transition test asserts an ACCEPTED move, and `validTransitionsSet` asserts
//  the table's contents without ever proving `transition` consults it. Delete
//  the `guard` and the suite stayed green.
//
//  Why it matters: the rejections are what stop a suspended call site from
//  writing state that no longer makes sense — a submit that resolves after the
//  driver went Home publishing `.showingResult` over a torn-down quiz, a start
//  path skipping `.startingQuiz` (and with it #111's nav teardown), a stale
//  timer resurrecting `.recording` from the result screen. A rejected
//  transition must therefore change NOTHING: not the state, and not the
//  side effects `transition` fires on an applied move.
//

import Foundation
@testable import Hangs
import Testing

@Suite("QuizViewModel.transition legal-table enforcement (#133 named gap)")
@MainActor
struct QuizViewModelTransitionGuardTests {
    private func makeResultState() -> QuizState {
        .showingResult(
            question: Fixtures.makeQuestion(id: "q_001"),
            evaluation: Evaluation(
                userAnswer: "Paris", result: .correct, points: 1.0,
                correctAnswer: "Paris", questionId: "q_001", explanation: nil
            )
        )
    }

    // MARK: - Rejection

    @Test("an illegal jump is refused, returns false, and leaves the state untouched")
    func illegalTransitionsAreRejected() {
        let vm = Fixtures.makeViewModel()
        let result = makeResultState()

        // Each pair is absent from the source state's `validTransitions`. The
        // representative case named in the audit is `.idle → .showingResult`:
        // a result screen with no quiz behind it.
        let illegal: [(from: QuizState, to: QuizState)] = [
            (.idle, result), // a result with no quiz behind it
            (.idle, .askingQuestion), // a start that never created a session (#111 nav teardown skipped)
            (.askingQuestion, .finished), // completion without an answer or a skip
            (result, .recording), // a stale timer re-opening the mic from the result screen
            (.finished, .askingQuestion), // resuming a finished set instead of restarting it
            (.error(message: "boom", context: .submission), .recording), // recording out of an error screen
        ]

        for (from, to) in illegal {
            vm.quizState = from // seed directly: the guard is what is under test
            let applied = vm.transition(to: to)

            #expect(applied == false, "\(from.label) → \(to.label) is not in the legal table and must be refused")
            #expect(vm.quizState == from, "a refused \(from.label) → \(to.label) must leave the state on \(from.label)")
        }
    }

    @Test("a refused transition fires none of the applied-transition side effects")
    func rejectedTransitionHasNoSideEffects() {
        let vm = Fixtures.makeViewModel()
        let coordinator = vm.voiceCommandCoordinator
        // Floor at zero so the action-landed signal would clear the glow the
        // instant it fired — the assertion below then discriminates "no signal"
        // from "signal fired but the floor held it".
        coordinator.matchedGlowMinDisplay = 0
        coordinator.noteMatchedForFeedback()

        // Recording-phase capture state that only a phase EXIT may drop.
        vm.quizState = .recording
        vm.liveTranscript = "the driver was mid-answer"

        #expect(vm.transition(to: .finished) == false, ".recording → .finished is not in the legal table")

        #expect(
            coordinator.voiceFeedbackPhase == .matched,
            "a refused transition must not claim the screen changed — the glow would stop meaning 'your command landed'"
        )
        #expect(
            vm.liveTranscript == "the driver was mid-answer",
            "a refused transition must not run the phase-exit reset — it would drop a live answer mid-capture"
        )
    }

    // MARK: - Acceptance (the other half of the same guard)

    @Test("a legal move is applied, returns true, and fires the applied-transition side effects")
    func legalTransitionIsApplied() {
        let vm = Fixtures.makeViewModel()
        let coordinator = vm.voiceCommandCoordinator
        coordinator.matchedGlowMinDisplay = 0 // past the floor by construction
        coordinator.noteMatchedForFeedback()

        #expect(vm.transition(to: .startingQuiz) == true, ".idle → .startingQuiz is the cold-start path and must be accepted")
        #expect(vm.quizState == .startingQuiz)
        #expect(
            coordinator.voiceFeedbackPhase == .idle,
            "an applied transition IS the action-landed signal — the matched glow clears once past its floor"
        )

        // The path a graded answer actually takes, so the accepted half covers
        // more than the one entry state.
        #expect(vm.transition(to: .askingQuestion) == true)
        #expect(vm.transition(to: .processing) == true)
        #expect(vm.transition(to: makeResultState()) == true)
        #expect(vm.quizState.isShowingResult)
    }
}
