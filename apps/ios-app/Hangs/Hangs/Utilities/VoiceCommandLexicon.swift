//
//  VoiceCommandLexicon.swift
//  Hangs
//
//  Issue #77 (voice commands hands-free), task 77.3 — the constant sibling of
//  MCQTranscriptMatcher's lookup tables. #120 made the word-set LANGUAGE-SCOPED:
//  the command grammar now exists in English (default, #77 P2) and Slovak
//  (founder-approved 2026-07-26, only reachable on the DictationTranscriber
//  engine — SpeechTranscriber has no sk_SK). Every lookup takes a
//  `CommandLanguage`; the app passes the quiz language explicitly (#175 —
//  `VoiceCommandCoordinator.commandLanguage`), the `.english` default is the
//  pre-#120 pin that tests rely on.
//
//  THE SLOVAK SET RANKS PRECISION ABOVE RECALL. In English mode the command
//  vocabulary is disjoint from what the car actually hears (the founder speaks
//  Slovak to passengers); in Slovak mode it is NOT — the mic is open to the
//  language being spoken. So Slovak phrases are chosen for disjointness from
//  ordinary conversation: multi-syllable imperatives over particles, and the
//  high-frequency backchannels ("áno", "dobre", "hej", "jasné", "no") are
//  deliberately FILLER — neutralized, never commands. Known residual hazards
//  are flagged inline; the founder owns the final wording (#120).
//
//  #175 added Czech on the same design (mic open to the spoken language →
//  precision over recall, backchannels are filler). #174 made the on-screen
//  buttons carry the command words in the imperative (Štart / Preskoč /
//  Potvrď / Znova / Zruš / Ďalej / Pauza), so the hints below and the button
//  labels in Localizable.xcstrings must stay word-for-word aligned.
//
//  #185 (car test 2026-09-23, founder 5.3 — 2026-09-24) moved ONE screen off
//  that trade: on the answer confirmation sheet "áno / hej" (cs "ano / jo",
//  en "yes / yeah") confirm and "nie / zle / ešte raz" re-record, because the
//  driver answers the sheet the way people answer a question. They stay filler
//  everywhere else (`VoiceCommandLexicon+Sheet.swift`). Every lexicon change
//  lands in sk / cs / en / uk at once (`VoiceCommandLexiconParityTests`).
//
//  #231 added Ukrainian on the same design. Its words are the ones Apple
//  dictation (uk_UA) recognised on the Mac (2026-11-17): старт, далі, повтори,
//  пропусти, ще раз, добре, стоп, пауза, додому. The buttons carry the same
//  words (Пропусти, Ще раз). Stored unfolded: Cyrillic is never diacritic-folded.
//
//  Founder 2026-11-22: four commands remain (next, repeat, answer, again).
//  The confirm words of #185 ("áno", "potvrď", "ok") are filler again
//  everywhere: silence confirms an answer.
//
//  #243 decision 5 (founder 2026-11-24): the round end asks "Znova, alebo
//  domov?", so "home" is back as a fifth command, on that screen only.
//

import Foundation

/// The small hands-free command grammar. Screen-scoped by `VoiceCommandScreen`.
/// Founder 2026-11-22: four commands, in the quiz language. Confirm, stop and
/// pause are gone: silence confirms an answer, the toolbar pauses. #243
/// decision 5 (2026-11-24) added "home", heard at the round end only. How
/// readily each one fires: `VoiceCommandSensitivity.swift`.
enum VoiceCommand: String, Sendable, CaseIterable, Equatable {
    /// Opens the answer recording early. Was "start" until 2026-11-22; it is
    /// the Answer button's word now, because "start" was not intuitive.
    case answer
    /// Skips the question (on the empty-answer sheet: moves on). Strict.
    case next
    case repeatQuestion // "repeat" — replay the question audio
    case again // re-record / retry / play again
    /// #243 decision 5: leave the round end for Home, like its Home button.
    /// The round end only (`commands(on:)`); retired everywhere else 2026-11-22.
    case home
}

