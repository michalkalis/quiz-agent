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
//  read-back.
//

import Foundation

enum SpokenPrompt: String, Sendable {
    /// Founder decision 1.1 (2026-09-24): an empty answer is met with this line
    /// and one automatic re-record.
    case didNotCatch

    func text(language: CommandLanguage) -> String {
        switch (self, language) {
        case (.didNotCatch, .slovak): "Nepočul som, povedz to znova."
        case (.didNotCatch, .czech): "Neslyšel jsem, řekni to znovu."
        case (.didNotCatch, .english): "I didn't catch that. Say it again."
        }
    }
}
