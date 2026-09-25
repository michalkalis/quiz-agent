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
    /// #185 track G (founder 2026-09-24): the server heard an MCQ answer but it
    /// named no single option (`mcq_unmatched`) — same flow, its own line,
    /// asking for the label the options carry.
    case mcqUnmatchedNumber
    case mcqUnmatchedLetter

    /// The line for a coded "say it again" 400 on `question` (nil = open
    /// question or none on screen).
    static func retry(for code: AnswerRetryCode, question: Question?) -> SpokenPrompt {
        guard code == .mcqUnmatched, let question, question.isMultipleChoice else { return .didNotCatch }
        return question.usesLetterLabels ? .mcqUnmatchedLetter : .mcqUnmatchedNumber
    }

    func text(language: CommandLanguage) -> String {
        switch (self, language) {
        // Founder wording 2026-09-24. The on-screen twin is the xcstrings key
        // "I didn't catch your answer, please try again." (app language).
        case (.didNotCatch, .slovak): "Nezachytil som odpoveď, skús to znova."
        case (.didNotCatch, .czech): "Nezachytil jsem odpověď, zkus to znovu."
        case (.didNotCatch, .english): "I didn't catch your answer, please try again."
        // Founder wording 2026-09-24; on-screen twins "…Please say its
        // number." / "…Please say its letter." (app language).
        case (.mcqUnmatchedNumber, .slovak): "Nezachytil som, ktorú možnosť myslíš. Povedz jej číslo."
        case (.mcqUnmatchedNumber, .czech): "Nezachytil jsem, kterou možnost myslíš. Řekni její číslo."
        case (.mcqUnmatchedNumber, .english): "I didn't catch which option you meant. Please say its number."
        case (.mcqUnmatchedLetter, .slovak): "Nezachytil som, ktorú možnosť myslíš. Povedz jej písmeno."
        case (.mcqUnmatchedLetter, .czech): "Nezachytil jsem, kterou možnost myslíš. Řekni její písmeno."
        case (.mcqUnmatchedLetter, .english): "I didn't catch which option you meant. Please say its letter."
        }
    }
}
