//
//  VoiceCommandLexicon+Sheet.swift
//  Hangs
//
//  #185 (car test 2026-09-23, founder decision 5.3 of 2026-09-24): the answer
//  confirmation sheet is answered the way people answer a question — "áno",
//  "nie, znova", "ešte raz" — so the sheet gets words no other screen has, the
//  two-word phrases arrive as one token, and the words that usually START a
//  longer sentence may only act once the recognizer has finished the sentence.
//  Every table here has an entry for all three quiz languages
//  (`VoiceCommandLexiconParityTests`).
//

import Foundation

extension VoiceCommandLexicon {
    /// Words that are a command ONLY on the answer confirmation sheet. Anywhere
    /// else they stay filler: "áno" / "hej" / "jo" / "yeah" are what passenger
    /// conversation is made of (#120), and on the result screen an "áno" would
    /// skip the explanation.
    static func confirmationOnlyVariants(
        for command: VoiceCommand,
        language: CommandLanguage
    ) -> [String] {
        switch (language, command) {
        case (.english, .ok): return ["yes", "yeah"]
        case (.slovak, .ok): return ["ano", "hej"]
        case (.czech, .ok): return ["ano", "jo"]
        default: return []
        }
    }

    /// The variants the matcher scores on `screen`: the command's own words,
    /// plus the confirmation-only ones on the sheet.
    static func variants(
        for command: VoiceCommand,
        language: CommandLanguage,
        on screen: VoiceCommandScreen
    ) -> [String] {
        let base = variants(for: command, language: language)
        guard screen == .confirmation else { return base }
        return base + confirmationOnlyVariants(for: command, language: language)
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
        }
    }

    /// Filler on `screen`: the language's filler minus every word that is a
    /// command there. "áno" is filler on the result screen and a confirm on the
    /// sheet — never both on one screen.
    static func fillerWords(
        for language: CommandLanguage,
        on screen: VoiceCommandScreen
    ) -> Set<String> {
        let commandWords = commands(on: screen).flatMap { variants(for: $0, language: language, on: screen) }
        return fillerWords(for: language).subtracting(commandWords)
    }
}
