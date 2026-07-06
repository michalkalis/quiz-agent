//
//  HomeCategoryMultiSelectTests.swift
//  HangsTests
//
//  #82 item 4 (decision 7) — Home categories are multi-select and the
//  selection must actually reach the create-session request.
//
//  Why these tests matter:
//  - Before #82 the single-select picker was a silent end-to-end no-op: the
//    backend stored `category` but filtered questions on the never-populated
//    `preferred_categories` list. The wiring test pins the request contract
//    (a `categories` list) so the picker can never regress into decoration.
//  - The display-name test locks the picker's value semantics: empty = All
//    Categories, one = its name, several = a count — the row label is the
//    only place the user can read their selection back.
//

import Foundation
@testable import Hangs
import Testing

@MainActor
@Suite("Home category multi-select (#82)")
struct HomeCategoryMultiSelectTests {

    @Test("selected categories reach the create-session request")
    func selectedCategoriesReachRequest() async {
        let network = Fixtures.makeFullMockNetwork()
        let vm = QuizViewModel(
            networkService: network,
            audioService: MockAudioService(),
            persistenceStore: MockPersistenceStore()
        )
        vm.settings.categories = ["kids", "disney"]

        await vm.startNewQuiz()

        #expect(network.capturedCategories == ["kids", "disney"],
                "the Home multi-select must reach the session request or it's a silent no-op")
    }

    @Test("no selection sends an empty list (= all categories)")
    func emptySelectionSendsEmptyList() async {
        let network = Fixtures.makeFullMockNetwork()
        let vm = QuizViewModel(
            networkService: network,
            audioService: MockAudioService(),
            persistenceStore: MockPersistenceStore()
        )

        await vm.startNewQuiz()

        #expect(network.capturedCategories == [])
    }

    @Test("category display name reflects selection count")
    func displayNameReflectsSelection() {
        var settings = QuizSettings.default

        settings.categories = []
        #expect(settings.categoryDisplayName() == Config.categoryOptions[0].display)

        settings.categories = ["kids"]
        #expect(settings.categoryDisplayName() == Config.categoryOptions.first { $0.id == "kids" }?.display)

        settings.categories = ["kids", "disney"]
        #expect(settings.categoryDisplayName().contains("2"))
    }
}
