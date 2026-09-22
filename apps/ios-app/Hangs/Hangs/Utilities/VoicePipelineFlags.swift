//
//  VoicePipelineFlags.swift
//  Hangs
//
//  #184 (car-noise field test, founder 2026-09-21): the three answer-pipeline
//  switches the founder A/Bs in the car. They are RUNTIME flags (UserDefaults),
//  not `Config` constants, because the whole point of the track is to measure
//  combinations on the same drive — voice processing on/off, realtime vs. batch
//  transcription — without a new TestFlight build per combination. Surfaced in
//  Settings under the TestFlight/debug "diagnostics" group only.
//
//  Defaults encode the research verdict (docs/research/stt-car-noise-research-
//  2026-09-21.md): voice processing ON (Apple AEC/NS/AGC on the mic — the raw
//  mic was root cause #1), realtime OFF (the answer goes record → upload →
//  Scribe v2 batch on the backend; ElevenLabs Realtime + its server VAD stays
//  reachable behind the switch until it has been measured against batch), and
//  sample saving OFF (privacy: recordings are only kept when the founder opts
//  in for the 30–50-sample measurement set).
//

import Foundation

nonisolated enum VoicePipelineFlags {
    enum Key {
        static let voiceProcessing = "voicePipeline.voiceProcessingEnabled"
        static let realtimeSTT = "voicePipeline.realtimeSTTEnabled"
        static let saveAnswerRecordings = "voicePipeline.saveAnswerRecordings"
    }

    /// Apple voice processing (echo cancellation, noise suppression, AGC) on
    /// every mic engine the quiz opens — the command listener AND the answer
    /// recording. Both or neither: #173 turned it off because it ran on one
    /// engine only and the hand-off between them jumped the music volume.
    static var voiceProcessingEnabled: Bool {
        get { bool(Key.voiceProcessing, default: true) }
        set { UserDefaults.standard.set(newValue, forKey: Key.voiceProcessing) }
    }

    /// Route answers through ElevenLabs Scribe v2 REALTIME (WebSocket, server
    /// VAD decides the end of speech) instead of the local-VAD + batch upload
    /// path. Off by default since #184; kept for the A/B measurement.
    static var realtimeSTTEnabled: Bool {
        get { bool(Key.realtimeSTT, default: false) }
        set { UserDefaults.standard.set(newValue, forKey: Key.realtimeSTT) }
    }

    /// Keep every batch answer recording (WAV + sidecar metadata) in the app's
    /// Documents folder for the offline STT comparison — see
    /// `AnswerRecordingStore`. Founder opted in 2026-09-21; off by default.
    static var saveAnswerRecordings: Bool {
        get { bool(Key.saveAnswerRecordings, default: false) }
        set { UserDefaults.standard.set(newValue, forKey: Key.saveAnswerRecordings) }
    }

    private static func bool(_ key: String, default defaultValue: Bool) -> Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: key) != nil else { return defaultValue }
        return defaults.bool(forKey: key)
    }
}
