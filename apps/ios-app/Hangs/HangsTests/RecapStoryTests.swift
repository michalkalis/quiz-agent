//
//  RecapStoryTests.swift
//  HangsTests
//
//  #213.5 / #216.3 — the recap card. Why it matters: the recap is a saved
//  snapshot the server never recomputes, so this build must read its real
//  shape and skip what it does not know instead of losing the whole recap.
//  The card shows only the three numbers the founder picked; the server must
//  learn it was seen, and Share is how we learn whether players pass it on.
//

import Foundation
@testable import Hangs
import Testing

@Suite("Recap card (#213.5, #216.3)")
@MainActor
struct RecapStoryTests {
    /// `GET /me/recaps` as `app/api/routes/me_recaps.py` sends it: a month
    /// recap, and a kind this build has never heard of.
    private static let serverJSON = """
    {"recaps": [
      {"id": "a1", "kind": "month", "period_start": "2026-10-01", "created_at": "2026-11-01T08:00:00Z",
       "seen": false, "schema_version": 1,
       "payload": {"cards": [
          {"kind": "totals", "state": "unlocked", "progress": {"current": 0, "target": 0, "unit": "answers"},
           "data": {"answers": 120, "games": 12, "minutes": 80}},
          {"kind": "moon_phase", "state": "unlocked", "progress": {"current": 1, "target": 1, "unit": "moons"},
           "data": {"phase": "full"}},
          {"kind": "where", "state": "unlocked", "progress": {"current": 5, "target": 5, "unit": "games"},
           "data": {"top": "car", "share": 70, "games": 10, "breakdown": {"car": 7}}}
        ],
        "player_type": "road_tripper", "summary": {"answers": 120}, "timezone": "Europe/Bratislava"}},
      {"id": "b2", "kind": "decade", "period_start": "2020-01-01", "created_at": "2026-11-01T08:00:00Z",
       "seen": true, "schema_version": 1, "payload": {"cards": [], "player_type": "explorer"}}
    ]}
    """

    private func card(_ kind: String, _ content: StatCardContent) -> StatCard {
        StatCard(kind: kind, progress: .init(current: 1, target: 1, unit: "games"), content: content)
    }

    private func recap(_ cards: [StatCard], kind: PlayerRecap.Kind? = .month, seen: Bool = false) -> PlayerRecap {
        PlayerRecap(id: "r", kind: kind, periodStart: "2026-10-01", seen: seen, cards: cards, playerType: "speedster")
    }

    @Test("reads the server's recaps; an unknown recap kind decodes without failing the list")
    func decodesServerShape() throws {
        let recaps = try JSONDecoder().decode(PlayerRecaps.self, from: Data(Self.serverJSON.utf8)).recaps
        #expect(recaps.map(\.id) == ["a1", "b2"])
        #expect(recaps[0].kind == .month)
        #expect(recaps[0].period?.month == 10)
        #expect(recaps[0].playerType == "road_tripper")
        #expect(recaps[0].cards.first?.content == .totals(answers: 120, minutes: 80))
        #expect(recaps[1].kind == nil)
    }

    @Test("the card shows total, strong suit and when you play, in that order, whatever order the server sends")
    func highlightsOrder() {
        let model = ProfileViewModel(service: MockPlayerStatsService(), tokenStore: RecapStubTokenStore())
        let rows = model.highlights(of: recap([
            card("best_streak", .bestStreak(length: 9)),
            card("when", .whenYouPlay(partOfDay: "evening", weekday: "sunday")),
            card("totals", .totals(answers: 312, minutes: 200)),
            card("where", .whereYouPlay(place: "car", share: 64)),
            card("best_category", .bestCategory(category: "history", accuracy: 82)),
        ]))
        // Founder 2026-10-30: only these three are interesting enough for the card.
        #expect(rows.map(\.kind) == ["totals", "best_category", "when"])
    }

    @Test("the card never shows a raw id: an unknown or off-taxonomy number is left out")
    func highlightsSkipWhatTheyCannotTell() {
        let model = ProfileViewModel(service: MockPlayerStatsService(), tokenStore: RecapStubTokenStore())
        let rows = model.highlights(of: recap([
            card("totals", .totals(answers: 50, minutes: 30)),
            card("best_category", .bestCategory(category: "astrology", accuracy: 90)),
            card("when", .unknown),
        ]))
        #expect(rows.map(\.kind) == ["totals"])
    }

    @Test("the month reads as a title says it in each language")
    func monthName() {
        let october = recap([])
        #expect(october.monthName(locale: Locale(identifier: "sk")) == "október")
        #expect(october.monthName(locale: Locale(identifier: "cs")) == "říjen")
        #expect(october.monthName(locale: Locale(identifier: "en")) == "October")
    }

    @Test("the newest known recap becomes the card; showing it tells the server once")
    func cardAndSeen() async throws {
        let service = MockPlayerStatsService(recaps: [.success([recap([], seen: false), recap([], kind: nil)])])
        let model = ProfileViewModel(service: service, tokenStore: RecapStubTokenStore())
        await model.refresh().value
        #expect(model.recaps.count == 1)
        let shown = try #require(model.latestRecap)

        model.recapShown(shown)
        #expect(model.latestRecap?.seen == true)
        model.recapShown(model.latestRecap!)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(service.seenIDs == ["r"])
    }

    @Test("a failed recap fetch keeps the card the player already has")
    func failedRecapFetchKeepsBanner() async {
        let service = MockPlayerStatsService(recaps: [.success([recap([])]), .failure(.invalidResponse)])
        let model = ProfileViewModel(service: service, tokenStore: RecapStubTokenStore())
        await model.refresh().value
        await model.refresh().value
        #expect(model.latestRecap?.id == "r")
    }

    @Test("Share is measured when the share sheet opens")
    func shareAnalytics() {
        let analytics = MockAnalyticsClient()
        let model = ProfileViewModel(service: MockPlayerStatsService(), tokenStore: RecapStubTokenStore(), analytics: analytics)

        model.shareOpened(recap([]))

        #expect(analytics.events == [.recapShared(kind: "month")])
    }

    @Test("an account change drops the previous player's recaps")
    func resetDropsRecaps() async {
        let model = ProfileViewModel(service: MockPlayerStatsService(recaps: [.success([recap([])])]), tokenStore: RecapStubTokenStore())
        await model.refresh().value
        model.reset()
        #expect(model.latestRecap == nil)
    }
}

private final nonisolated class RecapStubTokenStore: TokenStore, @unchecked Sendable {
    func load() -> AuthTokens? { nil }
    func save(_: AuthTokens) {}
    func clear() {}
}
