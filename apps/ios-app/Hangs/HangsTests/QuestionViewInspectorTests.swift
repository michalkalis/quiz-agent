//
//  QuestionViewInspectorTests.swift
//  HangsTests
//
//  #52 task 52.10 — QuestionView redesign (frames b8zObz/WCaT6/f9csl/uGhZg).
//  #83 — unified quiz chrome (G1): both MCQ and voice must render the SAME top bar
//  (close + settings), the muted category + counter meta row, and the bottom timer
//  strip — a driver glances at one predictable HUD regardless of question type.
//
//  Why these tests matter:
//  - MCQ meta row must include "QUESTION N" so the driver knows which question they're on
//    without having to look at the progress bar (design: b8zObz "GEOGRAPHY · QUESTION 3").
//  - Voice body must show the question in a lowercase muted category label (no question
//    number) and the Anton display question text (design: f9csl).
//  - Voice body must offer a Record button and a Skip button at the bottom — NOT the old
//    chipActionRow (repeat/keyboard/mute) which the design removed.
//  - The unified-chrome suite asserts settings button + counter + timer strip exist in
//    BOTH modes — if either mode diverges again (the pre-#83 bug), these fail.
//

import Foundation
@testable import Hangs
import SwiftUI
import Testing
import ViewInspector

// MARK: - MCQ body

@MainActor
@Suite("QuestionView — MCQ body (b8zObz / WCaT6)")
struct QuestionViewMCQInspectorTests {
    private func makeMCQViewModel() -> QuizViewModel {
        let vm = QuizViewModel(
            networkService: MockNetworkService(),
            audioService: MockAudioService(),
            persistenceStore: MockPersistenceStore()
        )
        vm.currentQuestion = Question.previewMCQ
        vm.quizState = .askingQuestion
        return vm
    }

    /// #173 A3 replaced the merged "CATEGORY · Qn" row with the shared header:
    /// lowercase category on the left, a compact 1-based "1/10" on the right,
    /// identical in MCQ and voice. The merged row is what collided with the
    /// TestFlight chips, so its absence is part of the contract.
    @Test("MCQ renders the shared A3 meta row, not the old merged Qn label")
    func mcqHeaderRendersSharedMetaRow() async throws {
        let vm = makeMCQViewModel()
        // questionsAnswered = 0 → question 1
        let view = QuestionView(viewModel: vm)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) { try tree.find(text: "adults") }
            #expect(throws: Never.self) { try tree.find(text: "1/10") }
            #expect(throws: (any Error).self, "the merged #125 row is gone") {
                try tree.find(text: "adults · Q1")
            }
        }
    }

    @Test("MCQ body renders AnswerOption rows for each option while asking")
    func mcqRendersAnswerOptions() async throws {
        let vm = makeMCQViewModel()
        // #132: no reveal gate any more — the options are on screen from the
        // first frame of the question, `.askingQuestion` included.
        let view = QuestionView(viewModel: vm)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            // Jupiter is one of the 4 MCQ options
            #expect(throws: Never.self) {
                try tree.find(text: "Jupiter")
            }
        }
    }

    @Test("MCQ body shows the docked answer ListenBar once recording starts (#125)")
    func mcqShowsListenBar() async throws {
        let vm = makeMCQViewModel()
        vm.quizState = .recording
        let view = QuestionView(viewModel: vm)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) {
                try tree.find(viewWithAccessibilityIdentifier: "listen-bar")
            }
        }
    }

    /// A driver must always be able to bail out of a question they can't answer,
    /// including while it is still being read aloud and the countdown runs.
    @Test("MCQ body shows Skip button while the countdown is still running")
    func mcqShowsSkipButton() async throws {
        let vm = makeMCQViewModel()
        vm.answerTimerCountdown = 12 // the countdown is still running
        let view = QuestionView(viewModel: vm)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) {
                try tree.find(viewWithAccessibilityIdentifier: "question.skip")
            }
        }
    }
}

// MARK: - MCQ options visible from the start + stem scroll region (#132)

