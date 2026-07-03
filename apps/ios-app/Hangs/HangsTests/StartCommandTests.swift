//
//  StartCommandTests.swift
//  HangsTests
//
//  Issue #77 (voice commands hands-free), task 77.8 — the spoken "start" wiring.
//  The Apple recognizer is MOCKED / bypassed: these tests drive
//  `handleRecognizedCommand` directly (the routing seam) so the per-screen START
//  routing is deterministic. Covers:
//    • flag ON  → "start" on askingQuestion opens the mic (startRecording path);
//    • flag OFF → "start" on askingQuestion is inert (button-only START, P4a);
//    • "start" is inert in every other quiz-flow state…
//    • …EXCEPT Home (idle), where it always begins the quiz (separate flag);
//    • NO auto-mic-open: a TTS finish alone never records (P1).
//

import Foundation
import Testing
import ConcurrencyExtras
@testable import Hangs

@MainActor
private func makeStartVM() -> (QuizViewModel, MockAudioService) {
    let audio = MockAudioService()
    let vm = QuizViewModel(
        networkService: Fixtures.makeFullMockNetwork(),
        audioService: audio,
        persistenceStore: MockPersistenceStore(),
        silenceDetectionService: MockSilenceDetectionService(),
        sttService: nil // nil STT → deterministic batch recording path
    )
    vm.currentSession = Fixtures.makeActiveSession()
    vm.currentQuestion = Fixtures.makeQuestion()
    return (vm, audio)
}

@MainActor
private func waitUntil(
    _ predicate: @MainActor () -> Bool,
    timeoutMillis: Int = 5_000,
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

@Suite("Start command — spoken START wiring (77.8)")
@MainActor
struct StartCommandTests {

    @Test("flag ON: 'start' on askingQuestion opens the mic (startRecording)")
    func flagOnStartsRecording() async {
        await withMainSerialExecutor {
            let (vm, audio) = makeStartVM()
            vm.voiceStartOnQuestionEnabled = true
            vm.quizState = .askingQuestion

            vm.handleRecognizedCommand(.start)

            await waitUntil({ vm.quizState == .recording }, "start did not open the mic")
            #expect(vm.quizState == .recording)
            #expect(audio.isRecording == true)
        }
    }

    @Test("flag OFF: 'start' on askingQuestion is inert (button-only START)")
    func flagOffIsInert() async {
        await withMainSerialExecutor {
            let (vm, audio) = makeStartVM()
            vm.voiceStartOnQuestionEnabled = false
            vm.quizState = .askingQuestion

            vm.handleRecognizedCommand(.start)

            // Give any (wrongly) spawned Task a chance to run — it must not.
            for _ in 0..<40 { await Task.yield() }
            #expect(vm.quizState == .askingQuestion, "flag OFF must not open the mic")
            #expect(audio.isRecording == false)
        }
    }

    @Test("flag OFF leaves the REST of the command layer intact (repeat still works)")
    func flagOffKeepsOtherCommands() async {
        await withMainSerialExecutor {
            let (vm, audio) = makeStartVM()
            vm.voiceStartOnQuestionEnabled = false
            vm.quizState = .askingQuestion
            vm.currentQuestionAudioUrl = "https://example.com/q.opus"

            // 'repeat' is a separate question-screen command — unaffected by the
            // start flag. It must still drive the TTS-replay path (durable signal:
            // the question audio was played back).
            vm.handleRecognizedCommand(.repeatQuestion)
            await waitUntil({ audio.playOpusCallCount >= 1 }, "repeat did not replay the question")
            #expect(audio.playOpusCallCount >= 1)
        }
    }

    @Test("'start' is inert in non-Home quiz-flow states")
    func startInertInOtherStates() async {
        await withMainSerialExecutor {
            for state in [QuizState.processing, .startingQuiz, .finished] {
                let (vm, audio) = makeStartVM()
                vm.voiceStartOnQuestionEnabled = true
                vm.quizState = state

                vm.handleRecognizedCommand(.start)

                for _ in 0..<40 { await Task.yield() }
                #expect(vm.quizState == state, "start must be inert in \(state.label)")
                #expect(audio.isRecording == false)
            }
        }
    }

    @Test("Home (idle): 'start' begins the quiz even with the question flag OFF")
    func startOnHomeBeginsQuiz() async {
        await withMainSerialExecutor {
            let (vm, _) = makeStartVM()
            vm.voiceStartOnQuestionEnabled = false // question flag OFF…
            vm.quizState = .idle                   // …still starts the quiz on Home
            #expect(vm.currentCommandScreen == .home)

            vm.handleRecognizedCommand(.start)

            await waitUntil({ vm.quizState != .idle }, "start on Home did not begin the quiz")
            #expect(vm.quizState != .idle)
        }
    }

    @Test("NO auto-mic-open: a TTS finish alone never opens the mic (P1)")
    func noAutoMicOpen() async {
        let (vm, audio) = makeStartVM()
        vm.quizState = .askingQuestion
        vm.settings.autoRecordEnabled = false

        // Simulate the post-TTS decision point. It arms a timer, never records.
        vm.startRecordingOrTimer()

        for _ in 0..<40 { await Task.yield() }
        #expect(vm.quizState == .askingQuestion, "TTS finish must NOT open the mic (P1)")
        #expect(audio.isRecording == false)
    }
}
