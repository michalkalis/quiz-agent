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

    // MARK: - #188 G1–G3: lines outside the answer retry

    /// #188 G2 (founder 2026-10-06): the free questions ran out mid-quiz. Said
    /// once, before the paywall opens, so the stop is not a silent "crash".
    static func quotaReachedLine(language: CommandLanguage) -> String {
        switch language {
        case .slovak: "Otázky zadarmo na tento mesiac sa minuli. Ako pokračovať, uvidíš na obrazovke."
        case .czech: "Otázky zdarma na tento měsíc došly. Jak pokračovat, uvidíš na obrazovce."
        case .english: "You've used up this month's free questions. The screen shows how to continue."
        }
    }

    /// The error screen's line (#188 G1, founder 2026-10-06). `commands` are
    /// the words that screen will act on — empty when voice commands are off,
    /// so the line never promises a word nobody listens for. Command words
    /// come from the lexicon, so the line and the matcher cannot drift.
    static func errorLine(commands: [VoiceCommand], language: CommandLanguage) -> String {
        let opening = switch language {
        case .slovak: "Niečo sa pokazilo."
        case .czech: "Něco se pokazilo."
        case .english: "Something went wrong."
        }
        return [opening, saySentence(commands, language: language)].compactMap { $0 }.joined(separator: " ")
    }

    /// The set-end score (#188 G3): "Hotovo, 7 z 10 správne." then the words
    /// the score screen acts on.
    static func setFinishedLine(
        correct: Int, total: Int, commands: [VoiceCommand], language: CommandLanguage
    ) -> String {
        let score = switch language {
        case .slovak: "Hotovo, \(correct) z \(total) správne."
        case .czech: "Hotovo, \(correct) z \(total) správně."
        case .english: "Done, \(correct) out of \(total) right."
        }
        return [score, saySentence(commands, language: language)].compactMap { $0 }.joined(separator: " ")
    }

    /// "Povedz znova alebo stop." — no quote marks, the voice would read them
    /// (copy rule 10).
    private static func saySentence(_ commands: [VoiceCommand], language: CommandLanguage) -> String? {
        let words = commands.map { VoiceCommandLexicon.spokenWord($0, language: language) }
        guard let last = words.last else { return nil }
        let (verb, or) = switch language {
        case .slovak: ("Povedz", "alebo")
        case .czech: ("Řekni", "nebo")
        case .english: ("Say", "or")
        }
        let list = words.count > 1 ? "\(words.dropLast().joined(separator: ", ")) \(or) \(last)" : last
        return "\(verb) \(list)."
    }
}
