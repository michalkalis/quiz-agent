//
//  DailyChallengeViewModelTests.swift
//  HangsTests
//
//  #205.4 — the Home card's state. Why it matters: the card is the only door
//  into the daily challenge, so a failed fetch must still offer it (the start
//  retries), a played day must show its result and the crowd line must move
//  as others play (the founder's success test: play first, see "Dnes si
//  prvý.", later see the numbers change). The date sent is the device's
//  local day, from an injected clock, never the wall clock.
//

import Foundation
@testable import Hangs
import Testing

@Suite("Daily challenge Home card model (#205.4)")
@MainActor
struct DailyChallengeViewModelTests {
    /// 2026-10-15 10:00 UTC.
    private static let instant = Date(timeIntervalSince1970: 1_792_058_400)
    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func makeModel(_ network: MockNetworkService) -> DailyChallengeViewModel {
        DailyChallengeViewModel(network: network, now: { Self.instant }, calendar: Self.utc)
    }

    private func played(comparison: String, score: Int = 4) -> DailyChallengeState {
        DailyChallengeState(
            date: "2026-10-15", language: "sk", status: .played, total: 5,
            summary: DailySummary(
                score: score, total: 5, marks: [true, true, false, true, true], players: 2,
                comparison: comparison, rank: nil, bestHit: nil
            )
        )
    }

    @Test("asks for today's local date in the quiz language")
    func fetchesToday() async {
        let network = MockNetworkService()
        let model = makeModel(network)

        await model.refreshToday(language: "sk")

        #expect(network.capturedDailyFetchDate == "2026-10-15")
        #expect(network.capturedDailyFetchLanguage == "sk")
        #expect(model.day == DailyChallengeDay(year: 2026, month: 10, day: 15))
    }

    private func state(
        _ status: DailyChallengeState.Status, offer: Int? = nil, left: Int? = nil, days: Int = 0
    ) -> DailyChallengeState {
        let summary = status == .played
            ? DailySummary(score: 4, total: 5, marks: [true, true, false, true, true], players: 2, comparison: nil, rank: nil, bestHit: nil)
            : nil
        return DailyChallengeState(
            date: "2026-10-15", language: "sk", status: status, total: 5, summary: summary,
            bonusOffer: offer, bonusLeft: left, daysPlayed: days
        )
    }

    private func refreshed(_ state: DailyChallengeState) async -> DailyChallengeViewModel {
        let network = MockNetworkService()
        network.stubbedDailyState = state
        let model = makeModel(network)
        await model.refreshToday(language: "sk")
        return model
    }

    @Test("205.8: not played with an offer: the promise is shown, nothing else about the reward")
    func promiseBeforePlaying() async {
        let model = await refreshed(state(.notPlayed, offer: 10))
        #expect(model.bonusPromise == 10)
        #expect(model.bonusLeft == nil)
        #expect(model.daysPlayed == nil)
    }

    @Test("205.8: no promise for a subscriber (nil), a reward switched off (0) or an interrupted run that already has none")
    func noPromiseWithoutOffer() async {
        #expect(await refreshed(state(.notPlayed)).bonusPromise == nil)
        #expect(await refreshed(state(.notPlayed, offer: 0)).bonusPromise == nil)
    }

    @Test("205.8: finished with extra questions left: one quiet line, and no promise any more")
    func leftAfterFinishing() async {
        let model = await refreshed(state(.played, offer: 10, left: 7, days: 3))
        #expect(model.bonusLeft == 7)
        #expect(model.bonusPromise == nil, "the promise is only for before playing")
        #expect(model.daysPlayed == 3)
    }

    @Test("205.8: finished with none left, expired or a subscriber: no reward line at all")
    func noLeftLine() async {
        #expect(await refreshed(state(.played, left: 0, days: 2)).bonusLeft == nil)
        #expect(await refreshed(state(.played, left: nil, days: 2)).bonusLeft == nil)
    }

    @Test("205.8: days played shows only once finished and at least one")
    func daysPlayedOnlyWhenFinished() async {
        #expect(await refreshed(state(.played, days: 0)).daysPlayed == nil)
        #expect(await refreshed(state(.played, days: 1)).daysPlayed == 1)
        #expect(await refreshed(state(.notPlayed, days: 5)).daysPlayed == nil, "a past count is not shown on today's open card")
    }

    @Test("205.8: the numbers follow a fresh fetch when the card reappears")
    func numbersRefreshOnReappear() async {
        let network = MockNetworkService()
        network.stubbedDailyState = state(.played, offer: 10, left: 10, days: 1)
        let model = makeModel(network)
        await model.refreshToday(language: "sk")
        #expect(model.bonusLeft == 10)
        network.stubbedDailyState = state(.played, offer: 10, left: 4, days: 1)
        await model.refreshToday(language: "sk")
        #expect(model.bonusLeft == 4)
    }

