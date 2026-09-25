//
//  QuizSequenceGenerator.swift
//  HangsTests
//
//  #186 step 2 — where the random sequences come from, and how a failing one
//  is cut down to the few inputs that matter.
//
//  Generation is ONLINE: each next input is drawn from what the driver (or the
//  server, the clock, the OS) could plausibly do on the screen the quiz is on
//  right now, so a run spends its budget on reachable interleavings instead of
//  taps on buttons that are not there. The drawn inputs are recorded as a
//  plain list, and everything downstream — replay, shrinking, the printed dump
//  — works on that list alone.
//

import Foundation
@testable import Hangs

/// SplitMix64: tiny, fast, and the same sequence on every machine for a seed.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func chance(_ probability: Double) -> Bool {
        Double.random(in: 0 ..< 1, using: &self) < probability
    }
}

/// The quiz a run plays and the settings it plays with — drawn from the seed,
/// written into every dump (`# quiz-sequence …`) so a replay plays the same one.
struct QuizSequenceConfig: Equatable {
    var seed: UInt64 = 0
    var questionCount = 5
    /// 1-based indices of the multiple-choice questions.
    var mcqQuestions: Set<Int> = []
    var autoRecord = true
    var thinkingTime = 10
    var autoConfirm = true
    var muted = false
    var voiceCommands = true
    var endOfSetReveal = false
    var feedbackAudio = true
    /// The on-device detector cannot vouch for silence (#185 track A verdict
    /// `.noAudio`), so the 5 s window defers to the dead-air cap.
    var deafDetector = false

    /// Production defaults, for a black box pulled off a device.
    static let fieldDefaults = QuizSequenceConfig()

    init() {}

    init(seed: UInt64) {
        var rng = SeededGenerator(seed: seed ^ 0xC0FF_EE18_6000_0002)
        self.seed = seed
        questionCount = Int.random(in: 3 ... 5, using: &rng)
        mcqQuestions = Set((1 ... questionCount).filter { _ in rng.chance(0.3) })
        autoRecord = rng.chance(0.8)
        thinkingTime = [0, 3, 10, 10].randomElement(using: &rng) ?? 10
        autoConfirm = rng.chance(0.85)
        muted = rng.chance(0.2)
        voiceCommands = rng.chance(0.9)
        endOfSetReveal = rng.chance(0.2)
        feedbackAudio = rng.chance(0.5)
        deafDetector = rng.chance(0.25)
    }

    var line: String {
        let mcq = mcqQuestions.sorted().map(String.init).joined(separator: ",")
        return "\(QuizSequenceDump.configPrefix) seed=\(seed) questions=\(questionCount) mcq=\(mcq.isEmpty ? "-" : mcq)"
            + " autoRecord=\(autoRecord ? 1 : 0) thinking=\(thinkingTime) autoConfirm=\(autoConfirm ? 1 : 0)"
            + " muted=\(muted ? 1 : 0) commands=\(voiceCommands ? 1 : 0) endOfSet=\(endOfSetReveal ? 1 : 0)"
            + " feedbackAudio=\(feedbackAudio ? 1 : 0) deafDetector=\(deafDetector ? 1 : 0)"
    }

    init?(line: String) {
        var values: [String: String] = [:]
        for field in line.split(separator: " ") {
            let pair = field.split(separator: "=", maxSplits: 1).map(String.init)
            if pair.count == 2 { values[pair[0]] = pair[1] }
        }
        guard let seed = values["seed"].flatMap(UInt64.init) else { return nil }
        self.seed = seed
        func flag(_ key: String, _ fallback: Bool) -> Bool { values[key].map { $0 == "1" } ?? fallback }
        questionCount = values["questions"].flatMap(Int.init) ?? questionCount
        mcqQuestions = Set((values["mcq"] ?? "").split(separator: ",").compactMap { Int($0) })
        autoRecord = flag("autoRecord", autoRecord)
        thinkingTime = values["thinking"].flatMap(Int.init) ?? thinkingTime
        autoConfirm = flag("autoConfirm", autoConfirm)
        muted = flag("muted", muted)
        voiceCommands = flag("commands", voiceCommands)
        endOfSetReveal = flag("endOfSet", endOfSetReveal)
        feedbackAudio = flag("feedbackAudio", feedbackAudio)
        deafDetector = flag("deafDetector", deafDetector)
    }
}

// MARK: - Online generation

@MainActor
struct QuizSequenceGenerator {
    private var rng: SeededGenerator
    private var now = 0

    init(seed: UInt64) {
        rng = SeededGenerator(seed: seed)
    }

    /// When the next input happens (ms since the quiz start). The run moves
    /// its clock there BEFORE the input is drawn, so the draw sees the screen
    /// the driver would see at that moment.
    /// `inFlight`: a request is waiting for the server — bursts get likelier,
    /// because an answer landing in the same instant as a tap is exactly the
    /// race a late result is made of.
    mutating func nextTime(isFirst: Bool, inFlight: Bool) -> Int {
        now += delay(burst: isFirst ? 0 : (inFlight ? 0.2 : 0.06))
        return now
    }

    /// The next input for the quiz as `run` has it right now.
    mutating func pick(for run: QuizSequenceRun, at time: Int) -> TimedInput {
        let options = candidates(run)
        let total = options.reduce(0) { $0 + $1.weight }
        var pick = Double.random(in: 0 ..< total, using: &rng)
        for option in options {
            pick -= option.weight
            if pick < 0 { return TimedInput(atMs: time, input: option.input, detail: option.detail) }
        }
        return TimedInput(atMs: time, input: .idle)
    }