/// The screen a command is heard on. Command routing is screen-scoped so an
/// utterance is only matched against that screen's 1–3 valid commands, never the
/// whole grammar — this is the confusion mitigation for the tiny accented vocab.
enum VoiceCommandScreen: Sendable, Equatable {
    case question // askingQuestion, after TTS
    case confirmation // processing — the answer-confirmation sheet
    /// #185 track B: the same sheet after a second empty recording — Again /
    /// Next (#243.4: and Repeat question), no countdown.
    case noAnswer
    /// #188 G1 (founder 2026-10-06): the error screen — "znova" retries, so a
    /// failure does not need a tap.
    case error
    /// #188 G3, #243 decision 5: every round end (score, recap, daily
    /// challenge) — "znova" plays again, "domov" goes Home.
    case setEnd
    /// #243.8: a result set to wait for "next", once its verdict has ended.
    case result
}

enum VoiceCommandLexicon {
    /// Commands that may be spoken on a given screen. Anything else on that
    /// screen resolves to `nil` (screen scoping). Home and the result
    /// screen have no command window at all (#224: the buttons are enough),
    /// except a result set to wait for "next" (#243.8).
    /// Language-independent — the grammar's SHAPE is fixed, only its words vary.
    static func commands(on screen: VoiceCommandScreen) -> [VoiceCommand] {
        switch screen {
        case .question: [.answer, .repeatQuestion, .next]
        // Founder 2026-11-22: silence confirms; "again" is the one word the
        // sheet acts on (#243.5: anything else said is ignored).
        case .confirmation: [.again]
        // The sheet's buttons, Repeat question / Again / Next (#243.4). No
        // confirm: confirming an empty field IS a skip.
        case .noAnswer: [.repeatQuestion, .again, .next]
        case .error: [.again]
        // #243 decision 5: the line asks "Znova, alebo domov?" in this order.
        case .setEnd: [.again, .home]
        case .result: [.next]
        }
    }

    /// Variant spellings per command (already normalized: lower, diacritic-folded,
    /// alphanumeric — "preskoč" is stored as "preskoc" because
    /// `VoiceCommandMatcher.normalize` folds the transcript the same way). The
    /// matcher scores a token against the MAX similarity across a command's
    /// variants.
    ///
    /// #119 (English): dictionary forms only, no hand-written accent tables —
    /// the en-US transcriber renders real command words perfectly, and a
    /// genuine slip is covered by the command's own floor.
    static func variants(
        for command: VoiceCommand,
        language: CommandLanguage = .english
    ) -> [String] {
        switch (language, command) {
        // Founder 2026-11-22: the Answer button's word and its close forms.
        case (.english, .answer): return ["answer"]
        // #224 (founder, TF 2026-11-02): the button reads "Next" — easier to
        // say than "skip"; the old words stay as hidden synonyms.
        case (.english, .next): return ["next", "skip", "pass"]
        case (.english, .repeatQuestion): return ["repeat"]
        // #185 5.3 (founder 2026-09-24): "no" / "wrong" / "one more time" ask
        // for the answer again. The two-word phrases arrive as ONE token
        // (`phrases(for:)`). "no" and "wrong" start sentences, so they act on a
        // final only (`finalOnlyVariants`).
        case (.english, .again): return ["again", "retry", "no", "wrong", "onemoretime", "oncemore", "tryagain", "playagain"]
        // #243 decision 5: the round end only.
        case (.english, .home): return ["home"]
        // „odpovedz“ (the button), „odpovedaj“, „odpoveď“.
        case (.slovak, .answer): return ["odpovedz", "odpovedaj", "odpoved"]
        // The question button reads "Ďalšia"; "preskoč" / "vynechaj" stay as
        // hidden synonyms. The empty-answer sheet's "Ďalej" is a button word
        // there only (`VoiceCommandLexicon+Buttons.swift`): "ďalej?" is
        // conversation on the question screen.
        case (.slovak, .next): return ["dalsia", "preskoc", "vynechaj"]
        case (.slovak, .repeatQuestion): return ["zopakuj", "opakuj"]
        // #185 5.3: "nie", "zle", "ešte raz", "znova" = record the answer again.
        // Founder 2026-10-13: the "Skús znova" / "Hraj znova" buttons.
        case (.slovak, .again): return ["znova", "znovu", "nie", "zle", "esteraz", "skusznova", "hrajznova"]
        case (.slovak, .home): return ["domov"]
        // Czech (#175): "odpověz" folds to "odpovez", "přeskoč" to "preskoc" —
        // the same folding the Slovak set relies on.
        case (.czech, .answer): return ["odpovez", "odpovidej", "odpoved"]
        case (.czech, .next): return ["dalsi", "preskoc", "vynech"]
        case (.czech, .repeatQuestion): return ["zopakuj", "opakuj"]
        case (.czech, .again): return ["znovu", "znova", "ne", "spatne", "jestejednou", "zkusznovu", "hrajznovu"]
        // „domů“ folds to "domu", so a recognizer writing „domu“ matches too.
        case (.czech, .home): return ["domu"]
        // Ukrainian (#231): «відповідай» (the button) and «відповідь».
        // Stored unfolded: Cyrillic is never diacritic-folded.
        case (.ukrainian, .answer): return ["відповідай", "відповідь"]
        // The button reads "Пропусти"; "наступне" (sk "ďalšia") stays a synonym.
        case (.ukrainian, .next): return ["пропусти", "наступне", "наступна", "наступний"]
        case (.ukrainian, .repeatQuestion): return ["повтори"]
        // "ще раз" (the button) and "знову" (a hidden synonym); "ні" and
        // "неправильно" act on a final only, like sk "nie" / "zle", and only
        // when heard exactly (`exactOnlyVariants`: «правильно», «неправда» are answers).
        case (.ukrainian, .again): return ["щераз", "знову", "ні", "неправильно", "спробуйщераз", "зіграйщераз"]
        case (.ukrainian, .home): return ["додому"]
        }
    }

