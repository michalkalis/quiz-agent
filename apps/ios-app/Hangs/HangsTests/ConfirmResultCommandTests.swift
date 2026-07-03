//
//  ConfirmResultCommandTests.swift
//  HangsTests
//
//  Issue #77 (voice commands hands-free), task 77.9 — the confirm / result / repeat
//  / skip command wiring. Drives `handleRecognizedCommand` directly (routing seam).
//  Covers:
//    • Confirmation sheet: "ok" → confirmAnswer, "again" → rerecordAnswer, "stop" →
//      cancelProcessing — all ON TOP of the untouched 10 s auto-confirm + buttons;
//    • the 10 s auto-confirm still fires with NO speech (regression guard);
//    • Result: "next" advances (auto-advance untouched);
//    • Question: "repeat" replays the question audio + re-arms the listener;
//    • Question: "skip" opens the ~2.5 s undo-window (commit / abort seam).
//

import Foundation
import Testing
import ConcurrencyExtras
@testable import Hangs

@MainActor
private func makeVM() -> (QuizViewModel, MockSilenceDetectionService, MockAudioService) {
    let audio = MockAudioService()
    let silence = MockSilenceDetectionService()
    let vm = QuizViewModel(
        networkService: Fixtures.makeFullMockNetwork(),
        audioService: audio,
        persistenceStore: MockPersistenceStore(),
        silenceDetectionService: silence,
        sttService: nil
    )
    vm.currentSession = Fixtures.makeActiveSession()
    vm.currentQuestion = Fixtures.makeQuestion(id: "q_001")
    return (vm, silence, audio)
}

@MainActor
private func makePendingResponse() -> QuizResponse {
    QuizResponse(
        success: true,
        message: "Answered",
        session: Fixtures.makeQuizSession(id: "test_session_123", phase: "asking"),
        currentQuestion: Fixtures.makeQuestion(id: "q_002", text: "Next?", source: "Next"),
        evaluation: Evaluation(
            userAnswer: "an answer", result: .correct, points: 1.0,
            correctAnswer: "an answer", questionId: "q_001", explanation: nil
        ),
        feedbackReceived: ["answer: correct"],
        audio: nil
    )
}

@MainActor
private func makeResultState() -> QuizState {
    .showingResult(
        question: Fixtures.makeQuestion(id: "q_001"),
        evaluation: Evaluation(
            userAnswer: "x", result: .correct, points: 1.0,
            correctAnswer: "x", questionId: "q_001", explanation: nil
        )
    )
}

@MainActor
private func waitUntil(
    _ predicate: @MainActor () -> Bool,
    timeoutMillis: Int = 6_000,
    _ comment: Comment? = nil,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    let deadline = ContinuousClock.now.advanced(by: .milliseconds(timeoutMillis))
    while ContinuousClock.now < deadline {
        if predicate() { return }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(1))
    }
    if predicate() { return }
    Issue.record(comment ?? "waitUntil timed out after \(timeoutMillis)ms", sourceLocation: sourceLocation)
}

@Suite("Confirm / Result / Repeat / Skip command wiring (77.9)")
@MainActor
struct ConfirmResultCommandTests {

    // MARK: - Confirmation sheet

    @Test("'ok' on the confirmation sheet confirms the answer")
    func okConfirms() async {
        await withMainSerialExecutor {
            let (vm, _, _) = makeVM()
            vm.quizState = .processing
            vm.showAnswerConfirmation = true
            vm.pendingResponse = makePendingResponse()

            vm.handleRecognizedCommand(.ok)

            await waitUntil({ !vm.showAnswerConfirmation }, "ok did not confirm")
            #expect(vm.showAnswerConfirmation == false)
            #expect(vm.pendingResponse == nil, "the pending response was consumed by confirm")
        }
    }

    @Test("'again' on the confirmation sheet re-records")
    func againReRecords() async {
        await withMainSerialExecutor {
            let (vm, _, _) = makeVM()
            vm.quizState = .processing
            vm.showAnswerConfirmation = true
            vm.pendingResponse = makePendingResponse()

            vm.handleRecognizedCommand(.again)

            for _ in 0..<40 { await Task.yield() }
            #expect(vm.showAnswerConfirmation == false)
            #expect(vm.isRerecording == true)
            #expect(vm.quizState == .askingQuestion, "re-record returns to ready-to-record")
        }
    }

    @Test("'stop' on the confirmation sheet cancels processing")
    func stopCancels() async {
        await withMainSerialExecutor {
            let (vm, _, _) = makeVM()
            vm.quizState = .processing
            vm.showAnswerConfirmation = true

            vm.handleRecognizedCommand(.stop)

            for _ in 0..<40 { await Task.yield() }
            #expect(vm.showAnswerConfirmation == false)
            #expect(vm.quizState == .askingQuestion)
        }
    }

