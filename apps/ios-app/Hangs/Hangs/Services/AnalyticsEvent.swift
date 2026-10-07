//
//  AnalyticsEvent.swift
//  Hangs
//
//  #51: the client-only product analytics events — only what the server
//  cannot observe itself. Names and property keys mirror the backend allowlist
//  (`apps/quiz-agent/app/analytics/taxonomy.py`, CLIENT_EVENTS) and
//  `docs/product/analytics-events.md`; the server drops anything else. Values
//  are short scalars only: never transcript or answer text, never a device
//  identifier.
//

import AVFAudio
import Foundation

enum AnalyticsEvent: Equatable {
    case appOpened(launch: AppLaunchKind)
    case onboardingFinished(outcome: OnboardingOutcome, step: String)
    case quizContext(audioRoute: AudioRouteKind, voiceCommandsEnabled: Bool, entryPoint: QuizEntryPoint)
    case quizAbandoned(questionsAnswered: Int, phase: String)
    case answerSubmitted(inputMode: AnswerInputMode, questionId: String?, isRetry: Bool)
    case voiceCaptureFailed(reason: VoiceCaptureFailure, questionId: String?)
    case voiceCommand(command: VoiceCommand, phase: String)
    case paywallViewed(source: PaywallSource)
    case purchaseResult(productId: String, kind: PurchaseKind, outcome: PurchaseResultOutcome)
    case restoreResult(outcome: RestoreOutcome)

    var name: String {
        switch self {
        case .appOpened: "app_opened"
        case .onboardingFinished: "onboarding_finished"
        case .quizContext: "quiz_context"
        case .quizAbandoned: "quiz_abandoned"
        case .answerSubmitted: "answer_submitted"
        case .voiceCaptureFailed: "voice_capture_failed"
        case .voiceCommand: "voice_command"
        case .paywallViewed: "paywall_viewed"
        case .purchaseResult: "purchase_result"
        case .restoreResult: "restore_result"
        }
    }

    /// A nil value (an unknown question id) leaves its key out.
    var properties: [String: AnalyticsValue] {
        let pairs: [(String, AnalyticsValue?)] = switch self {
        case let .appOpened(launch):
            [("launch", .string(launch.rawValue))]
        case let .onboardingFinished(outcome, step):
            [("outcome", .string(outcome.rawValue)), ("step", .string(step))]
        case let .quizContext(audioRoute, voiceCommandsEnabled, entryPoint):
            [
                ("audio_route", .string(audioRoute.rawValue)),
                ("voice_commands_enabled", .bool(voiceCommandsEnabled)),
                ("entry_point", .string(entryPoint.rawValue)),
            ]
        case let .quizAbandoned(questionsAnswered, phase):
            [("questions_answered", .int(questionsAnswered)), ("phase", .string(phase))]
        case let .answerSubmitted(inputMode, questionId, isRetry):
            [
                ("input_mode", .string(inputMode.rawValue)),
                ("question_id", questionId.map { .string($0) }),
                ("is_retry", .bool(isRetry)),
            ]
        case let .voiceCaptureFailed(reason, questionId):
            [("reason", .string(reason.rawValue)), ("question_id", questionId.map { .string($0) })]
        case let .voiceCommand(command, phase):
            [("command", .string(command.rawValue)), ("phase", .string(phase))]
        case let .paywallViewed(source):
            [("source", .string(source.rawValue))]
        case let .purchaseResult(productId, kind, outcome):
            [
                ("product_id", .string(productId)),
                ("kind", .string(kind.rawValue)),
                ("outcome", .string(outcome.rawValue)),
            ]
        case let .restoreResult(outcome):
            [("outcome", .string(outcome.rawValue))]
        }
        return pairs.reduce(into: [:]) { result, pair in
            if let value = pair.1 { result[pair.0] = value }
        }
    }
}

/// One property value on the wire: a bare JSON string, number or boolean.
nonisolated enum AnalyticsValue: Encodable, Equatable, Sendable {
    case string(String)
    case int(Int)
    case bool(Bool)

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .int(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        }
    }
}

// MARK: - Property values

enum AppLaunchKind: String {
    case cold
    case foreground
}

enum OnboardingOutcome: String {
    case micGranted = "mic_granted"
    case micDenied = "mic_denied"
    /// "Maybe later" on the permission page — the mic stays undecided.
    case micLater = "mic_later"
    /// "Skip" before the permission page was reached.
    case skipped
}

enum QuizEntryPoint: String {
    case home
    case pack
    case playAgain = "play_again"
    case retry

    /// Where a quiz start came from: a pack id, or the screen the start left.
    init(packId: String?, startedFrom state: QuizState) {
        if packId != nil {
            self = .pack
            return
        }
        switch state {
        case .finished: self = .playAgain
        case .error: self = .retry
        default: self = .home
        }
    }
}

/// Where the quiz's sound is going — the usage-context signal (car vs. home
/// vs. party). Only the route class leaves the device, never a device name.
enum AudioRouteKind: String {
    case carplay
    case bluetooth
    case speaker
    case headphones
    case airplay
    case other

    init(port: AVAudioSession.Port?) {
        switch port {
        case .carAudio: self = .carplay
        case .bluetoothA2DP, .bluetoothHFP, .bluetoothLE: self = .bluetooth
        case .builtInSpeaker, .builtInReceiver: self = .speaker
        case .headphones: self = .headphones
        case .airPlay: self = .airplay
        default: self = .other
        }
    }

    static var current: AudioRouteKind {
        AudioRouteKind(port: AVAudioSession.sharedInstance().currentRoute.outputs.first?.portType)
    }
}

enum AnswerInputMode: String {
    case voice
    case tap
    case typed
}

/// Why an on-device answer capture produced nothing to submit. Server-side
/// rejections are the server's `transcription_failed`, never this.
enum VoiceCaptureFailure: String {
    case tooShort = "too_short"
    case emptyTranscript = "empty_transcript"
    case sttTimeout = "stt_timeout"
    case sttCommitFailed = "stt_commit_failed"
    case recorderFailed = "recorder_failed"
}

enum PaywallSource: String {
    case quota
    case home
    case settings
    case completion
}

enum PurchaseKind: String {
    case subscription
    case credits
    case customPack = "custom_pack"
}

enum PurchaseResultOutcome: String {
    case success
    case cancelled
    case failed
    case pending
}

enum RestoreOutcome: String {
    case success
    case nothingToRestore = "nothing_to_restore"
    case failed
}
