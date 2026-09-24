//
//  AnswerDetection.swift
//  Hangs
//
//  #185 track A: the values that cross the SilenceDetectionService boundary
//  for one answer recording — the live input level, the verdict on whether
//  the 5 s no-speech window may end the recording, why a recording stopped,
//  and the per-recording detector report that goes to Sentry.
//

import Foundation

/// The mic level of one tap buffer — the signal a "the mic hears you" ring
/// draws from (#185 track F). Emitted for every buffer while the mic engine
/// runs (~47 per second), whether or not an answer is being recorded.
nonisolated struct InputLevel: Sendable, Equatable {
    /// Band-limited RMS level (dBFS) — the same measure the VAD decides on.
    let db: Float
    /// The VAD's current noise floor; `nil` while it is still calibrating.
    let noiseFloorDb: Float?

    /// 0…1: how far the level sits above the noise floor (0 at or below it,
    /// 1 at 30 dB above). 0 while calibrating.
    var normalized: Float {
        guard let noiseFloorDb else { return 0 }
        return min(1, max(0, (db - noiseFloorDb) / 30))
    }
}

/// May the visible "time to start speaking" window end this recording?
///
/// #185 (founder 2026-09-24): the 5 s window may cut a recording only when a
/// detector demonstrably works and heard nothing that could be speech;
/// anything else leaves the recording to the hidden dead-air cap, so a late or
/// quiet answer is never cut off by a deaf detector.
nonisolated enum NoSpeechWindowVerdict: String, Sendable, Equatable {
    /// Levels are flowing, the floor is measured, nothing rose above it.
    case quiet
    /// Speech was detected in this recording (the window should be gone).
    case speechHeard
    /// No level buffers lately (engine stalled or not up), digital silence,
    /// or no answer recording in progress — the detector cannot vouch.
    case noAudio
    /// The noise floor is not measured yet.
    case calibrating
    /// The level sat above the floor longer than a transient but never became
    /// speech — maybe a quiet voice in loud noise.
    case possibleSpeech

    var mayEndRecording: Bool { self == .quiet }
}

/// Why an answer recording stopped — the first question of every car-test
/// triage ("did the VAD end it, or a timer?").
nonisolated enum RecordingStopReason: String, Sendable, Equatable {
    /// Silence after speech (the VAD auto-stop).
    case vad
    /// The visible 5 s "time to start speaking" window ran out.
    case noSpeechWindow
    /// The hidden dead-air cap.
    case cap
    /// The driver tapped stop (or paused the quiz).
    case manual
}

/// What the detectors saw during one answer recording (#185 track A). Logged
/// on "answer recording stopped" so the next car test proves which detector
/// heard speech, whether audio reached them at all, and how loud it was.
nonisolated struct AnswerDetectionReport: Sendable, Equatable {
    var energyHeardSpeech = false
    var speechDetectorHeardSpeech = false
    /// Results Apple's `SpeechDetector` delivered (any kind) — expected 0 or
    /// errors only; `nil` when the detector is not paired at all.
    var speechDetectorResults: Int?
    /// Level buffers the energy detector measured (0 = no audio reached it).
    var levelBuffers = 0
    var noiseFloorDb: Float?
    var peakDb: Float?
    /// Audio time either detector called speech.
    var speechMs = 0
    /// Audio time above the floor that never became speech.
    var ambiguousMs = 0
    /// The blip bar this recording used (lower for multiple choice).
    var minSpeechMs = 0

    static let empty = AnswerDetectionReport()

    var speechHeardBy: String {
        switch (energyHeardSpeech, speechDetectorHeardSpeech) {
        case (true, true): "both"
        case (true, false): "energy"
        case (false, true): "speechDetector"
        case (false, false): "none"
        }
    }

    /// Flat Sentry attributes (dB rounded to 0.1 so the values stay readable).
    var sentryAttributes: [String: Any] {
        var attributes: [String: Any] = [
            "speechHeardBy": speechHeardBy,
            "speechDetectorResults": speechDetectorResults.map { "\($0)" } ?? "unpaired",
            "levelBuffers": levelBuffers,
            "speechMs": speechMs,
            "ambiguousMs": ambiguousMs,
            "minSpeechMs": minSpeechMs,
        ]
        if let noiseFloorDb { attributes["noiseFloorDb"] = Self.rounded(noiseFloorDb) }
        if let peakDb { attributes["peakDb"] = Self.rounded(peakDb) }
        return attributes
    }

    private static func rounded(_ value: Float) -> Double {
        (Double(value) * 10).rounded() / 10
    }
}
