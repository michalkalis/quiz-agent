//
//  VoiceCommandLexicon.swift
//  Hangs
//
//  Issue #77 (voice commands hands-free), task 77.3 — the constant sibling of
//  MCQTranscriptMatcher's lookup tables. #120 made the word-set LANGUAGE-SCOPED:
//  the command grammar now exists in English (default, #77 P2) and Slovak
//  (founder-approved 2026-07-26, only reachable on the DictationTranscriber
//  engine — SpeechTranscriber has no sk_SK). Every lookup takes a
//  `CommandLanguage` defaulting to the launch-time selection, so callers above
//  the engine seam stay unchanged and tests can pin a language explicitly.
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
}

/// The screen a command is heard on. Command routing is screen-scoped so an
/// utterance is only matched against that screen's 1–2 valid commands, never the
/// whole grammar — this is the confusion mitigation for the tiny accented vocab.
enum VoiceCommandScreen: Sendable, Equatable {
    case home // idle — pre-quiz
    case question // askingQuestion, after TTS
    case confirmation // processing — the answer-confirmation sheet
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
        case .confirmation: return [.ok, .again, .stop]
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
        language: CommandLanguage = CommandEngineSelection.current.commandLanguage
    ) -> [String] {
        switch (language, command) {
        case (.english, .start): return ["start"]
        case (.english, .ok): return ["ok", "okay", "okey", "oukej"]
        case (.english, .next): return ["next"]
        case (.english, .again): return ["again", "retry"]
        case (.english, .repeatQuestion): return ["repeat"]
        case (.english, .skip): return ["skip"]
        // Bare "no" is deliberately NOT a stop variant — it is one of the
        // highest-frequency Slovak discourse particles (~"well/so") and the
        // founder talks to passengers with the mic open. A false `.stop` on the
        // confirmation sheet calls cancelProcessing() and discards an in-flight
        // answer with no undo. The fail-safe undo-abort path keeps accepting it
        // via `undoCancelVariants`.
        case (.english, .stop): return ["stop", "cancel"]
        // "štart" folds to "start" — the command is IDENTICAL across languages,
        // which also keeps founder muscle memory intact.
        case (.slovak, .start): return ["start"]
        // ⚠️ FLAGGED HAZARD (#120): "ok"/"okej" occur in normal Slovak
        // conversation. Kept because (a) on the confirmation sheet `.ok` is
        // final-only + one-content-token capped, (b) on the result screen the
        // action is benign (advance = the default outcome anyway), and
        // (c) dropping the founder's habitual "ok" would cost real recall.
        // "potvrď" is the recommended disjoint form. "áno"/"dobre" are NOT
        // variants — they are filler (see `fillerWords`), by design.
        case (.slovak, .ok): return ["ok", "okej", "oukej", "potvrd"]
        // ⚠️ FLAGGED HAZARD (#120): a lone conversational "ďalej?" ("go on")
        // can fire `.next` — accepted because it is result-screen-only and
        // benign (auto-advance was coming anyway).
        case (.slovak, .next): return ["dalej", "pokracuj"]
        case (.slovak, .again): return ["znova", "znovu"]
        case (.slovak, .repeatQuestion): return ["zopakuj", "opakuj"]
        case (.slovak, .skip): return ["preskoc", "vynechaj"]
        // ⚠️ FLAGGED (minor): "stoj" scores 0.75 vs "stop" — above the final
        // floor. Rare in cabin conversation; `.stop` is final-only and
        // confirmation-screen-scoped, so the exposure is bounded.
        case (.slovak, .stop): return ["stop", "zrus"]
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
    /// Slovak set is built on: saying "áno" will NOT confirm an answer.
    static func fillerWords(
        for language: CommandLanguage = CommandEngineSelection.current.commandLanguage
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
        }
    }

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
        case (.slovak, .start): return "štart"
        case (.slovak, .ok): return "potvrď"
        case (.slovak, .next): return "ďalej"
        case (.slovak, .again): return "znova"
        case (.slovak, .repeatQuestion): return "zopakuj"
        case (.slovak, .skip): return "preskoč"
        case (.slovak, .stop): return "stop"
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
        case (.slovak, .home): return #"Povedz „štart""#
        case (.slovak, .question): return #"Povedz „štart" alebo „preskoč""#
        case (.slovak, .confirmation): return #"Povedz „potvrď", „znova" alebo „stop""#
        case (.slovak, .result): return #"Povedz „ďalej""#
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
        }
    }

    /// The cancel/undo words that abort an open `UndoWindow` (spoken form of a tap).
    static let cancelWords: [VoiceCommand] = [.stop]

    /// Words accepted ONLY on the loose undo-abort path: every `.stop` variant
    /// PLUS the plain no-words ("no"/"know"; Slovak adds "nie"). #119: that
    /// direction is deliberately looser than the matcher because it is fail-safe
    /// — aborting a pending skip loses nothing when it fires spuriously, while
    /// missing it burns a question. The reverse (a false `.stop` on the
    /// confirmation sheet) is destructive, which is why "no"/"nie" are never
    /// `.stop` variants.
    static func undoCancelVariants(for language: CommandLanguage) -> Set<String> {
        let looseNoWords: [String]
        switch language {
        case .english: looseNoWords = ["no", "know"]
        case .slovak: looseNoWords = ["nie", "no"]
        }
        return Set(
            cancelWords.flatMap { variants(for: $0, language: language) } + looseNoWords
        )
    }

    /// Whether `token` (already normalized) is a spoken cancel/undo word.
    static func isCancelWord(
        _ token: String,
        language: CommandLanguage = CommandEngineSelection.current.commandLanguage
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
            return ["start", "ok", "okay", "next", "again", "retry", "repeat", "skip", "stop", "cancel"]
        case .slovak:
            return [
                "štart", "ok", "okej", "potvrď", "ďalej", "pokračuj",
                "znova", "znovu", "zopakuj", "opakuj", "preskoč", "vynechaj", "stop", "zruš",
            ]
        }
    }
}
