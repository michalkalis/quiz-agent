//
//  QuizSequenceInput.swift
//  HangsTests
//
//  #186 step 2 — the harness's event alphabet, written in the quiz flight
//  recorder's own vocabulary (#186 step 1). Every input renders as a recorder
//  line (`<time> <kind> <name> attempt=… state=…`), and a recorder dump parses
//  back into inputs, so the same format serves three jobs: the minimal sequence
//  a failing seed prints, a regression fixture, and a black box pulled off a
//  TestFlight device (Sentry attachment / feedback report).
//

import Foundation
@testable import Hangs

/// A driver tap. Raw values are the recorder's `tap` names where step 1 records
/// the tap (`mic`, `confirm`, `again`, `cancel`, `editTranscript`,
/// `mcqOption`); the rest are UI entry points the black box does not log yet.
enum QuizTap: String, CaseIterable {
    case mic, confirm, again, cancel, editTranscript, mcqOption
    case skip, typedAnswer, replay, pause, mute, next, stay, resume, retry, playAgain, endWithResults
}

/// What the on-device VAD / barge-in detector reports — plus `audio`: a
/// second of sound reaching the answer capture WITHOUT a VAD event, the device
/// behaviour of the 2026-09-23 car test (the detector heard nothing in 16 of
/// 16 recordings). The black box cannot see it; fixtures write it by hand.
enum QuizSpeech: String, CaseIterable {
    case speechStarted = "vad.speechStarted"
    case silenceAfterSpeech = "vad.silenceAfterSpeech"
    case bargeIn
    case audio
}

/// A server answer to the OLDEST request still in flight on its channel —
/// a late answer to an earlier attempt is simply an old request resolving.
enum QuizReply: String, CaseIterable {
    case voiceTranscript = "voiceSubmit.transcript"
    case voiceEmpty = "voiceSubmit.noAnswer"
    case voiceNotUnderstood = "voiceSubmit.400"
    case voiceServerError = "voiceSubmit.500"
    case voiceColdWake = "voiceSubmit.503"
    case textEvaluated = "quizResponse"
    case textServerError = "textSubmit.500"
    case textColdWake = "textSubmit.503"

    var isVoice: Bool { rawValue.hasPrefix("voiceSubmit") }
}

enum QuizInput: Equatable, CustomStringConvertible {
    case tap(QuizTap)
    case command(VoiceCommand)
    case speech(QuizSpeech)
    case network(QuizReply)
    /// `route audioInterruption.began` — the audio service's interruption
    /// callback (a phone call); the system also stops any playback.
    case interruption
    /// `route routeChange.newDeviceAvailable` (the car's Bluetooth connects,
    /// `connected`) or `.oldDeviceUnavailable` (it leaves) — the audio
    /// service's route-change callback (#185 track C).
    case routeChange(connected: Bool)
    case background
    case foreground
    /// Time passing with nothing else happening.
    case idle
    /// `prompt questionReadOut.end completed` (or a replay's): a field dump's
    /// read-out lasted exactly this long. Replayed dumps end question clips
    /// only on this line (see `QuizSequenceConfig.readOutEndsFromDump`).
    case readOutEnd

    var kind: QuizFlightRecorder.Kind {
        switch self {
        case .tap: .tap
        case .command: .command
        case .speech: .speech
        case .network: .network
        case .interruption, .routeChange: .route
        case .background, .foreground: .scene
        case .idle: .timer
        case .readOutEnd: .prompt
        }
    }

    var name: String {
        switch self {
        case let .tap(tap): tap.rawValue
        case let .command(command): command.rawValue
        case let .speech(speech): speech.rawValue
        case let .network(reply): reply.rawValue
        case .interruption: "audioInterruption.began"
        case let .routeChange(connected): connected ? "routeChange.newDeviceAvailable" : "routeChange.oldDeviceUnavailable"
        case .background: "background"
        case .foreground: "active"
        case .idle: "idle"
        case .readOutEnd: "questionReadOut.end"
        }
    }

    var description: String { "\(kind.rawValue) \(name)" }

    /// Driver-initiated (a tap, a spoken command or speech) — the only inputs
    /// allowed to cut a question read-out short or to ask for a skip.
    var isDriver: Bool {
        switch self {
        case .tap, .command, .speech: true
        default: false
        }
    }

