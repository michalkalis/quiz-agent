//
//  NavigationSequenceTests.swift
//  HangsTests
//
//  #235.3 (navigation as a rule: the player always has a way out) — seeded
//  random sequences of what a player does around a quiz start (tab taps,
//  start, cancel, a slow / offline / failing server, ending the quiz, going
//  home, background) checked against one rule after every step: the tab bar
//  is up, or the Play tab's quiz screen, with its own close, is on screen.
//  The bug of build 87 (a slow start finishing behind the Together tab) broke
//  that rule; nobody wrote the test that would have caught it. This suite
//  does not need anyone to think of the ordering.
//
//  Knobs (xcodebuild passes TEST_RUNNER_<NAME> to the runner as <NAME>):
//    NAV_SEQUENCE_COUNT      sequences per run (default 300 — CI)
//    NAV_SEQUENCE_BASE_SEED  first seed (default 235300)
//    NAV_SEQUENCE_SEED       run just this seed (reproduce a failure)
//

import Foundation
@testable import Hangs
import Testing

/// Draws the next input from what the player, the server or the OS could do
/// on the screen the app shows right now (online, like `QuizSequenceGenerator`).
@MainActor
struct NavigationSequenceGenerator {
    private var rng: SeededGenerator
    private var now = 0

    init(seed: UInt64) {
        rng = SeededGenerator(seed: seed)
    }

    /// Mostly the gaps of a player's taps; some bursts, and some long gaps
    /// that let the start's retry backoff and timers run out.
    mutating func nextTime() -> Int {
        let roll = Double.random(in: 0 ..< 1, using: &rng)
        now += roll < 0.08 ? 0
            : roll < 0.6 ? Int.random(in: 50 ... 1500, using: &rng)
            : roll < 0.88 ? Int.random(in: 1500 ... 8000, using: &rng)
            : Int.random(in: 8000 ... 40000, using: &rng)
        return now
    }

    mutating func pick(for run: NavigationSequenceRun, at time: Int) -> TimedNavigationInput {
        var options: [(NavigationInput, Double)] = [(.idle, 1)]
        if run.vm.quizScreen.showsTabBar {
            for tab in [AppTab.play, .together, .profile] where tab != run.navigation.selectedTab {
                options.append((.tab(tab), 1.2))
            }
        }
        if run.canStart { options.append((.start, 2)) }
        if run.canCancelStart { options.append((.cancelStart, 0.6)) }
        if run.gate.heldCount > 0 {
            options += [(.server(.ok), 2), (.server(.offline), 0.5), (.server(.serverError), 0.4)]
        }
        if run.isOnQuizScreen {
            options.append((.close, 0.6))
            if run.vm.quizScreen == .question { options.append((.endWithResults, 0.4)) }
            if run.vm.quizState.isError { options.append((.retry, 1)) }
        }
        options.append(run.vm.isAppForeground ? (.background, 0.2) : (.foreground, 2))

        var roll = Double.random(in: 0 ..< options.reduce(0) { $0 + $1.1 }, using: &rng)
        for (input, weight) in options {
            roll -= weight
            if roll < 0 { return TimedNavigationInput(atMs: time, input: input) }
        }
        return TimedNavigationInput(atMs: time, input: .idle)
    }
}

@MainActor
enum NavigationSequenceHarness {
    typealias Configure = @MainActor (NavigationSequenceRun) -> Void

    static func generate(seed: UInt64, length: Int, configure: Configure = { _ in }) async -> NavigationSequenceRun {
        let run = NavigationSequenceRun()
        configure(run)
        var generator = NavigationSequenceGenerator(seed: seed)
        for _ in 0 ..< length {
            let at = generator.nextTime()
            await run.advance(to: at)
            // A violation while time passed keeps its moment in the list.
            let next = run.violation == nil ? generator.pick(for: run, at: at) : TimedNavigationInput(atMs: at, input: .idle)
            await run.apply(next)
            if run.violation != nil { break }
        }
        await run.finish()
        return run
    }

    static func replay(_ inputs: [TimedNavigationInput], configure: Configure = { _ in }) async -> NavigationSequenceRun {
        let run = NavigationSequenceRun()
        configure(run)
        for input in inputs {
            await run.advance(to: input.atMs)
            await run.apply(input)
            if run.violation != nil { break }
        }
        await run.finish()
        return run
    }

    /// The fewest inputs that still break the rule (same shrinker as #186).
    static func shrink(_ run: NavigationSequenceRun, configure: Configure = { _ in }) async -> NavigationSequenceRun {
        guard let target = run.violation?.invariant else { return run }
        let minimal = await QuizSequenceShrinker.shrink(run.log.map(\.timed)) { candidate in
            await replay(candidate, configure: configure).violation?.invariant == target
        }
        return await replay(minimal, configure: configure)
    }

