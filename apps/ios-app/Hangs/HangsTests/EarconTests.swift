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

            await vm.recordingCoordinator.startRecording()

            #expect(earcon.played == [.micLive], "start recording must play exactly mic-live, got \(earcon.played)")
        }
    }

    @Test("stopping recording gives exactly the got-it (STOP) cue, as a haptic only")
    func gotItOnStop() async {
        await withMainSerialExecutor {
            let (vm, earcon) = makeVM()
            vm.quizState = .recording
            vm.isStreamingSTT = false // batch path — no STT service in this VM

            await vm.recordingCoordinator.stopRecordingAndSubmit()

            // #188 G6: only the mic-live cue has a tone; STOP is a tap.
            #expect(earcon.hapticsOnly == [.gotIt], "stop must give exactly got-it, got \(earcon.hapticsOnly)")
            #expect(earcon.played.isEmpty, "stop must make no sound, got \(earcon.played)")
        }
    }

    @Test("opening the skip undo-window gives exactly the skip-confirm cue, as a haptic only")
    func skipConfirmOnUndoWindow() async {
        await withMainSerialExecutor {
            let (vm, earcon) = makeVM()
            vm.quizState = .askingQuestion

            vm.voiceCommandCoordinator.beginSkipUndoWindow(duration: 10) // long window: no commit during the assertion

            #expect(earcon.hapticsOnly == [.skipConfirm], "opening the skip window must give exactly skip-confirm, got \(earcon.hapticsOnly)")
            #expect(earcon.played.isEmpty, "skip-confirm makes no sound (#188 G6), got \(earcon.played)")
        }
    }

    @Test("recognizing a command gives exactly the command-ack cue, as a haptic only")
    func commandAckOnRecognition() async {
        await withMainSerialExecutor {
            let (vm, earcon) = makeVM()
            vm.quizState = makeResultState() // result: "next" advances, emits no further cue

            vm.voiceCommandCoordinator.handleRecognizedCommand(.next)

            // command-ack is emitted synchronously; the routed action (advance) emits
            // no earcon, so this is the only cue.
            #expect(earcon.hapticsOnly == [.commandAck], "recognizing a command must give exactly command-ack, got \(earcon.hapticsOnly)")
            #expect(earcon.played.isEmpty, "command-ack makes no sound (#188 G6), got \(earcon.played)")
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
            vm.emitEarcon(.speechStart)

            #expect(earcon.played.isEmpty, "no cue may play during TTS, got \(earcon.played)")
            #expect(earcon.hapticsOnly.isEmpty, "no tap during TTS either, got \(earcon.hapticsOnly)")
        }
    }

    @Test("recognizing a command during TTS emits no cue")
    func recognitionDuringTTSIsSilent() async {
        await withMainSerialExecutor {
            let (vm, earcon) = makeVM()
            vm.quizState = makeResultState()
            vm.isPlayingQuestionTTS = true

            vm.voiceCommandCoordinator.handleRecognizedCommand(.next)

            #expect(earcon.played.isEmpty && earcon.hapticsOnly.isEmpty,
                    "command-ack must be suppressed during TTS, got \(earcon.played) / \(earcon.hapticsOnly)")
        }
    }

    @Test("cues resume once TTS finishes")
    func cuesResumeAfterTTS() async {
        await withMainSerialExecutor {
            let (vm, earcon) = makeVM()
            vm.isPlayingQuestionTTS = true
            vm.emitEarcon(.micLive)
            #expect(earcon.played.isEmpty)

            vm.isPlayingQuestionTTS = false
            vm.emitEarcon(.micLive)
            #expect(earcon.played == [.micLive], "cue must fire once TTS ends, got \(earcon.played)")
        }
    }

    // MARK: - "Recording sounds" setting (#68)

    /// #188 G6 (founder 2026-10-06, earcons were "really annoying and
    /// frequent"): of all cues only mic-live has a tone, so one answer carries
    /// at most ONE sound. The other four are taps, whatever the setting.
    @Test("only mic-live makes a sound; the other cues are haptic only")
    func onlyMicLiveHasATone() async {
        await withMainSerialExecutor {
            let (vm, earcon) = makeVM()

            for cue in Earcon.allCases { vm.emitEarcon(cue) }

            #expect(earcon.played == [.micLive], "only mic-live may play a tone, got \(earcon.played)")
            #expect(earcon.hapticsOnly == [.speechStart, .gotIt, .skipConfirm, .commandAck])
        }
    }

    /// WHY: the policy lives in one pure rule; a cue added later must opt in to
    /// a tone explicitly, and every cue (tone or not) must still be felt.
    @Test("every cue keeps a haptic; exactly one has a tone")
    func toneRuleAndHaptics() {
        #expect(Earcon.allCases.filter(\.hasTone) == [.micLive])
    }

    /// #68: the Settings toggle must actually silence the one remaining tone —
    /// otherwise the user-facing switch is a lie. The tap stays, so the mic
    /// opening is still felt (founder 2026-09-25).
    @Test("recording sounds off silences the mic-live tone but keeps its haptic")
    func recordingSoundsToggleSilencesMicLiveTone() async {
        await withMainSerialExecutor {
            let (vm, earcon) = makeVM()
            vm.settings.recordingSoundsEnabled = false

            vm.emitEarcon(.micLive)
            vm.emitEarcon(.gotIt)
            vm.emitEarcon(.commandAck)
            vm.emitEarcon(.skipConfirm)

            #expect(earcon.played.isEmpty, "with recording sounds off nothing may sound, got \(earcon.played)")
            #expect(earcon.hapticsOnly == [.micLive, .gotIt, .commandAck, .skipConfirm])
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

    /// WHY (CI "signal abrt", 2026-09-25): a cue's AVAudioPlayer gets
    /// `finishedPlaying:` from AVFoundation after the tone ends — a player
    /// released mid-cue, because the view model that owned it went away,
    /// crashed the process there. Every view model must therefore share the
    /// one process-lifetime player instead of owning its own.
    @Test("every quiz shares the one process-lifetime earcon player")
    func earconPlayerOutlivesItsViewModel() {
        let first = Fixtures.makeViewModel()
        let second = Fixtures.makeViewModel()

        #expect(first.earconPlayer === SystemEarconPlayer.shared)
        #expect(second.earconPlayer === first.earconPlayer)
    }
}
