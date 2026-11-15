//
//  NavigationSequenceRun.swift
//  HangsTests
//
//  #235.3 (navigation as a rule: the player always has a way out) — one
//  seeded sequence of tab taps, quiz starts, cancels, slow or failing server
//  answers, quiz ends and trips to the background, played against the REAL
//  `QuizViewModel` and `NavigationModel`, wired the way ContentView wires them.
//
//  The rule, checked after every input and every move of the clock: either the
//  tab bar is up, or the tab on screen is Play, whose quiz screens (question,
//  result, recap, completion, daily end, error) each carry a close or home
//  control. Build 87's bug broke it: a slow start finished while the player
//  was on Together, the Play tab's question hid the tab bar, and Together was
//  left with no way back (fixed in `NavigationModel.handleQuizStateChange`).
//
//  Sibling of `QuizSequenceRun` (same clock, audio double, settle and shrink);
//  the network is the shared `MockNetworkService`, whose quiz-start calls wait
//  at a gate until an input answers them, well or badly (#235.1 conditions).
//

import Clocks
import Combine
import Foundation
@testable import Hangs
import SwiftUI

enum NavigationInput: Equatable, CustomStringConvertible {
    /// How the server answers the oldest held quiz-start call.
    enum Reply: String { case ok, offline, serverError }

    case tab(AppTab)
    /// Home's Start (Play), a pack's Play in My packs (Profile) or the round
    /// end's Play again.
    case start
    /// Home's Cancel while the start runs.
    case cancelStart
    /// The server answers the oldest held call of the start (the session,
    /// then the first question: a start that succeeds takes two).
    case server(Reply)
    /// The question screen's "End with results".
    case endWithResults
    /// The quiz screen's close or home control.
    case close
    /// The error screen's Try again.
    case retry
    case background
    case foreground
    case idle

    var description: String {
        switch self {
        case let .tab(tab): "tap tab.\(tab)"
        case .start: "tap start"
        case .cancelStart: "tap cancelStart"
        case let .server(reply): "server quizStart.\(reply.rawValue)"
        case .endWithResults: "tap endWithResults"
        case .close: "tap close"
        case .retry: "tap retry"
        case .background: "scene background"
        case .foreground: "scene active"
        case .idle: "timer idle"
        }
    }
}

struct TimedNavigationInput: Equatable {
    var atMs: Int
    var input: NavigationInput
}

/// Parks every quiz-start call (create session, first question) until an
/// input answers the oldest one; a cancelled caller sees `URLError(.cancelled)`.
@MainActor
final class StartCallGate {
    private let parked = ParkedCalls<NetworkCondition?> { URLError(.cancelled) }
    private var waiting: [Int] = []
    private var nextId = 0

    var heldCount: Int { waiting.count(where: parked.isOpen) }

    func wait() async throws -> NetworkCondition? {
        nextId += 1
        let id = nextId
        parked.register(id)
        waiting.append(id)
        defer { waiting.removeAll { $0 == id } }
        return try await parked.park(id)
    }

    /// `nil` condition = a normal answer.
    func answerOldest(_ condition: NetworkCondition?) -> Bool {
        guard let id = waiting.first(where: parked.isOpen) else { return false }
        return parked.resolve(id, .success(condition))
    }

    func failAll() {
        for id in waiting {
            parked.resolve(id, .failure(URLError(.cancelled)))
        }
    }
}

@MainActor
final class NavigationSequenceRun {
    let clock = SequenceClock()
    let network = Fixtures.makeFullMockNetwork()
    let audio: SequenceAudio
    let gate = StartCallGate()
    let navigation = NavigationModel()
    let vm: QuizViewModel

    /// ContentView: `.onReceive(viewModel.$quizState) { navModel.handleQuizStateChange($0) }`.
    /// The planted-bug test swaps in the pre-#799 rule.
    var route: (NavigationModel, QuizState) -> Void = { $0.handleQuizStateChange($1) }

    private(set) var violation: QuizSequenceRun.Violation?
    private(set) var log: [(timed: TimedNavigationInput, applied: Bool)] = []
    private(set) var statesSeen: Set<String> = []
    private(set) var nowMs = 0
    private var stateChanges = 0
    private var tasks: [Task<Void, Never>] = []
    private var cancellables: Set<AnyCancellable> = []

    init() {
        let anyClock = AnyClock(clock)
        audio = SequenceAudio(clock: anyClock)
        network.networkClock = anyClock
        let gate = gate
        for call in [MockNetworkCall.createSession, .startQuiz] {
            network.gates[call] = {
                if let condition = try await gate.wait() { try await condition.apply(clock: anyClock) }
            }
        }
        vm = QuizViewModel(
            networkService: network,
            audioService: audio,
            persistenceStore: MockPersistenceStore(),
            silenceDetectionService: MockSilenceDetectionService(),
            clock: anyClock
        )
        vm.settleClock = anyClock
        vm.earconPlayer = MockEarconPlayer()
        clock.settle = { [weak self] in await self?.drain() }
        vm.$quizState
            .sink { [weak self] state in
                guard let self else { return }
                stateChanges += 1
                statesSeen.insert(state.label)
                route(navigation, state)
            }
            .store(in: &cancellables)
    }

