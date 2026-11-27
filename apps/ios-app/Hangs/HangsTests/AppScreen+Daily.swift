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
        case .dailyEndGood: await Self.roundEnd(marks: DailyChallengeFixtures.goodMarks, bonusLeft: 10, crew: Self.crew)
        case .dailyEndWeak: await Self.roundEnd(marks: DailyChallengeFixtures.weakMarks)
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

    /// #239: a good day with a crew of two friends (the weak day has none).
    private static let crew = DailyCrew(weekStart: "2026-10-12", members: [
        DailyCrewMember(memberId: "m-1", name: "Peter", points: 240, today: 65, days: 3, place: 1, isYou: false),
        DailyCrewMember(memberId: nil, name: nil, points: 185, today: 120, days: 2, place: 2, isYou: true),
        DailyCrewMember(memberId: "m-2", name: "Mama", points: 90, today: 0, days: 2, place: 3, isYou: false),
    ])

    /// #251: the day's five questions, answered as the marks say.
    private static let questions: [(text: String, answer: String, wrong: String)] = [
        ("Ktoré mesto je hlavným mestom Kanady?", "Ottawa", "Toronto"),
        ("Koľko strún má klasické husle?", "Štyri", "Päť"),
        ("Ktorá rieka preteká Budapešťou?", "Dunaj", "Váh"),
        ("Ktorá planéta je najbližšie k Slnku?", "Merkúr", "Venuša"),
        ("Z ktorej krajiny pochádza pizza?", "Taliansko", "Grécko"),
    ]

    private static func roundEnd(marks: [Bool?], bonusLeft: Int? = nil, crew: DailyCrew? = nil) async -> AnyView {
        // #248.3: the good day earned the reward line; the weak one did not.
        let base = played(marks)
        let state = bonusLeft == nil ? base : DailyChallengeState(
            date: base.date, language: base.language, status: base.status, total: base.total, summary: base.summary,
            bonusOffer: 10, bonusLeft: bonusLeft, daysPlayed: 1
        )
        let vm = Fixtures.makeViewModel(clock: AnyClock(TestClock()))
        await fillLedger(vm, rounds: zip(marks, questions).enumerated().map { index, pair in
            let (mark, q) = pair
            let result: Evaluation.EvaluationResult = mark == nil ? .skipped : mark == true ? .correct : .incorrect
            return (index + 1, q.text, q.answer, result, mark == false ? q.wrong : (mark == true ? q.answer : ""), "geography-world")
        })
        vm.activeDaily = DailyRound(day: day, language: "sk", state: state)
        vm.quizState = .finished
        let network = network(state)
        network.stubbedDailyCrew = crew
        let daily = DailyChallengeViewModel(network: network, now: { fixedNow }, day: day, state: state)
        return AnyView(DailyRoundEndView(viewModel: vm, daily: daily, crew: DailyCrewViewModel(network: network, crew: crew)))
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
