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
//  read-back. On screen the retry is the open mic bar's "Didn't catch that"
//  (TF build 90), ordinary UI text in the app language.
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
        case (.didNotCatch, .slovak): "Odpoveď sa nepodarilo zachytiť, skús to znova."
        case (.didNotCatch, .czech): "Odpověď se nepodařilo zachytit, zkus to znovu."
        case (.didNotCatch, .ukrainian): "Не вдалося розчути відповідь, спробуй ще раз."
        case (.didNotCatch, .english): "I didn't catch your answer, please try again."
        // Founder wording 2026-09-24; on-screen twins "…Please say its
        // number." / "…Please say its letter." (app language).
        case (.mcqUnmatchedNumber, .slovak): "Nebolo jasné, ktorú možnosť myslíš. Povedz jej číslo."
        case (.mcqUnmatchedNumber, .czech): "Nebylo jasné, kterou možnost myslíš. Řekni její číslo."
        case (.mcqUnmatchedNumber, .ukrainian): "Незрозуміло, який варіант ти маєш на увазі. Назви його номер."
        case (.mcqUnmatchedNumber, .english): "I didn't catch which option you meant. Please say its number."
        case (.mcqUnmatchedLetter, .slovak): "Nebolo jasné, ktorú možnosť myslíš. Povedz jej písmeno."
        case (.mcqUnmatchedLetter, .czech): "Nebylo jasné, kterou možnost myslíš. Řekni její písmeno."
        case (.mcqUnmatchedLetter, .ukrainian): "Незрозуміло, який варіант ти маєш на увазі. Назви його літеру."
        case (.mcqUnmatchedLetter, .english): "I didn't catch which option you meant. Please say its letter."
        }
    }

    // MARK: - #188 G1–G3: lines outside the answer retry

    /// #188 G2 (founder 2026-10-06): the free questions ran out mid-quiz. Said
    /// once, before the paywall opens, so the stop is not a silent "crash".
    ///
    /// `upgradeAvailable == false`: a Trubbo Plus subscriber spent the month's
    /// allowance, so the questions that ran out are not "free" ones.
    static func quotaReachedLine(language: CommandLanguage, upgradeAvailable: Bool = true) -> String {
        guard upgradeAvailable else {
            return switch language {
            case .slovak: "Otázky Trubbo Plus na tento mesiac sa minuli. Ako pokračovať, uvidíš na obrazovke."
            case .czech: "Otázky Trubbo Plus na tento měsíc došly. Jak pokračovat, uvidíš na obrazovce."
            case .ukrainian: "Питання Trubbo Plus на цей місяць закінчилися. Як продовжити, побачиш на екрані."
            case .english: "You've used up this month's Trubbo Plus questions. The screen shows how to continue."
            }
        }
        return switch language {
        case .slovak: "Otázky zadarmo na tento mesiac sa minuli. Ako pokračovať, uvidíš na obrazovke."
        case .czech: "Otázky zdarma na tento měsíc došly. Jak pokračovat, uvidíš na obrazovce."
        case .ukrainian: "Безплатні питання на цей місяць закінчилися. Як продовжити, побачиш на екрані."
        case .english: "You've used up this month's free questions. The screen shows how to continue."
        }
    }

    /// Free tier split (founder 2026-11-21): the month's free voice answers
    /// are used up. Said once a month, the quiz goes on by typing and tapping.
    /// The on-screen twin is `VoiceLimitNotice` (app language).
    static func voiceLimitLine(language: CommandLanguage) -> String {
        switch language {
        case .slovak: "Hlasové odpovede zadarmo na tento mesiac sa minuli. Hraj ďalej písaním alebo klepnutím."
        case .czech: "Hlasové odpovědi zdarma na tento měsíc došly. Hraj dál psaním nebo klepnutím."
        case .ukrainian: "Безплатні голосові відповіді на цей місяць закінчилися. Грай далі й відповідай текстом або дотиком."
        case .english: "This month's free voice answers are used up. Keep playing by typing or tapping."
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
        case .ukrainian: "Щось пішло не так."
        case .english: "Something went wrong."
        }
        return [opening, saySentence(commands, language: language)].compactMap { $0 }.joined(separator: " ")
    }

    /// The round-end line (#248 — result screen and round-end cleanup,
    /// founder 2026-11-25): the score as a sentence, on a finished daily
    /// challenge the extra questions it earned today, then the offer naming
    /// the words the screen acts on. Every round end says it (score, recap,
    /// daily challenge). `bonusQuestions` is nil or 0 when nothing was earned.
    static func setFinishedLine(
        correct: Int, total: Int, bonusQuestions: Int? = nil, commands: [VoiceCommand], language: CommandLanguage
    ) -> String {
        let score = switch language {
        case .slovak: "Hotovo. Máš správne \(correct) z \(total) \(total == 1 ? "odpovede" : "odpovedí")."
        case .czech: "Hotovo. Máš správně \(correct) z \(total) \(total == 1 ? "odpovědi" : "odpovědí")."
        case .ukrainian: "Готово. У тебе правильно \(correct) з \(total) \(total == 1 ? "відповіді" : "відповідей")."
        case .english: "Done. You got \(correct) out of \(total) right."
        }
        let bonus = bonusQuestions.flatMap { $0 > 0 ? bonusSentence($0, language: language) : nil }
        return [score, bonus, setEndQuestion(commands: commands, language: language)]
            .compactMap { $0 }.joined(separator: " ")
    }

    /// "Za odmenu máš dnes 10 otázok navyše." The noun follows the number
    /// (sk / cs: 1, 2–4, 5+; uk also by the last digits).
    private static func bonusSentence(_ count: Int, language: CommandLanguage) -> String {
        switch language {
        case .slovak:
            let noun = switch count {
            case 1: "otázku"
            case 2 ... 4: "otázky"
            default: "otázok"
            }
            return "Za odmenu máš dnes \(count) \(noun) navyše."
        case .czech:
            let noun = switch count {
            case 1: "otázku"
            case 2 ... 4: "otázky"
            default: "otázek"
            }
            return "Za odměnu máš dnes \(count) \(noun) navíc."
        case .ukrainian:
            let lastTwo = count % 100
            let last = count % 10
            let noun = if (11 ... 14).contains(lastTwo) {
                "додаткових питань"
            } else if last == 1 {
                "додаткове питання"
            } else if (2 ... 4).contains(last) {
                "додаткові питання"
            } else {
                "додаткових питань"
            }
            return "У нагороду маєш сьогодні \(count) \(noun)."
        case .english:
            return "As a reward you get \(count) extra \(count == 1 ? "question" : "questions") today."
        }
    }

    /// The offer alone: "Chceš hrať ďalší kvíz? Povedz: ďalší. Alebo otvoriť
    /// úvodnú obrazovku? Povedz: domov." Also said once more when the round
    /// end hears nothing. Nil when nothing listens. The words come from the
    /// lexicon, so the line and the matcher cannot drift; no quote marks, the
    /// voice would read them (copy rule 10).
    static func setEndQuestion(commands: [VoiceCommand], language: CommandLanguage) -> String? {
        let sentences = commands.enumerated().compactMap { index, command in
            offerSentence(command, first: index == 0, language: language)
        }
        return sentences.isEmpty ? nil : sentences.joined(separator: " ")
    }

    private static func offerSentence(_ command: VoiceCommand, first: Bool, language: CommandLanguage) -> String? {
        let word = VoiceCommandLexicon.spokenWord(command, language: language, on: .setEnd)
        switch (command, language) {
        case (.next, .slovak): return "Chceš hrať ďalší kvíz? Povedz: \(word)."
        case (.next, .czech): return "Chceš hrát další kvíz? Řekni: \(word)."
        case (.next, .ukrainian): return "Хочеш зіграти ще одну вікторину? Скажи: \(word)."
        case (.next, .english): return "Want to play another quiz? Say: \(word)."
        case (.home, .slovak): return "\(first ? "Chceš" : "Alebo") otvoriť úvodnú obrazovku? Povedz: \(word)."
        case (.home, .czech): return "\(first ? "Chceš" : "Nebo") otevřít úvodní obrazovku? Řekni: \(word)."
        case (.home, .ukrainian): return "\(first ? "Хочеш" : "Або") відкрити головний екран? Скажи: \(word)."
        case (.home, .english): return "\(first ? "Want to" : "Or") go to the home screen? Say: \(word)."
        default: return nil
        }
    }

    /// "Povedz znova alebo stop." — no quote marks, the voice would read them
    /// (copy rule 10).
    private static func saySentence(_ commands: [VoiceCommand], language: CommandLanguage) -> String? {
        let words = commands.map { VoiceCommandLexicon.spokenWord($0, language: language) }
        guard let last = words.last else { return nil }
        let (verb, or) = switch language {
        case .slovak: ("Povedz", "alebo")
        case .czech: ("Řekni", "nebo")
        case .ukrainian: ("Скажи", "або")
        case .english: ("Say", "or")
        }
        let list = words.count > 1 ? "\(words.dropLast().joined(separator: ", ")) \(or) \(last)" : last
        return "\(verb) \(list)."
    }
}
