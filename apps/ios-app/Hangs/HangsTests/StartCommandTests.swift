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

import Clocks
import Foundation
import Testing
import ConcurrencyExtras
@testable import Hangs

/// The routing under test is time-free: a command either opens the mic now or
/// never does. The model still gets a parked `TestClock` (#180 track A) so no
/// production timer — the recording window, the dead-air cap — can fire
/// underneath these assertions while the suite runs under load.
@MainActor
private func makeStartVM() -> (QuizViewModel, MockAudioService) {
    let audio = MockAudioService()
    let vm = QuizViewModel(
        networkService: Fixtures.makeFullMockNetwork(),
        audioService: audio,
        persistenceStore: MockPersistenceStore(),
        silenceDetectionService: MockSilenceDetectionService(),
        sttService: nil, // nil STT → deterministic batch recording path
        clock: AnyClock(TestClock())
    )
    vm.currentSession = Fixtures.makeActiveSession()
    vm.currentQuestion = Fixtures.makeQuestion()
    return (vm, audio)
}

@Suite("Start command — spoken START wiring (77.8)")
@MainActor
struct StartCommandTests {

    @Test("flag ON: 'start' on askingQuestion opens the mic (startRecording)")
    func flagOnStartsRecording() async {
        await withMainSerialExecutor {
            let (vm, audio) = makeStartVM()
            vm.voiceCommandCoordinator.voiceStartOnQuestionEnabled = true
            vm.quizState = .askingQuestion

            vm.voiceCommandCoordinator.handleRecognizedCommand(.start)

            await pumpUntil({ vm.quizState == .recording }, turns: 2000, "start did not open the mic")
            #expect(vm.quizState == .recording)
            #expect(audio.isRecording == true)
        }
    }

    @Test("flag OFF: 'start' on askingQuestion is inert (button-only START)")
    func flagOffIsInert() async {
        await withMainSerialExecutor {
            let (vm, audio) = makeStartVM()
            vm.voiceCommandCoordinator.voiceStartOnQuestionEnabled = false
            vm.quizState = .askingQuestion

            vm.voiceCommandCoordinator.handleRecognizedCommand(.start)

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
            vm.voiceCommandCoordinator.voiceStartOnQuestionEnabled = false
            vm.quizState = .askingQuestion
            vm.recordingCoordinator.currentQuestionAudioUrl = "https://example.com/q.opus"

            // 'repeat' is a separate question-screen command — unaffected by the
            // start flag. It must still drive the TTS-replay path (durable signal:
            // the question audio was played back).
            vm.voiceCommandCoordinator.handleRecognizedCommand(.repeatQuestion)
            await pumpUntil({ audio.playOpusCallCount >= 1 }, turns: 2000, "repeat did not replay the question")
            #expect(audio.playOpusCallCount >= 1)
        }
    }

    @Test("'start' is inert in non-Home quiz-flow states")
    func startInertInOtherStates() async {
        await withMainSerialExecutor {
            for state in [QuizState.processing, .startingQuiz, .finished] {
                let (vm, audio) = makeStartVM()
                vm.voiceCommandCoordinator.voiceStartOnQuestionEnabled = true
                vm.quizState = state

                vm.voiceCommandCoordinator.handleRecognizedCommand(.start)

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
            vm.voiceCommandCoordinator.voiceStartOnQuestionEnabled = false // question flag OFF…
            vm.quizState = .idle                   // …still starts the quiz on Home
            #expect(vm.voiceCommandCoordinator.currentCommandScreen == .home)

            vm.voiceCommandCoordinator.handleRecognizedCommand(.start)

            await pumpUntil({ vm.quizState != .idle }, turns: 2000, "start on Home did not begin the quiz")
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
