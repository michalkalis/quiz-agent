//
//  Logging.swift
//  CarQuiz
//
//  Structured logging with os.Logger — categorized, persistent, zero-overhead when not observed.
//  Filter in Console.app by subsystem "com.carquiz" and category.
//
//  `SentryLog.*` mirrors the same categories to Sentry Structured Logs so they are queryable
//  after TestFlight incidents without needing the device in hand.
//

import Foundation
import os
import Sentry

extension Logger {
    // Hardcoded subsystem (Bundle.main is MainActor in Swift 6 strict concurrency).
    // Logger is a Sendable value type so these static immutables are safe across threads.
    nonisolated private static let subsystem = "com.missinghue.hangs"

    /// Quiz flow: state transitions, question lifecycle, scoring
    nonisolated static let quiz = Logger(subsystem: subsystem, category: "quiz")

    /// Audio: playback, recording, audio session management
    nonisolated static let audio = Logger(subsystem: subsystem, category: "audio")

    /// Network: API calls, responses, errors
    nonisolated static let network = Logger(subsystem: subsystem, category: "network")

    /// Voice commands: SpeechAnalyzer, command recognition
    nonisolated static let voice = Logger(subsystem: subsystem, category: "voice")

    /// Speech-to-text: ElevenLabs streaming STT
    nonisolated static let stt = Logger(subsystem: subsystem, category: "stt")

    /// Persistence: UserDefaults, question history
    nonisolated static let persistence = Logger(subsystem: subsystem, category: "persistence")
}

/// Sentry Structured Log category — matches `Logger` categories above.
enum LogCategory: String {
    case quiz, audio, network, voice, stt, persistence
}

/// Mirrors meaningful log points to Sentry so they are queryable from `/check-crashes` after TestFlight incidents.
///
/// Use alongside `Logger.<category>.info/warn/error` at critical points only — not every debug print.
/// Default defensive: never pass raw user speech/transcripts as attribute values; use metadata (length, confidence).
enum SentryLog {
    nonisolated static func info(_ message: String, category: LogCategory, attributes: [String: Any] = [:]) {
        SentrySDK.logger.info(message, attributes: attributes.merging(["category": category.rawValue]) { current, _ in current })
    }

    nonisolated static func warn(_ message: String, category: LogCategory, attributes: [String: Any] = [:]) {
        SentrySDK.logger.warn(message, attributes: attributes.merging(["category": category.rawValue]) { current, _ in current })
    }

    nonisolated static func error(_ message: String, category: LogCategory, attributes: [String: Any] = [:]) {
        SentrySDK.logger.error(message, attributes: attributes.merging(["category": category.rawValue]) { current, _ in current })
    }
}
