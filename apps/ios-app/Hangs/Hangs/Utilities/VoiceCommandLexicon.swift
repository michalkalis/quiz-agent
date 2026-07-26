//
//  VoiceCommandLexicon.swift
//  Hangs
//
//  Issue #77 (voice commands hands-free), task 77.3 — the constant sibling of
//  MCQTranscriptMatcher's lookup tables. The voice-command layer is a SEPARATE
//  native-English on-device recognizer (SpeechAnalyzer), English-only for all
//  users regardless of app language (P2). `AnalysisContext.contextualStrings`
//  and `SpeechAnalyzer.setContext(_:)` DO exist in the shipping iPhoneOS 26 SDK
//  (#110 correction — this file used to claim they don't), but the
//  SpeechTranscriber module IGNORES them; only DictationTranscriber honors them.
//  So for the transcriber this app runs there is still no vocabulary biasing,
//  and word choice + a fuzzy matcher remain the mitigation. This file owns the
//  word-set (P4b: start · ok · next · repeat · skip [+ optional stop]) and each
//  command's variant spellings — cut back in #110 to the spellings the build-33
//  field data actually supports (see `variants`).
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
    static func commands(on screen: VoiceCommandScreen) -> [VoiceCommand] {
        switch screen {
        case .home: return [.start]
        case .question: return [.start, .repeatQuestion, .skip]
        case .confirmation: return [.ok, .again, .stop]
        case .result: return [.next, .ok]
        }
    }

    /// Variant spellings per command (already normalized: lower, diacritic-folded,
    /// alphanumeric). The matcher scores a token against the MIN edit distance
    /// across a command's variants.
    ///
    /// #110: the hand-written ACCENT table ("sart", "staat", "nekt", "skib",
    /// "kay", "skp", "agian"…) is gone. The build-33 field transcripts show that
    /// when the founder actually says a command word the en-US transcriber
    /// renders it PERFECTLY — verbatim "start start start start start" — so the
    /// speculative spellings bought zero recall while being pure false-fire
    /// surface: they were the only reason radio/conversation words ("sort",
    /// "sat", "stan", "state", "stats", "nek", "nekst") scored as commands. They
    /// are dropped for the same reason "nx" and bare "no" were. A genuine
    /// one-edit slip is still covered by the edit-distance floor.
    static func variants(for command: VoiceCommand) -> [String] {
        switch command {
        case .start: return ["start"]
        case .ok: return ["ok", "okay", "okey", "oukej"]
        case .next: return ["next"]
        case .again: return ["again", "retry"]
        case .repeatQuestion: return ["repeat"]
        case .skip: return ["skip"]
        // Bare "no" is deliberately NOT a stop variant — it is one of the
        // highest-frequency Slovak discourse particles (~"well/so") and the
        // founder talks to passengers with the mic open. A false `.stop` on the
        // confirmation sheet calls cancelProcessing() and discards an in-flight
        // answer with no undo. The fail-safe undo-abort path keeps accepting it
        // via `undoCancelVariants`.
        case .stop: return ["stop", "cancel"]
        }
    }

    /// Filler words stripped before the STRICT whole-utterance skip check and
    /// tolerated as padding around a command token. Deliberately conservative —
    /// only true discourse filler, NOT content words ("this"/"one"/"question")
    /// so that "let's skip THIS one" stays a multi-token utterance and is
    /// rejected as a skip (contains-but-isn't-skip).
    static let fillerWords: Set<String> = [
        "um", "uh", "uhm", "eh", "hmm", "hm", "er",
        "please", "just", "well", "so", "like", "yeah", "then",
    ]

    /// Canonical spoken spelling of a command, for display (diagnostics + the
    /// listening indicator). NOT the matcher input — matching uses `variants`.
    static func spokenWord(_ command: VoiceCommand) -> String {
        switch command {
        case .start: return "start"
        case .ok: return "ok"
        case .next: return "next"
        case .again: return "again"
        case .repeatQuestion: return "repeat"
        case .skip: return "skip"
        case .stop: return "stop"
        }
    }

    /// Curated hint for the on-screen "LISTENING FOR COMMANDS" indicator (77.12,
    /// pen `s49sd`). A concise, driver-facing subset of each screen's routable
    /// commands. #105: the question screen previously omitted "start" on the
    /// theory that auto-record was the primary answer path — but "start" is
    /// what begins answer recording and its omission left the hint claiming
    /// commands that don't advertise how to actually answer; it must be shown.
    /// English by design (the command grammar is English-only for all users).
    static func hint(on screen: VoiceCommandScreen) -> String {
        switch screen {
        case .home: return #"Say "start""#
        case .question: return #"Say "start" or "skip""#
        case .confirmation: return #"Say "ok", "again" or "stop""#
        case .result: return #"Say "next""#
        }
    }

    /// The cancel/undo words that abort an open `UndoWindow` (spoken form of a tap).
    static let cancelWords: [VoiceCommand] = [.stop]

    /// Words accepted ONLY on the loose undo-abort path: every `.stop` variant
    /// PLUS "no"/"know". #110: that direction is deliberately looser than the
    /// matcher because it is fail-safe — aborting a pending skip loses nothing
    /// when it fires spuriously, while missing it burns a question. The reverse
    /// (a false `.stop` on the confirmation sheet) is destructive, which is why
    /// "no" is no longer a `.stop` variant.
    static let undoCancelVariants: Set<String> = Set(
        VoiceCommandLexicon.cancelWords.flatMap { VoiceCommandLexicon.variants(for: $0) } + ["no", "know"]
    )

    /// Whether `token` (already normalized) is a spoken cancel/undo word.
    static func isCancelWord(_ token: String) -> Bool {
        undoCancelVariants.contains(token)
    }
}
