//
//  VoiceCommandLexicon+Buttons.swift
//  Hangs
//
//  Founder 2026-10-13: whatever a button on a listening screen says must also
//  work as a voice command, even when the hint does not advertise the word.
//  #174 made most button titles the command words; the ones that drifted
//  since (the #194 redesign's "Odpovedz", the error and set-end screens'
//  "Skús znova" / "Hraj znova" / "Na úvod") are added here. Screen-scoped, so
//  a button word on one screen never fires a command on another — except the
//  retry titles, which mean "znova" everywhere "znova" is a command. Every entry
//  exists in sk / cs / en (`VoiceCommandButtonWordTests`).
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
        // The question screen's primary button reads "Answer" — it starts the
        // answer recording, exactly like "štart".
        case (.question, .start, .english): return ["answer"]
        case (.question, .start, .slovak): return ["odpovedz"]
        case (.question, .start, .czech): return ["odpovez"]
        // The error screen's "Go Home" / "Dismiss" both leave for Home — the
        // route its "stop" already takes.
        case (.error, .stop, .english): return ["gohome", "dismiss"]
        case (.error, .stop, .slovak): return ["nauvod", "uvod", "zavri"]
        case (.error, .stop, .czech): return ["nauvod", "uvod", "zavri"]
        // The set-end "Home" button reads "Úvod" in sk / cs.
        case (.setEnd, .home, .english): return ["gohome"]
        case (.setEnd, .home, .slovak), (.setEnd, .home, .czech): return ["uvod", "nauvod"]
        default: return []
        }
    }

    /// Multi-word button titles, joined like `phrases(for:)` joins the sheet's.
    /// "Try Again" / "Play Again" join into `.again` words valid wherever
    /// "znova" is, so the join never costs another screen its "znova".
    static func buttonPhrases(for language: CommandLanguage) -> [(words: [String], token: String)] {
        switch language {
        case .english:
            return [(["play", "again"], "playagain"), (["go", "home"], "gohome")]
        case .slovak:
            return [(["skus", "znova"], "skusznova"), (["hraj", "znova"], "hrajznova"), (["na", "uvod"], "nauvod")]
        case .czech:
            return [(["zkus", "znovu"], "zkusznovu"), (["hraj", "znovu"], "hrajznovu"), (["na", "uvod"], "nauvod")]
        }
    }

    /// The button titles in display spelling, for the recognizer's bias list.
    static func buttonVocabulary(for language: CommandLanguage) -> [String] {
        switch language {
        case .english: return ["answer", "try again", "play again", "go home", "home", "dismiss"]
        case .slovak: return ["odpovedz", "skús znova", "hraj znova", "na úvod", "úvod", "zavri"]
        case .czech: return ["odpověz", "zkus znovu", "hraj znovu", "na úvod", "úvod", "zavři"]
        }
    }
}
