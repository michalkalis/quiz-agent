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

    @Test("MCQ merged top row contains the abbreviated Qn label (#125)")
    func mcqHeaderContainsQuestionNumber() async throws {
        let vm = makeMCQViewModel()
        // questionsAnswered = 0 → question 1
        let view = QuestionView(viewModel: vm)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            // #125 Variant A: the MCQ chrome merges into one row using the
            // "CATEGORY · Qn" style. #56: uppercased via a `.textCase` *display*
            // modifier, so ViewInspector matches the source ("adults · Q1").
            #expect(throws: Never.self) {
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
            // The audio strip is the mute's fixed home in both phases (#131 C);
            // the countdown moved into the ListenBar (#132 B).
            #expect(throws: Never.self) {
                try tree.find(viewWithAccessibilityIdentifier: "question.timerStrip")
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
            // #131 Track C: the strip is the only mute on the screen now that the
            // bar dropped its duplicate — it must survive into the answer phase.
            #expect(throws: Never.self) {
                try tree.find(viewWithAccessibilityIdentifier: "question.timerStrip")
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

    /// #125: the MCQ screen drops its settings gear (settings reachable via the
    /// End Quiz sheet) to reclaim chrome for the stem; the voice body keeps the
    /// close + settings top bar. The close chip must survive in BOTH so a driver
    /// can always bail / reach settings.
    @Test("settings gear stays in voice mode and is dropped on MCQ (#125)", arguments: [Question.previewMCQ, Question.preview])
    func settingsGearPresence(question: Question) async throws {
        let vm = makeViewModel(question: question)
        let view = QuestionView(viewModel: vm)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            if question.isMultipleChoice {
                #expect(throws: (any Error).self) {
                    _ = try tree.find(viewWithAccessibilityIdentifier: "question.settingsButton")
                }
            } else {
                #expect(throws: Never.self) {
                    try tree.find(viewWithAccessibilityIdentifier: "question.settingsButton")
                }
            }
            // Close chip present in both modes.
            #expect(throws: Never.self) {
                try tree.find(viewWithAccessibilityIdentifier: "question.closeButton")
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

    /// G1: the think/answer timer lives at the bottom near the action row and must
    /// render identically in both modes — the pre-#83 report was "MCQ has no timer".
    @Test("timer strip is present in both MCQ and voice mode while asking", arguments: [Question.previewMCQ, Question.preview])
    func timerStripPresent(question: Question) async throws {
        let vm = makeViewModel(question: question)
        let view = QuestionView(viewModel: vm)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) {
                try tree.find(viewWithAccessibilityIdentifier: "question.timerStrip")
            }
        }
    }

    /// Founder batch 2026-07-12: the quiz chrome must render the moment the quiz
    /// starts — before the first question payload arrives — so the top bar is never
    /// perceived as "appearing after a delay". QuestionView with a nil question in
    /// `.startingQuiz` must still show the top bar (close + settings).
    @Test("top bar renders in .startingQuiz before the first question loads")
    func topBarRendersWhileStarting() async throws {
        let vm = QuizViewModel(
            networkService: MockNetworkService(),
            audioService: MockAudioService(),
            persistenceStore: MockPersistenceStore()
        )
        vm.quizState = .startingQuiz
        let view = QuestionView(viewModel: vm)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) {
                try tree.find(viewWithAccessibilityIdentifier: "question.settingsButton")
            }
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
            let strip = try tree.find(viewWithAccessibilityIdentifier: "question.timerStrip")
            #expect(throws: (any Error).self) {
                _ = try strip.find(viewWithAccessibilityIdentifier: "question.textInputToggle")
            }
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

    /// #85 acceptance, restored by #131 Track C: the mute lives in the audio strip
    /// in BOTH modes and BOTH answering states. #125 had moved it into the docked
    /// ListenBar, which made it a duplicate and tied the only mute to whether a bar
    /// happened to be on screen. Driving-first: one predictable spot, always there.
    @Test("mute toggle is present in both modes, asking and recording",
          arguments: [Question.previewMCQ, Question.preview])
    func mutePresentInBothModes(question: Question) async throws {
        for state in [QuizState.askingQuestion, .recording] {
            let vm = makeViewModel(question: question)
            vm.quizState = state
            let view = QuestionView(viewModel: vm)
            try await ViewHosting.host(view) {
                let tree = try view.inspect()
                #expect(throws: Never.self, "no mute in \(state)") {
                    try tree.find(viewWithAccessibilityIdentifier: "question.mute")
                }
            }
        }
    }

    /// The on-screen mute is a pure toggle over the persisted `settings.isMuted` —
    /// the same source of truth the Settings "Speak scores aloud" toggle and the
    /// TTS guards use, so flipping it here silences TTS and stays in sync everywhere.
    @Test("tapping mute flips settings.isMuted")
    func muteTogglesSetting() async throws {
        let vm = makeViewModel(question: Question.preview)
        vm.settings.isMuted = false
        vm.quizState = .recording // #125: mute lives in the docked ListenBar
        let view = QuestionView(viewModel: vm)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            let mute = try tree.find(viewWithAccessibilityIdentifier: "question.mute")
            try mute.button().tap()
            // toggleMute() became async when mute learned to stop in-flight TTS
            // (8a01675) — the flip happens inside a Task, so drain the main actor
            // instead of asserting synchronously (this test was red on main).
            for _ in 0 ..< 50 where !vm.settings.isMuted {
                await Task.yield()
            }
            #expect(vm.settings.isMuted == true)
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

    /// 59.6 (RS-15): the typed-answer path stays on QuestionView while the answer is
    /// evaluated (it bypasses the voice confirmation sheet that owns the only other
    /// spinner). The `question.processingIndicator` must appear in the `.processing` state
    /// so the screen isn't blank between submit and result.
    @Test("processing indicator is present while in the processing state (RS-15)")
    func processingIndicatorPresentWhenProcessing() async throws {
        let vm = makeVoiceViewModel()
        vm.quizState = .processing
        let view = QuestionView(viewModel: vm)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) {
                try tree.find(viewWithAccessibilityIdentifier: "question.processingIndicator")
            }
        }
    }

    @Test("processing indicator is absent while asking a question (RS-15)")
    func processingIndicatorAbsentWhenAsking() async throws {
        let vm = makeVoiceViewModel()
        vm.quizState = .askingQuestion
        let view = QuestionView(viewModel: vm)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: (any Error).self) {
                _ = try tree.find(viewWithAccessibilityIdentifier: "question.processingIndicator")
            }
        }
    }
}
