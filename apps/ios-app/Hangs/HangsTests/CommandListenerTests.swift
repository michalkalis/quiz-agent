//
//  CommandListenerTests.swift
//  HangsTests
//
//  Issue #77 (voice commands hands-free), task 77.5 — the windowed native-English
//  command listener. The Apple recognizer is MOCKED throughout (SpeechAnalyzer's
//  supportedLocales is empty on the Simulator and SpeechDetector is iOS 26+, so
//  the real recognizer can never run headlessly): MockSilenceDetectionService
//  stands in for the transcript source, and these tests exercise the VIEW-MODEL
//  window + consumer + defensive-fallback logic that rides on top of it.
//
//  Coverage:
//    • the window: which screen (if any) listens, per quizState + TTS + recording;
//    • NO arming during TTS or recording;
//    • the consumer: a transcript routes through the screen-scoped
//      matcher and fires onCommandRecognized (screen scoping enforced);
//    • #110 volatile results: at most ONE command per utterance, destructive
//      commands only from a final result, a volatile having to be proven
//      STOPPED GROWING before it may fire (so a growing sentence's one-word
//      prefix can't) — via EITHER an unchanged re-delivery or the settle timer,
//      the same-command cooldown, and the window being closed during feedback
//      TTS as well as question TTS;
//    • the defensive degrade: a failed recognizer setup / a nil service leaves the
//      manual mic-button flow working, no crash.
//

import ConcurrencyExtras
import Foundation
@testable import Hangs
import Testing

@MainActor
private func makeCommandVM(
    silence: MockSilenceDetectionService = MockSilenceDetectionService(),
    stt: MockElevenLabsSTTService? = nil
) -> (QuizViewModel, MockSilenceDetectionService, MockAudioService) {
    let audio = MockAudioService()
    let vm = QuizViewModel(
        networkService: Fixtures.makeFullMockNetwork(),
        audioService: audio,
        persistenceStore: MockPersistenceStore(),
        silenceDetectionService: silence,
        sttService: stt
    )
    vm.currentSession = Fixtures.makeActiveSession()
    vm.currentQuestion = Fixtures.makeQuestion()
    return (vm, silence, audio)
}

