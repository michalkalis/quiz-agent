//
//  VADTuning.swift
//  Hangs
//
//  Issue #77 (voice commands hands-free), task 77.11 — the single, centralised
//  home for every STOP-on-silence tuning knob. Before this, the numbers were
//  scattered: a `1.5` literal inside `SilenceDetectionService`, a `.medium`
//  detector sensitivity, and the ElevenLabs VAD threshold in `Config`. Pulling
//  them into ONE named-constants type makes the cabin-noise tuning pass a
//  single-file edit.
//
//  ⚠️ These are STARTING POINTS, not final values. They are dialled in on the
//  target iOS 26+ device in real cabin noise at the 77.15 [HUMAN] gate (accent /
//  cabin-noise / BT). Do not treat any number here as load-bearing until then.
//
//  NO pre-roll / prefix-padding lives here: START is the button/timer (P1), so
//  there is no need to capture audio before the mic opens. NO new VAD engine —
//  these only tune the existing SpeechDetector (on-device VAD) and the ElevenLabs
//  streaming commit strategy.
//

import Foundation

/// Detector sensitivity, mirrored as an app-level enum so this constants type
/// stays free of the iOS-26-only `SpeechDetector.SensitivityLevel` framework
/// type (and therefore compiles + is unit-testable on the iOS 18.6 sim).
/// `SilenceDetectionService` maps it to the real framework value.
nonisolated enum DetectorSensitivity: String, Equatable, Sendable {
    case low, medium, high
}

/// Centralised STOP-on-silence tuning (task 77.11). One type, all knobs.
/// `nonisolated`: consumed from nonisolated contexts (`Config`, the STT URL
/// builder) under the project's MainActor default isolation.
nonisolated enum VADTuning {

    // MARK: - On-device SpeechDetector VAD (SilenceDetectionService)

    /// Silence hangover: how long continuous silence must persist AFTER speech
    /// before the recorder auto-stops and submits. Kept near the shipped 1.5 s;
    /// the sane band is ~1.2–1.8 s (shorter clips a driver's thinking pause,
    /// longer feels laggy). Finalised on-device at 77.15.
    static let silenceHangoverSecs: TimeInterval = 1.5

    /// Minimum speech duration for an utterance to count. A burst shorter than
    /// this (a cough, a road-noise blip, a mic pop) is rejected as a false start
    /// rather than auto-submitted as an empty answer. Starting point; tuned in
    /// real cabin noise at 77.15.
    static let minSpeechDurationSecs: TimeInterval = 0.3

    /// SpeechDetector sensitivity. `.medium` → `.low` for the driving use-case:
    /// road/engine/HVAC noise inflates a `.medium` detector's false-speech rate,
    /// which both burns the min-speech guard and delays the STOP. `.low` trades
    /// some quiet-cabin responsiveness for far fewer road-noise false triggers.
    /// A/B'd against real cabin noise at 77.15.
    static let detectorSensitivity: DetectorSensitivity = .low

    // MARK: - ElevenLabs Scribe v2 Realtime streaming VAD

    /// Silence (seconds) after which ElevenLabs commits the streaming transcript.
    /// Source of truth for the value `Config.elevenLabsVadSilenceThresholdSecs`
    /// forwards for back-compat.
    static let elevenLabsVadSilenceThresholdSecs: Double = 1.5

    /// Minimum speech (ms) ElevenLabs should see before treating audio as an
    /// utterance — the streaming-side twin of `minSpeechDurationSecs`, rejecting
    /// blips server-side.
    static let elevenLabsMinSpeechDurationMs: Int = 300

    /// Minimum silence (ms) ElevenLabs should require before a commit — the
    /// streaming-side twin of the hangover.
    ///
    /// NOTE: `min_speech_duration_ms` / `min_silence_duration_ms` are sent as
    /// query params on a best-effort basis; their exact names + acceptance are
    /// confirmed on-device at 77.15. The streaming path already falls back to
    /// Whisper batch on any WebSocket setup failure, so an unrecognised param
    /// cannot strand the hot path.
    static let elevenLabsMinSilenceDurationMs: Int = 1500
}

/// Pure STOP-on-silence decision, factored OUT of the iOS-26-gated
/// `SilenceDetectionService` so it runs headlessly on the iOS 18.6 sim (the
/// whole detector class is `@available(iOS 26, *)` and is skipped there). This
/// is where the min-speech-duration blip rejection actually lives and can be
/// unit-tested with a fixture that genuinely fails if the guard regresses.
nonisolated enum SilenceStopDecision {

    enum Outcome: Equatable, Sendable {
        /// Keep waiting — the hangover has not elapsed yet.
        case wait
        /// The utterance ended and was long enough: auto-stop + submit.
        case stop
        /// The utterance ended but was too short (cough/blip): drop it, no submit.
        case rejectBlip
    }

    /// - Parameters:
    ///   - speechDuration: how long the utterance lasted before silence began.
    ///   - silenceElapsed: how long silence has persisted since speech stopped.
    static func evaluate(speechDuration: TimeInterval, silenceElapsed: TimeInterval) -> Outcome {
        guard silenceElapsed >= VADTuning.silenceHangoverSecs else { return .wait }
        if speechDuration < VADTuning.minSpeechDurationSecs { return .rejectBlip }
        return .stop
    }
}