    /// Filler words stripped before the STRICT whole-utterance skip check and
    /// tolerated as padding around a command token. English: deliberately
    /// conservative — only true discourse filler, NOT content words
    /// ("this"/"one"/"question") so that "let's skip THIS one" stays a
    /// multi-token utterance and is rejected as a skip (contains-but-isn't-skip).
    ///
    /// Slovak additionally NEUTRALIZES the high-frequency backchannels
    /// ("áno", "dobre", "hej", "jasné") — the words a passenger conversation is
    /// made of. As filler they can never fire a command (a backchannel-only
    /// utterance strips to zero content tokens) while still tolerating
    /// "dobre, preskoč" as padding. This is the precision-over-recall trade the
    /// Slovak set is built on. A word that IS a command on the screen in
    /// question is not filler there — see `fillerWords(for:on:)`.
    static func fillerWords(
        for language: CommandLanguage = .english
    ) -> Set<String> {
        switch language {
        case .english:
            return [
                "um", "uh", "uhm", "eh", "hmm", "hm", "er",
                "please", "just", "well", "so", "like", "yeah", "then",
                // Founder 2026-11-22: confirm is no command any more, and a
                // reflexive "ok" on the answer sheet must not become the answer.
                "ok", "okay", "okey",
            ]
        case .slovak:
            return [
                "um", "uh", "ehm", "eh", "hmm", "hm",
                "no", "tak", "takze", "teda", "proste", "prosim", "len", "este",
                "aha", "hej", "ano", "jasne", "dobre", "ok", "okej",
            ]
        case .czech:
            // "jo" is THE Czech backchannel ("yeah"); "ano"/"dobře"/"jasně" as
            // in Slovak. Neutralized so "jo" can never confirm an answer.
            return [
                "um", "uh", "ehm", "eh", "hmm", "hm",
                "no", "tak", "takze", "tedy", "teda", "proste", "prosim", "jen", "jeste",
                "aha", "jo", "ano", "jasne", "dobre", "ok", "okej",
            ]
        case .ukrainian:
            // "так" (yes) and "добре" (fine) are what conversation is made of.
            // "ну" is the Ukrainian "no" particle, never a "no".
            return [
                "um", "uh", "ем", "е", "хм", "м",
                "ну", "так", "отже", "тобто", "просто", "будь", "ласка", "лише", "тільки", "ще",
                "ага", "угу", "добре", "гаразд", "ясно", "звісно", "ок", "окей", "ok",
            ]
        }
    }
}