/// Founder, TestFlight 2026-07-29 (#132) — REVERSES the #125 reveal gate of
/// 2026-07-28: on a multiple-choice question the driver must SEE the options
/// while thinking, so the grid renders from the first frame, think phase
/// included. Hiding them cost the whole point of MCQ — you cannot pick between
/// alternatives you have not been shown.
///
/// What did NOT reverse: the answer `ListenBar` says "Listening — say A–D or
/// the answer" (#171 Track I — answering with the option text works), so
/// it must still appear only once the mic is actually live. The long-stem
/// scroll affordance has to keep working with the grid on screen throughout.
@MainActor
@Suite("QuestionView — MCQ options visible from the start (#132)")
struct QuestionViewMCQOptionVisibilityTests {
    /// A long-stem MCQ mid-countdown — the exact field shape (`--ui-test-mcq
    /// --ui-test-long`), still in the think phase.
    private func makeThinkPhaseViewModel() -> (QuizViewModel, MockNetworkService) {
        let (vm, network) = Fixtures.makeViewModelWithNetwork()
        vm.currentSession = Fixtures.makeActiveSession()
        vm.currentQuestion = Question.previewMCQLong
        vm.quizState = .askingQuestion
        vm.settings.autoRecordEnabled = false
        vm.settings.answerTimeLimit = 30
        vm.answerTimerCountdown = 12 // the answer countdown is still running
        return (vm, network)
    }

