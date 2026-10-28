//
//  DailyChallengeViewInspectorTests.swift
//  HangsTests
//
//  #205 — the daily challenge screens at the element level (#57 altitude:
//  presence and order, not pixels). Why: founder decision 2 puts the crowd
//  strip in ONE place on every verdict (under the answer sticker, above what
//  the player said); the round end is peak-end ordered (score, comparison,
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
private func resultViewModel(result: Evaluation.EvaluationResult, said: String, crowd: CrowdStrip?) -> QuizViewModel {
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
            correctAnswer: "Libanon", questionId: "q_daily", explanation: nil
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

    @Test("the strip sits under the answer sticker and above 'you said'")
    func stripPosition() async throws {
        let view = ResultView(viewModel: resultViewModel(result: .incorrect, said: "Sýria", crowd: DailyChallengeFixtures.hard))
        try await ViewHosting.host(view) {
            let order = try texts(view.inspect())
            let answer = try #require(order.firstIndex(of: "Libanon"))
            let strip = try #require(order.firstIndex(of: DailyChallengeFixtures.hard.text))
            let said = try #require(order.firstIndex(of: "you said"))
            #expect(answer < strip && strip < said, "founder decision 2: sticker, strip, then what was said — got \(order)")
        }
    }

    @Test("recap mode has no strip")
    func noStripInRecap() async throws {
        let panel = ResultAnswerPanel(
            answerLabel: "the question", answerText: "Ktorá krajina?", isRecap: true,
            explanation: nil, crowd: DailyChallengeFixtures.rare, onHearIt: {}
        )
        try await ViewHosting.host(panel) {
            #expect(throws: (any Error).self) { try panel.inspect().find(viewWithAccessibilityIdentifier: "result.crowd") }
        }
    }
}

@Suite("Daily round end (#205.5)")
@MainActor
struct DailyRoundEndInspectorTests {
    private func makeView(marks: [Bool?]) -> DailyRoundEndView {
        let day = DailyChallengeDay(year: 2026, month: 10, day: 15)
        let state = DailyChallengeFixtures.playedState(date: day.isoDate, language: "sk", marks: marks)
        let vm = Fixtures.makeViewModel(clock: AnyClock(TestClock()))
        vm.activeDaily = DailyRound(day: day, language: "sk", state: state)
        vm.quizState = .finished
        let network = MockNetworkService()
        network.stubbedDailyState = state
        return DailyRoundEndView(viewModel: vm, daily: DailyChallengeViewModel(network: network, day: day, state: state))
    }

    @Test("peak-end order: score, comparison, then the rarest hit last")
    func goodRoundOrder() async throws {
        let view = makeView(marks: DailyChallengeFixtures.goodMarks)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            let order = texts(tree)
            let hero = try #require(order.firstIndex(of: "COMPLETE"))
            let score = try #require(order.firstIndex(of: "final score"))
            let comparison = try #require(order.firstIndex(of: "Lepšie skóre ako 2 z 3 hráčov."))
            let hitLabel = try #require(order.firstIndex(of: "few knew this one"))
            let hitText = try #require(order.firstIndex(of: "Vedel to len 1 z 3."))
            #expect(hero < score && score < comparison && comparison < hitLabel && hitLabel < hitText, "\(order)")
            #expect(order.contains("4"))
            #expect(throws: Never.self) { try tree.find(viewWithAccessibilityIdentifier: "daily.tiles") }
        }
    }

    @Test("a weak round: 'Ťažká výzva.' and 'your best answer', never 'worse than'")
    func weakRound() async throws {
        let view = makeView(marks: DailyChallengeFixtures.weakMarks)
        try await ViewHosting.host(view) {
            let order = try texts(view.inspect())
            #expect(order.contains("Ťažká výzva."))
            #expect(order.contains("your best answer"))
            #expect(!order.contains("few knew this one"))
            #expect(!order.contains { $0.localizedStandardContains("horší") || $0.localizedStandardContains("worse") })
        }
    }

    @Test("one challenge a day: Share and Home, no Play Again, no upsell")
    func footer() async throws {
        let view = makeView(marks: DailyChallengeFixtures.goodMarks)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) { try tree.find(viewWithAccessibilityIdentifier: "daily.share") }
            #expect(throws: Never.self) { try tree.find(viewWithAccessibilityIdentifier: "daily.home") }
            #expect(throws: (any Error).self) { try tree.find(text: "Play Again") }
            #expect(throws: (any Error).self) { try tree.find(viewWithAccessibilityIdentifier: "completion.upsell") }
        }
    }

    @Test("no comparison yet: the card is hidden, the round's own score stands in")
    func comparisonHiddenWhenNil() async throws {
        let day = DailyChallengeDay(year: 2026, month: 10, day: 15)
        let vm = Fixtures.makeViewModel(clock: AnyClock(TestClock()))
        vm.activeDaily = DailyRound(day: day, language: "sk")
        vm.quizState = .finished
        let view = DailyRoundEndView(viewModel: vm, daily: DailyChallengeViewModel(network: MockNetworkService(), day: day))
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: (any Error).self) { try tree.find(viewWithAccessibilityIdentifier: "daily.comparison") }
            #expect(throws: (any Error).self) { try tree.find(viewWithAccessibilityIdentifier: "daily.bestHit") }
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
