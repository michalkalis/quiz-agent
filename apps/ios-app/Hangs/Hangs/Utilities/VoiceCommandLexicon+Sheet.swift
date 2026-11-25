//
//  VoiceCommandLexicon+Sheet.swift
//  Hangs
//
//  #185 (car test 2026-09-23, founder decision 5.3 of 2026-09-24): the answer
//  confirmation sheet is answered the way people answer a question — "nie,
//  znova", "ešte raz" — so the two-word phrases arrive as one token, and the
//  words that usually START a longer sentence may only act once the
//  recognizer has finished the sentence. (Its confirm words "áno" / "hej"
//  went with the confirm command, founder 2026-11-22.)
//  Every table here has an entry for every quiz language
//  (`VoiceCommandLexiconParityTests`).
//

import Foundation

extension VoiceCommandLexicon {
    /// The variants the matcher scores on `screen`: the command's own words
    /// plus that screen's button words, minus the sheet words that mean
    /// nothing on the quiz-end screens.
    static func variants(
        for command: VoiceCommand,
        language: CommandLanguage,
        on screen: VoiceCommandScreen
    ) -> [String] {
        // #248: at the round end "next" means the next quiz, with words of its own.
        if screen == .setEnd, command == .next { return roundEndNextVariants(for: language) }
        let base = variants(for: command, language: language)
        let buttons = buttonVariants(for: command, language: language, on: screen)
        switch screen {
        case .error, .setEnd:
            let excluded = quizEndExcludedVariants(for: language)
            return base.filter { !excluded.contains($0) } + buttons
        default:
            return base + buttons
        }
    }

    /// #188 G1/G3: words the error and set-end screens do NOT take. On the
    /// sheet "nie" / "zle" answer the read-back; on a screen that retries or
    /// restarts the whole quiz, a passenger's "nie" must not start a new set.
    /// "znova" / "ešte raz" stay.
    static func quizEndExcludedVariants(for language: CommandLanguage) -> Set<String> {
        finalOnlyVariants(for: language)
    }

    /// Variants that may only act on a FINAL result. They open ordinary
    /// sentences ("nie, to bol Paríž", "no, I think…"), so a volatile "nie" is
    /// usually the leading edge of a new answer rather than a finished command;
    /// the final tells the two apart (a sentence has more than one content
    /// word). "znova" / "ešte raz" do not start sentences and keep the fast
    /// volatile path (#185 track D: "znova" failed on the old final-only wait).
    static func finalOnlyVariants(for language: CommandLanguage) -> Set<String> {
        switch language {
        case .english: return ["no", "wrong"]
        case .slovak: return ["nie", "zle"]
        case .czech: return ["ne", "spatne"]
        case .ukrainian: return ["ні", "неправильно"]
        }
    }

    /// #231 (PR #862 review): words that count only when heard EXACTLY — never
    /// by edit distance or as a cut-off. The Ukrainian conversational words sit
    /// one letter from ordinary answers: «правильно» ("right") and «неправда»
    /// (a true/false answer) from «неправильно». sk / cs / en keep their
    /// field-tuned fuzzy match.
    static func exactOnlyVariants(for language: CommandLanguage) -> Set<String> {
        switch language {
        case .english, .slovak, .czech: return []
        case .ukrainian: return finalOnlyVariants(for: language)
        }
    }

    /// Multi-word commands, as normalized token runs, and the single token they
    /// are joined into before matching (`VoiceCommandMatcher.normalize`). The
    /// matcher counts content WORDS, so without the join "ešte raz" would be two
    /// words — and "ešte" alone is filler.
    static func phrases(for language: CommandLanguage) -> [(words: [String], token: String)] {
        switch language {
        case .english:
            return [
                (["one", "more", "time"], "onemoretime"),
                (["once", "more"], "oncemore"),
                (["try", "again"], "tryagain"),
            ]
        case .slovak:
            return [(["este", "raz"], "esteraz")]
        case .czech:
            return [(["jeste", "jednou"], "jestejednou")]
        case .ukrainian:
            return [(["ще", "раз"], "щераз")]
        }
    }

    /// Filler on `screen`: the language's filler minus every word that is a
    /// command there — never both on one screen.
    static func fillerWords(
        for language: CommandLanguage,
        on screen: VoiceCommandScreen
    ) -> Set<String> {
        let commandWords = commands(on: screen).flatMap { variants(for: $0, language: language, on: screen) }
        return fillerWords(for: language).subtracting(commandWords)
    }
}
