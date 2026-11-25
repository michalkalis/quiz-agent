//
//  RecapPasteDailyEndTests.swift
//  HangsTests
//
//  #240 — app quality from idle subscription capacity, 240.9 approved changes
//  (track F): the recap picture travels with a link, a pasted message with a
//  link opens the quiz, the daily round end keeps its numbers while open, and
//  an unseen older recap is not lost behind a newer one.
//

import Clocks
import Foundation
@testable import Hangs
import SwiftUI
import Testing
import ViewInspector

@Suite("Recap share, paste, daily end, recap order (#240)")
@MainActor
struct RecapPasteDailyEndTests {
    private static let token = "Ab3_k9-ZxQ"

    // MARK: - Recap share carries a link

    // WHY: the story picture alone gave the friend nothing to tap; with a
    // line and the trubbo.app address the share can bring a player.
    @Test("the recap picture is shared with a line and the trubbo.app address")
    func recapShareCarriesLink() {
        // ProfileRecapCard's ShareLink sends this as its message; the card's
        // picture is @State rendered in `.task`, which ViewInspector cannot
        // read from a hosted view, so the message is checked at its source.
        let message = RecapCopy.shareMessage
        #expect(message.contains("https://trubbo.app"), "the recap goes out without a link: \(message)")
        #expect(message.split(separator: "\n").count == 2, "a line, then the address: \(message)")
    }

    @Test("the site address follows the language", arguments: [("sk", "https://trubbo.app/sk/"), ("cs", "https://trubbo.app/cs/"), ("uk", "https://trubbo.app/uk/"), ("en", "https://trubbo.app")])
    func homePagePerLanguage(language: String, url: String) {
        #expect(Config.homePageURL(languageCode: language).absoluteString == url)
    }

    // MARK: - Pasting the whole message

    // WHY: chats copy the whole message ("Play my quiz… " and the link). The
    // paste row turned that down and asked to tap the link again.
    @Test("a pasted message that contains the link opens the quiz")
    func pastedMessageOpens() {
        let analytics = MockAnalyticsClient()
        let inbox = SharedQuizInbox(isFirstLaunch: true, analytics: analytics, clipboardProbablyHasURL: { true })
        inbox.paste(["Zahraj si môj kvíz v Trubbe. Je to 10 otázok, mám 7. Koľko dáš ty?\nhttps://trubbo.app/play?s=\(Self.token)"])
        #expect(inbox.token == Self.token)
        #expect(!inbox.pasteMissed)
        #expect(analytics.events(named: "shared_quiz_pasted") == [.sharedQuizPasted(outcome: .opened)])
    }

    @Test("text without a quiz link is still turned down", arguments: [
        "hello", "Look at https://trubbo.app/join?t=Ab3_k9-ZxQ", "https://example.com/play?s=Ab3_k9-ZxQ",
    ])
    func pastedNonLinkMisses(text: String) {
        #expect(SharedQuizLink.token(fromPasted: text) == nil)
    }

    // MARK: - Daily round end keeps its numbers

    private static let day = DailyChallengeDay(year: 2026, month: 10, day: 15)

    private static func roundEnd(state: DailyChallengeState?, network: MockNetworkService) -> DailyRoundEndView {
        let vm = Fixtures.makeViewModel(clock: AnyClock(TestClock()))
        vm.activeDaily = DailyRound(day: day, language: "sk", state: state)
        vm.quizState = .finished
        return DailyRoundEndView(
            viewModel: vm,
            daily: DailyChallengeViewModel(network: network, day: day, state: state)
        )
    }

