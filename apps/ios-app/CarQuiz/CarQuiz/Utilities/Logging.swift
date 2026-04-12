//
//  Logging.swift
//  CarQuiz
//
//  Structured logging with os.Logger — categorized, persistent, zero-overhead when not observed.
//  Filter in Console.app by subsystem "com.carquiz" and category.
//

import Foundation
import os

extension Logger {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.carquiz"

    /// Quiz flow: state transitions, question lifecycle, scoring
    static let quiz = Logger(subsystem: subsystem, category: "quiz")

    /// Audio: playback, recording, audio session management
    static let audio = Logger(subsystem: subsystem, category: "audio")

    /// Network: API calls, responses, errors
    static let network = Logger(subsystem: subsystem, category: "network")

    /// Voice commands: SpeechAnalyzer, command recognition
    static let voice = Logger(subsystem: subsystem, category: "voice")

    /// Speech-to-text: ElevenLabs streaming STT
    static let stt = Logger(subsystem: subsystem, category: "stt")

    /// Persistence: UserDefaults, question history
    static let persistence = Logger(subsystem: subsystem, category: "persistence")
}
