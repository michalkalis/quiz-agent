//
//  SettingsViewHistoryTests.swift
//  HangsTests
//
//  #54 task 54.17 — restored "Reset question history" recovery path.
//
//  Why these tests matter:
//  - The at-capacity startup guard (QuizViewModel.startNewQuiz) tells the user to
//    reset their history in Settings. The 52.9 redesign silently dropped that row,
//    leaving a user at the 500-question cap permanently locked out. The structural
//    test ensures the row can't be dropped again without a test going red.
//  - The error-model test pins the recovery CTA: retrying at capacity fails
//    identically, so the ErrorView must offer Go Home (→ Settings → reset), not
//    a misleading "Try Again" with connectivity copy.
//

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
        let view = SettingsView(viewModel: .preview)
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

// MARK: - VM: at-capacity error offers a reachable recovery action

@MainActor
@Suite("QuizViewModel — history at capacity recovery")
struct QuizViewModelHistoryCapacityTests {
    @Test("at-capacity start surfaces historyAtCapacity model with Go Home CTA")
    func atCapacityErrorIsRecoverable() async {
        let (vm, store) = Fixtures.makeViewModelWithPersistence()
        store.askedQuestionIds = (0 ..< 500).map { "q\($0)" }

        await vm.startNewQuiz()

        #expect(vm.activeErrorModel == .historyAtCapacity)
        #expect(
            vm.activeErrorModel?.retryAction == .goHome,
            "Retry at capacity fails identically — the CTA must route Home, where Settings → reset is reachable"
        )
    }
}