    /// Mostly the gaps of real driving; a few zero gaps (a burst — two things
    /// in the same instant) and a few long ones that let every timer run out.
    private mutating func delay(burst: Double) -> Int {
        if rng.chance(burst) { return 0 }
        let roll = Double.random(in: 0 ..< 1, using: &rng)
        if roll < 0.55 { return Int.random(in: 100 ... 1500, using: &rng) }
        if roll < 0.85 { return Int.random(in: 1500 ... 8000, using: &rng) }
        return Int.random(in: 8000 ... 30000, using: &rng)
    }

    private struct Option {
        var input: QuizInput
        var detail: String?
        var weight: Double
    }

    private mutating func candidates(_ run: QuizSequenceRun) -> [Option] {
        let vm = run.vm
        var options = [Option(input: .idle, weight: 2)]
        func add(_ input: QuizInput, _ weight: Double, _ detail: String? = nil) {
            options.append(Option(input: input, detail: detail, weight: weight))
        }

        // The server may answer any request still in flight, whatever the
        // screen shows by now — that is what a late result is.
        if run.network.hasPending(voice: true) {
            add(.network(.voiceTranscript), 2.4)
            add(.network(.voiceNotUnderstood), 0.7)
            add(.network(.voiceEmpty), 0.4)
            add(.network(.voiceColdWake), 0.3)
            add(.network(.voiceServerError), 0.15)
        }
        if run.network.hasPending(voice: false) {
            add(.network(.textEvaluated), 2.5, rng.chance(0.6) ? "correct" : "incorrect")
            add(.network(.textColdWake), 0.3)
            add(.network(.textServerError), 0.15)
        }

        if !vm.isAppForeground {
            add(.foreground, 3)
        } else if run.isOnQuestionScreen || vm.quizState.isShowingResult {
            add(.background, 0.25)
            add(.interruption, 0.2)
            add(.routeChange, 0.1)
        }
        if run.isOnQuestionScreen {
            add(.tap(.mute), 0.2)
            add(.tap(.endWithResults), 0.03)
            if vm.canPauseQuiz || vm.isPaused { add(.tap(.pause), 0.35) }
        }

        if run.isCommandWindowOpen {
            let screen = vm.voiceCommandCoordinator.currentCommandScreen
            let onScreen: [VoiceCommand] = switch screen {
            case .question: [.start, .repeatQuestion, .skip, .pause]
            case .confirmation: [.ok, .again, .stop, .pause]
            case .result: [.next, .ok]
            default: []
            }
            for command in onScreen {
                add(.command(command), 0.5)
            }
            if let stray = VoiceCommand.allCases.randomElement(using: &rng) { add(.command(stray), 0.1) }
        }

        switch vm.quizState {
        case .askingQuestion where !run.isSheetUp:
            add(.tap(.mic), 2.5)
            add(.tap(.skip), 0.7)
            add(.tap(.replay), 0.35)
            add(.tap(.typedAnswer), 0.25)
            if vm.currentQuestion?.isMultipleChoice == true { add(.tap(.mcqOption), 2, mcqKey(run)) }
            if vm.taskBag.contains(.bargeIn) { add(.speech(.bargeIn), 0.4) }
        case .recording:
            add(.tap(.mic), 1.5)
            if run.silence.isAnswerCaptureActive {
                add(.speech(.speechStarted), 3)
                add(.speech(.audio), 1)
                add(.speech(.silenceAfterSpeech), 2)
            }
            if vm.currentQuestion?.isMultipleChoice == true { add(.tap(.mcqOption), 1, mcqKey(run)) }
        case .processing where run.isSheetUp:
            add(.tap(.confirm), 2)
            add(.tap(.again), 1.2)
            add(.tap(.editTranscript), 0.2)
        case .showingResult:
            add(.tap(.next), 2)
            add(vm.isPaused ? .tap(.resume) : .tap(.stay), 0.5)
        case .finished, .idle:
            add(.tap(.playAgain), 1.5)
        case .error:
            add(.tap(.retry), 2)
        default:
            break
        }
        return options
    }

    private mutating func mcqKey(_ run: QuizSequenceRun) -> String? {
        run.vm.currentQuestion?.sortedAnswerOptions.randomElement(using: &rng)?.key
    }
}

// MARK: - Shrinking

enum QuizSequenceShrinker {
    /// Delta-debugging over the input list: drop chunks, halving the chunk
    /// size, while the SAME invariant still breaks. Removing an input keeps
    /// every later input at its own time, so the timers between them still
    /// run as they did. `fails` replays a candidate from scratch.
    @MainActor
    static func shrink(
        _ inputs: [TimedInput],
        fails: ([TimedInput]) async -> Bool
    ) async -> [TimedInput] {
        var current = inputs
        var chunk = max(1, current.count / 2)
        while chunk >= 1 {
            var progress = false
            var start = 0
            while start < current.count {
                var candidate = current
                candidate.removeSubrange(start ..< min(start + chunk, current.count))
                if await fails(candidate) {
                    current = candidate
                    progress = true
                } else {
                    start += chunk
                }
            }
            if !progress {
                if chunk == 1 { break }
                chunk = max(1, chunk / 2)
            }
        }
        return current
    }
}
