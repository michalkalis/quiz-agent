//
//  RecapStoryTests.swift
//  HangsTests
//
//  #213.5 — the recap story. Why it matters: the recap is a saved snapshot the
//  server never recomputes, so this build must read its real shape and skip
//  what it does not know instead of losing the whole recap. The story only
//  tells good news and always ends on the shareable player type. Opening a
//  recap must clear its "new" banner, and the two events are how we learn
//  whether players watch to the end and share.
//

import Foundation
@testable import Hangs
import Testing

@Suite("Recap story (#213.5)")
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

    @Test("story: totals first, highlights in story order, the player type last")
    func storyOrder() {
        let slides = RecapSlide.story(for: recap([
            card("best_streak", .bestStreak(length: 9)),
            card("totals", .totals(answers: 312, minutes: 200)),
            card("where", .whereYouPlay(place: "car", share: 64)),
            card("best_category", .bestCategory(category: "history", accuracy: 82)),
        ]))
        #expect(slides == [
            .intro(answers: 312, minutes: 200),
            .card(kind: "best_category", content: .bestCategory(category: "history", accuracy: 82)),
            .card(kind: "where", content: .whereYouPlay(place: "car", share: 64)),
            .card(kind: "best_streak", content: .bestStreak(length: 9)),
            .playerType("speedster"),
        ])
    }

    @Test("story only tells good news and never shows a raw id or more than five cards")
    func storySkipsWhatItCannotTell() {
        let slides = RecapSlide.story(for: recap([
            card("totals", .totals(answers: 50, minutes: 30)),
            card("best_category", .bestCategory(category: "astrology", accuracy: 90)),
            card("improvement", .improvement(deltaPoints: 5, direction: "down")),
            card("where", .unknown),
            card("weakest_category", .weakestCategory(category: "sports", accuracy: 20)),
        ]))
        #expect(slides == [.intro(answers: 50, minutes: 30), .playerType("speedster")])

        let full = RecapSlide.story(for: recap([
            card("best_category", .bestCategory(category: "history", accuracy: 82)),
            card("where", .whereYouPlay(place: "car", share: 64)),
            card("when", .whenYouPlay(partOfDay: "evening", weekday: "sunday")),
            card("improvement", .improvement(deltaPoints: 12, direction: "up")),
            card("best_streak", .bestStreak(length: 9)),
            card("fastest_slowest", .fastestCategory(category: "sports", medianMs: 2100)),
        ]))
        #expect(full.count == 6) // five cards + player type
        #expect(full.last == .playerType("speedster"))
    }

    @Test("the month reads as a title says it in each language")
    func monthName() {
        let october = recap([])
        #expect(october.monthName(locale: Locale(identifier: "sk")) == "október")
        #expect(october.monthName(locale: Locale(identifier: "cs")) == "říjen")
        #expect(october.monthName(locale: Locale(identifier: "en")) == "October")
    }

    @Test("the newest known recap becomes the banner; opening it clears 'new' and tells the server once")
    func bannerAndSeen() async throws {
        let service = MockPlayerStatsService(recaps: [.success([recap([], seen: false), recap([], kind: nil)])])
        let model = ProfileViewModel(service: service, tokenStore: RecapStubTokenStore())
        await model.refresh().value
        #expect(model.recaps.count == 1)
        let banner = try #require(model.latestRecap)

        model.play(banner)
        #expect(model.playingRecap == banner)
        #expect(model.latestRecap?.seen == true)
        await Task.yield()
        model.play(model.latestRecap!)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(service.seenIDs == ["r"])
    }

    @Test("a failed recap fetch keeps the banner the player already has")
    func failedRecapFetchKeepsBanner() async {
        let service = MockPlayerStatsService(recaps: [.success([recap([])]), .failure(.invalidResponse)])
        let model = ProfileViewModel(service: service, tokenStore: RecapStubTokenStore())
        await model.refresh().value
        await model.refresh().value
        #expect(model.latestRecap?.id == "r")
    }

    @Test("closing the story measures how far the player got; Share is measured on open")
    func storyAnalytics() {
        let analytics = MockAnalyticsClient()
        let model = ProfileViewModel(service: MockPlayerStatsService(), tokenStore: RecapStubTokenStore(), analytics: analytics)
        let october = recap([])
        model.play(october)

        model.shareOpened(october)
        model.storyClosed(october, slidesSeen: 3, slidesTotal: 6)

        #expect(model.playingRecap == nil)
        #expect(analytics.events == [
            .recapShared(kind: "month"),
            .recapViewed(kind: "month", slidesSeen: 3, slidesTotal: 6),
        ])
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
