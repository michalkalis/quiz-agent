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
        language: CommandLanguage = CommandEngineSelection.current.commandLanguage
    ) -> String {
        switch (language, command) {
        case (.english, .start): return "start"
        case (.english, .ok): return "ok"
        case (.english, .next): return "next"
        case (.english, .again): return "again"
        case (.english, .repeatQuestion): return "repeat"
        case (.english, .skip): return "skip"
        case (.english, .stop): return "stop"
        case (.english, .pause): return "pause"
        case (.slovak, .start): return "štart"
        case (.slovak, .ok): return "potvrď"
        case (.slovak, .next): return "ďalej"
        case (.slovak, .again): return "znova"
        case (.slovak, .repeatQuestion): return "zopakuj"
        case (.slovak, .skip): return "preskoč"
        // #174: the confirmation sheet's button reads "Zruš" — the spoken
        // word shown must be the button word (buttons ARE the hint).
        case (.slovak, .stop): return "zruš"
        case (.slovak, .pause): return "pauza"
        case (.czech, .start): return "start"
        case (.czech, .ok): return "potvrď"
        case (.czech, .next): return "dál"
        case (.czech, .again): return "znovu"
        case (.czech, .repeatQuestion): return "zopakuj"
        case (.czech, .skip): return "přeskoč"
        case (.czech, .stop): return "zruš"
        case (.czech, .pause): return "pauza"
        }
    }

    /// Curated hint for the on-screen "LISTENING FOR COMMANDS" indicator (77.12,
    /// pen `s49sd`). A concise, driver-facing subset of each screen's routable
    /// commands. #105: the question screen must advertise "start" — it is what
    /// begins answer recording. Rendered in the COMMAND language (#120), which
    /// is independent of the app/quiz language.
    static func hint(
        on screen: VoiceCommandScreen,
        language: CommandLanguage = CommandEngineSelection.current.commandLanguage
    ) -> String {
        switch (language, screen) {
        case (.english, .home): return #"Say "start""#
        case (.english, .question): return #"Say "start" or "skip""#
        case (.english, .confirmation): return #"Say "ok", "again" or "stop""#
        case (.english, .result): return #"Say "next""#
        case (.slovak, .home): return "Povedz „štart“"
        case (.slovak, .question): return "Povedz „štart“ alebo „preskoč“"
        case (.slovak, .confirmation): return "Povedz „potvrď“, „znova“ alebo „zruš“"
        case (.slovak, .result): return "Povedz „ďalej“"
        case (.czech, .home): return "Řekni „start“"
        case (.czech, .question): return "Řekni „start“ nebo „přeskoč“"
        case (.czech, .confirmation): return "Řekni „potvrď“, „znovu“ nebo „zruš“"
        case (.czech, .result): return "Řekni „dál“"
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
        language: CommandLanguage = CommandEngineSelection.current.commandLanguage,
        short: Bool = false
    ) -> String {
        switch (language, short) {
        case (.english, false): return "LISTENING FOR COMMANDS"
        case (.english, true): return "LISTENING"
        case (.slovak, false): return "POČÚVAM PRÍKAZY"
        case (.slovak, true): return "POČÚVAM"
        case (.czech, false): return "POSLOUCHÁM PŘÍKAZY"
        case (.czech, true): return "POSLOUCHÁM"
        }
    }
}
