//
//  FamilyModeTests.swift
//  HangsTests
//
//  #236 — family mode „S deťmi“ on Home (increment A1 of
//  docs/issues/issue-236-family-mode-build.md). Why these matter:
//  - with the server switches off (production today) Home and every start
//    must be exactly what they were; a leak shows a half-built mode to
//    every player or sends `age_band` the server answers 403 to;
//  - a family round is one topic of one band and the server picks it whole,
//    so the start must carry exactly that and skip the #174 availability
//    probe (a probe with the adult categories would block or shorten it);
//  - the mode is remembered across launches (founder 2026-11-18), the age is
//    asked once, and an empty topic must not trap the parent in a loop.
//

import Clocks
import Foundation
@testable import Hangs
import SwiftUI
import Testing
import ViewInspector

@MainActor
private func makeFamilyViewModel(
    store: MockPersistenceStore = MockPersistenceStore(),
    analytics: MockAnalyticsClient = MockAnalyticsClient(),
    topics: FamilyTopicsResponse = FamilyModeFixtures.topics
) -> (QuizViewModel, MockNetworkService) {
    let network = Fixtures.makeFullMockNetwork { $0.stubbedFamilyTopics = topics }
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

@Suite("#236 family mode — switches")
@MainActor
struct FamilyModeSwitchTests {
    private func store(
        _ config: RemoteAppConfig,
        testFlight: Bool = true,
        storefront: String? = nil,
        asked: (() -> Void)? = nil
    ) async -> AppConfigStore {
        let store = AppConfigStore(
            fetch: { config },
            defaults: UserDefaults(suiteName: "family-\(UUID().uuidString)")!,
            isAppStoreBuild: !testFlight,
            sendsTestFlightChannel: testFlight,
            storefront: {
                asked?()
                return storefront
            }
        )
        await store.refresh()
        return store
    }

    private func config(on: Bool, appStore: Bool = false, hidden: [String] = []) -> RemoteAppConfig {
        RemoteAppConfig(
            minVersionAppStore: nil, minVersionTestflight: nil, ordersEnabled: true, notice: nil,
            familyModeEnabled: on, familyModeEnabledAppStore: appStore, familyModeHiddenStorefronts: hidden
        )
    }

    @Test("Production today: both switches off, the mode is off on every channel")
    func offByDefault() async {
        #expect(await !store(config(on: false)).familyModeEnabled)
        #expect(await !store(config(on: false), testFlight: false).familyModeEnabled)
        // A server that predates the keys decodes as off, never on.
        let decoded = try? JSONDecoder().decode(RemoteAppConfig.self, from: Data("{}".utf8))
        #expect(decoded?.familyModeEnabled == false)
        #expect(decoded?.familyModeHiddenStorefronts == [])
    }

    @Test("TestFlight needs the main switch only; the App Store build needs both (server rule)")
    func channelRule() async {
        #expect(await store(config(on: true)).familyModeEnabled)
        #expect(await !store(config(on: true), testFlight: false).familyModeEnabled)
        #expect(await store(config(on: true, appStore: true), testFlight: false).familyModeEnabled)
    }

    @Test("A hidden country hides the mode; with a list set and no country known it stays hidden")
    func storefrontLever() async {
        #expect(await !store(config(on: true, hidden: ["USA"]), storefront: "USA").familyModeEnabled)
        #expect(await store(config(on: true, hidden: ["USA"]), storefront: "SVK").familyModeEnabled)
        #expect(await !store(config(on: true, hidden: ["USA"]), storefront: nil).familyModeEnabled)
    }

    @Test("StoreKit is not asked while no country is hidden")
    func storefrontOnlyWhenNeeded() async {
        var asked = 0
        _ = await store(config(on: true), asked: { asked += 1 })
        #expect(asked == 0)
    }
}

@Suite("#236 family mode — Home state")
@MainActor
struct FamilyModeHomeStateTests {
    @Test("Switch off: no topics are fetched and a saved 'on' does not show the mode")
    func switchOffHidesTheMode() async {
        let store = MockPersistenceStore()
        store.familySettings = FamilySettings(isOn: true, band: .kids7to9)
        let (vm, network) = makeFamilyViewModel(store: store)

        await vm.refreshFamilyTopics(enabled: false, language: "sk")

        #expect(network.familyTopicsCallCount == 0)
        #expect(!vm.isFamilyModeAvailable)
        #expect(!vm.isFamilyModeOn)
        // The parent's choice survives the switch going off.
        #expect(vm.familySettings == FamilySettings(isOn: true, band: .kids7to9))
    }

    @Test("Topics come per quiz language; a band this build does not know is dropped")
    func topicsPerLanguage() async {
        let response = FamilyTopicsResponse(bands: [
            .init(band: "kids_7_9", topics: [FamilyTopic(key: "family-lego", name: "LEGO", roundSize: 10)]),
            .init(band: "kids_13_15", topics: [FamilyTopic(key: "family-x", name: "X", roundSize: 10)]),
        ])
        let (vm, network) = makeFamilyViewModel(topics: response)

        await vm.refreshFamilyTopics(enabled: true, language: "cs")

        #expect(network.capturedFamilyTopicsLanguage == "cs")
        #expect(vm.familyBands == [.kids7to9])
    }

    @Test("No topics in the quiz language: no switch")
    func noTopicsNoSwitch() async {
        let (vm, _) = makeFamilyViewModel(topics: FamilyTopicsResponse(bands: []))
        await vm.refreshFamilyTopics(enabled: true, language: "uk")
        #expect(!vm.isFamilyModeAvailable)
    }

    @Test("The first flip asks for the age; the mode turns on only with a band")
    func firstFlipAsksForTheBand() async {
        let analytics = MockAnalyticsClient()
        let (vm, _) = makeFamilyViewModel(analytics: analytics)
        await vm.refreshFamilyTopics(enabled: true, language: "sk")

        vm.setFamilyMode(true)
        #expect(vm.showingFamilyBandSheet)
        #expect(!vm.isFamilyModeOn, "closing the sheet without a pick must leave Home on Kvíz")
        vm.dismissFamilyBandSheet()
        #expect(!vm.isFamilyModeOn)

        vm.setFamilyMode(true)
        vm.selectFamilyBand(.kids4to6)
        #expect(!vm.showingFamilyBandSheet)
        #expect(vm.isFamilyModeOn)
        #expect(vm.familyTopic?.key == "family-dinosaurs", "the band's first topic until one is picked")
        #expect(analytics.events == [
            .familyBandSelected(band: .kids4to6, firstTime: true),
            .familyModeChanged(enabled: true),
        ])

        // Later flips never ask again: the age is changed in the Vek pill.
        vm.setFamilyMode(false)
        vm.setFamilyMode(true)
        #expect(!vm.showingFamilyBandSheet)
        vm.selectFamilyBand(.kids10to12)
        #expect(analytics.events.last == .familyBandSelected(band: .kids10to12, firstTime: false))
    }

    @Test("Mode, band and the topic per band survive a relaunch")
    func modeIsRemembered() async {
        let store = MockPersistenceStore()
        let (vm, _) = makeFamilyViewModel(store: store)
        await vm.refreshFamilyTopics(enabled: true, language: "sk")
        vm.setFamilyMode(true)
        vm.selectFamilyBand(.kids7to9)
        vm.stepFamilyTopic(.next)
        vm.selectFamilyBand(.kids4to6)
        vm.selectFamilyTopic("family-your-body")

        let (relaunched, _) = makeFamilyViewModel(store: store)
        await relaunched.refreshFamilyTopics(enabled: true, language: "sk")

        #expect(relaunched.isFamilyModeOn)
        #expect(relaunched.familySettings.band == .kids4to6)
        #expect(relaunched.familyTopic?.key == "family-your-body")
        relaunched.selectFamilyBand(.kids7to9)
        #expect(relaunched.familyTopic?.key == "family-minecraft", "each band keeps its own last topic")
    }

    @Test("A real PersistenceStore keeps the family settings under their own key")
    func persistenceRoundTrip() {
        let isolated = IsolatedDefaults()
        let store = isolated.makeStore()
        #expect(store.loadFamilySettings() == FamilySettings())
        let settings = FamilySettings(isOn: true, band: .kids10to12, topicByBand: ["kids_10_12": "family-harry-potter"])
        store.saveFamilySettings(settings)
        #expect(isolated.makeStore().loadFamilySettings() == settings)
        // An unreadable value never takes the solo settings with it.
        isolated.defaults.set(Data("garbage".utf8), forKey: "family_settings")
        #expect(isolated.makeStore().loadFamilySettings() == FamilySettings())
    }

    @Test("The deck steps one topic per tap and wraps, with analytics")
    func deckSteps() async {
        let analytics = MockAnalyticsClient()
        let (vm, _) = makeFamilyViewModel(analytics: analytics)
        await vm.refreshFamilyTopics(enabled: true, language: "sk")
        vm.selectFamilyBand(.kids10to12)

        vm.stepFamilyTopic(.next)
        #expect(vm.familyTopic?.key == "family-spies-and-codes")
        vm.stepFamilyTopic(.next)
        #expect(vm.familyTopic?.key == "family-harry-potter")
        #expect(analytics.events.last == .familyTopicSelected(band: .kids10to12, topic: "family-harry-potter"))
    }
}

