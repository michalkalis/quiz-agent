//
//  VoiceCommandLexicon.swift
//  Hangs
//
//  Issue #77 (voice commands hands-free), task 77.3 — the constant sibling of
//  MCQTranscriptMatcher's lookup tables. The voice-command layer is a SEPARATE
//  native-English on-device recognizer (SpeechAnalyzer), English-only for all
//  users regardless of app language (P2). The new SpeechAnalyzer framework has
//  NO contextualStrings / custom-vocabulary biasing, so accent-robust word
//  choice + a fuzzy matcher are the ENTIRE mitigation for a Slovak-accented
//  driver. This file owns the word-set (P4b: start · ok · next · repeat · skip
//  [+ optional stop]) and each command's accent-tolerant variant spellings —
//  the provisional set is finalised on-device at the 77.15 [HUMAN] accent gate.
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

    /// Accent-tolerant variant spellings per command (already normalized: lower,
    /// diacritic-folded, alphanumeric). The matcher scores a token against the
    /// MIN edit distance across a command's variants, so common Slovak-accented
    /// mistranscriptions are first-class here rather than left to the threshold.
    static func variants(for command: VoiceCommand) -> [String] {
        switch command {
        case .start: return ["start", "stat", "staat", "sart", "strt", "shtart"]
        case .ok: return ["ok", "okay", "okey", "okei", "kay", "oukej"]
        case .next: return ["next", "nekst", "neks", "nekt", "nx"]
        case .again: return ["again", "agen", "agian", "retry", "retri"]
        case .repeatQuestion: return ["repeat", "repit", "repeet", "ripeat", "ripit"]
        case .skip: return ["skip", "skib", "skep", "skp", "skjp"]
        case .stop: return ["stop", "stap", "stahp", "no", "cancel", "kancel"]
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

    /// The cancel/undo words that abort an open `UndoWindow` (spoken form of a tap).
    static let cancelWords: [VoiceCommand] = [.stop]

    /// Whether `token` (already normalized) is a spoken cancel/undo word.
    static func isCancelWord(_ token: String) -> Bool {
        cancelWords.contains { variants(for: $0).contains(token) }
    }
}
