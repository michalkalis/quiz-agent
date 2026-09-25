//
//  QuizSequenceTests.swift
//  HangsTests
//
//  #186 step 2 — seeded random event sequences against the real quiz view
//  model. The unit tests of step 1 and #185 track B pin the chains someone
//  thought of; this suite plays thousands of orderings nobody wrote down —
//  speech, commands, taps, timers, interruptions, background/foreground and
//  late server answers — and checks the quiz invariants after every burst.
//  Deterministic: a seed is a run; a failure prints its minimal sequence as a
//  flight-recorder dump that replays.
//
//  Knobs (xcodebuild passes TEST_RUNNER_<NAME> to the runner as <NAME>):
//    QUIZ_SEQUENCE_COUNT      sequences per run (default 500 — CI)
//    QUIZ_SEQUENCE_BASE_SEED  first seed (default 186000)
//    QUIZ_SEQUENCE_LENGTH     inputs per sequence (default 30)
//    QUIZ_SEQUENCE_SEED       run just this seed (reproduce a failure)
//    QUIZ_SEQUENCE_STRICT=1   fail on the known bugs too (see `KnownBug`)
//
//  Cost: ~75 ms per 30-input sequence on the simulator — every scheduler turn
//  is a main-queue round trip (~50 µs) and a sequence needs ~900 of them. The
//  CI default stays well under a minute; run thousands locally with the knob,
//  e.g. QUIZ_SEQUENCE_COUNT=5000 (~6 min).
//

import Foundation
@testable import Hangs
import Testing

private final class QuizSequenceBundleToken {}

private struct Knobs {
    var count = 500
    var baseSeed: UInt64 = 186_000
    var length = 30
    var onlySeed: UInt64?

    static var current: Knobs {
        let environment = ProcessInfo.processInfo.environment
        var knobs = Knobs()
        if let value = environment["QUIZ_SEQUENCE_COUNT"].flatMap(Int.init) { knobs.count = value }
        if let value = environment["QUIZ_SEQUENCE_BASE_SEED"].flatMap(UInt64.init) { knobs.baseSeed = value }
        if let value = environment["QUIZ_SEQUENCE_LENGTH"].flatMap(Int.init) { knobs.length = value }
        knobs.onlySeed = environment["QUIZ_SEQUENCE_SEED"].flatMap(UInt64.init)
        return knobs
    }

    var seeds: [UInt64] {
        if let onlySeed { return [onlySeed] }
        return (0 ..< UInt64(count)).map { baseSeed + $0 }
    }
}

@Suite("#186 quiz state robustness — seeded random event sequences", .serialized)
@MainActor
struct QuizSequenceTests {
    /// WHY: the car test of 2026-09-23 broke on an ordering nobody had
    /// written a test for (an empty answer, a countdown, the next question's
    /// read-out and the driver repeating himself). Every invariant below is a
    /// promise the quiz makes to a driver who cannot look at the screen; a
    /// seed that breaks one is a bug report with its own minimal repro.
    @Test("hundreds of seeded sequences (thousands locally) keep every quiz invariant")
    func seededSequencesKeepInvariants() async {
        let knobs = Knobs.current
        let started = ContinuousClock.now
        var stats = QuizSequenceStats()
        var failures = 0
        for seed in knobs.seeds {
            let outcome = await QuizSequenceHarness.generate(seed: seed, length: knobs.length)
            stats.add(outcome)
            guard outcome.violation != nil else { continue }
            failures += 1
            let minimal = await QuizSequenceHarness.shrink(outcome)
            Issue.record(Comment(rawValue: QuizSequenceHarness.report(seed: seed, original: outcome, minimal: minimal)))
            if failures >= 3 { break }
        }
        let elapsed = ContinuousClock.now - started
        print("""
        [QuizSequence] seeds \(knobs.seeds.first ?? 0)…\(knobs.seeds.last ?? 0), \(knobs.length) inputs each, \
        \(elapsed.formatted(.units(allowed: [.seconds, .milliseconds]))) wall
        \(stats.summary)
        """)
        // A harness that silently stopped reaching the app would pass forever.
        #expect(stats.sheets > 0 && stats.results > 0, "the sequences never reached a confirmation sheet or a result")
        #expect(!stats.drops.isEmpty || knobs.onlySeed != nil, "no late result was ever dropped — the ownership check went unexercised")
    }

