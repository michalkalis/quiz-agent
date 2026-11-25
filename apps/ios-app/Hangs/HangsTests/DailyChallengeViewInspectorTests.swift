//
//  DailyChallengeViewInspectorTests.swift
//  HangsTests
//
//  #205 — the daily challenge screens at the element level (#57 altitude:
//  presence and order, not pixels). Why: founder decision 2 puts the crowd
//  strip in ONE place on every verdict (#224: the card's bottom row, left of
//  the source link); the round end is peak-end ordered (score, comparison,
//  best hit last) and must never offer a second attempt; the Home card must
//  stay hidden while the server switch is off.
//

import Clocks
import Foundation
@testable import Hangs
import SwiftUI
import Testing
import ViewInspector

@MainActor
private func texts<V>(_ tree: InspectableView<V>) -> [String] {
    tree.findAll(ViewType.Text.self).compactMap { try? $0.string() }
}

@MainActor
private func resultViewModel(result: Evaluation.EvaluationResult, said: String, crowd: CrowdStrip?, answer: String = "Libanon") -> QuizViewModel {
    let vm = Fixtures.makeViewModel(clock: AnyClock(TestClock()))
    let question = Fixtures.makeQuestion(id: "q_daily")
    var round = DailyRound(day: DailyChallengeDay(year: 2026, month: 10, day: 15), language: "sk")
    round.crowds["q_daily"] = crowd
    vm.activeDaily = round
    vm.currentSession = Fixtures.makeActiveSession(maxQuestions: 5)
    vm.quizState = .showingResult(
        question: question,
        evaluation: Evaluation(
            userAnswer: said, result: result, points: result == .correct ? 1 : 0,
            correctAnswer: answer, questionId: "q_daily", explanation: nil
        )
    )
    return vm
}

@Suite("Daily challenge crowd strip on the result card (#205.5)")
@MainActor
struct DailyCrowdStripInspectorTests {
    @Test("the strip shows for every kind the server sends", arguments: [
        (Evaluation.EvaluationResult.correct, "Libanon", DailyChallengeFixtures.rare),
        (.correct, "Libanon", DailyChallengeFixtures.plain),
        (.correct, "Libanon", DailyChallengeFixtures.first),
        (.incorrect, "Sýria", DailyChallengeFixtures.hard),
    ])
    func stripPresent(result: Evaluation.EvaluationResult, said: String, crowd: CrowdStrip) async throws {
        let view = ResultView(viewModel: resultViewModel(result: result, said: said, crowd: crowd))
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) { try tree.find(viewWithAccessibilityIdentifier: "result.crowd") }
            #expect(throws: Never.self, "the server's sentence, verbatim") { try tree.find(text: crowd.text) }
            if crowd.kind == .first {
                #expect(throws: (any Error).self, "the first player has nothing to measure") {
                    try tree.find(viewWithAccessibilityIdentifier: "result.crowd.meter")
                }
            } else {
                #expect(throws: Never.self) { try tree.find(viewWithAccessibilityIdentifier: "result.crowd.meter") }
            }
        }
    }

    @Test("no strip when the answer carries none (a wrong answer most knew, or a regular round)")
    func stripAbsent() async throws {
        let view = ResultView(viewModel: resultViewModel(result: .incorrect, said: "Sýria", crowd: nil))
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: (any Error).self) { try tree.find(viewWithAccessibilityIdentifier: "result.crowd") }
        }
    }

    @Test("the strip sits in the card's bottom row, after the answer and what was said")
    func stripPosition() async throws {
        let view = ResultView(viewModel: resultViewModel(result: .incorrect, said: "Sýria", crowd: DailyChallengeFixtures.hard))
        try await ViewHosting.host(view) {
            let order = try texts(view.inspect())
            let answer = try #require(order.firstIndex(of: "Libanon"))
            let strip = try #require(order.firstIndex(of: DailyChallengeFixtures.hard.text))
            let said = try #require(order.firstIndex(where: { $0.contains("Sýria") }))
            #expect(answer < said && said < strip, "#224 calm result: answer, what was said, then the strip in the bottom row — got \(order)")
        }
    }

    @Test("recap mode (nothing to show as an answer) has no strip")
    func noStripInRecap() async throws {
        let view = ResultView(viewModel: resultViewModel(result: .incorrect, said: "Sýria", crowd: DailyChallengeFixtures.rare, answer: ""))
        try await ViewHosting.host(view) {
            #expect(throws: (any Error).self) { try view.inspect().find(viewWithAccessibilityIdentifier: "result.crowd") }
        }
    }
}

@Suite("Daily round end (#205.5)")
@MainActor
struct DailyRoundEndInspectorTests {
    private func makeView(marks: [Bool?], bonusLeft: Int? = nil) -> DailyRoundEndView {
        let day = DailyChallengeDay(year: 2026, month: 10, day: 15)
        var state = DailyChallengeFixtures.playedState(date: day.isoDate, language: "sk", marks: marks)
        if let bonusLeft {
            state = DailyChallengeState(
                date: state.date, language: state.language, status: state.status, total: state.total, summary: state.summary,
                bonusOffer: 10, bonusLeft: bonusLeft, daysPlayed: 1
            )
        }
        let vm = Fixtures.makeViewModel(clock: AnyClock(TestClock()))
        vm.activeDaily = DailyRound(day: day, language: "sk", state: state)
        vm.quizState = .finished
        let network = MockNetworkService()
        network.stubbedDailyState = state
        return DailyRoundEndView(viewModel: vm, daily: DailyChallengeViewModel(network: network, day: day, state: state))
    }

