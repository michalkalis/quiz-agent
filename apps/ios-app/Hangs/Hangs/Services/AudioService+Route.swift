//
//  AudioService+Route.swift
//  Hangs
//
//  #185 track C (car test 2026-09-23: the car's Bluetooth went quiet and the
//  quiz played from the iPhone speaker): the route side of the audio session.
//  Every route change is decoded once, logged to Sentry as a structured event
//  and handed to the owner, which re-evaluates the command listener's voice
//  processing (AudioDeviceState+Route). The session restore puts the quiz
//  configuration back after a voice-processing engine switched the session to
//  `.voiceChat` implicitly — with that mode left behind, A2DP stays excluded
//  and the next sound plays from the iPhone even though the engine is gone.
//  See VoiceProcessingPolicy for the route rule itself.
//

@preconcurrency import AVFoundation
import Foundation
import os

/// One decoded route change, as the owner sees it.
nonisolated struct AudioRouteChange: Sendable, Equatable {
    let reason: AVAudioSession.RouteChangeReason
    /// Where the sound goes now ("BluetoothA2DPOutput", "Speaker", …).
    let outputPort: String
    /// Where it went before the change ("none" when iOS did not say).
    let previousOutputPort: String
    /// What a mic engine armed on the new route would get — the policy's
    /// verdict the owner compares with the live listener.
    let voiceProcessingMode: VoiceProcessingMode
}

extension AudioService {
    /// Decode a route-change notification into the event the owner acts on.
    /// Pure apart from reading the live output route, so a test can post the
    /// notification iOS would post and see the same event.
    nonisolated static func routeChange(from notification: Notification) -> AudioRouteChange? {
        guard let reason = routeChangeReason(from: notification) else { return nil }
        return AudioRouteChange(
            reason: reason,
            outputPort: VoiceProcessingPolicy.currentOutputPort(),
            previousOutputPort: previousOutputPort(from: notification),
            voiceProcessingMode: VoiceProcessingPolicy.currentMode()
        )
    }

    nonisolated static func previousOutputPort(from notification: Notification) -> String {
        guard let route = notification.userInfo?[AVAudioSessionRouteChangePreviousRouteKey]
            as? AVAudioSessionRouteDescription
        else { return "none" }
        return VoiceProcessingPolicy.outputPortName(route)
    }

    /// Readable reason names for the structured log (`String(describing:)` on
    /// an imported enum prints the type, not the case).
    nonisolated static func routeChangeReasonName(_ reason: AVAudioSession.RouteChangeReason) -> String {
        switch reason {
        case .unknown: "unknown"
        case .newDeviceAvailable: "newDeviceAvailable"
        case .oldDeviceUnavailable: "oldDeviceUnavailable"
        case .categoryChange: "categoryChange"
        case .override: "override"
        case .wakeFromSleep: "wakeFromSleep"
        case .noSuitableRouteForCategory: "noSuitableRouteForCategory"
        case .routeConfigurationChange: "routeConfigurationChange"
        @unknown default: "reason\(reason.rawValue)"
        }
    }

    /// The structured event for EVERY route change: the next car test needs to
    /// see where the sound went, from where, and what voice processing a mic
    /// engine armed on this route would get.
    nonisolated static func logRouteChange(_ change: AudioRouteChange) {
        SentryLog.info("audio route changed", category: .audio, attributes: [
            "reason": routeChangeReasonName(change.reason),
            "outputPort": change.outputPort,
            "previousOutputPort": change.previousOutputPort,
            "inputPort": VoiceProcessingPolicy.currentInputPort(),
            "sessionMode": VoiceProcessingPolicy.modeName(AVAudioSession.sharedInstance().mode),
            "vpMode": change.voiceProcessingMode.rawValue,
        ])
    }

    /// Whether the live session has left the configuration it was set up with.
    /// Only the voice-processing unit changes it behind our back (it forces
    /// `.voiceChat`); every other writer is `setupAudioSession` /
    /// `setupQuietListeningSession` themselves.
    nonisolated static func sessionNeedsRestore(
        configured: SessionConfiguration?,
        category: AVAudioSession.Category,
        mode: AVAudioSession.Mode
    ) -> Bool {
        guard let configured else { return false }
        return configured.category != category || configured.mode != mode
    }

    /// Re-apply the configuration the session was set up with, when a voice-
    /// processing engine left it on `.voiceChat`. Called by the command
    /// listener's choke points while no listener engine is up: right after the
    /// teardown (before anything plays, so the next sound can take the car
    /// route again) and before a fresh start (so the policy reads the real
    /// route). Never while this service's own mic engine runs: re-configuring
    /// under a live voice-processing unit would pull the rug from under it. A
    /// no-op when nothing drifted, which is always the case in the car (voice
    /// processing is off on A2DP), so the car path costs two property reads.
    func restoreSessionAfterVoiceProcessing() {
        guard !isStreamingEngineActive else { return }
        let session = AVAudioSession.sharedInstance()
        guard let configuration = appliedSessionConfiguration,
              Self.sessionNeedsRestore(configured: configuration, category: session.category, mode: session.mode)
        else { return }

        let driftedMode = VoiceProcessingPolicy.modeName(session.mode)
        let outputBefore = VoiceProcessingPolicy.currentOutputPort()
        do {
            try session.setCategory(configuration.category, mode: configuration.mode, options: configuration.options)
        } catch {
            SentryLog.warn("audio session restore failed", category: .audio, attributes: [
                "error": error.localizedDescription,
                "sessionMode": driftedMode,
            ])
            return
        }
        // Device evidence for the research's open point: does the implicit
        // `.voiceChat` outlive the engine, and does the route come back?
        SentryLog.info("audio session restored after voice processing", category: .audio, attributes: [
            "fromMode": driftedMode,
            "toMode": VoiceProcessingPolicy.modeName(configuration.mode),
            "outputBefore": outputBefore,
            "outputAfter": VoiceProcessingPolicy.currentOutputPort(),
        ])
    }
}
