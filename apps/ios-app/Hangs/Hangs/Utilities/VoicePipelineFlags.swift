//
//  VoicePipelineFlags.swift
//  Hangs
//
//  #184 (car-noise field test, founder 2026-09-21): the answer-pipeline
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
//  in for the 30–50-sample measurement set). #185 track C added voice
//  processing on external outputs, OFF (it moves the sound off the car), and
//  the cleaned-up answer upload, OFF (Scribe's input stays as it is).
//

import Foundation

nonisolated enum VoicePipelineFlags {
    enum Key {
        static let voiceProcessing = "voicePipeline.voiceProcessingEnabled"
        static let voiceProcessingOnExternalOutput = "voicePipeline.voiceProcessingOnExternalOutput"
        static let conditionAnswerUpload = "voicePipeline.conditionAnswerUpload"
        static let realtimeSTT = "voicePipeline.realtimeSTTEnabled"
        static let saveAnswerRecordings = "voicePipeline.saveAnswerRecordings"
        static let echoCancelledInputOnExternalRoutes = "voicePipeline.echoCancelledInputOnExternalRoutes"
        static let frontCardioidMic = "voicePipeline.frontCardioidMic"
        static let neuralVAD = "voicePipeline.neuralVADEnabled"
        static let avoidRejectedTranscriptOnRetry = "voicePipeline.avoidRejectedTranscriptOnRetry"
        static let autoTesting = "voicePipeline.autoTesting"
        static let aecBlockedGeneration = "voicePipeline.experiment.aecBlockedGeneration"
    }

    /// Apple voice processing (echo cancellation, noise suppression, AGC) on
    /// every mic engine the quiz opens — the command listener AND the answer
    /// recording. Both or neither: #173 turned it off because it ran on one
    /// engine only and the hand-off between them jumped the music volume.
    /// Since #185 track C this is the master switch; `VoiceProcessingPolicy`
    /// still keeps it off on an external output (A2DP, CarPlay, AirPlay…).
    static var voiceProcessingEnabled: Bool {
        get { bool(Key.voiceProcessing, default: true) }
        set { UserDefaults.standard.set(newValue, forKey: Key.voiceProcessing) }
    }

    /// #185 track C: arm voice processing on an external output too — the
    /// #184 behaviour, which moves the sound from the car to the iPhone
    /// speaker. Off by default; kept only so the founder can compare the two
    /// in the car without a new build.
    static var voiceProcessingOnExternalOutput: Bool {
        get { bool(Key.voiceProcessingOnExternalOutput, default: false) }
        set { UserDefaults.standard.set(newValue, forKey: Key.voiceProcessingOnExternalOutput) }
    }

    /// #185 track C: high-pass + level normalization on the UPLOADED answer
    /// (`AnswerAudioConditioning`) — the software stand-in for voice
    /// processing in the car. Off by default: the founder wants Scribe's input
    /// unchanged until the offline comparison shows a gain. Saved samples stay
    /// raw either way.
    static var conditionAnswerUpload: Bool {
        get { bool(Key.conditionAnswerUpload, default: false) }
        set { UserDefaults.standard.set(newValue, forKey: Key.conditionAnswerUpload) }
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
    /// `AnswerRecordingStore` — and upload it (#197). Founder opted in
    /// 2026-09-21; off by default; beta testers answer the one-time
    /// `AnswerRecordingConsent` question. Never on in an App Store build, even
    /// when a TestFlight install left the stored value on.
    static var saveAnswerRecordings: Bool {
        get { saveAnswerRecordings(channelAllows: BuildChannel.debugSurfacesEnabled()) }
        set { UserDefaults.standard.set(newValue, forKey: Key.saveAnswerRecordings) }
    }

    /// #204.4: Apple's echo-cancelled input (iOS 18.2+, 2024+ iPhones) on the
    /// routes voice processing stays off on — Bluetooth A2DP/LE, CarPlay,
    /// wired — so the car mic is no longer raw. Needs the session's default
    /// mode, so the quiz switches from `.spokenAudio` only while such a route
    /// is the output (`MicCapturePolicy`). Off by default until the car test.
    static var echoCancelledInputOnExternalRoutes: Bool {
        get { manualValue(.aec) }
        set { UserDefaults.standard.set(newValue, forKey: Key.echoCancelledInputOnExternalRoutes) }
    }

    /// #204.5: record with the iPhone's front built-in mic in a cardioid
    /// pattern when the built-in mic is the input and voice processing is
    /// off — less road noise from behind the phone. Never overrides a
    /// Bluetooth/HFP or user-chosen mic. Off by default until the car test.
    static var frontCardioidMic: Bool {
        get { manualValue(.frontMic) }
        set { UserDefaults.standard.set(newValue, forKey: Key.frontCardioidMic) }
    }

    /// #204 track 204.3: the Silero model (`SileroVAD`) instead of the level
    /// detector decides when the answer is over. Off until the car replay
    /// shows fewer recordings running to the cap; read when the mic engine
    /// starts, so a change applies from the next listening window.
    static var neuralVADEnabled: Bool {
        get { manualValue(.neuralVAD) }
        set { UserDefaults.standard.set(newValue, forKey: Key.neuralVAD) }
    }

    /// #204.2 (founder 2026-10-14): a re-recorded answer must not come back
    /// as the transcript the player just rejected ("modrá" heard as "mokrá",
    /// "znova", heard as "mokrá" again). Sends the transcripts rejected for the
    /// current question with the next upload (`rejected_transcripts`), so the
    /// backend tries another hypothesis. On by default; off = today's upload.
    static var avoidRejectedTranscriptOnRetry: Bool {
        get { bool(Key.avoidRejectedTranscriptOnRetry, default: true) }
        set { UserDefaults.standard.set(newValue, forKey: Key.avoidRejectedTranscriptOnRetry) }
    }

    /// #204.9 (founder 2026-10-14): the app runs the A/B of the three switches
    /// above itself (`VoiceExperimentStore`), with the odds the server sends in
    /// `/app-config`. On by default; off = the manual switches apply as before.
    /// The capture code reads the store's effective values, never these three
    /// directly, and the experiment never writes them.
    static var autoTesting: Bool {
        get { autoTesting(in: .standard) }
        set { UserDefaults.standard.set(newValue, forKey: Key.autoTesting) }
    }

    static func autoTesting(in defaults: UserDefaults) -> Bool {
        bool(Key.autoTesting, default: true, in: defaults)
    }

    /// The manual switch behind an experiment flag (all three default off).
    static func manualValue(_ flag: VoiceExperimentFlag, in defaults: UserDefaults = .standard) -> Bool {
        let key = switch flag {
        case .neuralVAD: Key.neuralVAD
        case .aec: Key.echoCancelledInputOnExternalRoutes
        case .frontMic: Key.frontCardioidMic
        }
        return bool(key, default: false, in: defaults)
    }

    static func saveAnswerRecordings(channelAllows: Bool) -> Bool {
        channelAllows && bool(Key.saveAnswerRecordings, default: false)
    }

    private static func bool(_ key: String, default defaultValue: Bool, in defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: key) != nil else { return defaultValue }
        return defaults.bool(forKey: key)
    }
}
