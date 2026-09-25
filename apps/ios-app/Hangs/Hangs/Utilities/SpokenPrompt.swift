//
//  SpokenPrompt.swift
//  Hangs
//
//  Short lines the app SAYS to the driver mid-quiz (#185 track B). Spoken in the
//  QUIZ language — the language the driver is answering in and the command
//  words are matched in (#120) — never the app locale, so, like the command
//  grammar in VoiceCommandLexicon+Display, none of this lives in
//  Localizable.xcstrings. Synthesised through the backend's generic TTS
//  (`POST /tts/synthesize`, cached server-side), the same path as the answer
//  read-back. The same sentence is also SHOWN during the retry
//  (`EmptyAnswerRetryHint`) — that copy is ordinary UI text and follows the
//  app language like the rest of the screen.
//

import Foundation

enum SpokenPrompt: String, Sendable {
    /// Founder decision 1.1 (2026-09-24): an empty answer is met with this line
    /// and one automatic re-record.
    case didNotCatch

    func text(language: CommandLanguage) -> String {
        switch (self, language) {
        // Founder wording 2026-09-24. The on-screen twin is the xcstrings key
        // "I didn't catch your answer, please try again." (app language).
        case (.didNotCatch, .slovak): "Nezachytil som odpoveď, skús to znova."
        case (.didNotCatch, .czech): "Nezachytil jsem odpověď, zkus to znovu."
        case (.didNotCatch, .english): "I didn't catch your answer, please try again."
        }
    }
}
