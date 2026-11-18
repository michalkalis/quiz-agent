//
//  CategoryCycleTests.swift
//  HangsTests
//
//  #224.6 — the Home deck steps one category per tap. The founder asked for
//  All → every category in the picker's order → back to All, so a player can
//  flip through single categories without opening the sheet. A multi-selection
//  must not trap the deck: its first tap leaves the set for a single category.
//

@testable import Hangs
import Testing

@MainActor
@Suite("Category deck cycle (#224.6)")
struct CategoryCycleTests {
    private let ids = Config.categoryOptions.compactMap(\.id)

    private func makeViewModel(categories: [String], analytics: AnalyticsClient = NoopAnalyticsClient()) -> QuizViewModel {
        let vm = QuizViewModel(
            networkService: Fixtures.makeFullMockNetwork(),
            audioService: MockAudioService(),
            persistenceStore: MockPersistenceStore(),
            silenceDetectionService: MockSilenceDetectionService(),
            analytics: analytics
        )
        vm.settings.categories = categories
        return vm
    }

    @Test("Forward from All visits every category in picker order, then wraps to All")
    func forwardCycleCoversEveryCategoryAndWraps() {
        var selection: [String] = []
        var visited: [[String]] = []
        for _ in 0 ... ids.count {
            selection = CategoryCycle.stepped(from: selection, .next)
            visited.append(selection)
        }
        #expect(visited == ids.map { [$0] } + [[]], "the deck would skip or repeat a category")
    }

    @Test("Backward from All lands on the last category and walks the order in reverse")
    func backwardWrapsToLastCategory() {
        #expect(CategoryCycle.stepped(from: [], .previous) == [ids.last!])
        #expect(CategoryCycle.stepped(from: [ids[1]], .previous) == [ids[0]])
        #expect(CategoryCycle.stepped(from: [ids[0]], .previous) == [])
    }

    @Test("A multi-selection steps from its first-picked category")
    func multiSelectionLeavesFromFirstPick() {
        // Picked in this order: sports first, then history.
        let picks = ["sports", "history"]
        #expect(CategoryCycle.stepped(from: picks, .next) == [ids[ids.firstIndex(of: "sports")! + 1]])
        #expect(CategoryCycle.stepped(from: picks, .previous) == [ids[ids.firstIndex(of: "sports")! - 1]])
    }

    @Test("An unknown id counts as All instead of crashing the deck")
    func unknownIdFallsBackToAll() {
        #expect(CategoryCycle.position(of: ["general"]) == 0)
        #expect(CategoryCycle.stepped(from: ["general"], .next) == [ids[0]])
    }

    @Test("The view model writes the stepped selection to the settings that start the quiz")
    func viewModelStepUpdatesSettings() {
        let vm = makeViewModel(categories: [])
        vm.stepCategory(.next)
        #expect(vm.settings.categories == [ids[0]])
        vm.stepCategory(.previous)
        vm.stepCategory(.previous)
        #expect(vm.settings.categories == [ids.last!], "a tap must change what the next quiz is drawn from")
    }

    @Test("A step reports its direction, how it was made and the category it landed on")
    func stepIsLogged() {
        let analytics = MockAnalyticsClient()
        let vm = makeViewModel(categories: [], analytics: analytics)
        vm.stepCategory(.next)
        vm.stepCategory(.previous, input: .voiceover)
        #expect(analytics.events == [
            .homeCategoryStepped(direction: .next, input: .tap, to: ids[0]),
            .homeCategoryStepped(direction: .previous, input: .voiceover, to: "all"),
        ], "the metric splits deck use from the picker and tap from VoiceOver")
    }

    @Test("Opening the picker reports where from")
    func pickerOpenIsLogged() {
        let analytics = MockAnalyticsClient()
        let vm = makeViewModel(categories: [], analytics: analytics)
        vm.categoryPickerOpened(from: .deckButton)
        vm.categoryPickerOpened(from: .pill)
        #expect(analytics.events == [.homeCategoryPickerOpened(source: .deckButton), .homeCategoryPickerOpened(source: .pill)])
    }
}
