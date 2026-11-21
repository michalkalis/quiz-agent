//
//  VoiceCommandLexicon+Vocabulary.swift
//  Hangs
//
//  What the recognizer is biased toward, and the one word that may ride along
//  with a command: the word for "question". Split out of
//  VoiceCommandLexicon.swift (past the ~300-line cap).
//
//  Voice commands never worked reliably (founder, 2026-11). Two causes were
//  ours: "zopakuj otázku" / "ďalšia otázka" / "next question" were two
//  content words and matched nothing, and the bias list handed to
//  DictationTranscriber carried backchannels ("áno", "hej", "nie") on every
//  screen, including the ones where they are deliberately not commands.
//  Every table here has an entry for every quiz language.
//

import Foundation

extension VoiceCommandLexicon {
    // MARK: - The word for "question"

    /// Normalized forms of the word "question" that may accompany a command
    /// about the question — "zopakuj otázku", "další otázka", "next question",
    /// "повтори питання". Alone, or next to any other content word, they are
    /// still not a command (`VoiceCommandMatcher.match`).
    static func questionWords(for language: CommandLanguage) -> Set<String> {
        switch language {
        case .english: ["question"]
        // "otázky" folds to "otazki" (#184 y → i).
        case .slovak, .czech: ["otazka", "otazku", "otazki"]
        case .ukrainian: ["питання", "запитання"]
        }
    }

    /// The English article joins into the question word, so "repeat the
    /// question" is a command plus the question word. Only "the": "this
    /// question" stays a content word, as Czech "tuhle otázku" always was.
    static func questionPhrases(for language: CommandLanguage) -> [(words: [String], token: String)] {
        switch language {
        case .english: [(["the", "question"], "question")]
        case .slovak, .czech, .ukrainian: []
        }
    }

    /// Commands about the question itself — the only ones the question word
    /// may accompany. "Štart otázka" or, on the answer sheet, "nie, otázka"
    /// stay inert: the sheet takes anything that is not a command as a new
    /// answer.
    static func takesQuestionWord(_ command: VoiceCommand) -> Bool {
        switch command {
        case .repeatQuestion, .skip, .next: true
        case .start, .ok, .again, .stop, .pause, .home: false
        }
    }

    // MARK: - Recognizer bias list

    /// The raw spoken vocabulary (real diacritics, no folding) handed to a
    /// recognizer that honors `AnalysisContext.contextualStrings` (#120 —
    /// DictationTranscriber does, SpeechTranscriber ignores them), for an
    /// engine started before any screen is known. Every command form we
    /// accept on any screen, in its display spelling.
    static func contextualVocabulary(for language: CommandLanguage) -> [String] {
        unique(commandVocabulary(for: language) + buttonVocabulary(for: language))
    }

    /// The bias list for one screen: only the words that ARE a command there,
    /// as the matcher itself decides, so the list cannot drift from the
    /// grammar. On the question screen the words that abort a pending skip
    /// ride along (the undo window listens there).
    static func contextualVocabulary(for language: CommandLanguage, on screen: VoiceCommandScreen) -> [String] {
        let commands = contextualVocabulary(for: language).filter {
            VoiceCommandMatcher.match(transcript: $0, on: screen, isFinal: true, language: language) != nil
        }
        return unique(commands + (screen == .question ? skipCancelVocabulary(for: language) : []))
    }

    /// The dedicated cancel words of the skip undo window. The plain "no"
    /// words also abort it, but they are conversation, so they are not biased
    /// for on the question screen.
    private static func skipCancelVocabulary(for language: CommandLanguage) -> [String] {
        switch language {
        case .english: ["stop", "cancel"]
        case .slovak, .czech: ["stop", "zruš"]
        case .ukrainian: ["стоп", "скасуй"]
        }
    }

    private static func commandVocabulary(for language: CommandLanguage) -> [String] {
        switch language {
        case .english:
            [
                "start", "ok", "okay", "confirm", "yes", "yeah", "next", "again", "retry", "no", "wrong",
                "one more time", "once more", "try again", "repeat", "skip", "pass", "stop", "wait", "cancel", "pause",
                "home", "next question", "skip question",
            ]
        case .slovak:
            [
                "štart", "ok", "okej", "potvrď", "áno", "hej", "ďalej", "pokračuj",
                "znova", "znovu", "nie", "zle", "ešte raz", "zopakuj", "opakuj", "ďalšia", "preskoč", "vynechaj",
                "stop", "počkaj", "zruš", "pauza", "domov", "zopakuj otázku", "ďalšia otázka",
            ]
        case .czech:
            [
                "start", "ok", "okej", "potvrď", "ano", "jo", "dál", "dále", "pokračuj",
                "znovu", "znova", "ne", "špatně", "ještě jednou", "zopakuj", "opakuj", "další", "přeskoč", "vynech",
                "stop", "počkej", "zruš", "pauza", "domů", "zopakuj otázku", "další otázka",
            ]
        case .ukrainian:
            [
                "старт", "ок", "окей", "підтверди", "так", "добре", "далі", "продовжуй",
                "ще раз", "знову", "ні", "неправильно", "повтори", "пропусти", "наступне",
                "стоп", "зачекай", "почекай", "скасуй", "пауза", "додому", "повтори питання", "наступне питання",
            ]
        }
    }

    private static func unique(_ words: [String]) -> [String] {
        var seen = Set<String>()
        return words.filter { seen.insert($0).inserted }
    }
}