    /// One recorder line → an input, or `nil` for a line that only reports a
    /// consequence (`state`, `attempt`, a fired `timer`, `recording.stop` …).
    /// A late result the app DROPPED shows up only as its `drop` line, so the
    /// drop paths map back to the reply that caused them.
    init?(kind: String, name: String, detail: String?) {
        switch kind {
        case "tap":
            guard let tap = QuizTap(rawValue: name) else { return nil }
            self = .tap(tap)
        case "command":
            guard let command = VoiceCommand(rawValue: name) else { return nil }
            self = .command(command)
        case "speech":
            guard let speech = QuizSpeech(rawValue: name) else { return nil }
            self = .speech(speech)
        case "network":
            guard let reply = QuizReply(rawValue: name) else { return nil }
            self = .network(reply)
        case "drop":
            switch name {
            case "voiceSubmit.result": self = .network(.voiceTranscript)
            case "voiceSubmit.error", "voiceSubmit.timeout", "voiceSubmit.quota": self = .network(.voiceServerError)
            case "mcqSubmit.error", "textSubmit.error", "skip.error": self = .network(.textServerError)
            case "quizResponse": self = .network(.textEvaluated)
            default: return nil
            }
        case "route":
            switch name {
            case "audioInterruption.began": self = .interruption
            case "routeChange.newDeviceAvailable": self = .routeChange(connected: true)
            case "routeChange.oldDeviceUnavailable": self = .routeChange(connected: false)
            default: return nil
            }
        case "scene":
            switch name {
            case "background": self = .background
            case "active": self = .foreground
            default: return nil
            }
        case "timer" where name == "idle":
            self = .idle
        case "prompt" where (name == "questionReadOut.end" || name == "questionReplay.end") && detail == "completed":
            self = .readOutEnd
        default:
            return nil
        }
    }
}

/// An input at a time, in milliseconds since the quiz start. Inputs sharing a
/// time are one burst: nothing runs between them — the "tap lands the instant
/// the answer arrives" race.
struct TimedInput: Equatable {
    var atMs: Int
    var input: QuizInput
    /// Free text carried on the recorder line (the MCQ key, a verdict).
    var detail: String?
}

// MARK: - Dump format

enum QuizSequenceDump {
    static let header = "Quiz flight recorder"
    static let configPrefix = "# quiz-sequence"

    /// `HH:mm:ss.SSS`, the recorder's time format.
    static func time(_ ms: Int) -> String {
        let hours = ms / 3_600_000, minutes = ms / 60000 % 60, seconds = ms / 1000 % 60
        return String(format: "%02d:%02d:%02d.%03d", hours, minutes, seconds, ms % 1000)
    }

    static func line(_ timed: TimedInput, attempt: String = "-", state: String = "-") -> String {
        var line = "\(time(timed.atMs)) \(timed.input.kind.rawValue) \(timed.input.name) attempt=\(attempt) state=\(state)"
        if let detail = timed.detail { line += " \(detail)" }
        return line
    }

    struct Parsed {
        var config: QuizSequenceConfig
        var inputs: [TimedInput]
    }

    /// Parse a dump. Times are made relative to the first timed line, so a
    /// recorder dump from a device replays from its first event. A
    /// `# quiz-sequence` line (the harness writes one) restores the run's
    /// configuration; a field dump without one replays on the defaults.
    static func parse(_ text: String) -> Parsed {
        var config = QuizSequenceConfig.fieldDefaults
        var inputs: [TimedInput] = []
        var origin: Int?
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix(configPrefix) {
                config = QuizSequenceConfig(line: line) ?? config
                continue
            }
            let fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard fields.count >= 3, let ms = milliseconds(fields[0]) else { continue }
            let base = origin ?? ms
            origin = base
            let detailFields = fields.dropFirst(3).filter { !$0.hasPrefix("attempt=") && !$0.hasPrefix("state=") }
            let detail = detailFields.isEmpty ? nil : detailFields.joined(separator: " ")
            guard let input = QuizInput(kind: fields[1], name: fields[2], detail: detail) else { continue }
            inputs.append(TimedInput(atMs: ms - base, input: input, detail: detail))
        }
        // A dump that says when each read-out ended replays those ends, not
        // the harness's fixed clip length.
        config.readOutEndsFromDump = inputs.contains { $0.input == .readOutEnd }
        return Parsed(config: config, inputs: inputs)
    }

    private static func milliseconds(_ field: String) -> Int? {
        let parts = field.split(separator: ":")
        guard parts.count == 3, let hours = Int(parts[0]), let minutes = Int(parts[1]) else { return nil }
        let secondParts = parts[2].split(separator: ".")
        guard let seconds = Int(secondParts[0]) else { return nil }
        let fraction = secondParts.count > 1 ? String(secondParts[1].prefix(3)) : "0"
        let millis = (Int(fraction) ?? 0) * Int(pow(10.0, Double(3 - fraction.count)))
        return ((hours * 60 + minutes) * 60 + seconds) * 1000 + millis
    }
}
