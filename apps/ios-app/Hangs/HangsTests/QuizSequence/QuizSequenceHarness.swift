//
//  QuizSequenceHarness.swift
//  HangsTests
//
//  #186 step 2 — generate a seeded sequence, replay a list of inputs (from a
//  seed, a fixture or a device's black box), shrink a failure to its minimal
//  sequence, and print that sequence as a flight-recorder dump that replays.
//
//  Reproduce a failing seed:
//    TEST_RUNNER_QUIZ_SEQUENCE_SEED=<seed> xcodebuild test … \
//      -only-testing:HangsTests/QuizSequenceTests
//  A larger local run (CI runs the default count):
//    TEST_RUNNER_QUIZ_SEQUENCE_COUNT=20000 TEST_RUNNER_QUIZ_SEQUENCE_BASE_SEED=<n> …
//  Replay a dump: save it under HangsTests/QuizSequence/Fixtures/ and replay it
//  like `QuizSequenceTests.carTestDumpReplays` does (`QuizSequenceDump.parse`
//  + `QuizSequenceHarness.replay`).
//

import Foundation
@testable import Hangs

@MainActor
enum QuizSequenceHarness {
    struct Outcome {
        let config: QuizSequenceConfig
        let inputs: [TimedInput]
        let run: QuizSequenceRun
        var violation: QuizSequenceRun.Violation? { run.violation }
    }

    typealias Configure = @MainActor (QuizSequenceRun) -> Void

    /// Draw and play one seeded sequence of `length` inputs.
    static func generate(seed: UInt64, length: Int, configure: Configure = { _ in }) async -> Outcome {
        let config = QuizSequenceConfig(seed: seed)
        let run = QuizSequenceRun(config: config)
        configure(run)
        await run.start()
        var generator = QuizSequenceGenerator(seed: seed)
        var inputs: [TimedInput] = []
        for index in 0 ..< length {
            let inFlight = run.network.hasPending(voice: true) || run.network.hasPending(voice: false)
            let at = generator.nextTime(isFirst: index == 0, inFlight: inFlight)
            await run.advance(to: at)
            // A violation while time passed still needs its moment in the
            // list, or a replay would let that time pass differently.
            let next = run.violation == nil ? generator.pick(for: run, at: at) : TimedInput(atMs: at, input: .idle)
            inputs.append(next)
            run.apply(next)
            if run.violation != nil { break }
        }
        await run.finish()
        return Outcome(config: config, inputs: inputs, run: run)
    }

    /// Play a fixed list of inputs — exactly what `generate` did, minus the drawing.
    static func replay(config: QuizSequenceConfig, inputs: [TimedInput], configure: Configure = { _ in }) async -> Outcome {
        let run = QuizSequenceRun(config: config)
        configure(run)
        await run.start()
        for input in inputs {
            await run.advance(to: input.atMs)
            run.apply(input)
            if run.violation != nil { break }
        }
        await run.finish()
        return Outcome(config: config, inputs: inputs, run: run)
    }

    /// The fewest inputs that still break the SAME invariant.
    static func shrink(_ outcome: Outcome, configure: Configure = { _ in }) async -> Outcome {
        guard let target = outcome.violation?.invariant else { return outcome }
        let minimal = await QuizSequenceShrinker.shrink(outcome.inputs) { candidate in
            await replay(config: outcome.config, inputs: candidate, configure: configure).violation?.invariant == target
        }
        return await replay(config: outcome.config, inputs: minimal, configure: configure)
    }

    // MARK: - Printing

    /// The run's inputs as a replayable flight-recorder dump. The first line
    /// anchors time zero (the quiz start) for `QuizSequenceDump.parse`.
    static func dump(_ outcome: Outcome) -> String {
        var lines = [outcome.config.line, "\(QuizSequenceDump.header) — \(outcome.inputs.count) inputs"]
        lines.append("\(QuizSequenceDump.time(0)) state quizStart attempt=- state=idle")
        for applied in outcome.run.log {
            lines.append(QuizSequenceDump.line(applied.timed, attempt: applied.attempt, state: applied.state))
        }
        return lines.joined(separator: "\n")
    }

    static func report(seed: UInt64, original: Outcome, minimal: Outcome) -> String {
        let violation = minimal.violation ?? original.violation
        return """
        Quiz sequence seed \(seed) broke "\(violation?.invariant ?? "?")" — \(violation?.detail ?? "") \
        at \(QuizSequenceDump.time(violation?.atMs ?? 0)).
        Reproduce: TEST_RUNNER_QUIZ_SEQUENCE_SEED=\(seed) xcodebuild test … -only-testing:HangsTests/QuizSequenceTests
        Minimal sequence (\(minimal.inputs.count) of \(original.inputs.count) inputs) — a replayable dump:
        \(dump(minimal))

        The app's own black box on that minimal run, up to the violation:
        \(minimal.run.recorderAtViolation ?? minimal.run.recorder.dump(last: 60))
        """
    }
}

// MARK: - Run-wide statistics

/// What a batch of sequences exercised — printed with every run so "no
/// violation" is visibly not "nothing happened".
struct QuizSequenceStats {
    var sequences = 0
    var inputs = 0
    var applied = 0
    var sheets = 0
    var results = 0
    var driverSkips = 0
    var retryPrompts = 0
    var drops: [String: Int] = [:]
    var rejects: [String: Int] = [:]
    var states: [String: Int] = [:]

    @MainActor
    mutating func add(_ outcome: QuizSequenceHarness.Outcome) {
        let run = outcome.run
        sequences += 1
        inputs += run.log.count
        applied += run.log.filter(\.applied).count
        sheets += run.sheetsSeen.count
        results += run.vm.recapEntries.count
        driverSkips += run.skipsSubmitted.count
        for entry in run.recorder.entries {
            switch entry.kind {
            case .drop: drops[entry.name, default: 0] += 1
            case .reject: rejects["\(entry.name) [\(entry.detail ?? "-")]", default: 0] += 1
            case .prompt where entry.name == "emptyAnswer.retry": retryPrompts += 1
            case .state:
                if let to = entry.name.split(separator: "→").last { states[String(to), default: 0] += 1 }
            default: break
            }
        }
    }

    var summary: String {
        func top(_ counts: [String: Int]) -> String {
            counts.sorted { $0.value > $1.value }.map { "\($0.key)×\($0.value)" }.joined(separator: ", ")
        }
        return """
        \(sequences) sequences, \(inputs) inputs (\(applied) reached the app), \(sheets) confirmation sheets, \
        \(results) results, \(driverSkips) driver skips, \(retryPrompts) empty-answer retries
        states entered: \(top(states))
        stale results dropped by the attempt check: \(drops.isEmpty ? "none" : top(drops))
        rejected transitions: \(rejects.isEmpty ? "none" : top(rejects))
        """
    }
}