    @Test("all four option tiles are on screen while the question is still being timed")
    func optionsVisibleDuringThinkPhase() async throws {
        let (vm, _) = makeThinkPhaseViewModel()
        let view = QuestionView(viewModel: vm)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            // #132 Variant A grid: all four tiles, from the first frame.
            for id in ["mcq.option.a", "mcq.option.b", "mcq.option.c", "mcq.option.d"] {
                #expect(throws: Never.self, "\(id) is hidden during the think phase again") {
                    try tree.find(viewWithAccessibilityIdentifier: id)
                }
            }
            // The stem must not have been pushed off in the process.
            #expect(throws: Never.self) {
                try tree.find(viewWithAccessibilityIdentifier: "question.text")
            }
            // #173: mute left the screen for the toolbar, so the strip is gone.
            // The countdown surface is the ListenBar, now ABOVE the grid.
            #expect(throws: Never.self) {
                try tree.find(viewWithAccessibilityIdentifier: "listen-bar")
            }
        }
    }

    /// #132 Track B (variant A): ONE bar slot across both phases. During the
    /// think phase the bar is MCQ's countdown surface — in the teal think state,
    /// which does NOT claim "LISTENING" (the #125-gate lesson survives) — and the
    /// moment the mic goes live it flips to the pink answer state.
    @Test("the ListenBar counts the think phase down and flips to answer mode with recording")
    func listenBarCountsThinkAndFlipsToAnswer() async throws {
        let (vm, _) = makeThinkPhaseViewModel()
        let thinking = QuestionView(viewModel: vm)
        try await ViewHosting.host(thinking) {
            let tree = try thinking.inspect()
            #expect(throws: Never.self) {
                try tree.find(viewWithAccessibilityIdentifier: "listen-bar")
            }
            // The think caption counts the running window down (12 s left in the
            // fixture's legacy answer window — the bar covers both timer paths)…
            #expect(throws: Never.self) {
                try tree.find(text: "THINK — LISTENING IN 12 S")
            }
            // …and never claims a live mic during the think phase.
            #expect(throws: (any Error).self) {
                _ = try tree.find(text: "Listening — say A–D or the answer")
            }
        }

        vm.quizState = .recording
        vm.answerTimerCountdown = 0
        let recording = QuestionView(viewModel: vm)
        try await ViewHosting.host(recording) {
            let tree = try recording.inspect()
            #expect(throws: Never.self) {
                try tree.find(text: "Listening — say A–D or the answer")
            }
            #expect(throws: (any Error).self) {
                _ = try tree.find(text: "THINK — LISTENING IN 0 S")
            }
            // #173: the mute is a toolbar control now — the on-screen strip that
            // used to carry it is gone from both phases.
            #expect(throws: (any Error).self) {
                _ = try tree.find(viewWithAccessibilityIdentifier: "question.timerStrip")
            }
        }
    }

    /// The whole point of showing the options during the think phase: they must
    /// be answerable there. `submitMCQAnswer` is legal from `.askingQuestion` and
    /// must cancel the countdown it was tapped over — otherwise the THINK chip
    /// keeps ticking on the processing screen and the thinking task still owns a
    /// pending auto-start of recording.
    @Test("tapping an option during the think phase submits and stops the countdown")
    func tapDuringThinkPhaseSubmitsAndStopsCountdown() async throws {
        let (vm, network) = makeThinkPhaseViewModel()
        vm.thinkingTimeCountdown = 7
        let view = QuestionView(viewModel: vm)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            let tile = try tree.find(viewWithAccessibilityIdentifier: "mcq.option.b")
            try tile.find(ViewType.Button.self).tap()
            // MCQOptionPicker debounces the tap (54.16) before submitting.
            for _ in 0 ..< 200 where network.capturedTextInputInput == nil {
                try? await Task.sleep(nanoseconds: 10_000_000)
                await Task.yield()
            }
            #expect(network.capturedTextInputInput == "Budapest")
            #expect(vm.thinkingTimeCountdown == 0, "the THINK countdown kept running under the result")
        }
    }

    /// The hands-free path must keep working regardless of what is on screen: the
    /// voice matcher writes `mcqVoiceMatchedKey` on the view model, not on the
    /// picker, so a spoken A–D answer is accepted during the think phase too.
    @Test("a spoken answer is accepted during the think phase")
    func voiceAnswerAcceptedDuringThinkPhase() async throws {
        let (vm, network) = makeThinkPhaseViewModel()
        let view = QuestionView(viewModel: vm)
        try await ViewHosting.host(view) {
            _ = try view.inspect()
            // Same call the MCQ voice matcher makes for a spoken "B" / "Budapest".
            await vm.submitMCQAnswer(key: "b", value: "Budapest")
            #expect(network.capturedTextInputInput == "Budapest")
        }
    }

    /// 54.2's MCQ counterpart, and the reason the grid could be hidden in the
    /// first place: with the option cards on screen for the WHOLE question, the
    /// stem's scroll region must still be measured against the available height
    /// (`GeometryReader` + `minHeight`), otherwise the fixed-height cards are
    /// served their floors first and the flexible ScrollView collapses — which is
    /// what made a long stem read as clipped rather than scrollable.
    @Test("the stem scroll region is height-measured with the grid on screen")
    func stemScrollRegionHasMeasuredMinimumHeight() async throws {
        let (vm, _) = makeThinkPhaseViewModel()
        let view = QuestionView(viewModel: vm)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            // Precondition: this is the with-grid layout, not a stem-only screen.
            #expect(throws: Never.self) {
                try tree.find(viewWithAccessibilityIdentifier: "mcq.option.a")
            }
            let stemGeometryReaders = tree.findAll(ViewType.GeometryReader.self).filter {
                (try? $0.find(viewWithAccessibilityIdentifier: "question.text")) != nil
            }
            #expect(
                !stemGeometryReaders.isEmpty,
                "MCQ stem is in a bare ScrollView again — a long question will be squeezed to near-zero height"
            )
        }
    }
}

// MARK: - Voice body (Listen / resting state)

@MainActor
@Suite("QuestionView — voice body (f9csl / uGhZg)")
struct QuestionViewVoiceInspectorTests {
    private func makeVoiceViewModel() -> QuizViewModel {
        let vm = QuizViewModel(
            networkService: MockNetworkService(),
            audioService: MockAudioService(),
            persistenceStore: MockPersistenceStore()
        )
        // Question.preview is type .text (non-MCQ → voice body)
        vm.currentQuestion = Question.preview
        vm.quizState = .askingQuestion
        return vm
    }

