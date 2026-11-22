//
//  VoiceCommandSensitivity.swift
//  Hangs
//
//  Founder decision 3 (2026-11-22): each command fires as readily as a false
//  fire of it can be afforded. The matcher used one floor for every command
//  (0.72 final, 0.85 volatile) plus a stricter one for skip; now the table
//  below is the one place that says how strict each command is, and why.
//
//  Scores are `VoiceCommandMatcher.score` similarities in [0, 1] (1 = the word
//  exactly). One edit on a five-letter word scores 0.8, two edits 0.6.
//

import Foundation

/// How readily one command fires.
struct CommandSensitivity: Equatable, Sendable {
    /// The lowest score a FINAL result may fire the command at.
    let finalFloor: Double
    /// The lowest score a VOLATILE hypothesis may match at. A volatile is
    /// revisable and arrives while the mic is still open, so it is held higher.
    let volatileFloor: Double
    /// Whether only a final result may fire it. Matching a volatile still
    /// shows the "recognising" cue meanwhile.
    let waitsForFinal: Bool
    /// What a false fire costs, 0 = nothing. A word close to two commands
    /// resolves to the cheaper one (`VoiceCommandMatcher.resolve`).
    let falseFireCost: Int
}

extension VoiceCommand {
    var sensitivity: CommandSensitivity {
        switch self {
        // Strict. It skips the question at once (no undo since 2026-11-22)
        // and a skip spends a question, so precision beats speed: the word
        // must be near exact and only the final result may fire it. The final
        // floor is the old skip floor; the volatile one only lights the cue.
        case .next: CommandSensitivity(finalFloor: 0.8, volatileFloor: 0.85, waitsForFinal: true, falseFireCost: 3)
        // Fast and fairly lenient: a stray answer opens the mic early, which
        // costs the rest of the think time, not the question. It shares the
        // question window with next and repeat, so it sits between them and a
        // near tie with next goes to it.
        case .answer: CommandSensitivity(finalFloor: 0.72, volatileFloor: 0.8, waitsForFinal: false, falseFireCost: 2)
        // Lenient: missing it is worse than a false fire, which only replays
        // the question.
        case .repeatQuestion: CommandSensitivity(finalFloor: 0.7, volatileFloor: 0.76, waitsForFinal: false, falseFireCost: 1)
        // The most lenient: it asks for the answer the player is about to give
        // anyway (or retries, or plays again), so it should catch an imperfect
        // or cut-off word, and never waits for the final result.
        case .again: CommandSensitivity(finalFloor: 0.65, volatileFloor: 0.7, waitsForFinal: false, falseFireCost: 0)
        }
    }
}
