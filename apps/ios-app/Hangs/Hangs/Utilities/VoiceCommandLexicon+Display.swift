//
//  VoiceCommandLexicon+Display.swift
//  Hangs
//
//  The driver-facing strings of the command grammar — spoken words, hints and
//  the listening caption — split out of VoiceCommandLexicon.swift when #175
//  (Czech) pushed the file past its size budget. Rendered in the COMMAND
//  language (#120), never the app locale, so none of this lives in
//  Localizable.xcstrings. #174: hints quote the exact button words.
//

import Foundation

extension VoiceCommandLexicon {
    /// Canonical spoken spelling of a command, for display (diagnostics + the
    /// listening indicator). NOT the matcher input — matching uses `variants`.
    /// Slovak forms carry their real diacritics (display, not matching).
    static func spokenWord(
        _ command: VoiceCommand,
        language: CommandLanguage = .english
    ) -> String {
        switch (language, command) {
        case (.english, .answer): return "answer"
        case (.english, .next): return "next"
        case (.english, .repeatQuestion): return "repeat"
        case (.english, .again): return "again"
        case (.slovak, .answer): return "odpovedz"
        case (.slovak, .next): return "ďalšia"
        case (.slovak, .repeatQuestion): return "zopakuj"
        case (.slovak, .again): return "znova"
        case (.czech, .answer): return "odpověz"
        case (.czech, .next): return "další"
        case (.czech, .repeatQuestion): return "zopakuj"
        case (.czech, .again): return "znovu"
        case (.ukrainian, .answer): return "відповідай"
        case (.ukrainian, .next): return "пропусти"
        case (.ukrainian, .repeatQuestion): return "повтори"
        case (.ukrainian, .again): return "ще раз"
        }
    }

    /// Curated hint for the on-screen "LISTENING FOR COMMANDS" indicator (77.12,
    /// pen `s49sd`). A concise, driver-facing subset of each screen's routable
    /// commands. #105: the question screen must advertise the answer word — it
    /// is what begins answer recording. Rendered in the COMMAND language (#120), which
    /// is independent of the app/quiz language.
    static func hint(
        on screen: VoiceCommandScreen,
        language: CommandLanguage = .english
    ) -> String {
        switch (language, screen) {
        // Founder 2026-11-22: the Answer button's word, not "start".
        case (.english, .question): return #"Say "answer" or "next""#
        // #189 founder feedback (2026-09-29): quote the word, then name the
        // fallback (a new answer covers anything else spoken on the sheet,
        // per #185 5.1 D1 2026-09-25). Silence confirms (founder 2026-11-22).
        case (.english, .confirmation): return #"Say "again" or a new answer"#
        // #185: the no-answer sheet's buttons are Again / Next.
        case (.english, .noAnswer): return #"Say "again" or "next""#
        case (.english, .error), (.english, .setEnd): return #"Say "again""#
        case (.slovak, .question): return "Povedz „odpovedz“ alebo „ďalšia“"
        case (.slovak, .confirmation): return "Povedz „znova“ alebo novú odpoveď"
        case (.slovak, .noAnswer): return "Povedz „znova“ alebo „ďalšia“"
        case (.slovak, .error), (.slovak, .setEnd): return "Povedz „znova“"
        case (.czech, .question): return "Řekni „odpověz“ nebo „další“"
        case (.czech, .confirmation): return "Řekni „znovu“ nebo novou odpověď"
        case (.czech, .noAnswer): return "Řekni „znovu“ nebo „další“"
        case (.czech, .error), (.czech, .setEnd): return "Řekni „znovu“"
        case (.ukrainian, .question): return "Скажи «відповідай» або «пропусти»"
        case (.ukrainian, .confirmation): return "Скажи «ще раз» або нову відповідь"
        case (.ukrainian, .noAnswer): return "Скажи «ще раз» або «пропусти»"
        case (.ukrainian, .error), (.ukrainian, .setEnd): return "Скажи «ще раз»"
        }
    }

