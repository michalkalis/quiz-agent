//
//  ScreenAwakeControllerTests.swift
//  HangsTests
//
//  Issue #108C: the founder reported the screen dimming mid-drive, including
//  on the result screen. These tests pin the decision (awake for every active
//  quiz state, asleep on idle/finished/minimized) and prove the idle-timer
//  flag is force-reset on teardown so it can never leak past a quiz.
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

    @Test("idle and finished never keep the screen awake, regardless of minimized")
    func idleAndFinishedSleep() {
        for isMinimized in [false, true] {
            #expect(ScreenAwakeController.shouldKeepScreenAwake(state: .idle, isMinimized: isMinimized) == false)
            #expect(ScreenAwakeController.shouldKeepScreenAwake(state: .finished, isMinimized: isMinimized) == false)
        }
    }

    @Test("every other quiz state keeps the screen awake when not minimized")
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
            #expect(
                ScreenAwakeController.shouldKeepScreenAwake(state: state, isMinimized: false) == true,
                "\(state) should keep the screen awake"
            )
        }
    }

    /// Regression: the founder's report was specifically about the RESULT
    /// screen dimming — this must never silently regress back to "asleep".
    @Test("showingResult counts as active")
    func resultScreenStaysAwake() {
        #expect(ScreenAwakeController.shouldKeepScreenAwake(state: makeResultState(), isMinimized: false) == true)
    }

    @Test("minimized always sleeps, even mid-quiz")
    func minimizedAlwaysSleeps() {
        let activeStates: [QuizState] = [.startingQuiz, .askingQuestion, .recording, .processing, .skipping, makeResultState()]
        for state in activeStates {
            #expect(
                ScreenAwakeController.shouldKeepScreenAwake(state: state, isMinimized: true) == false,
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
}
