//
//  VoiceCommand.swift
//  Hangs
//
//  Voice command model and matching logic for hands-free quiz control
//

import Foundation

/// Voice commands recognized by VoiceCommandService
enum VoiceCommand: String, Sendable, CaseIterable {
    case start    // Start recording or re-record
    case stop     // Stop recording + submit
    case skip     // Skip current question
    case `repeat` // Replay current question audio
    case score    // Announce current score via TTS
    case help     // List available commands via TTS
    case ok       // Confirm transcribed answer
    case again    // Play again (CompletionView)
    case home     // Return to home (CompletionView)
    case optionA  // MCQ: select option A
    case optionB  // MCQ: select option B
    case optionC  // MCQ: select option C
    case optionD  // MCQ: select option D
}

/// UI-facing listening state for voice command indicator
enum VoiceCommandListeningState: Sendable, Equatable {
    case disabled
    case listening
    case commandDetected(VoiceCommand)
}

/// Events emitted by silence detection (SpeechDetector VAD)
enum SilenceEvent: Sendable, Equatable {
    /// User started speaking
    case speechStarted
    /// Continuous silence detected after speech ended
    case silenceAfterSpeech(duration: TimeInterval)
}

// MARK: - Command Matching

extension VoiceCommand {

    /// Match a transcription string to a voice command.
    /// Uses priority ordering: start > stop > skip > repeat > score > help > ok
    /// Uses word-boundary matching (split into words) to prevent false positives
    /// like "book" matching "ok" or "helpful" matching "help".
    static func match(from transcription: String) -> VoiceCommand? {
        let lower = transcription.lowercased().trimmingCharacters(in: .whitespaces)
        let words = lower.split(separator: " ").map(String.init)
        let wordSet = Set(words)

        // MCQ option matching — strict: single letter or "option/answer X"
        if let mcq = matchMCQOption(words: words, lower: lower) {
            return mcq
        }

        // Priority order: time-sensitive commands first, "ok" last (least ambiguous)
        for command in [VoiceCommand.start, .stop, .skip, .repeat, .score, .help, .ok, .again, .home] {
            if wordSet.contains(command.rawValue) {
                return command
            }
        }

        return nil
    }

    /// Match MCQ option commands with strict rules to avoid false positives.
    /// Matches: "a", "b", "c", "d" (single word only), "option a", "answer b"
    private static func matchMCQOption(words: [String], lower: String) -> VoiceCommand? {
        let optionMap: [String: VoiceCommand] = [
            "a": .optionA, "b": .optionB, "c": .optionC, "d": .optionD
        ]

        // Single-word: must be exactly one letter
        if words.count == 1, let command = optionMap[words[0]] {
            return command
        }

        // "option X" or "answer X" pattern
        if words.count == 2,
           (words[0] == "option" || words[0] == "answer"),
           let command = optionMap[words[1]] {
            return command
        }

        return nil
    }
}
