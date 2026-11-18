//
//  SlowQuizStartTabTests.swift
//  HangsTests
//
//  #235.1 (a "bad network" switch for tests): the bug fixed in #799 (a quiz
//  that starts behind another tab brings the player to Play) as the founder
//  met it on build 87. The start was slow, so Home kept its tab bar up; he
//  walked to Together; the quiz then arrived with the tab bar hidden and no
//  way back. NavigationModelTests pins the rule on its own; this runs the
//  real pipeline: QuizViewModel's start, held at the network, feeding
//  NavigationModel the way ContentView wires them.
//

import Clocks
import Combine
import Foundation
@testable import Hangs
import Testing

@Suite("A slow quiz start while the player changes tab (#235.1)")
@MainActor
struct SlowQuizStartTabTests {
    private struct Pipeline {
        let viewModel: QuizViewModel
        let navigation: NavigationModel
        let network: MockNetworkService
        let wiring: AnyCancellable
    }

    private func makePipeline() -> Pipeline {
        let clock = TestClock()
        let network = Fixtures.makeFullMockNetwork()
        network.networkClock = AnyClock(clock)
        let viewModel = QuizViewModel(
            networkService: network,
            audioService: MockAudioService(),
            persistenceStore: MockPersistenceStore(),
            silenceDetectionService: MockSilenceDetectionService(),
            clock: AnyClock(clock)
        )
        let navigation = NavigationModel()
        // ContentView: `.onReceive(viewModel.$quizState) { navModel.handleQuizStateChange($0) }`
        let wiring = viewModel.$quizState.sink { navigation.handleQuizStateChange($0) }
        return Pipeline(viewModel: viewModel, navigation: navigation, network: network, wiring: wiring)
    }

    /// Starts a quiz whose first question is held at the server, and walks
    /// the player to Together while it is in flight.
    private func startAndWalkAway(_ pipeline: Pipeline) async -> (Task<Void, Never>, NetworkHold) {
        let hold = pipeline.network.hold(.startQuiz)
        let start = Task { await pipeline.viewModel.startNewQuiz() }
        await pumpUntil({ hold.heldCount == 1 }, "the start never reached the server")
        #expect(pipeline.viewModel.quizState == .startingQuiz)
        pipeline.navigation.selectedTab = .together
        return (start, hold)
    }

    @Test("a slow start that succeeds lands the player on the question, on Play")
    func slowStartArrivesOnPlay() async {
        let pipeline = makePipeline()
        let (start, hold) = await startAndWalkAway(pipeline)

        hold.release()
        await start.value

        #expect(pipeline.viewModel.quizState == .askingQuestion)
        #expect(pipeline.navigation.selectedTab == .play, "the question arrived behind the Together tab")
    }

    @Test("a slow start that fails shows its error screen on Play")
    func slowFailingStartShowsErrorOnPlay() async {
        let pipeline = makePipeline()
        // A permanent 5xx: no retry, straight to the error screen.
        pipeline.network.setNetworkCondition(.serverError(statusCode: 500), for: [.startQuiz])
        let (start, hold) = await startAndWalkAway(pipeline)

        hold.release()
        await start.value

        #expect(pipeline.viewModel.quizState.label == "error")
        #expect(pipeline.navigation.selectedTab == .play, "the error screen arrived behind the Together tab")
    }
}
