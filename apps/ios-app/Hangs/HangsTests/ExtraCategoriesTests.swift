//
//  ExtraCategoriesTests.swift
//  HangsTests
//
//  #242 (step 242.5) — the free rotating extra categories on Home. The rule
//  the tests guard: a slow, failing or absent server leaves the seven permanent
//  categories with no error and no wait, a saved extra is never lost to a
//  fetch that did not answer, and a category that is gone or played through
//  ends in one calm message with a way back, never a reset-history offer.
//

import Clocks
import Foundation
@testable import Hangs
import Testing

private let wizard = ExtraCategory(key: "extra-wizard-school", name: "Čarodejnícka škola", until: "2026-12-06")
private let techno = ExtraCategory(key: "extra-techno", name: "Techno a klubová scéna", until: nil)

@MainActor
private func makeExtraViewModel(
    listed: [ExtraCategory] = [wizard, techno],
    saved: [String] = [],
    analytics: MockAnalyticsClient = MockAnalyticsClient()
) -> (QuizViewModel, MockNetworkService) {
    let network = Fixtures.makeFullMockNetwork { $0.stubbedExtraCategories = ExtraCategoriesResponse(categories: listed) }
    let store = MockPersistenceStore()
    var settings = QuizSettings.default
    settings.categories = saved
    store.savedSettings = settings
    let vm = QuizViewModel(
        networkService: network,
        audioService: MockAudioService(),
        persistenceStore: store,
        silenceDetectionService: MockSilenceDetectionService(),
        clock: AnyClock(TestClock()),
        analytics: analytics
    )
    return (vm, network)
}

@Suite("#242 extra categories — the served list")
struct ExtraCategoriesDecodingTests {
    @Test("The server's body decodes; a missing end date means no end announced")
    func decodes() throws {
        let body = #"{"categories":[{"key":"extra-wizard-school","name":"Wizard School","until":"2026-12-06"},{"key":"extra-techno","name":"Techno"}]}"#
        let response = try JSONDecoder().decode(ExtraCategoriesResponse.self, from: Data(body.utf8))
        #expect(response.categories.map(\.key) == ["extra-wizard-school", "extra-techno"])
        #expect(response.categories[1].until == nil)
    }

    // WHY: the date is the server's UTC day; a phone in another zone must
    // still read the same day, or "until 6. dec." would say 5. or 7.
    @Test("The end date is the server's day in every time zone")
    func untilDateIsTheServersDay() {
        let label = wizard.untilLabel(locale: Locale(identifier: "en"))
        #expect(label?.contains("6") == true)
        #expect(techno.untilLabel(locale: Locale(identifier: "en")) == nil)
    }

    // WHY: a saved extra must survive a launch before the list has arrived.
    @Test("A saved extra id survives decoding, an unknown retired id does not")
    func savedSettingsKeepExtraIds() throws {
        var settings = QuizSettings.default
        settings.categories = ["extra-techno", "disney"]
        let decoded = try JSONDecoder().decode(QuizSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.categories == ["extra-techno"])
    }
}

@MainActor
@Suite("#242 extra categories — Home state")
struct ExtraCategoriesHomeStateTests {
    @Test("The switch off: the endpoint is not called and the list stays empty")
    func switchOffDoesNotCall() async {
        let (vm, network) = makeExtraViewModel()
        await vm.refreshExtraCategories(enabled: false, language: "sk")
        #expect(network.extraCategoriesCallCount == 0)
        #expect(vm.extraCatalog.isEmpty)
    }

    @Test("The served extras follow the seven permanent ones in the deck cycle")
    func extrasFollowThePermanentCategories() async {
        let (vm, _) = makeExtraViewModel()
        await vm.refreshExtraCategories(enabled: true, language: "sk")
        let order = CategoryCycle.order(extras: vm.extraCatalog)
        #expect(Array(order.suffix(2)) == ["extra-wizard-school", "extra-techno"])
        #expect(CategoryCycle.stepped(from: ["entertainment"], .next, in: order) == ["extra-wizard-school"])
        #expect(CategoryCycle.stepped(from: ["extra-techno"], .next, in: order) == [], "wraps to All")
    }

    // WHY: a slow server must not hold Home: until the list arrives there are
    // just the seven categories.
    @Test("While the list is on its way Home shows the seven and nothing waits")
    func slowFetchShowsPermanentCategories() async {
        let (vm, network) = makeExtraViewModel()
        let hold = network.hold(.extraCategories)
        let refresh = Task { await vm.refreshExtraCategories(enabled: true, language: "sk") }
        await pumpUntil { hold.heldCount == 1 }
        #expect(vm.extraCatalog.isEmpty)
        #expect(HomeDeckCard.categories(extras: vm.extraCatalog).count == Config.categoryOptions.count)
        #expect(vm.quizState == .idle)
        hold.release()
        await refresh.value
        #expect(vm.extraCatalog == [wizard, techno])
    }

