//
//  AppScreen+Daily.swift
//  HangsTests
//
//  #205 — daily challenge: the round end (a good and a weak day) and Home
//  with the card (not played, played). Home snapshots without the card stay
//  as they were: the card shows only with the server switch on.
//

import Clocks
import Foundation
@testable import Hangs
import SwiftUI

extension AppScreen {
    /// 2026-10-15 10:00 UTC: the fixtures' day, whatever the host's clock says.
    private static let fixedNow = Date(timeIntervalSince1970: 1_792_058_400)
    private static let day = DailyChallengeDay(year: 2026, month: 10, day: 15)

    func makeDaily() async -> AnyView {
        switch self {
        case .dailyEndGood: Self.roundEnd(marks: DailyChallengeFixtures.goodMarks, bonusLeft: 10)
        case .dailyEndWeak: Self.roundEnd(marks: DailyChallengeFixtures.weakMarks)
        case .homeDaily: await Self.home(state: nil)
        case .homeDailyPlayed: await Self.home(state: Self.played(DailyChallengeFixtures.goodMarks))
        case .homeDailyOffer:
            await Self.home(state: DailyChallengeState(
                date: Self.day.isoDate, language: "sk", status: .notPlayed, total: 5, summary: nil, bonusOffer: 10
            ))
        case .homeDailyPlayedBonus:
            await Self.home(state: Self.withBonus(Self.played(DailyChallengeFixtures.goodMarks)))
        default: preconditionFailure("\(self) is not a daily challenge screen")
        }
    }

    /// #205.8: a finished day with the reward still all there and three days played.
    private static func withBonus(_ base: DailyChallengeState) -> DailyChallengeState {
        DailyChallengeState(
            date: base.date, language: base.language, status: base.status, total: base.total, summary: base.summary,
            bonusOffer: 10, bonusLeft: 10, daysPlayed: 3
        )
    }

    private static func played(_ marks: [Bool?]) -> DailyChallengeState {
        DailyChallengeFixtures.playedState(date: day.isoDate, language: "sk", marks: marks)
    }

    private static func network(_ state: DailyChallengeState?) -> MockNetworkService {
        let network = MockNetworkService()
        network.stubbedDailyState = state
        return network
    }

    private static func roundEnd(marks: [Bool?], bonusLeft: Int? = nil) -> AnyView {
        // #248.3: the good day earned the reward line; the weak one did not.
        let base = played(marks)
        let state = bonusLeft == nil ? base : DailyChallengeState(
            date: base.date, language: base.language, status: base.status, total: base.total, summary: base.summary,
            bonusOffer: 10, bonusLeft: bonusLeft, daysPlayed: 1
        )
        let vm = Fixtures.makeViewModel(clock: AnyClock(TestClock()))
        vm.activeDaily = DailyRound(day: day, language: "sk", state: state)
        vm.quizState = .finished
        let network = network(state)
        let daily = DailyChallengeViewModel(network: network, now: { fixedNow }, day: day, state: state)
        return AnyView(DailyRoundEndView(viewModel: vm, daily: daily))
    }

    private static func home(state: DailyChallengeState?) async -> AnyView {
        let usage = UsageInfo(
            userId: "snapshot-subject", isPremium: false, questionsUsed: 12, questionsLimit: 30, remaining: 18,
            resetsAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(12 * 86400 + 12 * 3600)),
            subscriptionStatus: "none", creditBalance: 0
        )
        let quizNetwork = network(state)
        quizNetwork.stubbedUsage = usage
        let vm = QuizViewModel(
            networkService: quizNetwork,
            audioService: MockAudioService(),
            persistenceStore: MockPersistenceStore(),
            silenceDetectionService: MockSilenceDetectionService(),
            clock: AnyClock(TestClock())
        )
        vm.usageInfo = usage
        vm.settings.language = "sk"
        let config = AppConfigStore(fetch: {
            RemoteAppConfig(minVersionAppStore: nil, minVersionTestflight: nil, ordersEnabled: true, notice: nil, dailyChallengeEnabled: true)
        })
        await config.refresh()
        let daily = DailyChallengeViewModel(network: quizNetwork, now: { fixedNow }, state: state)
        await daily.refreshToday(language: "sk")
        return AnyView(HomeView(viewModel: vm, appConfig: config, dailyChallenge: daily))
    }
}