    /// WHY: reproducibility is the whole contract of a seed. If two runs of one
    /// seed differ, a reported failure cannot be replayed or shrunk, and a
    /// green CI run says nothing about the next one.
    @Test("the same seed plays the same run twice")
    func sameSeedSameRun() async {
        let first = await QuizSequenceHarness.generate(seed: 186_424, length: 40)
        let second = await QuizSequenceHarness.generate(seed: 186_424, length: 40)

        #expect(first.inputs == second.inputs)
        #expect(first.violation == second.violation)
        let trail = { (outcome: QuizSequenceHarness.Outcome) in
            outcome.run.recorder.entries.map { "\($0.kind.rawValue) \($0.name) \($0.attempt) \($0.state)" }
        }
        #expect(trail(first) == trail(second), "the app's own black box diverged between two runs of one seed")
        #expect(trail(first).count > 40, "the run did too little to prove anything")
    }

    /// WHY (#185 — car test 2026-09-23, finding 1): the dump replays what the
    /// driver did on that drive — an answer the VAD never heard, the server's
    /// 400 "speech not understood", then silence while the old build's empty
    /// sheet counted down and SKIPPED the question, and the driver repeating
    /// question 1's answer into question 2's mic. Played against today's build,
    /// the same inputs must never skip question 1: the first miss is met with
    /// the spoken retry on the same question, the second with the Again/Skip
    /// sheet that waits for the driver, and nothing lands on question 2.
    @Test("the car-test black box replays as a regression test")
    func carTestDumpReplays() async throws {
        let url = try #require(Bundle(for: QuizSequenceBundleToken.self)
            .url(forResource: "quiz-flight-recorder-car-test-2026-09-23", withExtension: "txt"))
        let parsed = try QuizSequenceDump.parse(String(contentsOf: url, encoding: .utf8))
        #expect(parsed.inputs.count == 9, "the fixture's input lines no longer parse")

        let outcome = await QuizSequenceHarness.replay(config: parsed.config, inputs: parsed.inputs)
        let run = outcome.run

        #expect(outcome.violation == nil, "\(outcome.violation.map { "\($0.invariant): \($0.detail)" } ?? "")")
        #expect(!run.network.requests.contains { $0.input == "skip" }, "question 1 was skipped — the car-test bug")
        #expect(run.recorder.entries.filter { $0.kind == .prompt && $0.name == "emptyAnswer.retry" }.count == 1,
                "the first empty answer must be met with exactly one spoken retry")
        #expect(run.sheetsSeen == ["q_001 (nothing heard)"], "the second miss must open Again/Skip on question 1")
        #expect(run.vm.currentQuestion?.id == "q_001" && run.vm.showAnswerConfirmation,
                "a minute later the sheet still waits for the driver")
        #expect(run.network.requests.allSatisfy { $0.questionId == "q_001" }, "nothing may be sent for question 2")
    }

    /// WHY: a harness that cannot fail is decoration. Plant a server bug (it
    /// grades the question AFTER the one asked about) and the run must catch
    /// it, cut it down to a handful of inputs, and print a dump that replays
    /// to the same failure.
    @Test("a planted bug is caught, shrunk and printed as a replayable dump")
    func plantedBugIsCaughtAndShrunk() async throws {
        let plant: QuizSequenceHarness.Configure = { $0.network.gradesNextQuestion = true }
        var caught: QuizSequenceHarness.Outcome?
        for seed in UInt64(186_000) ..< 186_050 {
            let outcome = await QuizSequenceHarness.generate(seed: seed, length: 30, configure: plant)
            if outcome.violation != nil { caught = outcome; break }
        }
        let failing = try #require(caught, "50 seeds never reached a graded result")
        #expect(failing.violation?.invariant == "result graded for another question")

        let minimal = await QuizSequenceHarness.shrink(failing, configure: plant)
        #expect(minimal.violation?.invariant == failing.violation?.invariant)
        #expect(minimal.inputs.count <= 6, "shrinking left \(minimal.inputs.count) inputs")

        let parsed = QuizSequenceDump.parse(QuizSequenceHarness.dump(minimal))
        #expect(parsed.config == minimal.config)
        #expect(parsed.inputs == minimal.inputs, "the printed dump does not parse back to the same inputs")
        let replayed = await QuizSequenceHarness.replay(config: parsed.config, inputs: parsed.inputs, configure: plant)
        #expect(replayed.violation?.invariant == failing.violation?.invariant)
    }
}