@Suite("#236 family mode — starting a round")
@MainActor
struct FamilyModeStartTests {
    private func readyViewModel(
        band: FamilyBand = .kids7to9,
        analytics: MockAnalyticsClient = MockAnalyticsClient()
    ) async -> (QuizViewModel, MockNetworkService) {
        let (vm, network) = makeFamilyViewModel(analytics: analytics)
        await vm.refreshFamilyTopics(enabled: true, language: "sk")
        vm.selectFamilyBand(band)
        return (vm, network)
    }

    @Test("Štart s deťmi sends the band and exactly one topic, and skips the availability probe")
    func startCarriesBandAndOneTopic() async {
        let (vm, network) = await readyViewModel()
        vm.settings.categories = ["history", "sports"]
        vm.settings.includeImageQuestions = true

        await vm.beginFamilyStart()?.value

        #expect(network.capturedAgeBand == "kids_7_9")
        #expect(network.capturedCategories == ["family-lego"])
        #expect(network.capturedIncludeImages == false)
        #expect(network.capturedMaxQuestions == 10)
        #expect(network.questionAvailabilityCallCount == 0, "the server picks the round whole; the adult probe would cut it")
        #expect(vm.quizState == .askingQuestion)
        #expect(vm.activeFamily == FamilyRound(band: .kids7to9, topic: "family-lego", roundSize: 10))
    }

