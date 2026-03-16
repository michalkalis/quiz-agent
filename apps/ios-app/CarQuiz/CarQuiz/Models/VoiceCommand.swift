//
//  VoiceCommand.swift
//  CarQuiz
//
//  Voice command model and matching logic for hands-free quiz control
//

import Foundation

/// Voice commands recognized by VoiceCommandService
enum VoiceCommand: String, Sendable, CaseIterable {
    case start   // Start recording or re-record
    case stop    // Stop recording + submit
    case skip    // Skip current question
    case `repeat` // Replay current question audio
    case score   // Announce current score via TTS
    case help    // List available commands via TTS
    case ok      // Confirm transcribed answer
    case again   // Play again (CompletionView)
    case home    // Return to home (CompletionView)
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
        let words = Set(transcription.lowercased().split(separator: " ").map(String.init))

        // Priority order: time-sensitive commands first, "ok" last (least ambiguous)
        for command in [VoiceCommand.start, .stop, .skip, .repeat, .score, .help, .ok, .again, .home] {
            if words.contains(command.rawValue) {
                return command
            }
        }

        return nil
    }
}