    @Test("Voice body shows category in lowercase (design: f9csl)")
    func voiceCategoryIsLowercase() async throws {
        let vm = makeVoiceViewModel()
        let view = QuestionView(viewModel: vm)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            // category is "adults" — lowercased
            #expect(throws: Never.self) {
                try tree.find(viewWithAccessibilityIdentifier: "question.category")
            }
        }
    }

    @Test("Voice body shows question text (no left bar, Anton font)")
    func voiceShowsQuestionText() async throws {
        let vm = makeVoiceViewModel()
        let view = QuestionView(viewModel: vm)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) {
                try tree.find(viewWithAccessibilityIdentifier: "question.text")
            }
        }
    }

    @Test("Voice body shows Record button in resting state (design: f9csl)")
    func voiceShowsRecordButton() async throws {
        let vm = makeVoiceViewModel()
        let view = QuestionView(viewModel: vm)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) {
                try tree.find(viewWithAccessibilityIdentifier: "question.record")
            }
        }
    }

    @Test("Voice body shows Skip button")
    func voiceShowsSkipButton() async throws {
        let vm = makeVoiceViewModel()
        let view = QuestionView(viewModel: vm)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) {
                try tree.find(viewWithAccessibilityIdentifier: "question.skip")
            }
        }
    }

    /// #125 addendum: the floating command pill on the question screen is
    /// replaced by the docked shared `ListenBar` in COMMAND mode — shown while a
    /// command window is armed (same gating as before: `commandListenerHint !=
    /// nil`). Arms the listener the way `VoiceCommandObservabilityTests` does
    /// (mock recognizer reports `.ready`, then start listening), then asserts the
    /// docked bar (id "listen-bar") appears. This is the unit-level cover for the
    /// sim state the UI-test harness cannot produce (its mock forces
    /// `commandAvailability = .unavailable`).
    @Test("Voice body shows the docked command ListenBar while a command window is armed (#125)")
    func voiceShowsCommandListenBarWhenArmed() async throws {
        let vm = QuizViewModel(
            networkService: MockNetworkService(),
            audioService: MockAudioService(),
            persistenceStore: MockPersistenceStore(),
            silenceDetectionService: MockSilenceDetectionService(),
            sttService: nil
        )
        vm.currentQuestion = Question.preview // .text → voice body
        vm.quizState = .askingQuestion
        await vm.audioDeviceState.startSilenceDetectionListening() // arms → .listening
        #expect(vm.commandListenerHint != nil, "precondition: the command window must be armed")

        let view = QuestionView(viewModel: vm)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) {
                try tree.find(viewWithAccessibilityIdentifier: "listen-bar")
            }
        }
    }
}

// MARK: - Unified quiz chrome (#83 / G1)

@MainActor
@Suite("QuestionView — unified chrome in both modes (#83 / G1)")
struct QuestionViewUnifiedChromeTests {
    private func makeViewModel(question: Question) -> QuizViewModel {
        let vm = QuizViewModel(
            networkService: MockNetworkService(),
            audioService: MockAudioService(),
            persistenceStore: MockPersistenceStore()
        )
        vm.currentQuestion = question
        vm.quizState = .askingQuestion
        return vm
    }

