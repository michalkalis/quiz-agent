//
//  SettingsViewHistoryTests.swift
//  HangsTests
//
//  #54 task 54.17 — restored "Reset question history" recovery path.
//
//  Why these tests matter:
//  - The reset row is how a player gets seen questions back. The 52.9 redesign
//    silently dropped it once; the structural test keeps it from going again.
//  - #200: a long history never blocks a start (the old 500 cap did).
//

import Clocks
import Foundation
@testable import Hangs
import SwiftUI
import Testing
import ViewInspector

// MARK: - Structural: row renders in the view tree

@MainActor
@Suite("SettingsView — reset question history row")
struct SettingsViewHistoryTests {
    @Test("'Reset question history' row label renders in the view tree")
    func resetRowLabelRendersInTree() async throws {
        // SettingsView reads AppState from the environment (#61 account section);
        // a mock-backed AppState satisfies it without the heavy production init.
        let appState = AppState(
            networkService: MockNetworkService(),
            audioService: MockAudioService(),
            persistenceStore: MockPersistenceStore()
        )
        let view = SettingsView(viewModel: .preview)
            .environmentObject(appState)
            .environmentObject(NavigationModel())
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) {
                try tree.find(text: "Reset question history")
            }
        }
    }

    @Test("resetQuestionHistory clears the persistence store")
    func resetClearsStore() {
        let (vm, store) = Fixtures.makeViewModelWithPersistence()
        store.askedQuestionIds = ["q1", "q2", "q3"]

        // This is what the Settings row's confirmation alert calls.
        vm.resetQuestionHistory()

        #expect(store.askedQuestionIds.isEmpty, "Reset row must clear the question history")
        #expect(vm.questionHistoryCount == 0)
    }
}

// MARK: - VM: a long history never blocks a start (#200)

@MainActor
@Suite("QuizViewModel — long history never blocks")
struct QuizViewModelHistoryWindowTests {
    /// WHY (#200, founder 2026-10-12): at 500 seen questions the app refused
    /// every quiz with "history is full". The history is only an exclusion
    /// list now; when questions truly run out the #174 shortfall offers the
    /// reset, so a long history alone must start the quiz like any other.
    @Test("a history far past the old 500 cap starts the quiz")
    func longHistoryStarts() async {
        let network = Fixtures.makeFullMockNetwork()
        let store = MockPersistenceStore()
        store.askedQuestionIds = (0 ..< PersistenceStore.historyWindow).map { "q\($0)" }
        let vm = QuizViewModel(
            networkService: network,
            audioService: MockAudioService(),
            persistenceStore: store,
            silenceDetectionService: MockSilenceDetectionService(),
            clock: AnyClock(TestClock())
        )

        await vm.startNewQuiz()

        #expect(vm.activeErrorModel == nil)
        #expect(vm.quizState == .askingQuestion)
        #expect(network.capturedStartQuizExcludedIds?.count == PersistenceStore.historyWindow)
    }
}
