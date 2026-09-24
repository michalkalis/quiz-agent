//
//  ScreenAwakeControllerTests.swift
//  HangsTests
//
//  Issue #108C: the founder reported the screen dimming mid-drive, including
//  on the result screen. These tests pin the decision (awake for every active
//  quiz state, asleep on idle/finished/minimized) and prove the idle-timer
//  flag is force-reset on teardown so it can never leak past a quiz.
//
//  #185 finding 7: the founder also reported the screen sleeping on the
//  end-of-set recap while it was still reading answers/explanations aloud.
//  `.finished` is where `SetRecapView`'s narration runs (`QuizViewModel+Recap.swift`
//  — `isNarratingRecap` toggles true/false while `quizState` stays `.finished`
//  the whole time), so the decision seam now takes that flag as the
//  `.finished` exception instead of always sleeping there.
//

@testable import Hangs
import Testing

@Suite("ScreenAwakeController — decision seam")
struct ScreenAwakeControllerTests {
    private func makeResultState() -> QuizState {
        .showingResult(
            question: Fixtures.makeQuestion(id: "q_001"),
            evaluation: Evaluation(
                userAnswer: "x", result: .correct, points: 1.0,
                correctAnswer: "x", questionId: "q_001", explanation: nil
            )
        )
    }

    @Test("idle never keeps the screen awake, regardless of minimized or narration")
    func idleSleeps() {
        for isMinimized in [false, true] {
            for isNarratingRecap in [false, true] {
                #expect(ScreenAwakeController.shouldKeepScreenAwake(state: .idle, isMinimized: isMinimized, isNarratingRecap: isNarratingRecap) == false)
            }
        }
    }

    @Test("finished sleeps once recap narration is not running")
    func finishedSleepsWithoutNarration() {
        for isMinimized in [false, true] {
            #expect(ScreenAwakeController.shouldKeepScreenAwake(state: .finished, isMinimized: isMinimized, isNarratingRecap: false) == false)
        }
    }

    /// Founder 09-24 (#185 finding 7): the screen must not sleep while the
    /// end-of-set recap is being read aloud, even though `quizState` is
    /// `.finished` for the whole recap screen.
    @Test("finished stays awake while recap narration is playing")
    func finishedStaysAwakeDuringNarration() {
        #expect(ScreenAwakeController.shouldKeepScreenAwake(state: .finished, isMinimized: false, isNarratingRecap: true) == true)
    }

    /// Narration never plays while minimized (SetRecapView isn't the visible
    /// screen), but the decision seam still honours the minimized guard first.
    @Test("finished + narrating still sleeps while minimized")
    func finishedNarratingSleepsWhileMinimized() {
        #expect(ScreenAwakeController.shouldKeepScreenAwake(state: .finished, isMinimized: true, isNarratingRecap: true) == false)
    }

    @Test("every other quiz state keeps the screen awake when not minimized, regardless of narration")
    func activeStatesStayAwake() {
        let activeStates: [QuizState] = [
            .startingQuiz,
            .askingQuestion,
            .recording,
            .processing,
            .skipping,
            makeResultState(),
            .error(message: "boom", context: .general),
        ]
        for state in activeStates {
            for isNarratingRecap in [false, true] {
                #expect(
                    ScreenAwakeController.shouldKeepScreenAwake(state: state, isMinimized: false, isNarratingRecap: isNarratingRecap) == true,
                    "\(state) should keep the screen awake"
                )
            }
        }
    }

    /// Regression: the founder's report was specifically about the RESULT
    /// screen dimming — this must never silently regress back to "asleep".
    @Test("showingResult counts as active")
    func resultScreenStaysAwake() {
        #expect(ScreenAwakeController.shouldKeepScreenAwake(state: makeResultState(), isMinimized: false, isNarratingRecap: false) == true)
    }

    @Test("minimized always sleeps, even mid-quiz")
    func minimizedAlwaysSleeps() {
        let activeStates: [QuizState] = [.startingQuiz, .askingQuestion, .recording, .processing, .skipping, makeResultState()]
        for state in activeStates {
            #expect(
                ScreenAwakeController.shouldKeepScreenAwake(state: state, isMinimized: true, isNarratingRecap: false) == false,
                "\(state) must sleep while minimized — QuestionView/ResultView aren't visible"
            )
        }
    }
}

@Suite("ScreenAwakeWriter — injectable singleton write")
@MainActor
struct ScreenAwakeWriterTests {
    @Test("apply forwards the computed decision to the injected setter")
    func applyForwardsDecision() {
        var received: [Bool] = []
        let writer = ScreenAwakeWriter(setIdleTimerDisabled: { received.append($0) })

        writer.apply(state: .askingQuestion, isMinimized: false)
        writer.apply(state: .idle, isMinimized: false)

        #expect(received == [true, false])
    }

    @Test("reset always sends false, e.g. on teardown mid-quiz")
    func resetSendsFalse() {
        var received: [Bool] = []
        let writer = ScreenAwakeWriter(setIdleTimerDisabled: { received.append($0) })

        // Simulate an active quiz leaving the idle timer disabled...
        writer.apply(state: .recording, isMinimized: false)
        #expect(received == [true])

        // ...then the view tears down (onDisappear) — the flag must never
        // leak past the view's lifetime, regardless of the state it left off at.
        writer.reset()

        #expect(received == [true, false])
    }

    /// #185 finding 7 — the wiring ContentView actually drives: `.finished`
    /// arrives first (recap screen shows), narration starts a moment later
    /// (still `.finished`), then narration ends on its own (state unchanged)
    /// and finally the user leaves the quiz back to `.idle`.
    @Test("stays awake through finished + narration, sleeps once narration ends, stays asleep on leaving")
    func recapNarrationLifecycle() {
        var received: [Bool] = []
        let writer = ScreenAwakeWriter(setIdleTimerDisabled: { received.append($0) })

        // Recap screen appears; narration hasn't started yet (e.g. muted
        // moment before autoPlayRecapIfHandsFree kicks in) — no reason to
        // hold the screen awake yet.
        writer.apply(state: .finished, isMinimized: false, isNarratingRecap: false)
        // Narration starts (isNarratingRecap flips true, quizState unchanged).
        writer.apply(state: .finished, isMinimized: false, isNarratingRecap: true)
        #expect(received == [false, true])

        // Narration finishes on its own (QuizViewModel+Recap.playRecapSummary
        // sets isNarratingRecap = false when the chunk loop completes).
        writer.apply(state: .finished, isMinimized: false, isNarratingRecap: false)
        #expect(received == [false, true, false])

        // User leaves the quiz back to idle — must stay asleep, never flip
        // awake again.
        writer.apply(state: .idle, isMinimized: false, isNarratingRecap: false)
        #expect(received == [false, true, false, false])
    }
}