    /// #125 had dropped the settings gear from MCQ only — exactly the per-mode
    /// divergence #173 removed. Both modes now draw the SAME toolbar (its
    /// contents are pinned in `QuizToolbarTests`), and neither may keep a
    /// hand-rolled top row of its own: a stray `question.closeButton` in the
    /// body means one mode grew its own chrome back.
    @Test("neither mode keeps a hand-rolled top row (#173)", arguments: [Question.previewMCQ, Question.preview])
    func noModeSpecificTopRow(question: Question) async throws {
        let vm = makeViewModel(question: question)
        let view = QuestionView(viewModel: vm)
        try await ViewHosting.host(view) {
            #expect(QuizToolbarInspection.hasToolbar(view))
            #expect(throws: (any Error).self, "the close chip belongs to the toolbar, not the body") {
                _ = try view.inspect().find(viewWithAccessibilityIdentifier: "question.closeButton")
            }
        }
    }

    /// The `NN / NN` counter moved from the nav bar into the meta row (#83); it must
    /// stay visible in both modes so the driver always knows where they are.
    @Test("question counter is present in both MCQ and voice mode", arguments: [Question.previewMCQ, Question.preview])
    func counterPresent(question: Question) async throws {
        let vm = makeViewModel(question: question)
        let view = QuestionView(viewModel: vm)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) {
                try tree.find(viewWithAccessibilityIdentifier: "question.counter")
            }
        }
    }

    /// #173 removed the on-screen audio strip: its only remaining occupant was
    /// the mute, and mute is a toolbar control now. A strip that comes back is a
    /// second mute in a second place — the #125 mistake #131 already undid once.
    @Test("the on-screen audio strip is gone from both modes", arguments: [Question.previewMCQ, Question.preview])
    func audioStripRemoved(question: Question) async throws {
        let vm = makeViewModel(question: question)
        let view = QuestionView(viewModel: vm)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            for id in ["question.timerStrip", "question.mute"] {
                #expect(throws: (any Error).self, "\(id) must not be drawn in the body any more") {
                    _ = try tree.find(viewWithAccessibilityIdentifier: id)
                }
            }
            #expect(QuizToolbarInspection.hasToolbar(view), "the mute still exists — in the toolbar")
        }
    }

    /// #131 Track C (founder, 2026-07-29): the footer row is Record · Type · Skip.
    /// "Type answer instead" left its floating slot in the audio strip and became a
    /// compact button beside the other two — one row a driver can hit without
    /// hunting. The strip must no longer contain it.
    @Test("typed-answer toggle sits in the footer row, not in the timer strip")
    func typeToggleSitsInFooterRow() async throws {
        let vm = makeViewModel(question: Question.preview)
        let view = QuestionView(viewModel: vm)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            // All three footer controls are on screen together.
            for id in ["question.record", "question.textInputToggle", "question.skip"] {
                #expect(throws: Never.self, "\(id) missing from the footer row") {
                    try tree.find(viewWithAccessibilityIdentifier: id)
                }
            }
        }
    }
}

// MARK: - Tap-to-replay question block + mute (#85 → tap-anywhere, founder 2026-07-11)

@MainActor
@Suite("QuestionView — tap-to-replay question + mute (#85)")
struct QuestionViewAudioStripTests {
    private func makeViewModel(question: Question) -> QuizViewModel {
        let vm = QuizViewModel(
            networkService: MockNetworkService(),
            audioService: MockAudioService(),
            persistenceStore: MockPersistenceStore()
        )
        vm.currentQuestion = question
        vm.quizState = .askingQuestion
        return vm
    }

    /// #85 acceptance, carried over to the tap-anywhere design (founder, 2026-07-11):
    /// a replay control must exist on BOTH question modes — pre-#85 it existed only in
    /// the voice body, leaving MCQ drivers with no way to re-hear the question. The
    /// control is now the tappable question block itself, not an audio-strip link.
    @Test("replay control is present in both MCQ and voice mode", arguments: [Question.previewMCQ, Question.preview])
    func replayPresentInBothModes(question: Question) async throws {
        let vm = makeViewModel(question: question)
        let view = QuestionView(viewModel: vm)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) {
                try tree.find(viewWithAccessibilityIdentifier: "question.replay")
            }
        }
    }

    /// Tap-anywhere-on-question: the replay control IS the question block — the
    /// question text must sit inside the tap target in both modes, so tapping the
    /// question (re)starts its TTS. If the id drifts back to a separate link this fails.
    @Test("question text is inside the replay tap target", arguments: [Question.previewMCQ, Question.preview])
    func questionTextInsideReplayTapTarget(question: Question) async throws {
        let vm = makeViewModel(question: question)
        let view = QuestionView(viewModel: vm)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            let replay = try tree.find(viewWithAccessibilityIdentifier: "question.replay")
            #expect(throws: Never.self) {
                try replay.find(viewWithAccessibilityIdentifier: "question.text")
            }
        }
    }

    /// #85 acceptance, carried to the toolbar by #173: the mute lives on ONE
    /// fixed spot in BOTH modes and BOTH answering states — the driving-first
    /// rule #125 broke by tying it to whether a bar happened to be on screen.
    /// The toolbar it now lives on must therefore exist in every one of them;
    /// the control itself is pinned in `QuizToolbarTests`.
    @Test("the toolbar that carries the mute exists in both modes, asking and recording",
          arguments: [Question.previewMCQ, Question.preview])
    func muteHostPresentInBothModes(question: Question) async throws {
        for state in [QuizState.askingQuestion, .recording] {
            let vm = makeViewModel(question: question)
            vm.quizState = state
            let view = QuestionView(viewModel: vm)
            try await ViewHosting.host(view) {
                #expect(QuizToolbarInspection.hasToolbar(view), "no toolbar in \(state)")
            }
        }
    }
}

