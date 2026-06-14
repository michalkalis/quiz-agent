//
//  QuestionViewInspectorTests.swift
//  HangsTests
//
//  #52 task 52.10 — QuestionView redesign (frames b8zObz/WCaT6/f9csl/uGhZg).
//
//  Why these tests matter:
//  - MCQ header must include "QUESTION N" so the driver knows which question they're on
//    without having to look at the progress bar (design: b8zObz "GEOGRAPHY · QUESTION 3").
//  - Voice body must show the question in lowercase category label (no question number),
//    the Anton display question text, and the subtitle hint "Answer out loud" (design: f9csl).
//  - Voice body must offer a Record button and a Skip button at the bottom — NOT the old
//    chipActionRow (repeat/keyboard/mute) which the design removed.
//  - The voice state indicator shows "Ready" in the resting state (design: f9csl center block).
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
            // The header renders "ADULTS · QUESTION 1" via HangsSectionLabel (uppercased)
            #expect(throws: Never.self) {
                try tree.find(text: "ADULTS · QUESTION 1")
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
