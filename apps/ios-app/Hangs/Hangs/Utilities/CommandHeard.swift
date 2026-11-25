//
//  CommandHeard.swift
//  Hangs
//
//  "What the app hears" (founder 2026-11-22): while the player speaks, a quiet
//  line names the command the words resemble and fills as they get close to
//  firing it. It answers "did it hear me?" before the command lands, without
//  showing anything that is not a command.
//

import Foundation

/// The command the words in progress resemble, and how close they are to
/// firing it.
struct CommandHeard: Equatable, Sendable {
    let command: VoiceCommand
    /// 0 at the first resemblance, rising to just under 1 at the command's
    /// fire threshold. Exactly 1 only once the command fired.
    let certainty: Double
    /// Where it was heard: the round end names "next" its own way (#248).
    var screen: VoiceCommandScreen? = nil

    var hasFired: Bool { certainty >= 1 }

    /// The screens that show it. Turning one on or off is this one line.
    static let screens: Set<VoiceCommandScreen> = [.question, .confirmation, .noAnswer, .setEnd]

    /// The similarity at which words first count as resembling a command.
    /// Unmatched field speech scores about 0.50 (build 33), so this sits just
    /// above it: ordinary words never show.
    static let resemblanceFloor = 0.55

    /// A command that has not fired never shows a full fill: full means done.
    static let unfiredCeiling = 0.9

    /// How long the full fill stays after a fire before it clears.
    static let firedHold: Duration = .milliseconds(600)

    static func fired(_ command: VoiceCommand, on screen: VoiceCommandScreen? = nil) -> CommandHeard {
        CommandHeard(command: command, certainty: 1, screen: screen)
    }

    /// The preview for words in progress that score `score` against
    /// `command`, or `nil` below the first resemblance. The fill is mapped
    /// onto the command's own threshold, so the same similarity fills a
    /// strict command ("next") less than a lenient one ("again").
    static func inProgress(_ command: VoiceCommand, score: Double, on screen: VoiceCommandScreen? = nil) -> CommandHeard? {
        guard score >= resemblanceFloor else { return nil }
        let sensitivity = command.sensitivity
        // "next" fires only from a final, so its final floor is its threshold.
        let threshold = sensitivity.waitsForFinal ? sensitivity.finalFloor : sensitivity.volatileFloor
        let progress = (score - resemblanceFloor) / (threshold - resemblanceFloor)
        return CommandHeard(command: command, certainty: min(max(progress, 0), unfiredCeiling), screen: screen)
    }
}

extension VoiceCommandMatcher {
    /// The command among `commands` that the words in progress resemble most,
    /// with its similarity, or `nil` when the words are not one command word
    /// (a sentence, filler only). Volatile scoring, like the matcher's own
    /// partial path; a near tie names the less destructive command.
    static func resemblance(
        transcript: String, on screen: VoiceCommandScreen, among commands: [VoiceCommand],
        language: CommandLanguage
    ) -> (command: VoiceCommand, score: Double)? {
        let tokens = normalize(transcript, language: language).split(separator: " ").map(String.init)
        let content = contentTokens(tokens, language: language, on: screen)
            .subtracting(VoiceCommandLexicon.questionWords(for: language))
        guard content.count == 1 else { return nil }
        let scores = commands.map { command in
            (command: command, score: bestScore(Array(content), command: command, on: screen, isFinal: false, language: language))
        }
        guard let top = scores.map(\.score).max() else { return nil }
        return scores
            .filter { top - $0.score < ambiguityMargin }
            .min { $0.command.sensitivity.falseFireCost < $1.command.sensitivity.falseFireCost }
    }
}
