//
//  DailyChallengeConditionTests.swift
//  HangsTests
//
//  #235.2 (flow × condition, daily challenge row). The Home card is the only
//  door into the daily challenge, so it must offer play while the server is
//  slow, and a late answer for another quiz language must never overwrite the
//  card the player is looking at. Failed fetches and a failed start already
//  have tests (DailyChallengeViewModelTests, QuizViewModelDailyChallengeTests).
//

import Clocks
import Foundation
@testable import Hangs
import Testing

@Suite("Daily challenge on a bad network (#235.2)")
@MainActor
struct DailyChallengeConditionTests {
    /// 2026-10-15 10:00 UTC.
    private static let instant = Date(timeIntervalSince1970: 1_792_058_400)

    private func makeModel(_ network: MockNetworkService) -> DailyChallengeViewModel {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return DailyChallengeViewModel(network: network, now: { Self.instant }, calendar: calendar)
    }

    // WHY: a slow server must not hide the challenge: until the day's state
    // arrives the card offers play (the start itself fetches the session).
    @Test("while today's state is on its way the card already offers the challenge")
    func slowFetchStillOffersPlay() async {
        let network = MockNetworkService()
        let hold = network.hold(.fetchDailyChallenge)
        let model = makeModel(network)
        let refresh = Task { await model.refreshToday(language: "sk") }
        await pumpUntil { hold.heldCount == 1 }

        #expect(model.card == .notPlayed)

        hold.release()
        await refresh.value
        #expect(model.state?.language == "sk")
    }

    // WHY: the player switched the quiz language while the old language's
    // state was still loading. When it lands it describes another challenge
    // and must be dropped, or the card would show a result (or an offer) for
    // a challenge the player is not about to play.
    @Test("a late answer for the previous quiz language never replaces the card")
    func lateAnswerForOldLanguageIsDropped() async {
        let network = MockNetworkService()
        let hold = network.hold(.fetchDailyChallenge)
        let model = makeModel(network)
        let slovak = Task { await model.refreshToday(language: "sk") }
        await pumpUntil { hold.heldCount == 1 }

        network.gates[.fetchDailyChallenge] = nil
        await model.refreshToday(language: "en")
        #expect(model.state?.language == "en")

        hold.release()
        await slovak.value
        #expect(model.state?.language == "en", "the Slovak answer replaced the English card")
    }
}