    // WHY (#248.3, founder variant B "Minimum"): the end is quiet. The score
    // is the headline, then the tiles, then one reward line and the server's
    // crowd sentence as one quiet line; the cards that crowded it are gone.
    @Test("score headline, tiles, reward line, then the quiet crowd line; no cards")
    func goodRoundOrder() async throws {
        let view = makeView(marks: DailyChallengeFixtures.goodMarks, bonusLeft: 10)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            let order = texts(tree)
            let label = try #require(order.firstIndex(of: "Daily challenge · done"))
            let score = try #require(order.firstIndex(of: "4"))
            let reward = try #require(order.firstIndex(of: "As a reward you get 10 extra questions today."))
            let comparison = try #require(order.firstIndex(of: "Lepšie skóre ako 2 z 3 hráčov."))
            #expect(label < score && score < reward && reward < comparison, "\(order)")
            #expect(throws: Never.self) { try tree.find(viewWithAccessibilityIdentifier: "daily.tiles") }
            #expect(throws: Never.self) { try tree.find(viewWithAccessibilityIdentifier: "daily.comparison") }
            for gone in ["COMPLETE", "final score", "few knew this one", "your best answer"] {
                #expect(!order.contains(gone), "\(gone) crowded the screen the founder wanted calm")
            }
            #expect(throws: (any Error).self, "the best-hit card is gone") { try tree.find(viewWithAccessibilityIdentifier: "daily.bestHit") }
        }
    }

    @Test("no reward line when no bonus is left")
    func noRewardWithoutBonus() async throws {
        let view = makeView(marks: DailyChallengeFixtures.weakMarks)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: (any Error).self) { try tree.find(viewWithAccessibilityIdentifier: "daily.bonusLeft") }
            let order = texts(tree)
            #expect(order.contains("Ťažká výzva."))
            #expect(!order.contains { $0.localizedStandardContains("horší") || $0.localizedStandardContains("worse") })
        }
    }

    // WHY: sharing is the icon in the top bar (Apple's place for it) and the
    // invite card is gone; "Next quiz" is the one filled action, Home sits
    // under it. One challenge a day, so still no Play Again and no upsell.
    @Test("Share is a top-bar icon, Next quiz and Home are the footer, no invite card")
    func footer() async throws {
        let view = makeView(marks: DailyChallengeFixtures.goodMarks)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            for id in ["daily.close", "daily.share", "daily.nextQuiz", "daily.home"] {
                #expect(throws: Never.self, "\(id) missing") { try tree.find(viewWithAccessibilityIdentifier: id) }
            }
            let order = texts(tree)
            #expect(order.contains("Next quiz"))
            #expect(!order.contains("Share"), "Share is an icon now, not a footer button")
            #expect(!order.contains("Play Again"))
            #expect(!order.contains { $0.contains("friend") || $0.contains("kamarát") }, "the invite card is gone: \(order)")
            #expect(throws: (any Error).self) { try tree.find(viewWithAccessibilityIdentifier: "completion.upsell") }
        }
    }

    // WHY (founder 2026-11-25): after the daily challenge "again" makes no
    // sense; Next quiz starts an ordinary quiz, the same as spoken "again".
    @Test("Next quiz starts an ordinary quiz through a tracked start")
    func nextQuizStartsOrdinaryQuiz() async throws {
        let view = makeView(marks: DailyChallengeFixtures.goodMarks)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            let vm = view.viewModel
            #expect(vm.activeDaily != nil)
            #expect(!vm.taskBag.contains(.quizStart))
            try tree.find(viewWithAccessibilityIdentifier: "daily.nextQuiz").button().tap()
            #expect(vm.taskBag.contains(.quizStart), "Home must be able to cancel the start Next quiz spawned")
            vm.taskBag.cancelAll()
        }
    }

    @Test("no comparison yet: no crowd line, the round's own score stands in")
    func comparisonHiddenWhenNil() async throws {
        let day = DailyChallengeDay(year: 2026, month: 10, day: 15)
        let vm = Fixtures.makeViewModel(clock: AnyClock(TestClock()))
        vm.activeDaily = DailyRound(day: day, language: "sk")
        vm.quizState = .finished
        let view = DailyRoundEndView(viewModel: vm, daily: DailyChallengeViewModel(network: MockNetworkService(), day: day))
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: (any Error).self) { try tree.find(viewWithAccessibilityIdentifier: "daily.comparison") }
        }
    }
}

