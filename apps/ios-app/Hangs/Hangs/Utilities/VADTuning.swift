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
//  there is no need to capture audio before the mic opens. Since #185 track A
//  the on-device speech signal is `EnergyVAD` (a band-limited level detector):
//  Apple's SpeechDetector reports no speech results at all (see
//  `commandGateSensitivity`).
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
    // MARK: - On-device VAD state machine (SilenceDetectionService)

    /// Silence hangover: how long continuous silence must persist AFTER speech
    /// before the recorder auto-stops and submits. #184 (car test 2026-09-21):
    /// 1.5 s was the window in which the passenger's next words and the road
    /// got appended to the answer — every production voice agent sits at
    /// 0.5–0.8 s (OpenAI server_vad 500 ms, LiveKit 550 ms, Pipecat 250–500 ms;
    /// research doc). 0.8 s keeps a thinking pause inside one answer while the
    /// batch model (Scribe v2) copes with the trailing silence the old value was
    /// hedging against. Re-measured on the car samples (track B).
    static let silenceHangoverSecs: TimeInterval = 0.8

    /// Minimum speech duration for an utterance to count. A burst shorter than
    /// this (a cough, a road-noise blip, a mic pop) is rejected as a false start
    /// rather than auto-submitted as an empty answer. 0.25 s per the #184
    /// research (one short Slovak word — "áno", "päť" — is ~200–300 ms).
    static let minSpeechDurationSecs: TimeInterval = 0.25

    /// The same guard for a multiple-choice answer (#185 — car test 2026-09-23).
    /// The whole answer can be one syllable ("c", "dva"), and at 0.25 s the
    /// driver's "c" was thrown away as a blip; the recording then ran on to the
    /// cap. The energy detector's onset hold still has to be met first, so a
    /// click or a bump does not get through on this lower bar.
    static let mcqMinSpeechDurationSecs: TimeInterval = 0.1

    /// Apple `SpeechDetector` paired into the command analyzer — `nil` = not
    /// paired (#185 track A). Apple documents its result stream as reporting
    /// only VAD-model ERRORS ("currently only support error handling from the
    /// VAD model", `SpeechDetector.Result`), which is why the car test saw 0 of
    /// 16 recordings reach "vad speech began" and why no speech was ever
    /// reported in 14 days. Its one real effect was gating what the command
    /// transcriber hears, and `.low` — the setting shipped since 77.11 — is
    /// already its most forgiving level ("low … more forgiving, high … more
    /// aggressive"), so the only way to stop commands depending on it is to not
    /// pair it. Speech is now detected by `EnergyVAD`. Set a level to pair it
    /// again: its results are counted per recording (`detectorResults`) and a
    /// `speechDetected` result, should an iOS update ever deliver one, counts
    /// as speech alongside the energy detector.
    static let commandGateSensitivity: DetectorSensitivity? = nil

    // MARK: - Energy VAD (EnergyVAD, #185 track A)

    /// High-pass corner of the VAD's level meter (two cascaded 2nd-order
    /// sections, 24 dB/octave). Engine and road rumble sit below it; the voice
    /// energy a detector needs (formants, 300–3400 Hz) sits above. It shapes
    /// ONLY what the detector measures — the uploaded answer stays unfiltered.
    static let energyHighPassHz: Double = 200

    /// Audio at the start of every recording that sets the noise floor (the
    /// lower quartile of its buffer levels, so a word spoken straight away
    /// does not become "the noise").
    static let noiseCalibrationSecs: TimeInterval = 0.3

    /// Speech starts when the level stays this far above the noise floor for
    /// `speechOnsetHoldSecs`, and ends when it drops below `speechReleaseMarginDb`
    /// (hysteresis, so one soft syllable does not split an answer).
    static let speechOnsetMarginDb: Float = 7
    static let speechReleaseMarginDb: Float = 4
    static let speechOnsetHoldSecs: TimeInterval = 0.06

    /// Speech is never below this level, however quiet the room: in a silent
    /// room the relative margin alone would fire on a rustle.
    static let absoluteSpeechFloorDbfs: Float = -60

    /// A floor at or below this is digital silence (a muted or dead input),
    /// not a room — the detector cannot vouch for anything it measures there.
    static let digitalSilenceDbfs: Float = -120

    /// How fast the floor follows the noise between words: down quickly (a
    /// quieter stretch is the better estimate), up slowly (so a soft voice is
    /// not absorbed into the floor). Frozen while speech is active.
    static let noiseFloorFallSecs: TimeInterval = 0.1
    static let noiseFloorRiseSecs: TimeInterval = 2.0

    /// Time the level may spend above the release margin without becoming
    /// speech before the detector admits "maybe someone is talking". Past it,
    /// the 5 s no-speech window may no longer end the recording (#185: an
    /// answer is never cut by a detector that might be deaf) — the hidden cap
    /// does.
    static let ambiguousActivityMaxSecs: TimeInterval = 0.2

    /// The detector counts as alive only while level buffers keep arriving —
    /// a stalled engine is not "silence".
    static let levelStaleAfterSecs: TimeInterval = 0.5

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

/// Pure STOP-on-silence decision, factored OUT of
/// `SilenceDetectionService` so it can be exercised headlessly. This
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
    ///   - minSpeechDuration: the blip bar for this recording — lower for a
    ///     multiple-choice answer (`VADTuning.mcqMinSpeechDurationSecs`).
    static func evaluate(
        speechDuration: TimeInterval,
        silenceElapsed: TimeInterval,
        minSpeechDuration: TimeInterval = VADTuning.minSpeechDurationSecs
    ) -> Outcome {
        guard silenceElapsed >= VADTuning.silenceHangoverSecs else { return .wait }
        if speechDuration < minSpeechDuration { return .rejectBlip }
        return .stop
    }
}
