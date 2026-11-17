//
//  SharedQuizConditionTests.swift
//  HangsTests
//
//  #235.2 (flow × condition, shared quiz link row). A friend's link first
//  asks the server whose link it is (the sender sees the comparison, a friend
//  plays), then starts the friend's round. On a bad network the start must
//  end on the spinner's Cancel or the error screen with Try again, a second
//  tap on the link must not start it twice, and the comparison sheet must
//  say when it cannot load. A gone or already played link, the refusal
//  notices and a link that waits for Home are in SharedQuizFlowTests and
//  SharedQuizLinkTests.
//

import Clocks
import Foundation
@testable import Hangs
import Testing

@Suite("Shared quiz link on a bad network (#235.2)")
@MainActor
struct SharedQuizConditionTests {
    private let clock = TestClock<Duration>()
    private let network = Fixtures.makeFullMockNetwork()
    private let token = "Ab3_k9-ZxQ"

    nonisolated static let failures: [NetworkCondition] = [
        .timeout, .offline, .dropped(after: .seconds(2)), .serverError(statusCode: 500), .malformed,
    ]

    private func makeVM() -> QuizViewModel {
        network.networkClock = AnyClock(clock)
        return QuizViewModel(
            networkService: network,
            audioService: MockAudioService(),
            persistenceStore: MockPersistenceStore(),
            silenceDetectionService: MockSilenceDetectionService(),
            clock: AnyClock(clock),
            sharedQuizEnabled: { true }
        )
    }

    private func makeShare() -> SharedQuizShareModel {
        network.networkClock = AnyClock(clock)
        return SharedQuizShareModel(network: network, source: nil, token: token, displayName: "Jana", present: { _ in })
    }

    private static let results = SharedQuizResults(
        kind: "round", language: "sk", title: nil, categories: [], questionCount: 10,
        players: [SharedQuizPlayer(name: "Jana", score: 8, total: 10)]
    )

    // WHY: a friend's round that cannot start on the network must end on the
    // error screen with Try again (which keeps the link), never on a spinner
    // that waits for as long as the network is down.
    @Test("a friend's round that fails to start on the network ends on the error screen with Try again", arguments: failures)
    func failedStartEndsOnError(condition: NetworkCondition) async {
        let vm = makeVM()
        network.setNetworkCondition(condition, for: [.startSharedQuiz])
        let start = vm.beginSharedQuiz(token: token)

        await advanceUntil(clock, limit: .seconds(60)) { vm.quizState.isError }
        await start.value

        #expect(vm.activeErrorModel?.retryAction == .retryOperation)
        #expect(vm.activeShare?.token == token, "Try again would no longer play the friend's link")
    }

    // WHY: a slow start shows the spinner (with Cancel); a Cancel lands on
    // Home, and the start that answers afterwards must not open the round.
    @Test("a slow start shows the spinner, and after Cancel the late answer opens nothing")
    func slowStartCancelled() async {
        let vm = makeVM()
        let hold = network.hold(.startSharedQuiz)
        let start = vm.beginSharedQuiz(token: token)
        await pumpUntil { hold.heldCount == 1 }
        #expect(vm.quizState == .startingQuiz)

        vm.cancelQuizStart()
        hold.release()
        await start.value

        #expect(vm.quizState == .idle)
        #expect(vm.currentSession == nil, "the cancelled round opened anyway")
    }

    // WHY: tapping the link twice (or the link arriving twice) must start the
    // friend's round once: a second start could count as "already played"
    // on the server and show the comparison instead of the quiz.
    @Test("a link opened twice while the first is still on its way starts the round once")
    func linkTwiceStartsOnce() async {
        let vm = makeVM()
        let hold = network.hold(.sharedQuizResults)
        let first = vm.beginSharedQuiz(token: token)
        await pumpUntil { hold.heldCount == 1 }
        let second = vm.beginSharedQuiz(token: token)
        await pumpUntil { hold.arrivals == 2 }

        hold.release()
        await first.value
        await second.value

        #expect(network.startSharedQuizCalls.count == 1, "the friend's round was started twice")
        #expect(vm.currentSession != nil, "neither tap started the round")
    }

    // WHY: the "is this my own link?" question must not strand a friend. Any
    // failure, even a request that never answers, means "play it". Today the
    // player waits on Home without a spinner meanwhile (founder case F7).
    @Test("a sender check the server never answers still starts the friend's round")
    func senderCheckTimeoutStillPlays() async {
        let vm = makeVM()
        network.setNetworkCondition(.timeout, for: [.sharedQuizResults])
        let start = vm.beginSharedQuiz(token: token)

        let waited = await advanceUntil(clock, limit: .seconds(60)) { !network.startSharedQuizCalls.isEmpty }
        await start.value

        #expect(waited >= NetworkCondition.requestTimeout, "pinned: today the friend waits for the full timeout")
        #expect(vm.currentSession != nil)
    }

    // WHY: the comparison sheet shows a spinner while it loads; when it
    // cannot load it says so instead of spinning forever.
    @Test("a comparison that cannot load says so instead of spinning", arguments: failures)
    func failedComparisonSaysSo(condition: NetworkCondition) async {
        let share = makeShare()
        network.stubbedShareResults = Self.results
        network.setNetworkCondition(condition, for: [.sharedQuizResults])
        let load = share.loadResults()
        #expect(!share.loadFailed && share.rows.isEmpty, "the sheet does not show it is loading")

        await advanceUntil(clock, limit: .seconds(60)) { share.loadFailed }
        await load.value
        #expect(share.rows.isEmpty)
    }

    // WHY: a refresh that fails (back from the background on a bad network)
    // keeps the ranking the player already sees instead of replacing it with
    // an error.
    @Test("a failed refresh keeps the ranking already shown")
    func failedRefreshKeepsRanking() async {
        let share = makeShare()
        network.stubbedShareResults = Self.results
        await share.loadResults().value
        network.setNetworkCondition(.offline, for: [.sharedQuizResults])

        await share.loadResults().value

        #expect(share.rows.count == 1)
        #expect(!share.loadFailed)
    }

    // WHY: when a newer load replaced an older one (the sheet reappeared),
    // the older answer arriving late must not overwrite the newer ranking.
    @Test("an older comparison answer that arrives late does not overwrite the newer one")
    func lateComparisonIgnored() async {
        let share = makeShare()
        network.stubbedShareResults = Self.results
        let hold = network.hold(.sharedQuizResults)
        let old = share.loadResults()
        await pumpUntil { hold.heldCount == 1 }
        network.gates[.sharedQuizResults] = nil

        await share.loadResults().value
        hold.release()
        await old.value

        #expect(share.rows.count == 1)
        #expect(!share.loadFailed, "the replaced load turned the ranking into an error")
    }
}
