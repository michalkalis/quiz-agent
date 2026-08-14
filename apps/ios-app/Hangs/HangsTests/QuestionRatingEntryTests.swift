//
//  QuestionRatingEntryTests.swift
//  HangsTests
//
//  #155 gating. The rating panel is a TestFlight-only debug surface: it must be
//  present for the founder on both quiz screens and absent from an App Store
//  build. Both halves are asserted structurally here — "it's behind a flag" is
//  worth nothing if nothing checks the flag actually hides it.
//

import Foundation
@testable import Hangs
import SwiftUI
import Testing
import ViewInspector

// MARK: - Build-channel predicate

@Suite("BuildChannel — TestFlight gating predicate (#155)")
struct BuildChannelTests {
    @Test("only a sandbox receipt counts as TestFlight")
    func sandboxReceiptIsTestFlight() {
        #expect(BuildChannel.isTestFlight(receiptURL: URL(string: "file:///app/StoreKit/sandboxReceipt")!))
        // An App Store install ships `receipt`, never `sandboxReceipt`.
        #expect(BuildChannel.isTestFlight(receiptURL: URL(string: "file:///app/StoreKit/receipt")!) == false)
        // No receipt at all (simulator / fresh install) is not TestFlight either.
        #expect(BuildChannel.isTestFlight(receiptURL: nil) == false)
    }

    @Test("debug surfaces are on in development and TestFlight, off in the App Store build")
    func debugSurfaceGate() {
        let appStore = URL(string: "file:///app/StoreKit/receipt")!
        let testFlight = URL(string: "file:///app/StoreKit/sandboxReceipt")!

        #expect(BuildChannel.debugSurfacesEnabled(receiptURL: appStore, isDebugBuild: false) == false)
        #expect(BuildChannel.debugSurfacesEnabled(receiptURL: testFlight, isDebugBuild: false))
        #expect(BuildChannel.debugSurfacesEnabled(receiptURL: appStore, isDebugBuild: true))
    }
}

// MARK: - Entry affordance on the two quiz screens

@MainActor
private func makeEntry(enabled: Bool) -> QuestionRatingEntry {
    QuestionRatingEntry(isEnabled: enabled) { questionId, questionText in
        QuestionRatingViewModel(
            questionId: questionId,
            questionText: questionText,
            ratingService: MockQuestionRatingService(),
            networkService: MockNetworkService()
        )
    }
}

@MainActor
private func makeAskingViewModel() -> QuizViewModel {
    let vm = Fixtures.makeViewModel()
    vm.currentSession = Fixtures.makeActiveSession()
    vm.currentQuestion = Question.preview
    vm.quizState = .askingQuestion
    return vm
}

@MainActor
private func makeResultViewModel() -> QuizViewModel {
    let vm = Fixtures.makeViewModel()
    vm.currentSession = Fixtures.makeActiveSession()
    vm.quizState = .showingResult(question: Question.preview, evaluation: .previewCorrect)
    return vm
}

@Suite("Rating entry chip gating (#155)")
@MainActor
struct QuestionRatingEntryTests {
    @Test("question screen shows the rating chip when the gate is open")
    func questionScreenShowsChipWhenEnabled() async throws {
        let view = QuestionView(viewModel: makeAskingViewModel(), ratingEntry: makeEntry(enabled: true))
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) {
                try tree.find(viewWithAccessibilityIdentifier: "rating.entry")
            }
        }
    }

    @Test("question screen hides the rating chip when the gate is closed")
    func questionScreenHidesChipWhenDisabled() async throws {
        let view = QuestionView(viewModel: makeAskingViewModel(), ratingEntry: makeEntry(enabled: false))
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: (any Error).self, "an App Store build must render no rating affordance") {
                try tree.find(viewWithAccessibilityIdentifier: "rating.entry")
            }
        }
    }

    @Test("result screen shows the rating chip when the gate is open")
    func resultScreenShowsChipWhenEnabled() async throws {
        let view = ResultView(viewModel: makeResultViewModel(), ratingEntry: makeEntry(enabled: true))
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) {
                try tree.find(viewWithAccessibilityIdentifier: "rating.entry")
            }
        }
    }

    @Test("result screen hides the rating chip when the gate is closed")
    func resultScreenHidesChipWhenDisabled() async throws {
        let view = ResultView(viewModel: makeResultViewModel(), ratingEntry: makeEntry(enabled: false))
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: (any Error).self, "an App Store build must render no rating affordance") {
                try tree.find(viewWithAccessibilityIdentifier: "rating.entry")
            }
        }
    }

    @Test("default construction (no entry passed) renders no chip at all")
    func defaultConstructionHasNoChip() async throws {
        let view = ResultView(viewModel: makeResultViewModel())
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: (any Error).self) {
                try tree.find(viewWithAccessibilityIdentifier: "rating.entry")
            }
        }
    }

    @Test("the chip targets the question just answered, not a later one")
    func resultChipTargetsTheAnsweredQuestion() {
        let answered = Fixtures.makeQuestion(id: "q_answered")
        let vm = Fixtures.makeViewModel()
        vm.currentSession = Fixtures.makeActiveSession()
        vm.quizState = .showingResult(question: answered, evaluation: .previewCorrect)
        // The quiz has already prefetched the NEXT question underneath the
        // result screen — rating must still describe the one on screen.
        vm.currentQuestion = Fixtures.makeQuestion(id: "q_next")

        #expect(vm.resultQuestion?.id == answered.id)
        #expect(vm.resultQuestion?.id != vm.currentQuestion?.id)
    }
}
