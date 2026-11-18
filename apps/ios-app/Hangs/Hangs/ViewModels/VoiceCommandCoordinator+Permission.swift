//
//  VoiceCommandCoordinator+Permission.swift
//  Hangs
//
//  #237 (founder 2026-11-17): speech recognition is asked for only when the
//  player wants voice commands — from the onboarding or the listen bar's
//  "Turn on" button (canvas pick L1). This file maps the recognizer's
//  permission state onto that button and re-arms the listener once commands
//  are ready, so a player who turns them on mid-quiz can use them on the same
//  question.
//

import Foundation

extension VoiceCommandCoordinator {
    /// The listen bar's trailing control for a question-screen phase, or `nil`.
    /// Shown only where command words would be (`phaseHasCommands`), with the
    /// master switch on and the hints visible — the player who hid the hints
    /// in Settings hid this too — and never with the mic denied: commands
    /// listen through the mic, so turning them on could not help.
    func commandsBarAccessory(phaseHasCommands: Bool, micDenied: Bool) -> ListenBar.CommandsAccessory? {
        Self.commandsBarAccessory(
            availability: commandAvailability,
            voiceCommandsEnabled: settings().voiceCommandsEnabled,
            showsHints: QuizSettings.voiceHintsVisible(override: settings().voiceHintsEnabled),
            micDenied: micDenied,
            phaseHasCommands: phaseHasCommands
        )
    }

    /// Pure so every availability × switch combination is assertable.
    static func commandsBarAccessory(
        availability: VoiceCommandAvailability,
        voiceCommandsEnabled: Bool,
        showsHints: Bool,
        micDenied: Bool,
        phaseHasCommands: Bool
    ) -> ListenBar.CommandsAccessory? {
        guard phaseHasCommands, voiceCommandsEnabled, showsHints, !micDenied else { return nil }
        return switch availability {
        case .permissionNeeded: .turnOn
        case .installingAssets: .preparing
        case .permissionDenied: .openSettings
        case .unknown, .ready, .unavailable: nil
        }
    }

    /// The player turned commands on. Raises the system prompt (the service
    /// decides whether one is still due), reports the answer, and asks for the
    /// listener to be rebuilt once the recognizer is ready: the engine that
    /// runs now was started without a transcriber, so it cannot hear a command.
    @discardableResult
    func enableCommands(source: VoiceCommandsSource) async -> Bool {
        // Set before the call: the service may report `.ready` before it returns.
        rearmsListenerWhenCommandsReady = true
        let granted = await silenceDetectionService.enableCommands()
        if !granted { rearmsListenerWhenCommandsReady = false }
        trackAnalytics(.voiceCommandsTurnedOn(source: source, result: granted ? .granted : .denied))
        return granted
    }

    /// Availability observer hook: commands just became ready after the player
    /// turned them on — rebuild the live listener so it runs the transcriber.
    func noteCommandAvailabilityChanged() {
        guard rearmsListenerWhenCommandsReady, commandAvailability == .ready else { return }
        refreshCommandWindow()
    }

    /// The restart half, run inside `syncCommandListenerWindow`: only a live
    /// listener in a window that may capture, and never under any playing
    /// audio (the read keeps an echo-cancelling engine it must not lose) —
    /// otherwise the flag waits for the next sync, and a window that starts
    /// from scratch builds the transcriber anyway.
    func restartListenerIfCommandsBecameReady() {
        guard rearmsListenerWhenCommandsReady, commandAvailability == .ready else { return }
        guard silenceDetectionService.isListening else {
            rearmsListenerWhenCommandsReady = false
            return
        }
        guard currentCommandScreen != nil, !isPlayingTTS() else { return }
        rearmsListenerWhenCommandsReady = false
        stopSilenceDetectionListening()
    }
}
