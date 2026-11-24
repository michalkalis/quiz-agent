//
//  CommandWindowReport.swift
//  Hangs
//
//  One listening window of the voice-command recognizer, as the
//  `voice_command_window` analytics event carries it: the numbers the
//  on-device-or-cloud decision for sk / cs / uk turns on. Counts and one
//  latency only, never a word of what was said.
//

import Foundation

nonisolated struct CommandWindowReport: Equatable, Sendable {
    /// "speech" (SpeechTranscriber) or "dictation" (DictationTranscriber).
    var engine: String
    /// The command language, "sk" / "cs" / "en" / "uk".
    var language: String
    /// The screen the window listened on (`VoiceCommandScreen`).
    var screen: String
    /// Recognizer results the window received, volatile and final.
    var transcripts: Int
    /// Commands that fired.
    var matched: Int
    /// Finished utterances that were no command (#243.5: on the answer sheet
    /// too — speech there is no longer a new answer).
    var unmatched: Int
    /// Results that arrived after the window had closed.
    var late: Int
    /// An utterance still in progress (results, no final yet) when the
    /// window ended — a command said just before the window closed.
    var cutOff: Int
    /// Window open (listener live) → first result; `nil` when none came.
    var firstTranscriptMs: Int?

    var propertyPairs: [(String, AnalyticsValue?)] {
        [
            ("engine", .string(engine)),
            ("language", .string(language)),
            ("screen", .string(screen)),
            ("transcripts", .int(transcripts)),
            ("matched", .int(matched)),
            ("unmatched", .int(unmatched)),
            ("late", .int(late)),
            ("cut_off", .int(cutOff)),
            ("first_transcript_ms", firstTranscriptMs.map { .int($0) }),
        ]
    }
}
