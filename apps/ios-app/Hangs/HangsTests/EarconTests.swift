//
//  EarconTests.swift
//  HangsTests
//
//  Issue #77 (voice commands hands-free), task 77.10 — the language-neutral
//  earcon set. Injects a `MockEarconPlayer` and asserts that each meaningful
//  event triggers EXACTLY its cue, and that NO cue is emitted while question TTS
//  is playing (the one hard rule for the tone set).
//
//  Seam-to-cue mapping under test:
//    • startRecording()          → .micLive
//    • stopRecordingAndSubmit()  → .gotIt
//    • beginSkipUndoWindow()     → .skipConfirm
//    • handleRecognizedCommand() → .commandAck
//

import Foundation
import Testing
import ConcurrencyExtras
@testable import Hangs

@MainActor
private func makeVM() -> (QuizViewModel, MockEarconPlayer) {
    let vm = QuizViewModel(
        networkService: Fixtures.makeFullMockNetwork(),
        audioService: MockAudioService(),
        persistenceStore: MockPersistenceStore(),
        silenceDetectionService: MockSilenceDetectionService(),
        sttService: nil
    )
    vm.currentSession = Fixtures.makeActiveSession()
    vm.currentQuestion = Fixtures.makeQuestion(id: "q_001")
    let earcon = MockEarconPlayer()
    vm.earconPlayer = earcon
    return (vm, earcon)
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

@Suite("Earcons — one distinct language-neutral cue per event (77.10)")
@MainActor
struct EarconTests {

    // MARK: - Per-event cue

    @Test("opening the mic plays exactly the mic-live cue")
    func micLiveOnRecordingStart() async {
        await withMainSerialExecutor {
            let (vm, earcon) = makeVM()
            vm.quizState = .askingQuestion

            await vm.startRecording()

            #expect(earcon.played == [.micLive], "start recording must play exactly mic-live, got \(earcon.played)")
        }
    }

    @Test("stopping recording plays exactly the got-it (STOP) cue")
    func gotItOnStop() async {
        await withMainSerialExecutor {
            let (vm, earcon) = makeVM()
            vm.quizState = .recording
            vm.isStreamingSTT = false // batch path — no STT service in this VM

            await vm.recordingCoordinator.stopRecordingAndSubmit()

            #expect(earcon.played.first == .gotIt, "stop must play got-it first, got \(earcon.played)")
            #expect(earcon.played == [.gotIt], "stop must play exactly got-it, got \(earcon.played)")
        }
    }

    @Test("opening the skip undo-window plays exactly the skip-confirm cue")
    func skipConfirmOnUndoWindow() async {
        await withMainSerialExecutor {
            let (vm, earcon) = makeVM()
            vm.quizState = .askingQuestion

            vm.voiceCommandCoordinator.beginSkipUndoWindow(duration: 10) // long window: no commit during the assertion

            #expect(earcon.played == [.skipConfirm], "opening the skip window must play exactly skip-confirm, got \(earcon.played)")
        }
    }

    @Test("recognizing a command plays exactly the command-ack cue")
    func commandAckOnRecognition() async {
        await withMainSerialExecutor {
            let (vm, earcon) = makeVM()
            vm.quizState = makeResultState() // result: "next" advances, emits no further cue

            vm.voiceCommandCoordinator.handleRecognizedCommand(.next)

            // command-ack is emitted synchronously; the routed action (advance) emits
            // no earcon, so this is the only cue.
            #expect(earcon.played == [.commandAck], "recognizing a command must play exactly command-ack, got \(earcon.played)")
        }
    }

    // MARK: - No cue during TTS

    @Test("no earcon is emitted while question TTS is playing")
    func noEarconDuringTTS() async {
        await withMainSerialExecutor {
            let (vm, earcon) = makeVM()
            vm.isPlayingQuestionTTS = true

            // Every funnelled cue must be suppressed for the duration of TTS.
            vm.emitEarcon(.micLive)
            vm.emitEarcon(.gotIt)
            vm.emitEarcon(.skipConfirm)
            vm.emitEarcon(.commandAck)

            #expect(earcon.played.isEmpty, "no cue may play during TTS, got \(earcon.played)")
        }
    }

    @Test("recognizing a command during TTS emits no cue")
    func recognitionDuringTTSIsSilent() async {
        await withMainSerialExecutor {
            let (vm, earcon) = makeVM()
            vm.quizState = makeResultState()
            vm.isPlayingQuestionTTS = true

            vm.voiceCommandCoordinator.handleRecognizedCommand(.next)

            #expect(earcon.played.isEmpty, "command-ack must be suppressed during TTS, got \(earcon.played)")
        }
    }

    @Test("cues resume once TTS finishes")
    func cuesResumeAfterTTS() async {
        await withMainSerialExecutor {
            let (vm, earcon) = makeVM()
            vm.isPlayingQuestionTTS = true
            vm.emitEarcon(.commandAck)
            #expect(earcon.played.isEmpty)

            vm.isPlayingQuestionTTS = false
            vm.emitEarcon(.commandAck)
            #expect(earcon.played == [.commandAck], "cue must fire once TTS ends, got \(earcon.played)")
        }
    }

    // MARK: - "Recording sounds" setting (#68)

    /// #68: the Settings toggle must actually silence the recording pair —
    /// otherwise the user-facing switch is a lie. Only mic-live/got-it are
    /// gated; command-ack and skip stay on as driving-safety feedback, so a
    /// driver still hears that a spoken command landed.
    @Test("recording sounds off silences mic-live and got-it but not command cues")
    func recordingSoundsToggleGatesOnlyRecordingPair() async {
        await withMainSerialExecutor {
            let (vm, earcon) = makeVM()
            vm.settings.recordingSoundsEnabled = false

            vm.emitEarcon(.micLive)
            vm.emitEarcon(.gotIt)
            vm.emitEarcon(.commandAck)
            vm.emitEarcon(.skipConfirm)

            #expect(earcon.played == [.commandAck, .skipConfirm],
                    "with recording sounds off only command/skip cues may play, got \(earcon.played)")
        }
    }

    /// #68: default ON — a fresh install keeps the eyes-free mic confirmation
    /// (the original P0 gap this earcon set fixed).
    @Test("recording sounds default on keeps the mic-live cue")
    func recordingSoundsDefaultOn() async {
        await withMainSerialExecutor {
            let (vm, earcon) = makeVM()
            #expect(vm.settings.recordingSoundsEnabled == true)

            vm.emitEarcon(.micLive)

            #expect(earcon.played == [.micLive])
        }
    }
}