    // MARK: - The rule

    /// The tab bar follows the Play tab's screen (`QuizScreen.showsTabBar`,
    /// what ContentView reads) wherever the player is; with it hidden, only
    /// Play shows a screen that has its own way out.
    func check() {
        guard violation == nil, !vm.quizScreen.showsTabBar, navigation.selectedTab != .play else { return }
        violation = .init(
            invariant: "no way out",
            detail: "the quiz (\(vm.quizState.label)) hid the tab bar while \(navigation.selectedTab) is on screen",
            atMs: nowMs
        )
    }

    // MARK: - Driving

    func advance(to ms: Int) async {
        guard ms > nowMs, violation == nil else { return }
        await drain()
        check()
        guard violation == nil else { return }
        await clock.advance(by: .milliseconds(ms - nowMs))
        nowMs = ms
        check()
    }

    func apply(_ timed: TimedNavigationInput) async {
        guard violation == nil else { return }
        log.append((timed, perform(timed.input)))
        await drain()
        check()
    }

    /// Let 45 s pass in 5 s steps (backoffs, the stall watchdog), then tear down.
    func finish() async {
        await drain()
        check()
        for _ in 0 ..< 9 where violation == nil {
            await clock.advance(by: .seconds(5))
            nowMs += 5000
            check()
        }
        cancellables.removeAll()
        tasks.forEach { $0.cancel() }
        vm.taskBag.cancelAll()
        gate.failAll()
        audio.teardown()
        await drain()
    }

    /// Yield until nothing observable moved for 12 turns in a row.
    private func drain() async {
        var last = fingerprint
        var quiet = 0
        for _ in 0 ..< QuizSequenceRun.maxTurns {
            await Task.yield()
            let now = fingerprint
            if now == last {
                quiet += 1
                if quiet >= QuizSequenceRun.defaultQuietTurns { return }
            } else {
                quiet = 0
                last = now
            }
        }
    }

    private var fingerprint: [Int] {
        [
            stateChanges, clock.sleepCount, gate.heldCount, vm.taskBag.count, audio.activity,
            network.createSessionCallCount, network.endSessionCallCount, network.submitVoiceAnswerCallCount,
            network.submitTextInputCallCount, network.nextQuestionCallCount,
        ]
    }

    // MARK: - What the player can reach right now

    /// The Play tab's quiz screen (not Home) is the one on screen.
    var isOnQuizScreen: Bool { navigation.selectedTab == .play && !vm.quizScreen.showsTabBar }

    var canStart: Bool {
        switch navigation.selectedTab {
        case .play: vm.quizState == .idle || [.completion, .setRecap].contains(vm.quizScreen)
        case .profile: vm.quizState == .idle || vm.quizState == .startingQuiz
        case .together: false
        }
    }

    var canCancelStart: Bool { navigation.selectedTab == .play && vm.quizState == .startingQuiz }

    // MARK: - Inputs → the app

    /// An input whose control is not on screen is inert, in generation,
    /// replay and shrinking alike.
    private func perform(_ input: NavigationInput) -> Bool {
        let vm = vm
        switch input {
        case let .tab(tab):
            guard vm.quizScreen.showsTabBar, navigation.selectedTab != tab else { return false }
            navigation.selectedTab = tab
        case .start:
            guard canStart else { return false }
            if vm.quizState == .finished { vm.playAgain() } else { vm.beginQuizStart() }
        case .cancelStart:
            guard canCancelStart else { return false }
            vm.cancelQuizStart()
        case let .server(reply):
            let condition: NetworkCondition? = switch reply {
            case .ok: nil
            case .offline: .offline
            case .serverError: .serverError(statusCode: 500)
            }
            return gate.answerOldest(condition)
        case .endWithResults:
            guard isOnQuizScreen, vm.quizScreen == .question else { return false }
            spawn { await vm.endQuizWithResults() }
        case .close:
            guard isOnQuizScreen else { return false }
            switch vm.quizScreen {
            case .question, .result: spawn { await vm.endQuiz() }
            default: vm.resetToHome()
            }
        case .retry:
            guard isOnQuizScreen, vm.quizState.isError else { return false }
            vm.retryFromErrorScreen()
        case .background:
            guard vm.isAppForeground else { return false }
            vm.handleScenePhase(.background)
        case .foreground:
            guard !vm.isAppForeground else { return false }
            vm.handleScenePhase(.active)
        case .idle:
            return false
        }
        return true
    }

    private func spawn(_ body: @escaping @MainActor () async -> Void) {
        tasks.append(Task { await body() })
    }
}