    /// #179 D1: the same words as `hint(on:language:)` promises, but as separate
    /// quoted chips — the question screen renders them in a row under the bar's
    /// caption instead of in one sentence. Takes the commands explicitly rather
    /// than a screen, because the question screen shows a DIFFERENT subset per
    /// bar state (no "answer" while the question is still being read — saying
    /// it there would cut the read off mid-sentence).
    ///
    /// Quoting follows the language's own convention, exactly as the sentence
    /// form does, so the two never look like two different features.
    static func spokenChips(
        _ commands: [VoiceCommand],
        language: CommandLanguage = .english
    ) -> [String] {
        commands.map { command in
            let word = spokenWord(command, language: language)
            switch language {
            case .english: return "\u{201C}\(word)\u{201D}"
            case .slovak, .czech: return "\u{201E}\(word)\u{201C}"
            case .ukrainian: return "\u{00AB}\(word)\u{00BB}"
            }
        }
    }

    /// Caption for the on-screen listening indicator, in the COMMAND language
    /// (#120 rule — same as `hint(on:language:)`; #122 closes the gap for the
    /// caption itself, which was hardcoded English). Deliberately NOT in
    /// Localizable.xcstrings: it must track the command-engine language, not
    /// the app locale.
    /// `short` is the slim-bar form (#131 Track F): a 40pt one-row bar cannot
    /// carry the full sentence AND the words to say, and the words matter more.
    static func listeningCaption(
        language: CommandLanguage = .english,
        short: Bool = false
    ) -> String {
        switch (language, short) {
        case (.english, false): return "LISTENING FOR COMMANDS"
        case (.english, true): return "LISTENING"
        case (.slovak, false): return "POČÚVAM PRÍKAZY"
        case (.slovak, true): return "POČÚVAM"
        case (.czech, false): return "POSLOUCHÁM PŘÍKAZY"
        case (.czech, true): return "POSLOUCHÁM"
        case (.ukrainian, false): return "СЛУХАЮ КОМАНДИ"
        case (.ukrainian, true): return "СЛУХАЮ"
        }
    }

    /// #189 (founder feedback 2026-09-29): caption for the sheet's listening
    /// indicator while the answer read-back plays or the listener has not yet
    /// come back up afterwards — same COMMAND-language rule as
    /// `listeningCaption`, and the same pre-uppercased convention (the caller
    /// applies `.textCase(.uppercase)` on top, as it does for that caption).
    static func readingBackCaption(language: CommandLanguage = .english) -> String {
        switch language {
        case .english: return "READING BACK"
        case .slovak: return "ČÍTAM ODPOVEĎ"
        case .czech: return "ČTU ODPOVĚĎ"
        case .ukrainian: return "ЧИТАЮ ВІДПОВІДЬ"
        }
    }

    /// #208.7 (founder, TF 2026-10-16: "it should show it hears me, then that
    /// it's processing"): the bar's caption while the driver is speaking —
    /// command language, verbatim, like `listeningCaption`.
    static func hearingCaption(language: CommandLanguage = .english) -> String {
        switch language {
        case .english: return "Hearing you…"
        case .slovak: return "Počujem…"
        case .czech: return "Slyším…"
        case .ukrainian: return "Чую…"
        }
    }

    /// #208.7: the caption once the driver stopped and nothing is decided yet
    /// (the recognizer runs ~1 s behind the voice).
    static func processingCaption(language: CommandLanguage = .english) -> String {
        switch language {
        case .english: return "Processing…"
        case .slovak: return "Spracúvam…"
        case .czech: return "Zpracovávám…"
        case .ukrainian: return "Обробляю…"
        }
    }

    /// #122 follow-up (TF 2026-10-07, founder: no feedback that the app heard a
    /// command): the listen bar's caption while a matched command waits to fire
    /// — the recognized word, quoted and trailed by an ellipsis, in the COMMAND
    /// language (same quote style as `hint`). Verbatim, never localized.
    static func recognizingCaption(
        _ command: VoiceCommand,
        language: CommandLanguage = .english
    ) -> String {
        let word = spokenWord(command, language: language)
        switch language {
        case .english: return "\"\(word)\"…"
        case .slovak, .czech: return "„\(word)“…"
        case .ukrainian: return "«\(word)»…"
        }
    }
}