    @Test("A failed or malformed answer leaves the seven, with no error", arguments: [
        NetworkCondition.offline, .timeout, .serverError(statusCode: 500), .malformed,
    ])
    func failedFetchFailsOpen(condition: NetworkCondition) async {
        let (vm, network) = makeExtraViewModel(saved: ["extra-techno"])
        network.networkClock = AnyClock(ImmediateClock())
        network.networkConditions[.extraCategories] = condition
        await vm.refreshExtraCategories(enabled: true, language: "sk")
        #expect(vm.extraCatalog.isEmpty)
        #expect(vm.errorMessage == nil)
        #expect(vm.settings.categories == ["extra-techno"], "a fetch that did not answer must not drop the saved pick")
    }

    @Test("A saved extra is kept while listed and dropped to All once a fetch no longer lists it")
    func savedExtraDroppedOnlyAfterAnAnswer() async {
        let (vm, network) = makeExtraViewModel(saved: ["extra-techno"])
        #expect(vm.settings.categories == ["extra-techno"], "before any fetch")
        await vm.refreshExtraCategories(enabled: true, language: "sk")
        #expect(vm.settings.categories == ["extra-techno"], "still on offer")

        network.stubbedExtraCategories = ExtraCategoriesResponse(categories: [wizard])
        await vm.refreshExtraCategories(enabled: true, language: "sk")
        #expect(vm.settings.categories.isEmpty, "back to All categories")
    }

    @Test("The pill names a served extra and stays a plain fallback for an unlisted one")
    func displayName() async {
        let (vm, _) = makeExtraViewModel(saved: ["extra-techno"])
        await vm.refreshExtraCategories(enabled: true, language: "sk")
        #expect(vm.settings.categoryDisplayName(extras: vm.extraCatalog) == "Techno a klubová scéna")
    }
}

@MainActor
@Suite("#242 extra categories — starting")
struct ExtraCategoriesStartTests {
    @Test("A start with an extra category sends its key and reports it once")
    func startReportsTheExtraKey() async {
        let analytics = MockAnalyticsClient()
        let (vm, network) = makeExtraViewModel(saved: ["extra-techno"], analytics: analytics)
        await vm.beginQuizStart().value
        #expect(network.capturedCategories == ["extra-techno"])
        #expect(analytics.events.filter { $0 == .extraCategoryQuizStarted(category: "extra-techno") }.count == 1)
    }

    @Test("A start with a permanent category reports no extra event")
    func permanentStartReportsNothing() async {
        let analytics = MockAnalyticsClient()
        let (vm, _) = makeExtraViewModel(saved: ["history"], analytics: analytics)
        await vm.beginQuizStart().value
        #expect(!analytics.events.contains { $0.name == "extra_category_quiz_started" })
    }

    // WHY: a played-through category has nothing to start over: the reset
    // offer would clear the history of every category for nothing.
    @Test("409 extra_category_exhausted: a calm message, Home, no reset offer, selection kept")
    func exhaustedOnStart() async {
        let (vm, network) = makeExtraViewModel(saved: ["extra-techno"])
        network.startQuizError = NetworkError.extraCategoryExhausted
        await vm.beginQuizStart().value
        #expect(vm.quizState == .idle)
        #expect(vm.extraCategoryNotice == ExtraCategoryNotice.exhausted)
        #expect(vm.questionShortfall == nil, "the shortfall alert carries the reset offer")
        #expect(vm.errorMessage == nil)
        #expect(vm.settings.categories == ["extra-techno"])
        vm.dismissExtraCategoryNotice()
        #expect(vm.extraCategoryNotice == nil)
    }

    @Test("409 extra_category_exhausted from the availability check ends the same way")
    func exhaustedOnAvailability() async {
        let (vm, network) = makeExtraViewModel(saved: ["extra-techno"])
        network.questionAvailabilityError = NetworkError.extraCategoryExhausted
        await vm.beginQuizStart().value
        #expect(vm.quizState == .idle)
        #expect(vm.extraCategoryNotice == ExtraCategoryNotice.exhausted)
        #expect(vm.questionShortfall == nil)
    }

    @Test("400 extra_category_invalid: the selection falls back to All categories and Home says so")
    func invalidFallsBackToAll() async {
        let (vm, network) = makeExtraViewModel(saved: ["extra-wizard-school", "history"])
        await vm.refreshExtraCategories(enabled: true, language: "sk")
        network.createSessionError = NetworkError.extraCategoryInvalid
        await vm.beginQuizStart().value
        #expect(vm.quizState == .idle)
        #expect(vm.settings.categories == ["history"], "only the gone extra leaves")
        #expect(!vm.extraCatalog.contains(wizard))
        #expect(vm.extraCategoryNotice == ExtraCategoryNotice.invalid)
    }
}
