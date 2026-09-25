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
//  lands in sk / cs / en at once (`VoiceCommandLexiconParityTests`).
//

import Foundation

/// The small hands-free command grammar. Screen-scoped by `VoiceCommandScreen`.
enum VoiceCommand: String, Sendable, CaseIterable, Equatable {
    case start
    case ok
    case next
    case again // re-record / retry on the confirmation sheet
    case repeatQuestion // "repeat" — replay the question audio
    case skip // destructive: strict whole-utterance match only
    case stop // cancel / undo word — resolves an open UndoWindow
    case pause // #171 Track D: freeze the confirmation sheet (hands-free pause)
}

/// The screen a command is heard on. Command routing is screen-scoped so an
/// utterance is only matched against that screen's 1–2 valid commands, never the
/// whole grammar — this is the confusion mitigation for the tiny accented vocab.
enum VoiceCommandScreen: Sendable, Equatable {
    case home // idle — pre-quiz
    case question // askingQuestion, after TTS
    case confirmation // processing — the answer-confirmation sheet
    /// #185 track B: the same sheet after a second empty recording — Again /
    /// Skip, no countdown. Its own screen so "potvrď" can never skip there.
    case noAnswer
    case result // showingResult
}

enum VoiceCommandLexicon {
    /// Commands that may be spoken on a given screen. Anything else on that
    /// screen resolves to `nil` (screen scoping). "ok" is valid on BOTH the
    /// confirmation sheet (→ confirm) and the result (→ advance); the differing
    /// action is the caller's job (Session 4), the matcher only returns `.ok`.
    /// Language-independent — the grammar's SHAPE is fixed, only its words vary.
    static func commands(on screen: VoiceCommandScreen) -> [VoiceCommand] {
        switch screen {
        case .home: return [.start]
        case .question: return [.start, .repeatQuestion, .skip]
        // #171 Track D: `.pause` is confirmation-only by founder decision —
        // the sheet is the universal "after answer" point, so it is the one
        // place a pause cannot lose an in-flight question or recording.
        case .confirmation: return [.ok, .again, .stop, .pause]
        // #185 (founder 2026-09-24): "znova" retries, "preskoč" / "ďalej"
        // skip. No `.ok` — confirming an empty field IS a skip, and the old
        // sheet let a "potvrď" do that.
        case .noAnswer: return [.again, .skip, .next]
        case .result: return [.next, .ok]
        }
    }

