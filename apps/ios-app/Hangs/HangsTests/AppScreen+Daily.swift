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
        case .dailyEndGood: Self.roundEnd(marks: DailyChallengeFixtures.goodMarks, crew: Self.crew)
        case .dailyEndWeak: Self.roundEnd(marks: DailyChallengeFixtures.weakMarks)
        case .homeDaily: await Self.home(state: nil)
        case .homeDailyPlayed: await Self.home(state: Self.played(DailyChallengeFixtures.goodMarks))
        default: preconditionFailure("\(self) is not a daily challenge screen")
        }
    }

    private static func played(_ marks: [Bool?]) -> DailyChallengeState {
        DailyChallengeFixtures.playedState(date: day.isoDate, language: "sk", marks: marks)
    }

    private static func network(_ state: DailyChallengeState?) -> MockNetworkService {
        let network = MockNetworkService()
        network.stubbedDailyState = state
        return network
    }

    /// #239: a good day with a crew of two friends (the weak day has none).
    private static let crew = DailyCrew(weekStart: "2026-10-12", members: [
        DailyCrewMember(memberId: "m-1", name: "Peter", points: 240, today: 65, days: 3, place: 1, isYou: false),
        DailyCrewMember(memberId: nil, name: nil, points: 185, today: 120, days: 2, place: 2, isYou: true),
        DailyCrewMember(memberId: "m-2", name: "Mama", points: 90, today: 0, days: 2, place: 3, isYou: false),
    ])

    private static func roundEnd(marks: [Bool?], crew: DailyCrew? = nil) -> AnyView {
        let state = played(marks)
        let vm = Fixtures.makeViewModel(clock: AnyClock(TestClock()))
        vm.activeDaily = DailyRound(day: day, language: "sk", state: state)
        vm.quizState = .finished
        let network = network(state)
        network.stubbedDailyCrew = crew
        let daily = DailyChallengeViewModel(network: network, now: { fixedNow }, day: day, state: state)
        let crewModel = DailyCrewViewModel(network: network, crew: crew)
        return AnyView(DailyRoundEndView(viewModel: vm, daily: daily, crew: crewModel))
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
