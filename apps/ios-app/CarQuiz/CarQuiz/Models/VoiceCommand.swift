//
//  VoiceCommand.swift
//  CarQuiz
//
//  Voice command model and matching logic for hands-free quiz control
//

import Foundation

/// Voice commands recognized by VoiceCommandService
enum VoiceCommand: String, Sendable, CaseIterable {
    case start  // Start recording or re-record
    case stop   // Stop recording + submit
    case skip   // Skip current question
    case ok     // Confirm transcribed answer
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
    /// Uses priority ordering: start > stop > skip > ok
    /// Returns nil if no command word is found.
    static func match(from transcription: String) -> VoiceCommand? {
        let text = transcription.lowercased()

        // Priority order prevents ambiguity when multiple words appear
        for command in [VoiceCommand.start, .stop, .skip, .ok] {
            if text.contains(command.rawValue) {
                return command
            }
        }

        return nil
    }
}
