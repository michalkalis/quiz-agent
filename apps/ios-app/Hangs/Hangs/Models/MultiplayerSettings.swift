//
//  MultiplayerSettings.swift
//  Hangs
//
//  #212: what a game together plays with (plan table "Nastavenia v hre spolu").
//

import Foundation

/// The host's choices for a game together. Language, categories, difficulty,
/// local questions and the number of questions are the host's solo choices
/// and hold for everyone; reveal and thinking time are sent with the room.
/// Playing together never writes to the solo settings. Where these are
/// edited is #213 (Profile and quick settings); until then they follow the
/// host's solo values.
struct MultiplayerSettings: Equatable, Sendable {
    var revealMode: RoomState.RevealMode
    /// Answer time before the server's typing/tap margin, 3–60 s for everyone.
    var thinkingSeconds: Int
    /// After a reveal the host's phone moves on by itself after this long.
    var autoAdvanceSeconds: Int
    /// The host's phone reads every question aloud (off when muted).
    var readsAloud: Bool
    /// Off by default in a game together; guests never have voice.
    var voiceCommandsEnabled = false
    /// The host answers by tapping or typing like everyone else by default.
    var hostAnswersByVoice = false
    /// Picture questions are not in the first version (the server enforces it).
    let includeImageQuestions = false

    static let thinkingRange = 3 ... 60
    static let defaultThinkingSeconds = 10

    init(solo: QuizSettings) {
        revealMode = solo.answerRevealMode == .endOfSet ? .round : .question
        // Solo's 0 means "record at once", which is no answer time for typing.
        thinkingSeconds = solo.thinkingTime == 0
            ? Self.defaultThinkingSeconds
            : min(max(solo.thinkingTime, Self.thinkingRange.lowerBound), Self.thinkingRange.upperBound)
        autoAdvanceSeconds = solo.autoAdvanceDelay
        readsAloud = !solo.isMuted
    }
}