    /// The inputs that reached the app, one per line, as the player did them.
    static func steps(_ run: NavigationSequenceRun) -> [String] {
        run.log.filter(\.applied).map(\.timed.input.description)
    }

    static func report(seed: UInt64, original: NavigationSequenceRun, minimal: NavigationSequenceRun) -> String {
        let violation = minimal.violation ?? original.violation
        let lines = minimal.log.map { "\(QuizSequenceDump.time($0.timed.atMs)) \($0.timed.input)\($0.applied ? "" : " (inert)")" }
        return """
        Navigation sequence seed \(seed) broke "\(violation?.invariant ?? "?")" — \(violation?.detail ?? "") \
        at \(QuizSequenceDump.time(violation?.atMs ?? 0)).
        Reproduce: TEST_RUNNER_NAV_SEQUENCE_SEED=\(seed) xcodebuild test … -only-testing:HangsTests/NavigationSequenceTests
        Minimal sequence (\(minimal.log.count) of \(original.log.count) inputs):
        \(lines.joined(separator: "\n"))
        """
    }
}

@Suite("#235.3 the player always has a way out — seeded navigation sequences", .serialized)
@MainActor
struct NavigationSequenceTests {
    private static let length = 25

    private static var seeds: [UInt64] {
        let environment = ProcessInfo.processInfo.environment
        if let only = environment["NAV_SEQUENCE_SEED"].flatMap(UInt64.init) { return [only] }
        let count = environment["NAV_SEQUENCE_COUNT"].flatMap(Int.init) ?? 300
        let base = environment["NAV_SEQUENCE_BASE_SEED"].flatMap(UInt64.init) ?? 235_300
        return (0 ..< UInt64(count)).map { base + $0 }
    }

    /// WHY: a screen with no tab bar and no close is a dead end the player
    /// can only leave by killing the app — the founder met one on build 87.
    /// Any ordering of taps, server answers and scene changes must keep a way
    /// out; a seed that finds one prints its minimal sequence.
    @Test("hundreds of seeded sequences never leave the player without a way out")
    func seededSequencesKeepAWayOut() async {
        var states: Set<String> = []
        var tabTaps = 0
        var failures = 0
        for seed in Self.seeds {
            let run = await NavigationSequenceHarness.generate(seed: seed, length: Self.length)
            states.formUnion(run.statesSeen)
            tabTaps += NavigationSequenceHarness.steps(run).count(where: { $0.hasPrefix("tap tab.") })
            guard run.violation != nil else { continue }
            failures += 1
            let minimal = await NavigationSequenceHarness.shrink(run)
            Issue.record(Comment(rawValue: NavigationSequenceHarness.report(seed: seed, original: run, minimal: minimal)))
            if failures >= 3 { break }
        }
        print("[NavigationSequence] \(Self.seeds.count) seeds × \(Self.length) inputs; states: \(states.sorted()); tab taps: \(tabTaps)")
        // A harness that never reached the screens the rule is about would pass
        // forever (skipped when a failure cut the batch short).
        for state in ["startingQuiz", "askingQuestion", "finished", "error"] where failures == 0 {
            #expect(states.contains(state), "no sequence ever reached \(state)")
        }
    }

    /// WHY: a rule check that cannot fail is decoration. Plant build 87's
    /// routing (a start clears the navigation, nothing brings the player back
    /// to Play when the quiz arrives) and the sequences must find the dead
    /// end on their own and cut it down to the founder's three steps.
    @Test("the build 87 routing is caught and shrunk to start, switch tab, start completes")
    func build87RoutingIsCaught() async throws {
        let plant: NavigationSequenceHarness.Configure = { run in
            run.route = { navigation, state in if state == .startingQuiz { navigation.clearAll() } }
        }
        var caught: NavigationSequenceRun?
        for seed in Self.seeds.prefix(100) {
            let run = await NavigationSequenceHarness.generate(seed: seed, length: Self.length, configure: plant)
            if run.violation != nil { caught = run; break }
        }
        let failing = try #require(caught, "100 seeds never walked away from a slow start")

        let minimal = await NavigationSequenceHarness.shrink(failing, configure: plant)
        let steps = NavigationSequenceHarness.steps(minimal)
        #expect(minimal.violation?.invariant == "no way out")
        #expect(steps.count <= 4, "shrinking left \(steps)")
        #expect(steps.first == "tap start" && steps.last?.hasPrefix("server quizStart.") == true,
                "not the start → walk away → arrival shape: \(steps)")
        #expect(steps.contains { $0.hasPrefix("tap tab.") && $0 != "tap tab.play" }, "\(steps)")
    }
}
