//
//  ProfileViewModelTests.swift
//  HangsTests
//
//  #213.4 — the Profile tab. Why it matters: the stat cards are the reason a
//  player opens Profile, and the server adds card kinds without an app build
//  (they are plain strings on purpose), so this build must skip a kind it does
//  not know instead of failing the whole Profile. A network blip must not
//  blank cards already on screen, and a new account must never see the
//  previous player's numbers.
//

import Foundation
@testable import Hangs
import os
import SwiftUI
import Testing
import ViewInspector

@Suite("Profile stats and account (#213.4)")
@MainActor
struct ProfileViewModelTests {
    /// The server's real shape (`app/player_stats/cards.py`), with a kind
    /// this build has never heard of and a locked card with empty data.
    private static let serverJSON = """
    {
      "cards": [
        {"kind": "totals", "state": "unlocked", "progress": {"current": 0, "target": 0, "unit": "answers"},
         "data": {"answers": 312, "games": 31, "minutes": 200}},
        {"kind": "best_category", "state": "unlocked", "progress": {"current": 3, "target": 3, "unit": "categories"},
         "data": {"category": "geography-world", "accuracy": 82, "answers": 40, "standout": true, "versatile": false}},
        {"kind": "where", "state": "locked", "progress": {"current": 2, "target": 5, "unit": "games"}, "data": {}},
        {"kind": "moon_phase", "state": "unlocked", "progress": {"current": 1, "target": 1, "unit": "moons"},
         "data": {"phase": "full"}},
        {"kind": "typical_game", "state": "unlocked", "progress": {"current": 5, "target": 5, "unit": "games"},
         "data": {"minutes": 6.5, "answers": 10}}
      ],
      "first_recap_progress": {"answers": 37, "answers_target": 60, "days": 2, "days_target": 3}
    }
    """

    private func decoded() throws -> PlayerStats {
        try JSONDecoder().decode(PlayerStats.self, from: Data(Self.serverJSON.utf8))
    }

    private func card(_ kind: String, content: StatCardContent?) -> StatCard {
        StatCard(kind: kind, progress: .init(current: 1, target: 1, unit: "games"), content: content)
    }

    @Test("decodes the server's cards; a locked card has no content, an unknown kind decodes as unknown")
    func decodesServerShape() throws {
        let stats = try decoded()
        #expect(stats.cards.map(\.kind) == ["totals", "best_category", "where", "moon_phase", "typical_game"])
        #expect(stats.cards[0].content == .totals(answers: 312, minutes: 200))
        #expect(stats.cards[1].content == .bestCategory(category: "geography-world", accuracy: 82))
        #expect(stats.cards[2].isLocked)
        #expect(stats.cards[2].progress.remaining == 3)
        #expect(stats.cards[3].content == .unknown)
        #expect(stats.cards[4].content == .typicalQuiz(minutes: 6.5, answers: 10))
        #expect(stats.firstRecapProgress.answersLeft == 23)
        #expect(stats.firstRecapProgress.daysLeft == 1)
    }

    @Test("a known kind whose numbers changed shape reads as unknown, not as a failed Profile")
    func malformedKnownKindIsUnknown() throws {
        let json = """
        {"cards": [{"kind": "best_streak", "state": "unlocked",
                    "progress": {"current": 1, "target": 1, "unit": "games"}, "data": {"longest": 9}}],
         "first_recap_progress": {"answers": 0, "answers_target": 60, "days": 0, "days_target": 3}}
        """
        let stats = try JSONDecoder().decode(PlayerStats.self, from: Data(json.utf8))
        #expect(stats.cards.first?.content == .unknown)
    }

    @Test("shows unlocked cards first, drops unknown kinds and categories outside the taxonomy")
    func cardOrderAndFiltering() async {
        let stats = PlayerStats(
            cards: [
                card("where", content: nil),
                card("totals", content: .totals(answers: 5, minutes: 3)),
                card("moon_phase", content: .unknown),
                card("best_category", content: .bestCategory(category: "adults", accuracy: 90)),
                card("fastest_slowest", content: .fastestCategory(category: "history", medianMs: 2100)),
            ],
            firstRecapProgress: FirstRecapProgress(answers: 5, answersTarget: 60, days: 1, daysTarget: 3)
        )
        let model = ProfileViewModel(service: MockPlayerStatsService(results: [.success(stats)]), tokenStore: StubTokenStore(nil))

        await model.refresh().value

        #expect(model.cards.map(\.kind) == ["totals", "fastest_slowest", "where"])
        #expect(model.loadState == .loaded)
    }

