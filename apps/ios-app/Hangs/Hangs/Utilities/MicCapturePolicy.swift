//
//  MicCapturePolicy.swift
//  Hangs
//
//  #204.4 / #204.5 — two ways to clean up the car mic WITHOUT the voice-
//  processing unit, which pulls the sound off an A2DP car stereo (#185 track C,
//  see VoiceProcessingPolicy). Both are diagnostics switches the founder A/Bs
//  on a real drive; the route rules live here so they are unit-testable
//  without a live audio session.
//
//  204.4 echo-cancelled input (`AVAudioSession.setPrefersEchoCancelledInput`,
//  iOS 18.2+, "certain 2024 or later iPhone models"): valid only with
//  `.playAndRecord` + `.default` mode (SDK header), so the quiz's
//  `.spokenAudio` gives way to `.default` — and only while the output is a
//  route voice processing stays off on. The speaker / receiver / HFP path is
//  never touched: there voice processing already cancels the echo. Whether
//  iOS honours it on an A2DP output at all is the open question the car test
//  answers (`isEchoCancelledInputEnabled` is logged with every answer).
//
//  204.5 front built-in mic + cardioid (Apple QA1799): only while the
//  built-in mic IS the input and voice processing is off (the unit picks its
//  own mics). The built-in mic is pinned as the preferred input only in
//  Media Mode, whose category has no HFP: in Call Mode a pin would keep the
//  car's hands-free mic from taking over when it connects.
//

@preconcurrency import AVFoundation
import Foundation

nonisolated enum MicCapturePolicy {
    /// Outputs that get echo-cancelled input when the switch is on: the car and
    /// headphone routes voice processing is kept off on.
    static let echoCancelledInputOutputs: Set<AVAudioSession.Port> = [
        .bluetoothA2DP, .bluetoothLE, .carAudio, .headphones,
    ]

    /// Every output must be such a route; an empty or mixed route keeps
    /// today's session (an unknown route is never the place to experiment).
    static func wantsEchoCancelledInput(outputs: [AVAudioSession.Port], enabled: Bool) -> Bool {
        enabled && !outputs.isEmpty && outputs.allSatisfy { echoCancelledInputOutputs.contains($0) }
    }

    /// Front + cardioid only on the built-in mic, and only without voice
    /// processing.
    static func wantsFrontCardioidMic(
        inputs: [AVAudioSession.Port],
        enabled: Bool,
        voiceProcessing: Bool
    ) -> Bool {
        enabled && !voiceProcessing && inputs == [.builtInMic]
    }

    /// Pin the built-in mic as the preferred input: Media Mode only, and never
    /// over an input someone else chose (the input picker, Call Mode's HFP).
    static func shouldPinBuiltInMic(audioModeId: String, hasForeignPreferredInput: Bool) -> Bool {
        audioModeId == "media" && !hasForeignPreferredInput
    }

    /// What the mic actually runs with right now — logged with every answer
    /// (`answer recording stopped`) next to the two switches, for the A/B.
    @MainActor
    static func captureAttributes() -> [String: Any] {
        let session = AVAudioSession.sharedInstance()
        let source = session.currentRoute.inputs.first?.selectedDataSource
        return [
            "ecFlag": VoicePipelineFlags.echoCancelledInputOnExternalRoutes,
            "ecAvailable": session.isEchoCancelledInputAvailable,
            "ecEnabled": session.isEchoCancelledInputEnabled,
            "frontMicFlag": VoicePipelineFlags.frontCardioidMic,
            "micDataSource": source?.orientation?.rawValue ?? "none",
            "micPolarPattern": source?.selectedPolarPattern?.rawValue ?? "none",
        ]
    }
}