    @Test("205.8: a failed refresh keeps the last numbers instead of blanking the card")
    func failedRefreshKeepsNumbers() async {
        let network = MockNetworkService()
        network.stubbedDailyState = state(.played, left: 6, days: 2)
        let model = makeModel(network)
        await model.refreshToday(language: "sk")
        network.fetchDailyChallengeError = NetworkError.serverError(statusCode: 500, message: "boom")
        await model.refreshToday(language: "sk")
        #expect(model.bonusLeft == 6)
        #expect(model.daysPlayed == 2)
    }

    @Test("205.8: the round end fetches the finished state when the start only gave an in-progress one")
    func roundEndFetchesFinishedState() async {
        let network = MockNetworkService()
        network.stubbedDailyState = state(.played, left: 10, days: 1)
        let day = DailyChallengeDay(year: 2026, month: 10, day: 15)
        let model = DailyChallengeViewModel(network: network, now: { Self.instant }, calendar: Self.utc, day: day, state: state(.inProgress))
        await model.loadIfMissing(day: day, language: "sk")
        #expect(model.bonusLeft == 10, "bonus_left is only known after finishing, so the start's state cannot show it")
        #expect(network.fetchDailyChallengeCallCount == 1)
        await model.loadIfMissing(day: day, language: "sk")
        #expect(network.fetchDailyChallengeCallCount == 1, "numbers stay put once the finished state is here (#240)")
    }

    @Test("not played yet: the card offers the challenge")
    func notPlayed() async {
        let model = makeModel(MockNetworkService())
        await model.refreshToday(language: "sk")
        #expect(model.card == .notPlayed)
        #expect(model.questionCount == 5)
    }

    @Test("an interrupted challenge still offers play (the start resumes it)")
    func inProgress() async {
        let network = MockNetworkService()
        network.stubbedDailyState = DailyChallengeState(date: "2026-10-15", language: "sk", status: .inProgress, total: 5, summary: nil)
        let model = makeModel(network)
        await model.refreshToday(language: "sk")
        #expect(model.card == .notPlayed)
    }

    @Test("played: the card shows the result with the server's crowd line")
    func playedShowsResult() async {
        let network = MockNetworkService()
        network.stubbedDailyState = played(comparison: "Dnes si prvý.")
        let model = makeModel(network)

        await model.refreshToday(language: "sk")

        guard case let .played(summary) = model.card else {
            Issue.record("a played day must show its result, got \(model.card)")
            return
        }
        #expect(summary.score == 4)
        #expect(summary.comparison == "Dnes si prvý.")
    }

    @Test("every refresh picks up the crowd's new numbers")
    func refreshUpdatesNumbers() async {
        let network = MockNetworkService()
        network.stubbedDailyState = played(comparison: "Dnes si prvý.")
        let model = makeModel(network)
        await model.refreshToday(language: "sk")

        network.stubbedDailyState = played(comparison: "Najlepšie skóre z 2 hráčov.")
        await model.refreshToday(language: "sk")

        #expect(network.fetchDailyChallengeCallCount == 2)
        guard case let .played(summary) = model.card else {
            Issue.record("expected the played card")
            return
        }
        #expect(summary.comparison == "Najlepšie skóre z 2 hráčov.", "a second player finished: the line must move")
    }

    @Test("a failed fetch with nothing known shows the card to play")
    func failureShowsPlayCard() async {
        let network = MockNetworkService()
        network.fetchDailyChallengeError = URLError(.notConnectedToInternet)
        let model = makeModel(network)

        await model.refreshToday(language: "sk")

        #expect(model.card == .notPlayed, "the start retries; the card must never vanish")
        #expect(model.loadFailed)
    }

    @Test("a failed refresh keeps the day's result already shown")
    func failureKeepsLastResult() async {
        let network = MockNetworkService()
        network.stubbedDailyState = played(comparison: "Dnes si prvý.")
        let model = makeModel(network)
        await model.refreshToday(language: "sk")

        network.fetchDailyChallengeError = URLError(.timedOut)
        await model.refreshToday(language: "sk")

        #expect(model.card != .notPlayed, "a blip must not offer a challenge already played")
    }

    @Test("another quiz language is another challenge: the old result goes")
    func languageChangeDropsState() async {
        let network = MockNetworkService()
        network.stubbedDailyState = played(comparison: "Dnes si prvý.")
        let model = makeModel(network)
        await model.refreshToday(language: "sk")

        network.stubbedDailyState = nil
        network.fetchDailyChallengeError = URLError(.timedOut)
        await model.refreshToday(language: "cs")

        #expect(model.card == .notPlayed)
        #expect(network.capturedDailyFetchLanguage == "cs")
    }
}