// MARK: - Replay availability + processing indicator (RS-14 / RS-15)

@MainActor
@Suite("QuestionView — replay availability & processing indicator (RS-14 / RS-15)")
struct QuestionViewReplayProcessingInspectorTests {
    private func makeVoiceViewModel() -> QuizViewModel {
        let vm = QuizViewModel(
            networkService: MockNetworkService(),
            audioService: MockAudioService(),
            persistenceStore: MockPersistenceStore()
        )
        vm.currentQuestion = Question.preview // .text → voice body
        vm.quizState = .askingQuestion
        return vm
    }

    /// 59.5 (RS-14): the replay control (now the tappable question block, founder
    /// 2026-07-11) must reflect capability — when no question audio is available it
    /// must be disabled, never look interactive while silently no-opping.
    @Test("replay button is disabled when no question audio URL is available (RS-14)")
    func replayDisabledWhenNoAudio() async throws {
        let vm = makeVoiceViewModel()
        vm.recordingCoordinator.currentQuestionAudioUrl = nil
        let view = QuestionView(viewModel: vm)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            let replay = try tree.find(viewWithAccessibilityIdentifier: "question.replay")
            #expect(try replay.isDisabled())
        }
    }

    @Test("replay button is enabled when a question audio URL is available (RS-14)")
    func replayEnabledWhenAudioPresent() async throws {
        let vm = makeVoiceViewModel()
        vm.settings.isMuted = false
        vm.recordingCoordinator.currentQuestionAudioUrl = "https://example.com/q.mp3"
        let view = QuestionView(viewModel: vm)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            let replay = try tree.find(viewWithAccessibilityIdentifier: "question.replay")
            #expect(try replay.isDisabled() == false)
        }
    }

    /// 59.6 (RS-15): the typed-answer path stays on QuestionView while the answer
    /// is evaluated (it bypasses the voice confirmation sheet that owns the other
    /// evaluating state). #174 moved that state into the Record button itself, so
    /// this is what keeps the screen from looking idle between submit and result.
    @Test("the record button carries the evaluating state while processing (RS-15)")
    func recordButtonShowsEvaluatingWhileProcessing() async throws {
        let vm = makeVoiceViewModel()
        vm.quizState = .processing
        let view = QuestionView(viewModel: vm)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) { try tree.find(text: "Evaluating…") }
        }
    }

    /// The other half of that contract: nothing claims to be evaluating while the
    /// driver is still being asked the question.
    @Test("no evaluating state while asking a question (RS-15)")
    func noEvaluatingStateWhileAsking() async throws {
        let vm = makeVoiceViewModel()
        vm.quizState = .askingQuestion
        let view = QuestionView(viewModel: vm)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: (any Error).self) { _ = try tree.find(text: "Evaluating…") }
            #expect(throws: (any Error).self) {
                _ = try tree.find(viewWithAccessibilityIdentifier: "question.processingIndicator")
            }
        }
    }

    /// #174 (founder rule, locked 2026-09-07): a loading state lives IN the control
    /// that triggered it, never in an overlay. The full-screen "Vyhodnocujem…"
    /// overlay is gone, so the footer must STAY on screen while the answer is
    /// graded — an empty bottom is exactly what read as "the app fell over".
    @Test("evaluating keeps the voice controls on screen")
    func evaluatingKeepsVoiceControls() async throws {
        let vm = makeVoiceViewModel()
        vm.quizState = .processing
        let view = QuestionView(viewModel: vm)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            for id in ["question.record", "question.textInputToggle", "question.skip"] {
                #expect(throws: Never.self, "\(id) must stay on screen while evaluating") {
                    try tree.find(viewWithAccessibilityIdentifier: id)
                }
            }
        }
    }

    /// A skip in flight has to be visible somewhere now that the overlay is gone:
    /// in the control that started it.
    @Test("skipping spins in the skip control on the voice body")
    func skippingSpinsInVoiceSkipControl() async throws {
        let vm = makeVoiceViewModel()
        vm.quizState = .skipping
        let view = QuestionView(viewModel: vm)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            let skip = try tree.find(viewWithAccessibilityIdentifier: "question.skip")
            #expect(throws: Never.self) {
                try skip.find(viewWithAccessibilityIdentifier: "question.processingIndicator")
            }
        }
    }

    /// Review on #174: with the footer mounted during a skip, the Record CTA must
    /// not read as tappable — a tap there is a silent no-op while `.skipping`.
    @Test("skipping disables the record CTA next to the spinning skip control")
    func skippingDisablesRecordButton() async throws {
        let vm = makeVoiceViewModel()
        vm.quizState = .skipping
        let view = QuestionView(viewModel: vm)
        try await ViewHosting.host(view) {
            let record = try view.inspect().find(viewWithAccessibilityIdentifier: "question.record")
            #expect(try record.isDisabled(), "record CTA must be disabled while a skip is in flight")
        }
    }

    /// Same contract on the MCQ side — one evaluating state, not two. The chip
    /// stays put instead of vanishing, and it keeps its label while spinning so
    /// the capsule cannot change width under the driver's thumb.
    @Test("skipping spins in the MCQ skip chip and keeps its label")
    func skippingSpinsInMCQSkipChip() async throws {
        let vm = makeMCQEvaluatingViewModel(state: .skipping)
        let view = QuestionView(viewModel: vm)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            let skip = try tree.find(viewWithAccessibilityIdentifier: "question.skip")
            #expect(throws: Never.self) {
                try skip.find(viewWithAccessibilityIdentifier: "question.processingIndicator")
            }
            #expect(throws: Never.self, "the label must survive so the chip keeps its width") {
                try skip.find(text: "Skip question")
            }
        }
    }

    /// #174: a tapped option is graded IN its own tile — the letter badge becomes
    /// a spinner while the tile keeps its text and selected styling — and the other
    /// options stop taking taps so a second answer can't be queued behind the first.
    @Test("a tapped MCQ option spins in its own tile and locks the others")
    func tappedMCQOptionSpinsInItsTile() async throws {
        let vm = makeMCQEvaluatingViewModel(state: .processing)
        // The tap path writes the chosen key through this VM-owned binding (#110 T4).
        vm.mcqVoiceMatchedKey = "b"
        let view = QuestionView(viewModel: vm)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            let chosen = try tree.find(viewWithAccessibilityIdentifier: "mcq.option.b")
            #expect(throws: Never.self) {
                try chosen.find(viewWithAccessibilityIdentifier: "question.processingIndicator")
            }
            #expect(throws: Never.self, "the tile keeps its text — only the badge changes") {
                try chosen.find(text: "Jupiter")
            }
            let other = try tree.find(viewWithAccessibilityIdentifier: "mcq.option.a")
            #expect(throws: (any Error).self, "only the chosen tile spins") {
                _ = try other.find(viewWithAccessibilityIdentifier: "question.processingIndicator")
            }
            #expect(try other.isDisabled(), "the other options must stop taking taps")
        }
    }

    private func makeMCQEvaluatingViewModel(state: QuizState) -> QuizViewModel {
        let vm = QuizViewModel(
            networkService: MockNetworkService(),
            audioService: MockAudioService(),
            persistenceStore: MockPersistenceStore()
        )
        vm.currentQuestion = Question.previewMCQ
        vm.quizState = state
        return vm
    }
}
