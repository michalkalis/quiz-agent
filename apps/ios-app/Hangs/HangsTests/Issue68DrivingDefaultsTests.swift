//
//  Issue68DrivingDefaultsTests.swift
//  HangsTests
//
//  #68 — driving-critical defaults + session settings + image questions
//  (founder decision 6, 2026-07-05; Pencil frames Jjcs5 sessionWrap / rJ7dB row4).
//
//  Why these tests matter:
//  - The four session fields were code-only for months (a driver couldn't
//    shorten the 60s thinking time without a code change). The structural tests
//    pin that each field now has a user-facing row, so none can be silently
//    dropped in a redesign again.
//  - "Image questions" is a per-session opt-in that must actually reach the
//    create-session request — a toggle that never leaves the device is a lie.
//  - An image-type question must render its image; before #68 it fell through
//    to the plain voice body and showed nothing (the orphaned-view bug).
//

import Foundation
@testable import Hangs
import SwiftUI
import Testing
import ViewInspector

// MARK: - SettingsView session group (decision 6 Variant A)

@MainActor
@Suite("SettingsView — session group (#68)")
struct SettingsViewSessionGroupTests {
    private func makeView() -> some View {
        let appState = AppState(
            networkService: MockNetworkService(),
            audioService: MockAudioService(),
            persistenceStore: MockPersistenceStore()
        )
        return SettingsView(viewModel: .preview)
            .environmentObject(appState)
    }

    @Test("all four session rows render in the view tree")
    func sessionRowsRender() async throws {
        let view = makeView()
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            for label in [
                "Thinking time", "Questions per session",
                "Auto-advance delay", "Answer time limit",
            ] {
                #expect(throws: Never.self, "session row '\(label)' must render") {
                    try tree.find(text: label)
                }
            }
        }
    }

    @Test("'Recording sounds' toggle renders in the audio feedback group")
    func recordingSoundsToggleRenders() async throws {
        let view = makeView()
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) {
                try tree.find(text: "Recording sounds")
            }
        }
    }
}

// MARK: - Home image-questions opt-in (default OFF)

@MainActor
@Suite("HomeView — image questions toggle (#68)")
struct HomeImageQuestionsToggleTests {
    @Test("Home renders the 'Image questions' toggle, default off")
    func imageQuestionsToggleRendersDefaultOff() async throws {
        let vm = QuizViewModel(
            networkService: MockNetworkService(),
            audioService: MockAudioService(),
            persistenceStore: MockPersistenceStore()
        )
        let view = HomeView(viewModel: vm)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) {
                try tree.find(text: "Image questions")
            }
            #expect(vm.settings.includeImageQuestions == false,
                    "image questions must default OFF — unsuitable while driving")
        }
    }
}

// MARK: - Opt-in reaches the create-session request

@MainActor
@Suite("QuizViewModel — image opt-in rides createSession (#68)")
struct ImageOptInRequestTests {
    @Test("startNewQuiz forwards includeImageQuestions to createSession")
    func optInReachesCreateSession() async {
        let network = Fixtures.makeFullMockNetwork()
        let vm = QuizViewModel(
            networkService: network,
            audioService: MockAudioService(),
            persistenceStore: MockPersistenceStore()
        )
        vm.settings.includeImageQuestions = true

        await vm.startNewQuiz()

        #expect(network.capturedIncludeImages == true,
                "the Home toggle must reach the session request or it's a silent no-op")
    }

    @Test("default settings request no images")
    func defaultRequestsNoImages() async {
        let network = Fixtures.makeFullMockNetwork()
        let vm = QuizViewModel(
            networkService: network,
            audioService: MockAudioService(),
            persistenceStore: MockPersistenceStore()
        )

        await vm.startNewQuiz()

        #expect(network.capturedIncludeImages == false)
    }
}

// MARK: - Image question renders its image block

@MainActor
@Suite("QuestionView — image question body (#68)")
struct QuestionViewImageInspectorTests {
    @Test("image-type question renders the image block above the question text")
    func imageQuestionRendersImageBlock() async throws {
        let vm = QuizViewModel(
            networkService: MockNetworkService(),
            audioService: MockAudioService(),
            persistenceStore: MockPersistenceStore()
        )
        vm.currentQuestion = Question.previewImage
        vm.quizState = .askingQuestion

        let view = QuestionView(viewModel: vm)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self, "image block must render for an image question") {
                try tree.find(viewWithAccessibilityIdentifier: "question.image")
            }
            // The text/TTS fallback stays — driving mode never depends on the image.
            #expect(throws: Never.self) {
                try tree.find(viewWithAccessibilityIdentifier: "question.text")
            }
        }
    }

    @Test("plain voice question renders no image block")
    func voiceQuestionHasNoImageBlock() async throws {
        let vm = QuizViewModel(
            networkService: MockNetworkService(),
            audioService: MockAudioService(),
            persistenceStore: MockPersistenceStore()
        )
        vm.currentQuestion = Fixtures.makeQuestion(id: "q_001")
        vm.quizState = .askingQuestion

        let view = QuestionView(viewModel: vm)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: (any Error).self) {
                try tree.find(viewWithAccessibilityIdentifier: "question.image")
            }
        }
    }
}
