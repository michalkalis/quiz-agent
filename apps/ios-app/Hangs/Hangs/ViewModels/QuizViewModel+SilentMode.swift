//
//  QuizViewModel+SilentMode.swift
//  Hangs
//
//  "No sound" (founder 2026-11-22): a switch on Home under "Quick quiz". With
//  it on, nothing in the quiz makes a sound or listens: no read aloud, no
//  microphone, no voice commands and no tones. A question has no time limit;
//  the player types the answer (the field is open at once) or taps an option,
//  and leaves it by sending or skipping. The result keeps its pause and
//  auto-advance, it only speaks nothing.
//
//  `isSilentMode` is the one decision. It reaches the existing switches
//  through `audioSettings` (read aloud, voice commands, the mic tone) and the
//  microphone through the think window and the recording start, which ask it
//  directly. The settings the player chose are never rewritten, so turning
//  the switch off brings back exactly what they had.
//

import Foundation

extension QuizViewModel {
    /// The quiz is silent now. Phone only: a round in CarPlay keeps its voice,
    /// the car has no keyboard.
    var isSilentMode: Bool {
        settings.silentMode && !isCarPlaySceneForeground
    }

    /// The settings every sound and listening path reads: the player's own,
    /// with silent mode turning off read aloud, voice commands and the mic tone.
    var audioSettings: QuizSettings {
        guard isSilentMode else { return settings }
        var silent = settings
        silent.isMuted = true
        silent.voiceCommandsEnabled = false
        silent.recordingSoundsEnabled = false
        return silent
    }

    /// Whether an answer, a skip or the next question asks the server for its
    /// spoken audio. A silent quiz would only throw it away.
    var requestsSpokenAudio: Bool {
        settings.audioMode != "off" && !isSilentMode
    }

    /// The Home "No sound" row. The Home command listener follows at once.
    func setSilentMode(_ on: Bool) {
        guard settings.silentMode != on else { return }
        settings.silentMode = on
        trackAnalytics(.silentModeChanged(enabled: on))
        refreshCommandWindow()
    }
}
