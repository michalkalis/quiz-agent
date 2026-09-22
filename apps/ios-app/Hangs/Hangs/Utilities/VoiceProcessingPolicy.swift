//
//  VoiceProcessingPolicy.swift
//  Hangs
//
//  #184 track A — the ONE place Apple voice processing is armed on a mic
//  engine. Both engines the quiz opens (the command listener in
//  SilenceDetectionService and the streaming answer engine in AudioService)
//  call this right after `AVAudioEngine()`, BEFORE reading the input format or
//  installing a tap: toggling voice processing changes the input node's format,
//  and a tap whose explicit format no longer matches the bus traps on start.
//
//  WHY on both engines, consistently: #119 armed it on the listener only and
//  #173 then removed it because every listen→record hand-off (listener with
//  VPIO down, answer engine without it up) jumped the music volume. The car test
//  of 2026-09-21 showed the raw mic is root cause #1 for the answers (shouting
//  required, trailing words), so voice processing comes back — on EVERY engine,
//  under one runtime switch (`VoicePipelineFlags.voiceProcessingEnabled`), with
//  the least aggressive other-audio ducking the SDK offers.
//
//  Deliberately NOT changing the session mode to `.voiceChat`: that mode enables
//  Bluetooth HFP as a side effect and would put the car's 8 kHz hands-free mic
//  on the answers — the exact routing #104's Media Mode exists to avoid. The
//  engine-level VPIO unit does its AEC/NS/AGC under `.spokenAudio` too; whether
//  it engaged is logged per recording so the car samples can tell.
//

@preconcurrency import AVFoundation
import Foundation

nonisolated enum VoiceProcessingPolicy {
    /// Arm voice processing on `inputNode` when the runtime switch is on.
    /// Returns whether the node reports voice processing enabled afterwards —
    /// the value the recording telemetry logs. Failure only means degraded
    /// audio, so it is logged, never thrown.
    @MainActor
    static func arm(_ inputNode: AVAudioInputNode, enabled: Bool = VoicePipelineFlags.voiceProcessingEnabled) -> Bool {
        guard enabled else { return false }
        do {
            try inputNode.setVoiceProcessingEnabled(true)
            // iOS 17+ VPIO ducks other audio by default. The founder drives with
            // music on; pick the least aggressive configuration the SDK exposes
            // rather than ducking the car stereo for the whole quiz (#119).
            inputNode.voiceProcessingOtherAudioDuckingConfiguration =
                AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
                    enableAdvancedDucking: false,
                    duckingLevel: .min
                )
        } catch {
            SentryLog.warn(
                "voice processing enable failed",
                category: .audio,
                attributes: ["error": error.localizedDescription]
            )
        }
        return inputNode.isVoiceProcessingEnabled
    }

    /// The current input route as one log-friendly string ("MicrophoneBuiltIn",
    /// "BluetoothHFP", …) — the field the car test needs to tell a phone-mic
    /// recording from a car-HFP one (#184 track A open question).
    static func currentInputPort() -> String {
        AVAudioSession.sharedInstance().currentRoute.inputs.first?.portType.rawValue ?? "none"
    }
}