    // WHY (240.9): the crowd line and the crew table changed while the
    // screen was open, which confused. What the screen opened with stays;
    // the next opening shows the new numbers.
    @Test("numbers shown at opening stay while the screen is open")
    func numbersStayWhileOpen() async throws {
        let shown = DailyChallengeFixtures.playedState(date: Self.day.isoDate, language: "sk", marks: DailyChallengeFixtures.goodMarks)
        let network = MockNetworkService()
        network.stubbedDailyState = DailyChallengeState(
            date: shown.date, language: "sk", status: .played, total: shown.total,
            summary: DailySummary(score: 4, total: 5, marks: DailyChallengeFixtures.goodMarks, players: 9,
                                  comparison: "Lepšie skóre ako 7 z 8 hráčov.", rank: nil, bestHit: nil)
        )
        let view = Self.roundEnd(state: shown, network: network)

        try await ViewHosting.host(view) {
            for _ in 0 ..< 50 {
                await Task.yield()
            }
            #expect(network.fetchDailyChallengeCallCount == 0, "the crowd numbers were fetched again while open")
            #expect(network.fetchDailyCrewCallCount == 0, "the invite card is gone: nothing asks for the crew table")
            let tree = try view.inspect()
            #expect(throws: Never.self) { try tree.find(text: "Lepšie skóre ako 2 z 3 hráčov.") }
        }
    }

    // WHY: a screen that opens before the server's summary (the normal end
    // of a played round) still fills in once.
    @Test("what is missing at opening is fetched once")
    func missingNumbersFetchedOnce() async throws {
        let network = MockNetworkService()
        network.stubbedDailyState = DailyChallengeFixtures.playedState(date: Self.day.isoDate, language: "sk", marks: DailyChallengeFixtures.goodMarks)
        let view = Self.roundEnd(state: nil, network: network)

        try await ViewHosting.host(view) {
            await pumpUntil({ network.fetchDailyChallengeCallCount == 1 },
                            "the round end never asked for its numbers")
            for _ in 0 ..< 20 {
                await Task.yield()
            }
            #expect(network.fetchDailyChallengeCallCount == 1)
            #expect(network.fetchDailyCrewCallCount == 0)
        }
    }

    // MARK: - Unseen older recap

    private static func recap(_ id: String, _ periodStart: String, seen: Bool) -> PlayerRecap {
        PlayerRecap(id: id, kind: .month, periodStart: periodStart, seen: seen, cards: [], playerType: "speedster")
    }

    // WHY: the card showed only the newest recap, so an October recap the
    // player never opened was lost for good once November's arrived.
    @Test("an unseen older recap shows first; the card stays while open; the next visit moves on")
    func unseenOlderRecapFirst() async {
        let defaults = UserDefaults(suiteName: "RecapPasteDailyEndTests.recaps")!
        defaults.removePersistentDomain(forName: "RecapPasteDailyEndTests.recaps")
        let november = Self.recap("nov", "2026-11-01", seen: false)
        let october = Self.recap("oct", "2026-10-01", seen: false)
        let service = MockPlayerStatsService(recaps: [
            .success([november, october]),
            .success([november, Self.recap("oct", "2026-10-01", seen: true)]),
        ])
        let model = ProfileViewModel(service: service, tokenStore: NoTokenStore(), defaults: defaults)

        await model.refresh().value
        #expect(model.latestRecap?.id == "oct", "the unseen October recap is hidden behind November's")

        model.recapShown(model.latestRecap!)
        #expect(model.latestRecap?.id == "oct", "the card swapped while the player looked at it")

        await model.refresh().value
        #expect(model.latestRecap?.id == "nov")
        defaults.removePersistentDomain(forName: "RecapPasteDailyEndTests.recaps")
    }

    @Test("with every recap seen the card is the newest")
    func allSeenShowsNewest() async {
        let service = MockPlayerStatsService(recaps: [.success([
            Self.recap("nov", "2026-11-01", seen: true), Self.recap("oct", "2026-10-01", seen: true),
        ])])
        let model = ProfileViewModel(service: service, tokenStore: NoTokenStore())
        await model.refresh().value
        #expect(model.latestRecap?.id == "nov")
    }
}

private final nonisolated class NoTokenStore: TokenStore, @unchecked Sendable {
    func load() -> AuthTokens? { nil }
    func save(_: AuthTokens) {}
    func clear() {}
}