    @Test("With the switch off Start is today's quiz: no band, the adult categories, the probe runs")
    func switchOffStartIsUnchanged() async {
        let store = MockPersistenceStore()
        store.familySettings = FamilySettings(isOn: true, band: .kids7to9)
        let (vm, network) = makeFamilyViewModel(store: store)
        await vm.refreshFamilyTopics(enabled: false, language: "sk")
        vm.settings.categories = ["history"]

        #expect(vm.beginFamilyStart() == nil)
        await vm.beginQuizStart().value

        #expect(network.capturedAgeBand == nil)
        #expect(network.capturedCategories == ["history"])
        #expect(network.questionAvailabilityCallCount == 1)
        #expect(vm.activeFamily == nil)
    }

    @Test("409 family_topic_empty hides the topic until relaunch, moves on, and does not refetch")
    func emptyTopicHides() async {
        let analytics = MockAnalyticsClient()
        let (vm, network) = await readyViewModel(analytics: analytics)
        network.startQuizError = NetworkError.familyTopicEmpty
        let fetches = network.familyTopicsCallCount

        await vm.beginFamilyStart()?.value

        #expect(vm.quizState == .idle, "Home, not the error screen")
        #expect(vm.familyTopic?.key == "family-minecraft")
        #expect(!vm.familyBandTopics.contains { $0.key == "family-lego" })
        #expect(network.familyTopicsCallCount == fetches, "a refetch would bring the cached topic straight back")
        #expect(analytics.events.contains(.familyTopicEmpty(band: .kids7to9, topic: "family-lego")))

        // A refresh (Home reappearing) keeps it hidden: only a relaunch forgets.
        await vm.refreshFamilyTopics(enabled: true, language: "sk")
        #expect(vm.familyTopic?.key == "family-minecraft")
        // The same key in another band is another set of questions.
        #expect(vm.hiddenFamilyTopics == ["kids_7_9/family-lego"])
    }

