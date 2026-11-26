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
/// written to the solo settings (the categories included, #249.1). Language, difficulty, local
/// questions, the number of questions and the auto-advance pause still come
/// from the host's solo choices. The reveal is fixed once the game starts;
/// the answer time and reading aloud can change mid-game (the server applies
/// the time from the next question).
nonisolated struct MultiplayerSettings: Codable, Equatable, Sendable {
    /// #240.9 (founder 2026-11-18): answers show after every question, and
    /// 15 s to answer, unless the host picked otherwise (`Choices`).
    var revealMode: RoomState.RevealMode = .question
    /// Answer time before the server's typing/tap margin.
    var thinkingSeconds = 15
    /// The host's phone reads every question aloud.
    var readsAloud = true
    /// #249.1: the categories the room plays, empty = all. Their own choice,
    /// never the solo categories (#212: solo settings do not change through a game together).
    var categories: [String] = []

    /// What the host picks from; the server accepts 3–60 s.
    static let thinkingChoices = [15, 30, 45, 60]
    static let thinkingRange = 3 ... 60
    /// #224: any other value in the range is "custom".
    static func isPreset(_ seconds: Int) -> Bool { thinkingChoices.contains(seconds) }
    /// Guests never have voice; the host taps or types like everyone else.
    static let voiceCommandsEnabled = false
    static let hostAnswersByVoice = false
    /// Picture questions are not in the first version (the server enforces it).
    static let includeImageQuestions = false

    enum CodingKeys: String, CodingKey {
        case revealMode = "reveal_mode"
        case thinkingSeconds = "thinking_seconds"
        case readsAloud = "reads_aloud"
        case categories
    }

    init(revealMode: RoomState.RevealMode = .question, thinkingSeconds: Int = 15, readsAloud: Bool = true, categories: [String] = []) {
        self.revealMode = revealMode
        self.thinkingSeconds = thinkingSeconds
        self.readsAloud = readsAloud
        self.categories = categories
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
