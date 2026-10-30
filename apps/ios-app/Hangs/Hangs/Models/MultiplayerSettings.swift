//
//  MultiplayerSettings.swift
//  Hangs
//
//  #212: what a game together plays with (plan table "Nastavenia v hre spolu").
//  #213.8: the host's own rules for it, kept apart from solo.
//

import Foundation

/// The host's rules for a game together, the same for every player. They are
/// their own set, kept on the device (`MultiplayerSettingsStore`), and never
/// written to the solo settings. Language, categories, difficulty, local
/// questions, the number of questions and the auto-advance pause still come
/// from the host's solo choices. The reveal is fixed once the game starts;
/// the answer time and reading aloud can change mid-game (the server applies
/// the time from the next question).
nonisolated struct MultiplayerSettings: Codable, Equatable, Sendable {
    var revealMode: RoomState.RevealMode = .round
    /// Answer time before the server's typing/tap margin.
    var thinkingSeconds = 30
    /// The host's phone reads every question aloud.
    var readsAloud = true

    /// What the host picks from; the server accepts 3–60 s.
    static let thinkingChoices = [15, 30, 45, 60]
    static let thinkingRange = 3 ... 60
    /// Guests never have voice; the host taps or types like everyone else.
    static let voiceCommandsEnabled = false
    static let hostAnswersByVoice = false
    /// Picture questions are not in the first version (the server enforces it).
    static let includeImageQuestions = false

    enum CodingKeys: String, CodingKey {
        case revealMode = "reveal_mode"
        case thinkingSeconds = "thinking_seconds"
        case readsAloud = "reads_aloud"
    }
}

extension RoomState.RevealMode {
    /// The same words as solo's "When to show answers".
    var displayName: String {
        (self == .round ? AnswerRevealMode.endOfSet : .perQuestion).displayName
    }
}

extension MultiplayerSettings {
    /// "30 s" for the answer time rows and chips.
    static func secondsDisplay(_ seconds: Int) -> String {
        String(localized: "\(seconds) s", bundle: .interface, locale: .interface, comment: "Hra spolu (#212)")
    }
}