    @Test("the first-recap card shows until the server says it is reached")
    func firstRecapCard() async {
        let model = ProfileViewModel(service: MockPlayerStatsService(results: [.success(.mockNewPlayer)]), tokenStore: StubTokenStore(nil))
        await model.refresh().value
        #expect(model.firstRecapProgress?.answersLeft == 23)

        let seasoned = ProfileViewModel(service: MockPlayerStatsService(results: [.success(.mockSeasoned)]), tokenStore: StubTokenStore(nil))
        await seasoned.refresh().value
        #expect(seasoned.firstRecapProgress == nil)
    }

    @Test("a failed first load offers Retry; a failed refresh keeps the cards on screen")
    func failureHandling() async {
        let failing = ProfileViewModel(service: MockPlayerStatsService(results: [.failure(.invalidResponse)]), tokenStore: StubTokenStore(nil))
        await failing.refresh().value
        #expect(failing.loadState == .failed)
        #expect(failing.cards.isEmpty)

        let service = MockPlayerStatsService(results: [.success(.mockSeasoned), .failure(.invalidResponse)])
        let model = ProfileViewModel(service: service, tokenStore: StubTokenStore(nil))
        await model.refresh().value
        await model.refresh().value
        #expect(model.loadState == .loaded)
        #expect(model.stats == .mockSeasoned)
    }

    @Test("an account change drops the previous player's cards")
    func resetDropsCards() async {
        let model = ProfileViewModel(service: MockPlayerStatsService(), tokenStore: StubTokenStore(nil))
        await model.refresh().value
        #expect(model.stats != nil)

        model.reset()

        #expect(model.stats == nil)
        #expect(model.loadState == .loading)
    }

    @Test("the account row: Apple name when signed in, else the name chosen for a game together")
    func accountName() throws {
        let defaults = try #require(UserDefaults(suiteName: "ProfileViewModelTests.accountName"))
        defaults.removePersistentDomain(forName: "ProfileViewModelTests.accountName")
        let names = PlayerNameStore(defaults: defaults)
        names.save("Rýchly gepard")

        let anonymous = ProfileViewModel(
            service: MockPlayerStatsService(),
            tokenStore: StubTokenStore(AuthTokens(accessToken: "a", refreshToken: "r", anonId: "anon")),
            nameStore: names
        )
        anonymous.appeared()
        #expect(anonymous.account == .init(name: "Rýchly gepard", isSignedIn: false))

        let signedIn = ProfileViewModel(
            service: MockPlayerStatsService(),
            tokenStore: StubTokenStore(AuthTokens(
                accessToken: "a", refreshToken: "r", anonId: "user",
                accountName: "Michal", accountEmail: nil, appleUserId: "apple"
            )),
            nameStore: names
        )
        signedIn.appeared()
        #expect(signedIn.account == .init(name: "Michal", isSignedIn: true))
    }

    @Test("opening the tab is measured, split by signed in or not")
    func tabOpenedIsTracked() {
        let analytics = MockAnalyticsClient()
        let model = ProfileViewModel(service: MockPlayerStatsService(), tokenStore: StubTokenStore(nil), analytics: analytics)

        model.tabOpened()

        #expect(analytics.events == [.profileOpened(hasAccount: false)])
    }

    @Test("a locked card names what is missing in its own unit, with the right plural")
    func remainingCopy() throws {
        func text(_ current: Int, _ target: Int, _ unit: String, _ language: String) throws -> String {
            try Text(ProfileStatTile.remaining(.init(current: current, target: target, unit: unit)))
                .inspect().text().string(locale: Locale(identifier: language))
        }
        #expect(try text(3, 5, "games", "en") == "2 more quizzes")
        #expect(try text(4, 5, "games", "en") == "1 more quiz")
        #expect(try text(1, 3, "days", "en") == "2 more days of play")
        // ViewInspector picks plurals by English rules, so the Slovak and Czech
        // forms (one / few / other) are read from the catalog directly.
        func resolved(_ resource: LocalizedStringResource, _ language: String) -> String {
            var resource = resource
            resource.locale = Locale(identifier: language)
            return String(localized: resource)
        }
        #expect(resolved("\(1) more quizzes", "sk") == "Ešte 1 kvíz")
        #expect(resolved("\(2) more quizzes", "sk") == "Ešte 2 kvízy")
        #expect(resolved("\(5) more quizzes", "sk") == "Ešte 5 kvízov")
        #expect(resolved("\(2) more days of play", "cs") == "Ještě 2 dny hraní")
        #expect(try text(0, 2, "moons", "en") == "Keep playing")
    }
}

private final nonisolated class StubTokenStore: TokenStore, @unchecked Sendable {
    private let lock: OSAllocatedUnfairLock<AuthTokens?>

    init(_ seed: AuthTokens?) {
        lock = OSAllocatedUnfairLock(initialState: seed)
    }

    func load() -> AuthTokens? { lock.withLock { $0 } }
    func save(_ tokens: AuthTokens) { lock.withLock { $0 = tokens } }
    func clear() { lock.withLock { $0 = nil } }
}