/// Spin the main serial executor until `predicate` holds or the deadline passes.
/// Used to pump the AsyncStream → consumer-task → @MainActor handler hops.
@MainActor
private func waitUntil(
    _ predicate: @MainActor () -> Bool,
    timeoutMillis: Int = 5000,
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

/// Driven clock for the command cooldown (#110). A reference box so the test can
/// move "now" forward without a real `Task.sleep` — the repo's three flaky async
/// voice tests all came from sleeping in tests.
@MainActor
private final class TestClock {
    var now: Date
    init(_ now: Date) { self.now = now }
}

@MainActor
private func makeResultState() -> QuizState {
    .showingResult(
        question: Fixtures.makeQuestion(),
        evaluation: Evaluation(
            userAnswer: "x", result: .correct, points: 1.0,
            correctAnswer: "x", questionId: "q_001", explanation: nil
        )
    )
}

@Suite("Command listener — window + consumer + defensive fallback")
@MainActor
struct CommandListenerTests {
    // MARK: - Window mapping

    @Test("currentCommandScreen maps each listening state, nil elsewhere")
    func windowMapping() {
        let (vm, _, _) = makeCommandVM()

        vm.quizState = .idle
        #expect(vm.voiceCommandCoordinator.currentCommandScreen == .home)

        vm.quizState = .askingQuestion
        #expect(vm.voiceCommandCoordinator.currentCommandScreen == .question)

        vm.quizState = .processing
        #expect(vm.voiceCommandCoordinator.currentCommandScreen == .confirmation)

        vm.quizState = makeResultState()
        #expect(vm.voiceCommandCoordinator.currentCommandScreen == .result)

        // Non-listening states → nil (never armed).
        vm.quizState = .recording
        #expect(vm.voiceCommandCoordinator.currentCommandScreen == nil)
        vm.quizState = .startingQuiz
        #expect(vm.voiceCommandCoordinator.currentCommandScreen == nil)
        vm.quizState = .finished
        #expect(vm.voiceCommandCoordinator.currentCommandScreen == nil)
    }

    @Test("the window is CLOSED during question TTS (self-trigger guard)")
    func windowClosedDuringTTS() {
        let (vm, _, _) = makeCommandVM()
        vm.quizState = .askingQuestion
        #expect(vm.voiceCommandCoordinator.currentCommandScreen == .question)

        vm.isPlayingQuestionTTS = true
        #expect(vm.voiceCommandCoordinator.currentCommandScreen == nil, "listener must be torn down while TTS plays")

        vm.isPlayingQuestionTTS = false
        #expect(vm.voiceCommandCoordinator.currentCommandScreen == .question)
    }

    // MARK: - Arm / tear-down per state

    @Test("syncCommandListenerWindow arms on a listening screen and tears down otherwise")
    func syncArmsAndTearsDown() async {
        let (vm, silence, _) = makeCommandVM()
        let mock = silence

        vm.quizState = .askingQuestion
        await vm.voiceCommandCoordinator.syncCommandListenerWindow()
        #expect(mock.isListening == true)

        // Recording → torn down (NEVER armed during recording).
        vm.quizState = .recording
        await vm.voiceCommandCoordinator.syncCommandListenerWindow()
        #expect(mock.isListening == false)

        // Result → armed again.
        vm.quizState = makeResultState()
        await vm.voiceCommandCoordinator.syncCommandListenerWindow()
        #expect(mock.isListening == true)
    }

    @Test("syncCommandListenerWindow does NOT arm during TTS")
    func noArmDuringTTS() async {
        let (vm, silence, _) = makeCommandVM()
        let mock = silence

        vm.quizState = .askingQuestion
        vm.isPlayingQuestionTTS = true
        await vm.voiceCommandCoordinator.syncCommandListenerWindow()
        #expect(mock.isListening == false, "listener must stay down while TTS is playing")
    }

    @Test("entering .recording tears down the listener (never both mic-command + answer)")
    func recordingTearsDownListener() async {
        let (vm, silence, _) = makeCommandVM()
        let mock = silence

        vm.quizState = .askingQuestion
        await vm.audioDeviceState.startSilenceDetectionListening()
        #expect(mock.isListening == true)

        // Simulate the answer window opening.
        vm.quizState = .recording
        await vm.voiceCommandCoordinator.syncCommandListenerWindow()
        #expect(mock.isListening == false)
    }

    // MARK: - Consumer routing (screen-scoped)

    @Test("a finalized transcript routes through the matcher and fires the recognition hook")
    func consumerRoutesRecognizedCommand() async {
        await withMainSerialExecutor {
            let (vm, silence, _) = makeCommandVM()
            let mock = silence

            var recognized: [VoiceCommand] = []
            vm.voiceCommandCoordinator.onCommandRecognized = { recognized.append($0) }

            vm.quizState = .askingQuestion
            await vm.audioDeviceState.startSilenceDetectionListening() // arms the consumer

            mock.simulateCommandTranscript("start")
            await waitUntil({ !recognized.isEmpty }, "no command recognized")

            #expect(recognized == [.start])
        }
    }

    @Test("screen scoping: 'next' is inert on the question screen, valid on result")
    func consumerScreenScoping() async {
        await withMainSerialExecutor {
            let (vm, silence, _) = makeCommandVM()
            let mock = silence

            var recognized: [VoiceCommand] = []
            vm.voiceCommandCoordinator.onCommandRecognized = { recognized.append($0) }

            // "next" is NOT a question-screen command → dropped.
            vm.quizState = .askingQuestion
            await vm.audioDeviceState.startSilenceDetectionListening()
            mock.simulateCommandTranscript("next")
            // Give the consumer a chance to (not) fire.
            for _ in 0 ..< 20 {
                await Task.yield()
            }
            #expect(recognized.isEmpty, "‘next’ must not match on the question screen")

            // On the result screen, "next" matches.
            vm.quizState = makeResultState()
            mock.simulateCommandTranscript("next")
            await waitUntil({ !recognized.isEmpty }, "‘next’ never matched on result")
            #expect(recognized == [.next])
        }
    }

    @Test("a non-command transcript produces no recognition")
    func consumerIgnoresNonCommand() async {
        await withMainSerialExecutor {
            let (vm, silence, _) = makeCommandVM()
            let mock = silence

            var recognized: [VoiceCommand] = []
            vm.voiceCommandCoordinator.onCommandRecognized = { recognized.append($0) }

            vm.quizState = .askingQuestion
            await vm.audioDeviceState.startSilenceDetectionListening()
            mock.simulateCommandTranscript("what is the capital of france")
            for _ in 0 ..< 20 {
                await Task.yield()
            }
            #expect(recognized.isEmpty)
        }
    }

    @Test("startCommandConsumer drives the capture phase idle → listening; stop resets to idle")
    func consumerDrivesCapturePhase() async {
        let (vm, _, _) = makeCommandVM()
        #expect(vm.voiceCommandCoordinator.commandCapturePhase == .idle)

        vm.quizState = .askingQuestion
        await vm.audioDeviceState.startSilenceDetectionListening()
        #expect(vm.voiceCommandCoordinator.commandCapturePhase == .listening)

        vm.audioDeviceState.stopSilenceDetectionListening()
        #expect(vm.voiceCommandCoordinator.commandCapturePhase == .idle)
    }

    // MARK: - Volatile results: one command per utterance (#110)

    /// WHY: the transcriber now reports a GROWING volatile hypothesis several
    /// times per utterance (the build-33 latency fix — waiting for the
    /// end-of-speech endpoint meant the first "start" never fired). Field data
    /// shows the founder repeating himself when nothing responds
    /// ("start start start start start"), so firing per hypothesis would run the
    /// action once per repeat.
    @Test("a repeated volatile 'start' fires once; later transcripts of the same utterance do not")
    func volatileFiresOncePerUtterance() async {
        await withMainSerialExecutor {
            let (vm, silence, _) = makeCommandVM()
            let mock = silence

            var recognized: [VoiceCommand] = []
            vm.voiceCommandCoordinator.onCommandRecognized = { recognized.append($0) }

            // Routing is deliberately inert (the P4a flag is off) so the screen
            // never changes: the ONLY thing that can stop the 2nd/3rd fire is
            // the utterance latch.
            vm.voiceCommandCoordinator.voiceStartOnQuestionEnabled = false
            // Isolate the REPEAT signal: with the settle fallback parked out of
            // reach, the only thing that can fire below is a re-delivery. The
            // settle path has its own tests (`lonelyVolatileFiresViaSettle` …).
            vm.voiceCommandCoordinator.volatileSettleDelay = 3600
            vm.quizState = .askingQuestion
            await vm.audioDeviceState.startSilenceDetectionListening() // arms the consumer

            mock.simulateCommandTranscript("start", isFinal: false)
            for _ in 0 ..< 20 {
                await Task.yield()
            }
            #expect(recognized.isEmpty, "an unproven first hypothesis must not fire — every sentence has a prefix")

            // Re-emitted unchanged while he is silent: THAT is what proves it was
            // a one-word command, and it still lands long before the end-of-speech
            // endpoint — the latency fix survives the stability gate.
            mock.simulateCommandTranscript("start", isFinal: false)
            await waitUntil({ !recognized.isEmpty }, "a repeated volatile hypothesis must fire")

            // The hypothesis keeps growing as he repeats himself, then finalizes.
            mock.simulateCommandTranscript("start start", isFinal: false)
            mock.simulateCommandTranscript("start start start", isFinal: true)
            for _ in 0 ..< 40 {
                await Task.yield()
            }

            #expect(recognized == [.start], "one utterance = at most one command, got \(recognized)")
        }
    }

    /// WHY (#110, the hole the content-token cap structurally cannot see): the
    /// cap is evaluated on ONE delivered transcript, but the transcriber emits a
    /// GROWING hypothesis — so every utterance passes through a 1-token prefix
    /// state and the cap is a no-op on the leading edge of ALL speech. Without a
    /// stability gate, "Okay, tak to bolo dobré" from the passenger advances the
    /// quiz from its first half-second, and a radio "Starting now…" starts one. A
    /// sentence never presents the same hypothesis twice — it keeps growing.
    @Test("a growing sentence's one-word prefix never fires")
    func growingSentencePrefixDoesNotFire() async {
        await withMainSerialExecutor {
            let (vm, _, _) = makeCommandVM()
            let coordinator = vm.voiceCommandCoordinator
            // Isolate the REPEAT signal (see volatileFiresOncePerUtterance); the
            // settle fallback's own supersede path is
            // `okayPrefixOnResultCancelsPendingSettle`.
            coordinator.volatileSettleDelay = 3600
            vm.quizState = makeResultState()

            var recognized: [VoiceCommand] = []
            coordinator.onCommandRecognized = { recognized.append($0) }

            for hypothesis in ["okay", "okay tak", "okay tak to", "okay tak to bolo dobre"] {
                await coordinator.handleCommandTranscript(CommandTranscript(text: hypothesis, isFinal: false))
            }
            await coordinator.handleCommandTranscript(
                CommandTranscript(text: "okay tak to bolo dobre", isFinal: true)
            )

            #expect(recognized.isEmpty, "conversational speech must not advance the quiz, got \(recognized)")
        }
    }

    /// WHY: a volatile hypothesis is revisable — the transcriber may replace it
    /// as more audio arrives — and a skip burns one of the 100 free questions a
    /// month. Destructive commands must wait for the final result.
    @Test("'skip' fires only from a final result, never from a volatile hypothesis")
    func skipRequiresFinalResult() async {
        await withMainSerialExecutor {
            let (vm, _, _) = makeCommandVM()
            let coordinator = vm.voiceCommandCoordinator
            vm.quizState = .askingQuestion

            var recognized: [VoiceCommand] = []
            coordinator.onCommandRecognized = { recognized.append($0) }

            await coordinator.handleCommandTranscript(CommandTranscript(text: "skip", isFinal: false))
            #expect(recognized.isEmpty, "a revisable hypothesis must never burn a question")
            #expect(coordinator.pendingSkipWindow == nil)

            await coordinator.handleCommandTranscript(CommandTranscript(text: "skip", isFinal: true))
            #expect(recognized == [.skip], "the final result commits the skip")
            #expect(coordinator.pendingSkipWindow != nil, "…via the 2.5 s undo-window")

            coordinator.abortSkipUndoWindow() // don't let the window commit after the test
        }
    }

    /// WHY: both discard an answer irreversibly — `again` throws away the
    /// transcribed answer, `stop` cancels the in-flight evaluation — so neither
    /// may act on a hypothesis the transcriber can still revise. (`ok` on this
    /// sheet is held to the same rule, for the opposite reason — see
    /// `okRequiresFinalOnConfirmationOnly`.)
    @Test("volatile 'again' / 'stop' on the confirmation sheet do not fire; finals do")
    func destructiveConfirmationCommandsRequireFinal() async {
        await withMainSerialExecutor {
            for (text, expected) in [("again", VoiceCommand.again), ("stop", VoiceCommand.stop)] {
                let (vm, _, _) = makeCommandVM()
                let coordinator = vm.voiceCommandCoordinator
                vm.quizState = .processing // the confirmation sheet

                var recognized: [VoiceCommand] = []
                coordinator.onCommandRecognized = { recognized.append($0) }

                await coordinator.handleCommandTranscript(CommandTranscript(text: text, isFinal: false))
                #expect(recognized.isEmpty, "'\(text)' must not discard an answer from a revisable hypothesis")

                await coordinator.handleCommandTranscript(CommandTranscript(text: text, isFinal: true))
                #expect(recognized == [expected], "'\(text)' must still work on the final result")
            }
        }
    }

    /// WHY: within ONE utterance an early hypothesis can resolve to one command
    /// and a later one to another — on the question screen that would open the
    /// mic and then burn the question. The first command wins and the utterance
    /// is closed to the rest.
    @Test("two different commands resolved from one utterance fire at most once")
    func twoCommandsInOneUtteranceFireOnce() async {
        await withMainSerialExecutor {
            let (vm, _, _) = makeCommandVM()
            let coordinator = vm.voiceCommandCoordinator
            // Inert routing (see volatileFiresOncePerUtterance) so the screen stays open.
            coordinator.voiceStartOnQuestionEnabled = false
            vm.quizState = .askingQuestion

            var recognized: [VoiceCommand] = []
            coordinator.onCommandRecognized = { recognized.append($0) }

            // Same hypothesis twice → proven, so the benign `start` fires.
            await coordinator.handleCommandTranscript(CommandTranscript(text: "start", isFinal: false))
            await coordinator.handleCommandTranscript(CommandTranscript(text: "start", isFinal: false))
            #expect(recognized == [.start])
            #expect(coordinator.commandFiredThisUtterance, "the latch is what must block what follows")

            await coordinator.handleCommandTranscript(CommandTranscript(text: "skip", isFinal: true))

            #expect(recognized == [.start], "the same utterance must not also burn the question, got \(recognized)")
            #expect(coordinator.pendingSkipWindow == nil)
        }
    }

    /// WHY (#110): `ok` on the confirmation sheet SUBMITS the answer. The 10 s
    /// auto-confirm does NOT make that benign — that timer exists precisely so a
    /// wrong transcription can be caught with "again", and firing `ok` from a
    /// revisable hypothesis removes the escape before the founder can use it.
    /// "okay" is the highest-frequency backchannel in conversation, and `again`
    /// (the escape) waits for a final, so ambient speech would otherwise race
    /// the correction and win. On the RESULT screen `ok` stays benign: advancing
    /// is the default outcome there anyway.
    @Test("'ok' requires a final on the confirmation sheet, but not on the result")
    func okRequiresFinalOnConfirmationOnly() async {
        await withMainSerialExecutor {
            let (vm, _, _) = makeCommandVM()
            let coordinator = vm.voiceCommandCoordinator
            vm.quizState = .processing // the confirmation sheet

            var recognized: [VoiceCommand] = []
            coordinator.onCommandRecognized = { recognized.append($0) }

            // Even a STABLE volatile (delivered twice unchanged) must not submit.
            await coordinator.handleCommandTranscript(CommandTranscript(text: "okay", isFinal: false))
            await coordinator.handleCommandTranscript(CommandTranscript(text: "okay", isFinal: false))
            #expect(recognized.isEmpty, "a revisable hypothesis must not submit the answer")

            await coordinator.handleCommandTranscript(CommandTranscript(text: "okay", isFinal: true))
            #expect(recognized == [.ok], "the final still confirms")

            // The result screen keeps the low-latency volatile path.
            let (resultVM, _, _) = makeCommandVM()
            let resultCoordinator = resultVM.voiceCommandCoordinator
            resultVM.quizState = makeResultState()
            var advanced: [VoiceCommand] = []
            resultCoordinator.onCommandRecognized = { advanced.append($0) }

            await resultCoordinator.handleCommandTranscript(CommandTranscript(text: "okay", isFinal: false))
            await resultCoordinator.handleCommandTranscript(CommandTranscript(text: "okay", isFinal: false))
            #expect(advanced == [.ok], "advancing early is the default outcome — no reason to wait")
        }
    }

    /// WHY: one spoken word can arrive as two utterances (he repeats himself
    /// when nothing seems to happen), which the per-utterance latch cannot see.
    /// The cooldown is the second layer. Driven clock — no `Task.sleep`.
    @Test("the cooldown suppresses a same-command repeat inside the window and allows it after")
    func cooldownSuppressesSameCommandRepeat() async {
        await withMainSerialExecutor {
            let (vm, _, _) = makeCommandVM()
            let coordinator = vm.voiceCommandCoordinator
            let clock = TestClock(Date())
            let base = clock.now
            coordinator.now = { clock.now }

            // Inert routing (see volatileFiresOncePerUtterance) so the screen stays open.
            coordinator.voiceStartOnQuestionEnabled = false
            vm.quizState = .askingQuestion

            var recognized: [VoiceCommand] = []
            coordinator.onCommandRecognized = { recognized.append($0) }

            await coordinator.handleCommandTranscript(CommandTranscript(text: "start", isFinal: true))
            #expect(recognized == [.start])

            clock.now = base.addingTimeInterval(0.5) // still inside the cooldown
            await coordinator.handleCommandTranscript(CommandTranscript(text: "start", isFinal: true))
            #expect(recognized == [.start], "a repeat inside the cooldown must not fire twice, got \(recognized)")

            clock.now = base.addingTimeInterval(VoiceCommandCoordinator.commandCooldown + 0.1)
            await coordinator.handleCommandTranscript(CommandTranscript(text: "start", isFinal: true))
            #expect(recognized == [.start, .start], "after the cooldown the command must work again")
        }
    }

    /// WHY: the cooldown must not be re-litigated after a delay. `.awaitingStable`
    /// PARKS a hypothesis and `fireSettledVolatile` re-runs the whole gate
    /// `volatileSettleDelay` later — by which time the cooldown can have expired.
    /// Gated in the wrong order, a first-delivery volatile arriving inside the
    /// cooldown is parked instead of rejected and then fires late, converting
    /// cooldown-suppressed repeats into fires for exactly the command he repeats
    /// most when nothing responds ("start start start …"). So the assertion is
    /// that nothing is parked at all, not merely that nothing fired now.
    @Test("a volatile arriving inside the cooldown is rejected outright, not parked for the settle")
    func cooldownRejectsVolatileRatherThanParkingIt() async {
        await withMainSerialExecutor {
            let (vm, _, _) = makeCommandVM()
            let coordinator = vm.voiceCommandCoordinator
            let clock = TestClock(Date())
            let base = clock.now
            coordinator.now = { clock.now }

            // Inert routing (see volatileFiresOncePerUtterance) so the screen stays open.
            coordinator.voiceStartOnQuestionEnabled = false
            vm.quizState = .askingQuestion

            var recognized: [VoiceCommand] = []
            coordinator.onCommandRecognized = { recognized.append($0) }

            // A FINAL seeds the cooldown and ends the utterance, so the latch is
            // not what suppresses the volatile below — the cooldown is.
            await coordinator.handleCommandTranscript(CommandTranscript(text: "start", isFinal: true))
            #expect(recognized == [.start])

            clock.now = base.addingTimeInterval(0.5) // still inside the cooldown
            await coordinator.handleCommandTranscript(CommandTranscript(text: "start", isFinal: false))
            #expect(coordinator.pendingVolatileSettle == nil,
                    "a cooldown-suppressed volatile must not be parked for later re-evaluation")
            #expect(coordinator.taskBag.contains(.volatileSettle) == false, "…and must arm no timer")

            // The consequence, made executable: once the cooldown has expired
            // there is nothing left that could fire, because nothing was parked.
            clock.now = base.addingTimeInterval(VoiceCommandCoordinator.commandCooldown + 0.1)
            coordinator.fireSettledVolatile()
            #expect(recognized == [.start],
                    "the cooldown must not be re-litigated after a delay, got \(recognized)")
        }
    }

    // MARK: - Volatile results: the settle fallback (second stability signal)

    /// WHY: this is the entire point of turning volatile results on. The repeat
    /// signal is NOT contractual — Apple emits a volatile when the hypothesis
    /// CHANGES, so a one-word command followed by silence can be delivered
    /// exactly once and then never again until the end-of-speech final. If a
    /// lone delivery cannot fire, the founder is back to waiting for the end of
    /// speech — the build-33 bug (he says "start" seven times, each repeat
    /// EXTENDING the segment and pushing finalization past the window).
    @Test("a single volatile 'start' that is never repeated still fires, via the settle delay")
    func lonelyVolatileFiresViaSettle() async {
        await withMainSerialExecutor {
            let (vm, _, _) = makeCommandVM()
            let coordinator = vm.voiceCommandCoordinator
            coordinator.volatileSettleDelay = 0 // driven to negligible — never a wall-clock race
            // Inert routing (see volatileFiresOncePerUtterance) so the screen stays open.
            coordinator.voiceStartOnQuestionEnabled = false
            vm.quizState = .askingQuestion

            var recognized: [VoiceCommand] = []
            coordinator.onCommandRecognized = { recognized.append($0) }

            await coordinator.handleCommandTranscript(CommandTranscript(text: "start", isFinal: false))
            #expect(coordinator.pendingVolatileSettle?.command == .start,
                    "an unproven volatile must be PARKED for the settle, not dropped")

            await waitUntil({ !recognized.isEmpty }, "the settle timer never fired the parked command")
            #expect(recognized == [.start])
            #expect(coordinator.pendingVolatileSettle == nil, "a fired settle must not stay armed")
        }
    }

    /// WHY: the settle fallback must not re-open the growing-hypothesis hole it
    /// sits next to. "Start telling me about…" reaches the consumer first as the
    /// bare volatile "start"; the very next, longer hypothesis is proof the
    /// sentence is still growing and must kill the parked command. The assertion
    /// is that the settle is GONE — not that a timer happened to lose a race.
    @Test("a volatile 'start' superseded by a longer hypothesis never fires")
    func growingHypothesisCancelsPendingSettle() async {
        await withMainSerialExecutor {
            let (vm, _, _) = makeCommandVM()
            let coordinator = vm.voiceCommandCoordinator
            coordinator.voiceStartOnQuestionEnabled = false
            vm.quizState = .askingQuestion

            var recognized: [VoiceCommand] = []
            coordinator.onCommandRecognized = { recognized.append($0) }

            await coordinator.handleCommandTranscript(CommandTranscript(text: "start", isFinal: false))
            #expect(coordinator.pendingVolatileSettle?.command == .start)

            await coordinator.handleCommandTranscript(
                CommandTranscript(text: "start telling me about", isFinal: false)
            )
            #expect(coordinator.pendingVolatileSettle == nil, "a growing sentence must supersede the parked command")
            #expect(coordinator.taskBag.contains(.volatileSettle) == false, "…and cancel its timer")

            coordinator.fireSettledVolatile() // even a timer that somehow ran must be inert
            #expect(recognized.isEmpty, "a sentence prefix must never fire, got \(recognized)")
        }
    }

    /// WHY: on the result screen `ok` fires from a volatile (advancing is the
    /// default outcome), which is exactly what makes the passenger's "Okay, tak
    /// to bolo dobré" dangerous — it arrives as the volatile "okay" and would
    /// advance past the answer the founder is still listening to.
    @Test("a volatile 'okay' superseded by 'okay tak to bolo dobre' does not advance the result")
    func okayPrefixOnResultCancelsPendingSettle() async {
        await withMainSerialExecutor {
            let (vm, _, _) = makeCommandVM()
            let coordinator = vm.voiceCommandCoordinator
            vm.quizState = makeResultState()

            var recognized: [VoiceCommand] = []
            coordinator.onCommandRecognized = { recognized.append($0) }

            await coordinator.handleCommandTranscript(CommandTranscript(text: "okay", isFinal: false))
            #expect(coordinator.pendingVolatileSettle?.command == .ok,
                    "the low-latency path IS live for 'okay' here — which is why it needs superseding")

            await coordinator.handleCommandTranscript(
                CommandTranscript(text: "okay tak to bolo dobre", isFinal: false)
            )
            #expect(coordinator.pendingVolatileSettle == nil)

            coordinator.fireSettledVolatile()
            #expect(recognized.isEmpty, "conversational speech must not advance the quiz, got \(recognized)")
        }
    }

    /// WHY: the settle fallback must not become the slow path for everyone. When
    /// the transcriber DOES re-deliver an unchanged hypothesis, that is proof in
    /// hand and the command fires on the spot. The delay is parked out of reach
    /// here, so a fire can only have come from the repeat signal.
    @Test("the repeat signal fires immediately, without waiting out the settle delay")
    func repeatSignalDoesNotWaitForSettle() async {
        await withMainSerialExecutor {
            let (vm, _, _) = makeCommandVM()
            let coordinator = vm.voiceCommandCoordinator
            coordinator.volatileSettleDelay = 3600
            coordinator.voiceStartOnQuestionEnabled = false
            vm.quizState = .askingQuestion

            var recognized: [VoiceCommand] = []
            coordinator.onCommandRecognized = { recognized.append($0) }

            await coordinator.handleCommandTranscript(CommandTranscript(text: "start", isFinal: false))
            #expect(recognized.isEmpty, "one delivery is not yet proof")

            await coordinator.handleCommandTranscript(CommandTranscript(text: "start", isFinal: false))
            #expect(recognized == [.start], "an unchanged re-delivery must fire without any delay")
            #expect(coordinator.pendingVolatileSettle == nil, "and must leave no settle armed behind it")
        }
    }

    /// WHY: once the final arrives it is strictly better evidence than the
    /// hypothesis we parked, and it makes its own decision (destructive commands
    /// are allowed only there). A settle surviving the final would fire a SECOND
    /// command for one utterance and break the at-most-one invariant that makes
    /// volatile results safe at all.
    @Test("a final result cancels the pending settle and its own decision is what applies")
    func finalCancelsPendingSettle() async {
        await withMainSerialExecutor {
            let (vm, _, _) = makeCommandVM()
            let coordinator = vm.voiceCommandCoordinator
            coordinator.volatileSettleDelay = 3600
            vm.quizState = makeResultState()

            var recognized: [VoiceCommand] = []
            coordinator.onCommandRecognized = { recognized.append($0) }

            await coordinator.handleCommandTranscript(CommandTranscript(text: "okay", isFinal: false))
            #expect(coordinator.pendingVolatileSettle?.command == .ok)

            await coordinator.handleCommandTranscript(CommandTranscript(text: "okay", isFinal: true))
            #expect(recognized == [.ok], "the final decides")
            #expect(coordinator.pendingVolatileSettle == nil)
            #expect(coordinator.taskBag.contains(.volatileSettle) == false)

            coordinator.fireSettledVolatile()
            #expect(recognized == [.ok], "one utterance = at most one command, got \(recognized)")
        }
    }

    /// WHY: the settle is the ONE path that can outlive the transcript that
    /// armed it, so it has to die with its utterance and with its listener. A
    /// command firing after the founder stopped talking — or after the window
    /// closed and the consumer was torn down — acts on a screen that has moved on.
    @Test("a pending settle is cancelled when the utterance ends and when the consumer stops")
    func pendingSettleDiesWithItsUtteranceAndListener() async {
        await withMainSerialExecutor {
            let (vm, _, _) = makeCommandVM()
            let coordinator = vm.voiceCommandCoordinator
            coordinator.volatileSettleDelay = 3600
            coordinator.voiceStartOnQuestionEnabled = false
            vm.quizState = .askingQuestion

            var recognized: [VoiceCommand] = []
            coordinator.onCommandRecognized = { recognized.append($0) }

            // (1) the utterance ends under a parked command.
            await coordinator.handleCommandTranscript(CommandTranscript(text: "start", isFinal: false))
            #expect(coordinator.pendingVolatileSettle != nil)
            coordinator.endUtterance()
            #expect(coordinator.pendingVolatileSettle == nil, "no settle outlives its utterance")
            #expect(coordinator.taskBag.contains(.volatileSettle) == false)

            // (2) the consumer is torn down under a parked command (window closed).
            await coordinator.handleCommandTranscript(CommandTranscript(text: "start", isFinal: false))
            #expect(coordinator.pendingVolatileSettle != nil)
            coordinator.stopCommandConsumer()
            #expect(coordinator.pendingVolatileSettle == nil, "no settle outlives its listener")

            coordinator.fireSettledVolatile()
            #expect(recognized.isEmpty, "nothing may fire once the utterance/listener is gone, got \(recognized)")
        }
    }

    // MARK: - Emission-cadence telemetry (what replaces the volatileSettleDelay guess)

    /// WHY: `volatileSettleDelay`'s lower bound is the transcriber's interval
    /// between consecutive volatile hypotheses — if the settle is shorter than
    /// that interval, a growing sentence's prefix fires before the next
    /// hypothesis can supersede it. That interval has been measured off-device
    /// only (the real recognizer cannot run on the Simulator at all, see the file
    /// header), so `sincePrevMs` in the field logs is the only way it is
    /// confirmed on iPhone. It must report `nil` for an utterance's first
    /// transcript: the gap
    /// there is the founder's thinking time since the last utterance, and folding
    /// that into the cadence would make us tune the settle on a number that has
    /// nothing to do with the transcriber.
    @Test("the inter-transcript interval is absent on an utterance's first transcript and measured after")
    func transcriptIntervalIsNilOnFirstThenMeasured() async {
        let (vm, _, _) = makeCommandVM()
        let coordinator = vm.voiceCommandCoordinator
        let clock = TestClock(Date())
        let base = clock.now
        coordinator.now = { clock.now }

        #expect(coordinator.noteTranscriptArrival() == nil,
                "the first transcript of an utterance has no interval to report")

        clock.now = base.addingTimeInterval(0.42)
        #expect(coordinator.noteTranscriptArrival() == 420,
                "the second must report the measured gap — this is the cadence the settle is tuned against")

        // A final ends the utterance, so the NEXT utterance starts over: the
        // silence between two utterances must never be reported as cadence.
        coordinator.endUtterance()
        clock.now = base.addingTimeInterval(9.0)
        #expect(coordinator.noteTranscriptArrival() == nil,
                "an utterance boundary must reset the clock, not report the 9 s pause as an interval")
    }

    /// WHY: the cadence must describe what the TRANSCRIBER emitted, not the
    /// subset that happened to match a command. The growing hypotheses that
    /// supersede a parked prefix are mostly UNMATCHED ("start telling me
    /// about…"), so stamping only on matches would measure the rare case and
    /// leave the settle tuned on a cadence that never occurs in real speech.
    @Test("the interval clock is stamped for transcripts the matcher rejects too")
    func transcriptIntervalCoversUnmatchedTranscripts() async {
        await withMainSerialExecutor {
            let (vm, _, _) = makeCommandVM()
            let coordinator = vm.voiceCommandCoordinator
            vm.quizState = .askingQuestion

            await coordinator.handleCommandTranscript(
                CommandTranscript(text: "tak to bolo dobre", isFinal: false)
            )
            #expect(coordinator.lastTranscriptAt != nil,
                    "an unmatched hypothesis still advances the emission clock")
        }
    }

    // MARK: - Window closed during ANY TTS (#110 root cause #3)

    /// WHY: `handleAnswerResponse` transitions to `.showingResult`, arms the
    /// command window and only THEN plays feedback TTS — so the recognizer was
    /// transcribing the app's own voice. The build-33 field transcripts
    /// "you said proud answer proud" and "he is proud of you" are exactly that.
    @Test("the window is CLOSED while feedback TTS plays and a transcript is dropped")
    func windowClosedDuringFeedbackTTS() async {
        await withMainSerialExecutor {
            let (vm, _, _) = makeCommandVM()
            vm.quizState = makeResultState()
            #expect(vm.voiceCommandCoordinator.currentCommandScreen == .result)

            var recognized: [VoiceCommand] = []
            vm.voiceCommandCoordinator.onCommandRecognized = { recognized.append($0) }

            vm.isPlayingFeedbackTTS = true
            #expect(vm.voiceCommandCoordinator.currentCommandScreen == nil, "feedback TTS must close the window too")

            await vm.voiceCommandCoordinator.handleCommandTranscript(CommandTranscript(text: "next", isFinal: true))
            #expect(recognized.isEmpty, "a transcript arriving during feedback must be dropped, not routed")

            vm.isPlayingFeedbackTTS = false
            #expect(vm.voiceCommandCoordinator.currentCommandScreen == .result, "and reopen when the app stops talking")
        }
    }

    /// WHY: the flag is only worth anything if the playback path actually sets
    /// it AND tears the input tap down — a closed "window" over a live mic still
    /// feeds the recognizer the app's own feedback audio.
    @Test("playing result feedback tears the listener down and re-arms it after")
    func feedbackPlaybackTearsListenerDown() async {
        let (vm, silence, _) = makeCommandVM()
        vm.quizState = makeResultState()
        await vm.audioDeviceState.startSilenceDetectionListening()
        #expect(silence.isListening)
        let stopsBefore = silence.stopListeningCallCount

        _ = await vm.audioDeviceState.playFeedbackAudioBase64("ZmFrZQ==")

        #expect(silence.stopListeningCallCount > stopsBefore, "feedback must stop the mic — the app must not hear itself")
        #expect(vm.isPlayingFeedbackTTS == false, "the flag must not leak past playback")
        #expect(silence.isListening, "the window re-arms once feedback ends")
    }

    // MARK: - Defensive degrade to buttons (E-fallback)

    @Test("a failed recognizer setup leaves button-only mode: no crash, buttons work")
    func failedSetupDegradesToButtons() async {
        let (vm, silence, audio) = makeCommandVM()
        let mock = silence
        mock.shouldFailSetup = true

        vm.quizState = .askingQuestion
        await vm.voiceCommandCoordinator.syncCommandListenerWindow()
        // Setup failed → listener stays DOWN, no command layer, no crash.
        #expect(mock.isListening == false)
        #expect(mock.startListeningCallCount >= 1, "setup was attempted")

        // The manual mic button still works (batch path — no STT service).
        await vm.recordingCoordinator.startRecording()
        #expect(vm.quizState == .recording)
        #expect(audio.isRecording == true)
    }
}
