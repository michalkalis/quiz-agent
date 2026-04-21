//
//  Logging.swift
//  Hangs
//
//  Structured logging with os.Logger — categorized, persistent, zero-overhead when not observed.
//  Filter in Console.app by subsystem "com.missinghue.hangs" and category.
//
//  `SentryLog.*` always writes to `Logger.<category>` (console) and additionally forwards to
//  Sentry Structured Logs when the SDK is running. On simulator Sentry is intentionally disabled
//  (see HangsApp.init), so routing through console keeps logs visible during local development.
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

    nonisolated var logger: Logger {
        switch self {
        case .quiz: return .quiz
        case .audio: return .audio
        case .network: return .network
        case .voice: return .voice
        case .stt: return .stt
        case .persistence: return .persistence
        }
    }
}

/// Adds a Sentry breadcrumb when the SDK is running; no-op otherwise.
/// Keeps scattered call sites free of `SentrySDK.isEnabled` checks so simulator builds
/// (where Sentry is intentionally off) don't emit "SDK is disabled" warnings.
enum SentryBreadcrumb {
    nonisolated static func add(_ crumb: Breadcrumb) {
        guard SentrySDK.isEnabled else { return }
        SentrySDK.addBreadcrumb(crumb)
    }
}

/// Mirrors meaningful log points to Sentry so they are queryable from `/check-crashes` after TestFlight incidents.
///
/// Always emits to the OS console via `Logger.<category>` so messages remain visible locally
/// (simulator disables Sentry to preserve quota). Use alongside `Logger.<category>.debug` for verbose
/// traces — `SentryLog` is reserved for warn/error/critical points.
/// Default defensive: never pass raw user speech/transcripts as attribute values; use metadata (length, confidence).
enum SentryLog {
    nonisolated static func info(_ message: String, category: LogCategory, attributes: [String: Any] = [:]) {
        let summary = attributesSummary(attributes)
        category.logger.info("\(message, privacy: .public)\(summary, privacy: .public)")
        guard SentrySDK.isEnabled else { return }
        SentrySDK.logger.info(message, attributes: attributes.merging(["category": category.rawValue]) { current, _ in current })
    }

    nonisolated static func warn(_ message: String, category: LogCategory, attributes: [String: Any] = [:]) {
        let summary = attributesSummary(attributes)
        category.logger.warning("\(message, privacy: .public)\(summary, privacy: .public)")
        guard SentrySDK.isEnabled else { return }
        SentrySDK.logger.warn(message, attributes: attributes.merging(["category": category.rawValue]) { current, _ in current })
    }

    nonisolated static func error(_ message: String, category: LogCategory, attributes: [String: Any] = [:]) {
        let summary = attributesSummary(attributes)
        category.logger.error("\(message, privacy: .public)\(summary, privacy: .public)")
        guard SentrySDK.isEnabled else { return }
        SentrySDK.logger.error(message, attributes: attributes.merging(["category": category.rawValue]) { current, _ in current })
    }

    nonisolated private static func attributesSummary(_ attributes: [String: Any]) -> String {
        guard !attributes.isEmpty else { return "" }
        let joined = attributes
            .map { "\($0.key)=\($0.value)" }
            .sorted()
            .joined(separator: " ")
        return " [\(joined)]"
    }
}