    @Test("Play Again replays the same family round")
    func playAgainReplaysTheRound() async {
        let (vm, network) = await readyViewModel(band: .kids4to6)
        await vm.beginFamilyStart()?.value
        vm.quizState = .finished
        network.capturedAgeBand = nil

        await vm.playAgain().value

        #expect(network.capturedAgeBand == "kids_4_6")
        #expect(network.capturedCategories == ["family-dinosaurs"])
    }

    @Test("A family session is known from the session's band (also after a restore)")
    func familySessionFromSession() {
        let (vm, _) = makeFamilyViewModel()
        var session = QuizSession.preview()
        #expect(!vm.isFamilySession)
        session.ageBand = "kids_4_6"
        vm.currentSession = session
        #expect(vm.isFamilySession)
    }

    @Test("The server's session band and the start's repeats decode")
    func decodesServerFields() throws {
        let json = """
        {"success": true, "message": "ok", "repeats": true,
         "session": {"session_id": "s", "mode": "single", "phase": "asking", "max_questions": 6,
          "current_difficulty": "random", "category": "family-dinosaurs", "language": "sk",
          "participants": [], "expires_at": "2026-11-18T10:00:00Z", "created_at": "2026-11-18T09:00:00Z",
          "age_band": "kids_4_6"}}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let response = try decoder.decode(QuizResponse.self, from: Data(json.utf8))
        #expect(response.repeats == true)
        #expect(response.session.ageBand == "kids_4_6")
    }
}

@Suite("#236 family mode — Home view")
@MainActor
struct FamilyModeHomeViewTests {
    private func appConfig(on: Bool) async -> AppConfigStore {
        let store = AppConfigStore(
            fetch: {
                RemoteAppConfig(minVersionAppStore: nil, minVersionTestflight: nil, ordersEnabled: true, notice: nil, familyModeEnabled: on)
            },
            defaults: UserDefaults(suiteName: "family-home-\(UUID().uuidString)")!,
            sendsTestFlightChannel: true,
            storefront: { nil }
        )
        await store.refresh()
        return store
    }

    private func ids(_ view: HomeView) async throws -> Set<String> {
        var found: Set<String> = []
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            for node in tree.findAll(where: { (try? $0.accessibilityIdentifier()) != nil }) {
                if let id = try? node.accessibilityIdentifier() { found.insert(id) }
            }
        }
        return found
    }

    @Test("Switch off: Home has no switch and keeps difficulty, categories and Quick quiz")
    func switchOffHomeUnchanged() async throws {
        let store = MockPersistenceStore()
        store.familySettings = FamilySettings(isOn: true, band: .kids4to6)
        let (vm, _) = makeFamilyViewModel(store: store)
        let found = try await ids(HomeView(viewModel: vm, appConfig: appConfig(on: false)))

        #expect(!found.contains("home.mode"))
        #expect(!found.contains("home.startFamily"))
        #expect(found.isSuperset(of: ["home-difficulty-menu", "home-categories-menu", "home.quickGame", "home.startQuiz"]))
    }

    @Test("Mode on: switch, Vek and Téma pills, Štart s deťmi; Quick quiz and Choose several gone")
    func modeOnHome() async throws {
        let store = MockPersistenceStore()
        store.familySettings = FamilySettings(isOn: true, band: .kids7to9)
        let (vm, _) = makeFamilyViewModel(store: store)
        await vm.refreshFamilyTopics(enabled: true, language: "sk")
        let found = try await ids(HomeView(viewModel: vm, appConfig: appConfig(on: true)))

        #expect(found.isSuperset(of: ["home.mode", "home.band.menu", "home.topic.menu", "home.startFamily", "home.family.adultAnswers"]))
        #expect(found.isDisjoint(with: ["home-difficulty-menu", "home-categories-menu", "home.quickGame", "home.categories.chooseSeveral", "home.startQuiz"]))
    }
}
