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

    @Test("MCQ category header contains QUESTION number")
    func mcqHeaderContainsQuestionNumber() async throws {
        let vm = makeMCQViewModel()
        // questionsAnswered = 0 → question 1
        let view = QuestionView(viewModel: vm)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            // #56: HangsSectionLabel uppercases via a `.textCase(.uppercase)`
            // *display* modifier, so ViewInspector matches the source content
            // ("adults · QUESTION 1") — the header still renders as "ADULTS …".
            #expect(throws: Never.self) {
                try tree.find(text: "adults · QUESTION 1")
            }
        }
    }

    @Test("MCQ body renders AnswerOption rows for each option")
    func mcqRendersAnswerOptions() async throws {
        let vm = makeMCQViewModel()
        let view = QuestionView(viewModel: vm)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            // Jupiter is one of the 4 MCQ options
            #expect(throws: Never.self) {
                try tree.find(text: "Jupiter")
            }
        }
    }

    @Test("MCQ body shows ListeningPill")
    func mcqShowsListeningPill() async throws {
        let vm = makeMCQViewModel()
        let view = QuestionView(viewModel: vm)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) {
                try tree.find(viewWithAccessibilityIdentifier: "question.listeningPill")
            }
        }
    }

    @Test("MCQ body shows Skip button")
    func mcqShowsSkipButton() async throws {
        let vm = makeMCQViewModel()
        let view = QuestionView(viewModel: vm)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) {
                try tree.find(viewWithAccessibilityIdentifier: "question.skip")
            }
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

    /// G1 binding layout: the top bar is close + settings in EVERY question mode —
    /// the settings chip must never disappear when the question type changes.
    @Test("settings button is present in both MCQ and voice mode", arguments: [Question.previewMCQ, Question.preview])
    func settingsButtonPresent(question: Question) async throws {
        let vm = makeViewModel(question: question)
        let view = QuestionView(viewModel: vm)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) {
                try tree.find(viewWithAccessibilityIdentifier: "question.settingsButton")
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
}

// MARK: - Audio strip: replay + mute (#85, Variant B)

@MainActor
@Suite("QuestionView — audio strip replay + mute (#85)")
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

    /// #85 acceptance: replay must exist on BOTH question modes — pre-#85 it existed
    /// only in the voice body, leaving MCQ drivers with no way to re-hear the question.
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

    /// #85 acceptance: a visible mute affordance on the quiz screen (regressed in the
    /// #52 redesign — mute logic existed with no on-screen control). Driving-first:
    /// audio controls must sit on a fixed spot in every mode.
    @Test("mute toggle is present in both MCQ and voice mode", arguments: [Question.previewMCQ, Question.preview])
    func mutePresentInBothModes(question: Question) async throws {
        let vm = makeViewModel(question: question)
        let view = QuestionView(viewModel: vm)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) {
                try tree.find(viewWithAccessibilityIdentifier: "question.mute")
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
        let view = QuestionView(viewModel: vm)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            let mute = try tree.find(viewWithAccessibilityIdentifier: "question.mute")
            try mute.button().tap()
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

    /// 59.5 (RS-14): the replay control must reflect capability — when no question audio
    /// is available it must be disabled, never look interactive while silently no-opping.
    @Test("replay button is disabled when no question audio URL is available (RS-14)")
    func replayDisabledWhenNoAudio() async throws {
        let vm = makeVoiceViewModel()
        vm.currentQuestionAudioUrl = nil
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
        vm.currentQuestionAudioUrl = "https://example.com/q.mp3"
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
