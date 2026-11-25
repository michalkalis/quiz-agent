//
//  VoiceCommandLexicon+Buttons.swift
//  Hangs
//
//  Founder 2026-10-13: whatever a button on a listening screen says must also
//  work as a voice command, even when the hint does not advertise the word.
//  #174 made most button titles the command words; the ones that differ (the
//  empty-answer sheet's "Ďalej", the error and set-end screens' "Skús znova" /
//  "Hraj znova") are added here. Screen-scoped, so a button word on one screen
//  never fires a command on another — except the retry titles, which mean
//  "znova" everywhere "znova" is a command. Founder 2026-11-22: only buttons
//  that do what one of the four commands does are words (Answer, Next, Again);
//  "Na úvod" / "Home" are buttons only now. #243 decision 5 (2026-11-24) made
//  "home" a command at the round end, so there the Home button's "Úvod" is a
//  word again. #248 (2026-11-25): the round end's "Ďalší kvíz" button and
//  its spoken „ďalší“ start the next quiz (`roundEndNextVariants`). Every
//  entry exists in sk / cs / en / uk (`VoiceCommandButtonWordTests`).
//

import Foundation

extension VoiceCommandLexicon {
    /// Normalized button titles that act as `command` on `screen` only. The
    /// two-word titles arrive as one token (`phrases(for:)`).
    static func buttonVariants(
        for command: VoiceCommand,
        language: CommandLanguage,
        on screen: VoiceCommandScreen
    ) -> [String] {
        switch (screen, command, language) {
        // The empty-answer sheet's Next button reads "Ďalej" / "Dál" / "Далі".
        // There only: on the question screen "ďalej?" / "dál" ("he gave") are
        // conversation, and a skip there has no undo.
        case (.noAnswer, .next, .slovak): return ["dalej"]
        case (.noAnswer, .next, .czech): return ["dal", "dale"]
        case (.noAnswer, .next, .ukrainian): return ["далі"]
        // The round end's Home button reads "Úvod" in sk / cs; en "Home" and
        // uk "Додому" are the command words themselves.
        case (.setEnd, .home, .slovak), (.setEnd, .home, .czech): return ["uvod"]
        default: return []
        }
    }

    /// #248 (founder 2026-11-25): "next" at the round end starts the next
    /// quiz. Said as „ďalší“ / „další“ / "next" / «далі», plus the founder's
    /// „ďalšia“, „ďalej“ / „dál“, and the "Next quiz" button title (one token,
    /// `buttonPhrases`); never required as the two words. Not the question's
    /// skip synonyms ("preskoč", "skip", «пропусти»): a skip word starting a
    /// whole new quiz would surprise.
    static func roundEndNextVariants(for language: CommandLanguage) -> [String] {
        switch language {
        case .english: ["next", "nextquiz"]
        case .slovak: ["dalsi", "dalsia", "dalej", "dalsikviz"]
        case .czech: ["dalsi", "dal", "dale", "dalsikviz"]
        case .ukrainian: ["далі", "наступна", "наступний", "наступне", "наступнавікторина"]
        }
    }

    /// Multi-word button titles, joined like `phrases(for:)` joins the sheet's.
    /// "Try Again" / "Play Again" join into `.again` words valid wherever
    /// "znova" is, so the join never costs another screen its "znova".
    static func buttonPhrases(for language: CommandLanguage) -> [(words: [String], token: String)] {
        switch language {
        case .english:
            return [(["play", "again"], "playagain"), (["next", "quiz"], "nextquiz")]
        case .slovak:
            return [(["skus", "znova"], "skusznova"), (["hraj", "znova"], "hrajznova"), (["dalsi", "kviz"], "dalsikviz")]
        case .czech:
            return [(["zkus", "znovu"], "zkusznovu"), (["hraj", "znovu"], "hrajznovu"), (["dalsi", "kviz"], "dalsikviz")]
        case .ukrainian:
            return [
                (["спробуй", "ще", "раз"], "спробуйщераз"), (["зіграй", "ще", "раз"], "зіграйщераз"),
                (["наступна", "вікторина"], "наступнавікторина"),
            ]
        }
    }

    /// The button titles in display spelling, for the recognizer's bias list.
    static func buttonVocabulary(for language: CommandLanguage) -> [String] {
        switch language {
        case .english: return ["try again", "play again", "next quiz"]
        case .slovak: return ["ďalej", "skús znova", "hraj znova", "úvod", "ďalší kvíz"]
        case .czech: return ["dál", "dále", "zkus znovu", "hraj znovu", "úvod", "další kvíz"]
        case .ukrainian: return ["далі", "спробуй ще раз", "зіграй ще раз", "наступна вікторина"]
        }
    }
}