    @Test("the 10 s auto-confirm still fires with NO speech (unchanged fallback)")
    func autoConfirmStillFires() async {
        await withMainSerialExecutor {
            let (vm, _, _) = makeVM()
            vm.quizState = .processing
            vm.showAnswerConfirmation = true
            vm.pendingResponse = makePendingResponse()
            vm.settings.autoConfirmEnabled = true

            // No spoken command — the auto-confirm timer alone must confirm.
            vm.startAutoConfirmIfEnabled(duration: 1)

            await waitUntil({ !vm.showAnswerConfirmation }, "auto-confirm did not fire with no speech")
            #expect(vm.showAnswerConfirmation == false)
        }
    }

    // MARK: - Result

    @Test("'next' on the result screen advances")
    func nextAdvances() async {
        await withMainSerialExecutor {
            let (vm, _, _) = makeVM()
            vm.quizState = makeResultState()
            #expect(vm.currentCommandScreen == .result)

            vm.handleRecognizedCommand(.next)

            await waitUntil({ vm.currentCommandScreen != .result }, "next did not advance")
            if case .showingResult = vm.quizState {
                Issue.record("still on the result screen after 'next'")
            }
        }
    }

    @Test("'ok' also advances on the result screen")
    func okAlsoAdvances() async {
        await withMainSerialExecutor {
            let (vm, _, _) = makeVM()
            vm.quizState = makeResultState()

            vm.handleRecognizedCommand(.ok)

            await waitUntil({ vm.currentCommandScreen != .result }, "ok did not advance on result")
            if case .showingResult = vm.quizState {
                Issue.record("still on the result screen after 'ok'")
            }
        }
    }

    // MARK: - Repeat

    @Test("'repeat' on the question screen replays the audio and re-arms the listener")
    func repeatReplaysAndReArms() async {
        await withMainSerialExecutor {
            let (vm, silence, audio) = makeVM()
            vm.quizState = .askingQuestion
            vm.currentQuestionAudioUrl = "https://example.com/q.opus"

            vm.handleRecognizedCommand(.repeatQuestion)

            // Durable signals: the question audio was replayed, and once the replay
            // finished the command listener was re-armed (77.9). isPlayingQuestionTTS
            // is only transiently true, so it's not a reliable assertion target.
            await waitUntil({ audio.playOpusCallCount >= 1 }, "repeat did not replay the question")
            await waitUntil({ !vm.isPlayingQuestionTTS && silence.isListening },
                            "listener was not re-armed after replay")
            #expect(audio.playOpusCallCount >= 1)
            #expect(silence.isListening == true)
        }
    }

    // MARK: - Skip undo-window

    @Test("'skip' on the question screen opens the undo-window (does not commit immediately)")
    func skipOpensUndoWindow() async {
        await withMainSerialExecutor {
            let (vm, _, _) = makeVM()
            vm.quizState = .askingQuestion

            var earconFired = false
            vm.onSkipUndoWindowOpened = { earconFired = true }

            // Use a long window so it can't commit during the assertion.
            vm.beginSkipUndoWindow(duration: 10)

            #expect(vm.pendingSkipWindow != nil, "skip must open an undo-window, not commit")
            #expect(earconFired == true, "the skip-confirm earcon seam must fire on open")
            #expect(vm.quizState == .askingQuestion, "skip must not commit while the window is open")
        }
    }

    @Test("aborting the skip undo-window cancels the pending skip")
    func skipUndoAbort() async {
        await withMainSerialExecutor {
            let (vm, _, _) = makeVM()
            vm.quizState = .askingQuestion
            vm.beginSkipUndoWindow(duration: 10)
            #expect(vm.pendingSkipWindow != nil)

            vm.abortSkipUndoWindow()
            #expect(vm.pendingSkipWindow == nil, "abort must clear the pending skip")
            #expect(vm.quizState == .askingQuestion, "aborted skip never leaves the question")
        }
    }

    @Test("the skip undo-window commits the skip on expiry")
    func skipUndoCommits() async {
        await withMainSerialExecutor {
            let (vm, _, _) = makeVM()
            vm.quizState = .askingQuestion

            // Short window so the commit path runs quickly.
            vm.beginSkipUndoWindow(duration: 0.05)

            // On expiry the window commits via skipQuestion() (→ .skipping then advance).
            await waitUntil({ vm.pendingSkipWindow == nil && vm.quizState != .askingQuestion },
                            "skip did not commit on undo-window expiry")
            #expect(vm.pendingSkipWindow == nil)
            #expect(vm.quizState != .askingQuestion, "expiry must commit the skip")
        }
    }
}
