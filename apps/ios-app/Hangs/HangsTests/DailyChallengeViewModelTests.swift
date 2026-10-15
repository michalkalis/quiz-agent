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