@Suite("Daily challenge Home card (#205.4)")
@MainActor
struct HomeDailyChallengeSectionInspectorTests {
    private func store(enabled: Bool) async -> AppConfigStore {
        let store = AppConfigStore(fetch: {
            RemoteAppConfig(minVersionAppStore: nil, minVersionTestflight: nil, ordersEnabled: true, notice: nil, dailyChallengeEnabled: enabled)
        })
        await store.refresh()
        return store
    }

    private func section(_ store: AppConfigStore, _ model: DailyChallengeViewModel) -> HomeDailyChallengeSection {
        HomeDailyChallengeSection(
            appConfig: store, viewModel: model, language: "sk",
            isStarting: false, isStartDisabled: false, onPlay: { _ in }
        )
    }

    @Test("switch off: no card at all")
    func hiddenWhenOff() async throws {
        let view = await section(store(enabled: false), DailyChallengeViewModel(network: MockNetworkService()))
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: (any Error).self) { try tree.find(viewWithAccessibilityIdentifier: "home.daily") }
        }
    }

    @Test("not played: the title, and the play pill")
    func notPlayedCard() async throws {
        let view = await section(store(enabled: true), DailyChallengeViewModel(network: MockNetworkService()))
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) { try tree.find(text: "Five questions. The same for everyone.") }
            #expect(throws: Never.self) { try tree.find(viewWithAccessibilityIdentifier: "home.daily.play") }
        }
    }

    @Test("205.8: the promise shows before playing only when an offer is on, and no after-lines")
    func promiseOnCard() async throws {
        let network = MockNetworkService()
        network.stubbedDailyState = DailyChallengeState(date: "2026-10-15", language: "sk", status: .notPlayed, total: 5, summary: nil, bonusOffer: 10)
        let withOffer = DailyChallengeViewModel(network: network, now: { Date(timeIntervalSince1970: 1_792_058_400) })
        await withOffer.refreshToday(language: "sk")
        let view = await section(store(enabled: true), withOffer)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) { try tree.find(viewWithAccessibilityIdentifier: "home.daily.bonusOffer") }
            #expect(throws: (any Error).self) { try tree.find(viewWithAccessibilityIdentifier: "home.daily.bonusLeft") }
        }
        let none = await section(store(enabled: true), DailyChallengeViewModel(network: MockNetworkService()))
        try await ViewHosting.host(none) {
            #expect(throws: (any Error).self, "a subscriber or older server hears nothing about a reward") {
                try none.inspect().find(viewWithAccessibilityIdentifier: "home.daily.bonusOffer")
            }
        }
    }

    @Test("205.8: finished: the left line and days played; none left means no reward line")
    func leftAndDaysOnCard() async throws {
        let base = DailyChallengeFixtures.playedState(date: "2026-10-15", language: "sk", marks: DailyChallengeFixtures.goodMarks)
        func model(left: Int?) -> DailyChallengeViewModel {
            let state = DailyChallengeState(
                date: base.date, language: base.language, status: base.status, total: base.total, summary: base.summary,
                bonusOffer: 10, bonusLeft: left, daysPlayed: 3
            )
            let network = MockNetworkService()
            network.stubbedDailyState = state
            return DailyChallengeViewModel(network: network, now: { Date(timeIntervalSince1970: 1_792_058_400) }, state: state)
        }
        let withLeft = await section(store(enabled: true), model(left: 10))
        try await ViewHosting.host(withLeft) {
            let tree = try withLeft.inspect()
            #expect(throws: Never.self) { try tree.find(viewWithAccessibilityIdentifier: "home.daily.bonusLeft") }
            #expect(throws: Never.self) { try tree.find(viewWithAccessibilityIdentifier: "home.daily.daysPlayed") }
            #expect(throws: (any Error).self, "the promise is gone once played") { try tree.find(viewWithAccessibilityIdentifier: "home.daily.bonusOffer") }
        }
        let used = await section(store(enabled: true), model(left: 0))
        try await ViewHosting.host(used) {
            let tree = try used.inspect()
            #expect(throws: (any Error).self) { try tree.find(viewWithAccessibilityIdentifier: "home.daily.bonusLeft") }
            #expect(throws: Never.self) { try tree.find(viewWithAccessibilityIdentifier: "home.daily.daysPlayed") }
        }
    }

    @Test("played: the score and the crowd line, the card opens the round end")
    func playedCard() async throws {
        let state = DailyChallengeFixtures.playedState(date: "2026-10-15", language: "sk", marks: DailyChallengeFixtures.goodMarks)
        let network = MockNetworkService()
        network.stubbedDailyState = state
        // Pinned to the state's day, so the card's own refresh keeps it.
        let model = DailyChallengeViewModel(network: network, now: { Date(timeIntervalSince1970: 1_792_058_400) }, state: state)
        let view = await section(store(enabled: true), model)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) { try tree.find(viewWithAccessibilityIdentifier: "home.daily.open") }
            #expect(throws: Never.self) { try tree.find(text: "4/5") }
            #expect(throws: Never.self) { try tree.find(text: "Lepšie skóre ako 2 z 3 hráčov.") }
            #expect(throws: (any Error).self, "a played day is not offered again") {
                try tree.find(viewWithAccessibilityIdentifier: "home.daily.play")
            }
        }
    }
}
