//
//  AudioDeviceState+Route.swift
//  Hangs
//
//  #185 track C: a device change re-evaluates the command listener's voice
//  processing. The policy decides it once per engine start (from the output
//  route); this is the only place a LIVE engine is revisited — the car
//  connecting while the phone speaker was the output, or the car going away
//  while voice processing was off. See VoiceProcessingPolicy for the rule.
//

import Foundation
import os

extension AudioDeviceState {
    /// Restart the live listener when its voice processing no longer fits the
    /// route (`VoiceProcessingPolicy.shouldRestartListener`). The restart runs
    /// through the choke points, so the stop half also restores the session
    /// before the new engine asks the policy again.
    ///
    /// Only a listener that is up with capture allowed is touched: during an
    /// answer the engine IS the recorder (a restart would cut the answer),
    /// during TTS it is already down, and in both cases the next engine start
    /// decides on the new route anyway. At most one restart per listening
    /// window, so a route change a restart itself causes can never loop.
    func handleAudioRouteChange(_ change: AudioRouteChange) async {
        let service = silenceDetectionService
        guard service.isListening, mayCaptureAudio(), !routeRestartedThisWindow else { return }

        let armed = service.voiceProcessingStatus?.armed ?? false
        guard VoiceProcessingPolicy.shouldRestartListener(
            reason: change.reason,
            armed: armed,
            wantsVoiceProcessing: change.voiceProcessingMode.armsVoiceProcessing
        ) else { return }

        SentryLog.info("command listener restarted for route", category: .audio, attributes: [
            "reason": AudioService.routeChangeReasonName(change.reason),
            "outputPort": change.outputPort,
            "wasArmed": armed,
            "vpMode": change.voiceProcessingMode.rawValue,
        ])
        stopSilenceDetectionListening()
        // After the stop (which clears it): this window already had its restart.
        routeRestartedThisWindow = true
        await startSilenceDetectionListening()
    }
}
