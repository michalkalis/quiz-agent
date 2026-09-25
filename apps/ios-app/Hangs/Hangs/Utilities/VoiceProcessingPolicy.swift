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
//  required, trailing words), so voice processing came back on every engine,
//  under one runtime switch (`VoicePipelineFlags.voiceProcessingEnabled`), with
//  the least aggressive other-audio ducking the SDK offers.
//
//  #185 track C (car test 2026-09-23): voice processing is ROUTE-AWARE. Arming
//  the voice-processing I/O unit makes iOS switch the session to `.voiceChat`
//  implicitly, whatever mode we set (`.spokenAudio` does NOT survive it — Apple,
//  `AVAudioSession.Mode.voiceChat`). The chat modes only allow duplex call
//  routes, so an A2DP car stereo drops out and the sound falls back to the
//  iPhone speaker for the whole quiz. No public API (iOS 17–26) keeps voice
//  processing on an A2DP output, so the policy arms it only where it cannot
//  move the sound: the iPhone's own speaker/receiver, or a hands-free (HFP)
//  route, which is what Call Mode opts into. On A2DP, Bluetooth LE, CarPlay,
//  AirPlay, wired or any unknown output it stays off. Research:
//  docs/research/bt-route-noise-suppression-2026-09-24.md. Toggling it per
//  recording was rejected (founder 2026-09-24): every toggle re-routes other
//  apps' audio and renegotiates A2DP.
//

@preconcurrency import AVFoundation
import Foundation

/// What the policy decided for one mic engine. The raw value is the `vpMode`
/// field the recording telemetry, the sample sidecars and Settings show.
nonisolated enum VoiceProcessingMode: String, Sendable, Equatable, CaseIterable {
    /// Armed: the output is the iPhone itself or a hands-free call route.
    case on
    /// Armed on an output the policy would keep it off — the diagnostics
    /// switch that reproduces the #184 behaviour for an in-car comparison.
    case forcedOn = "forced_on"
    /// Off: the output is external media (or unknown). Arming would pull the
    /// sound off it onto the iPhone speaker.
    case offOutput = "off_output"
    /// Off: the diagnostics master switch is off.
    case offSwitch = "off_switch"

    var armsVoiceProcessing: Bool {
        self == .on || self == .forcedOn
    }
}

/// One mic engine's voice-processing state: what the policy decided, whether
/// the input node actually reports it enabled (arming can fail), and the
/// output the decision was made on.
nonisolated struct VoiceProcessingStatus: Sendable, Equatable {
    let mode: VoiceProcessingMode
    let armed: Bool
    let outputPort: String
}

nonisolated enum VoiceProcessingPolicy {
    /// Outputs voice processing may run on without moving the sound: the
    /// iPhone's own speaker/receiver and the hands-free call route (Call Mode).
    static let voiceProcessingSafeOutputs: Set<AVAudioSession.Port> = [
        .builtInSpeaker, .builtInReceiver, .bluetoothHFP,
    ]

    /// Route → mode. Pure, so the whole table is unit-testable without a live
    /// session. Every output must be safe; an empty route is unknown, and
    /// unknown stays off — worst case the answer is unprocessed, never that
    /// the car goes quiet.
    static func mode(
        outputs: [AVAudioSession.Port],
        enabled: Bool,
        forceOnExternalOutput: Bool
    ) -> VoiceProcessingMode {
        guard enabled else { return .offSwitch }
        let safe = !outputs.isEmpty && outputs.allSatisfy { voiceProcessingSafeOutputs.contains($0) }
        if safe { return .on }
        return forceOnExternalOutput ? .forcedOn : .offOutput
    }

    /// The mode a mic engine armed NOW would get: the live output route and
    /// the two diagnostics switches.
    static func currentMode() -> VoiceProcessingMode {
        mode(
            outputs: AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portType),
            enabled: VoicePipelineFlags.voiceProcessingEnabled,
            forceOnExternalOutput: VoicePipelineFlags.voiceProcessingOnExternalOutput
        )
    }

    /// Arm voice processing on `inputNode` when `mode` says so. Returns the
    /// engine's status for the telemetry — `armed` is what the node reports
    /// afterwards. Failure only means degraded audio, so it is logged, never
    /// thrown.
    @MainActor
    static func arm(_ inputNode: AVAudioInputNode, mode: VoiceProcessingMode = currentMode()) -> VoiceProcessingStatus {
        let outputPort = currentOutputPort()
        guard mode.armsVoiceProcessing else {
            return VoiceProcessingStatus(mode: mode, armed: false, outputPort: outputPort)
        }
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
                attributes: ["error": error.localizedDescription, "vpMode": mode.rawValue]
            )
        }
        return VoiceProcessingStatus(mode: mode, armed: inputNode.isVoiceProcessingEnabled, outputPort: outputPort)
    }

    /// Whether a device change should restart a LIVE command listener so its
    /// voice processing matches the new route. Only real device changes count
    /// (the route changes voice processing and the session restore cause
    /// themselves must not loop). A listener with voice processing armed is
    /// restarted on every new device: while it runs, iOS hides A2DP from the
    /// route, so the new device may be the car the sound should move to — only
    /// releasing the unit lets the route show it.
    static func shouldRestartListener(
        reason: AVAudioSession.RouteChangeReason,
        armed: Bool,
        wantsVoiceProcessing: Bool
    ) -> Bool {
        switch reason {
        case .newDeviceAvailable:
            return armed || wantsVoiceProcessing
        case .oldDeviceUnavailable:
            return armed != wantsVoiceProcessing
        default:
            return false
        }
    }

    /// The current input route as one log-friendly string ("MicrophoneBuiltIn",
    /// "BluetoothHFP", …) — the field the car test needs to tell a phone-mic
    /// recording from a car-HFP one (#184 track A open question).
    static func currentInputPort() -> String {
        AVAudioSession.sharedInstance().currentRoute.inputs.first?.portType.rawValue ?? "none"
    }

    /// The current output route, same format ("Speaker", "BluetoothA2DPOutput",
    /// "CarAudio", …) — where the quiz's sound is going right now (#185 C).
    static func currentOutputPort() -> String {
        outputPortName(AVAudioSession.sharedInstance().currentRoute)
    }

    static func outputPortName(_ route: AVAudioSessionRouteDescription) -> String {
        route.outputs.first?.portType.rawValue ?? "none"
    }

    /// The session mode without its `AVAudioSessionMode` prefix ("SpokenAudio",
    /// "VoiceChat") — logged so a device run shows the implicit `.voiceChat`.
    static func modeName(_ mode: AVAudioSession.Mode) -> String {
        let raw = mode.rawValue
        let prefix = "AVAudioSessionMode"
        return raw.hasPrefix(prefix) ? String(raw.dropFirst(prefix.count)) : raw
    }

    /// One line for Settings › voice diagnostics: output, input, session mode
    /// and the mode a mic engine would get now.
    static func routeSummary() -> String {
        let session = AVAudioSession.sharedInstance()
        return [
            currentOutputPort(),
            currentInputPort(),
            modeName(session.mode),
            "VP \(currentMode().rawValue)",
        ].joined(separator: " · ")
    }
}