    /// Variant spellings per command (already normalized: lower, diacritic-folded,
    /// alphanumeric — "preskoč" is stored as "preskoc" because
    /// `VoiceCommandMatcher.normalize` folds the transcript the same way). The
    /// matcher scores a token against the MIN edit distance across a command's
    /// variants.
    ///
    /// #119 (English): the hand-written ACCENT table is gone — field data showed
    /// the en-US transcriber renders real command words perfectly, so speculative
    /// spellings bought zero recall while being pure false-fire surface. A
    /// genuine one-edit slip is still covered by the edit-distance floor. The
    /// Slovak set inherits that lesson: dictionary forms only, no phonetics.
    static func variants(
        for command: VoiceCommand,
        language: CommandLanguage = .english
    ) -> [String] {
        switch (language, command) {
        case (.english, .start): return ["start"]
        // #174: the button reads "Confirm" (buttons ARE the voice hints now), so
        // the word on the button must be a word the matcher accepts.
        case (.english, .ok): return ["ok", "okay", "okey", "oukej", "confirm"]
        case (.english, .next): return ["next"]
        // #185 5.3 (founder 2026-09-24): "no" / "wrong" / "one more time" ask
        // for the answer again. The two-word phrases arrive as ONE token
        // (`phrases(for:)`). "no" and "wrong" start sentences, so they act on a
        // final only (`finalOnlyVariants`).
        case (.english, .again): return ["again", "retry", "no", "wrong", "onemoretime", "oncemore", "tryagain"]
        case (.english, .repeatQuestion): return ["repeat"]
        case (.english, .skip): return ["skip", "pass"]
        // #185 5.3: "stop" only HOLDS the auto-confirm countdown — the voice
        // cancel of an answer ("cancel"/"zruš") is gone by founder decision.
        // "cancel" still aborts a pending skip (`undoCancelVariants`).
        case (.english, .stop): return ["stop", "wait"]
        case (.english, .pause): return ["pause"]
        // "štart" folds to "start" — the command is IDENTICAL across languages,
        // which also keeps founder muscle memory intact.
        case (.slovak, .start): return ["start"]
        // ⚠️ FLAGGED HAZARD (#120): "ok"/"okej" occur in normal Slovak
        // conversation. Kept because (a) on the confirmation sheet `.ok` is
        // final-only + one-content-token capped, (b) on the result screen the
        // action is benign (advance = the default outcome anyway), and
        // (c) dropping the founder's habitual "ok" would cost real recall.
        // "potvrď" is the recommended disjoint form. "áno"/"hej" confirm on
        // the sheet only (#185, `confirmationOnlyVariants`); elsewhere they
        // are filler, like "dobre".
        case (.slovak, .ok): return ["ok", "okej", "oukej", "potvrd"]
        // ⚠️ FLAGGED HAZARD (#120): a lone conversational "ďalej?" ("go on")
        // can fire `.next` — accepted because it is result-screen-only and
        // benign (auto-advance was coming anyway).
        case (.slovak, .next): return ["dalej", "pokracuj"]
        // #185 5.3: "nie", "zle", "ešte raz", "znova" = record the answer again.
        case (.slovak, .again): return ["znova", "znovu", "nie", "zle", "esteraz"]
        case (.slovak, .repeatQuestion): return ["zopakuj", "opakuj"]
        case (.slovak, .skip): return ["preskoc", "vynechaj"]
        // ⚠️ FLAGGED (minor): "stoj" scores 0.75 vs "stop" — above the final
        // floor. Harmless since #185: `.stop` only holds the countdown.
        case (.slovak, .stop): return ["stop", "pockaj"]
        // "pauza" is the same word in Slovak and Czech, and it is not a
        // discourse particle in either — a rare, multi-syllable noun, which
        // is exactly the disjointness the Slovak set is chosen for.
        case (.slovak, .pause): return ["pauza"]
        // Czech (#175): "přeskoč" folds to "preskoc", "potvrď" to "potvrd",
        // "dál"/"dále" to "dal"/"dale" — the same folding the Slovak set relies
        // on, so the edit-distance floors behave identically.
        case (.czech, .start): return ["start"]
        // Same hazard as Slovak "ok" (conversational) — same bounded exposure.
        case (.czech, .ok): return ["ok", "okej", "oukej", "potvrd"]
        // ⚠️ FLAGGED HAZARD (#175): "dal" is also the Czech past tense of "dát"
        // ("he gave"), a frequent conversational word. Accepted for the same
        // reason as Slovak "ďalej": result-screen-only and benign (advance was
        // coming anyway). "dále" is the formal form, "dál" the spoken one.
        case (.czech, .next): return ["dal", "dale", "pokracuj"]
        case (.czech, .again): return ["znovu", "znova", "ne", "spatne", "jestejednou"]
        case (.czech, .repeatQuestion): return ["zopakuj", "opakuj"]
        case (.czech, .skip): return ["preskoc", "vynech"]
        case (.czech, .stop): return ["stop", "pockej"]
        case (.czech, .pause): return ["pauza"]
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
    /// Slovak set is built on. #185: a word that IS a command on the screen in
    /// question ("áno" on the confirmation sheet) is not filler there — see
    /// `fillerWords(for:on:)`.
    static func fillerWords(
        for language: CommandLanguage = .english
    ) -> Set<String> {
        switch language {
        case .english:
            return [
                "um", "uh", "uhm", "eh", "hmm", "hm", "er",
                "please", "just", "well", "so", "like", "yeah", "then",
            ]
        case .slovak:
            return [
                "um", "uh", "ehm", "eh", "hmm", "hm",
                "no", "tak", "takze", "teda", "proste", "prosim", "len", "este",
                "aha", "hej", "ano", "jasne", "dobre",
            ]
        case .czech:
            // "jo" is THE Czech backchannel ("yeah"); "ano"/"dobře"/"jasně" as
            // in Slovak. Neutralized so "jo" can never confirm an answer.
            return [
                "um", "uh", "ehm", "eh", "hmm", "hm",
                "no", "tak", "takze", "tedy", "teda", "proste", "prosim", "jen", "jeste",
                "aha", "jo", "ano", "jasne", "dobre",
            ]
        }
    }

    /// The cancel/undo words that abort an open `UndoWindow` (spoken form of a tap).
    static let cancelWords: [VoiceCommand] = [.stop]

    /// Words accepted ONLY on the loose undo-abort path: every `.stop` variant
    /// PLUS the plain no-words ("no"/"know"; Slovak adds "nie") and the cancel
    /// words. #119: that direction is deliberately looser than the matcher
    /// because it is fail-safe — aborting a pending skip loses nothing when it
    /// fires spuriously, while missing it burns a question. #185 took
    /// "cancel"/"zruš" out of `.stop` (no voice cancel of an answer), so they
    /// are listed here to keep aborting a skip.
    static func undoCancelVariants(for language: CommandLanguage) -> Set<String> {
        let looseNoWords: [String]
        switch language {
        case .english: looseNoWords = ["no", "know", "cancel"]
        case .slovak: looseNoWords = ["nie", "no", "zrus"]
        case .czech: looseNoWords = ["ne", "no", "zrus"]
        }
        return Set(
            cancelWords.flatMap { variants(for: $0, language: language) } + looseNoWords
        )
    }

    /// Whether `token` (already normalized) is a spoken cancel/undo word.
    static func isCancelWord(
        _ token: String,
        language: CommandLanguage = .english
    ) -> Bool {
        undoCancelVariants(for: language).contains(token)
    }

    /// The raw spoken vocabulary (real diacritics, no folding) handed to a
    /// recognizer that honors `AnalysisContext.contextualStrings` (#120 —
    /// DictationTranscriber does, SpeechTranscriber ignores them). Biasing the
    /// engine toward these exact words is a structurally better defence than
    /// spelling variants + edit distance, so every command form we accept is
    /// listed, in its display spelling.
    static func contextualVocabulary(for language: CommandLanguage) -> [String] {
        switch language {
        case .english:
            return [
                "start", "ok", "okay", "confirm", "yes", "yeah", "next", "again", "retry", "no", "wrong",
                "one more time", "once more", "try again", "repeat", "skip", "pass", "stop", "wait", "cancel", "pause",
            ]
        case .slovak:
            return [
                "štart", "ok", "okej", "potvrď", "áno", "hej", "ďalej", "pokračuj",
                "znova", "znovu", "nie", "zle", "ešte raz", "zopakuj", "opakuj", "preskoč", "vynechaj",
                "stop", "počkaj", "zruš", "pauza",
            ]
        case .czech:
            return [
                "start", "ok", "okej", "potvrď", "ano", "jo", "dál", "dále", "pokračuj",
                "znovu", "znova", "ne", "špatně", "ještě jednou", "zopakuj", "opakuj", "přeskoč", "vynech",
                "stop", "počkej", "zruš", "pauza",
            ]
        }
    }
}
