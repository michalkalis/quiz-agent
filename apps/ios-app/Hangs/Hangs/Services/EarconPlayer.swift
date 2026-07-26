//
//  EarconPlayer.swift
//  Hangs
//
//  Issue #77 (voice commands hands-free), task 77.10 — the minimal, LANGUAGE-
//  NEUTRAL earcon set. Hands-free driving means the driver's eyes stay on the
//  road, so the app confirms state changes with short non-speech tones instead
//  of spoken words (words would need per-language recording + add latency, and
//  the command layer is English-only regardless of app language — a spoken cue
//  would be jarring for the Slovak UI). Tones are locale-independent by design.
//
//  Four distinct cues, one per meaningful transition:
//    • micLive    — the mic just opened (start recording)
//    • gotIt      — STOP: recording ended / was auto-submitted
//    • skipConfirm — the skip undo-window opened (destructive, tap/say to abort)
//    • commandAck — a spoken command was recognized
//
//  This ALSO delivers #68's record-start / record-stop earcon item (micLive +
//  gotIt) — #68 should mark that delivered-by-#77.
//
//  Earcons are NEVER emitted during question TTS (the funnel that plays them —
//  `QuizViewModel.emitEarcon` — guards on `isPlayingQuestionTTS`).
//

import AudioToolbox
import CoreHaptics
import Foundation
import UIKit

/// The four hands-free audio cues (77.10). Language-neutral tones — no words.
enum Earcon: String, CaseIterable, Sendable, Equatable {
    case micLive       // mic opened
    case gotIt         // STOP: recording ended / auto-submitted
    case skipConfirm   // skip undo-window opened
    case commandAck    // a spoken command was recognized
}

/// Seam so the earcon player can be mocked in tests (assert exactly-one cue per
/// event, and none during TTS).
@MainActor
protocol EarconPlaying: AnyObject {
    func play(_ earcon: Earcon)
}

/// Production earcon player: distinct built-in iOS system sounds per cue. System
/// sounds are language-neutral, need no bundled assets, and mix over the active
/// audio session without tearing down TTS/recording. IDs are stable Apple system
/// sounds; the exact tones are a starting point and can be swapped for bespoke
/// generated tones without touching any call site.
@MainActor
final class SystemEarconPlayer: EarconPlaying {
    /// Whether this device has a Taptic Engine. Cached — the capability query is
    /// not free and the answer cannot change at runtime.
    private static let supportsHaptics = CHHapticEngine.capabilitiesForHardware().supportsHaptics

    private let impact = UIImpactFeedbackGenerator(style: .light)
    private let notification = UINotificationFeedbackGenerator()

    func play(_ earcon: Earcon) {
        AudioServicesPlaySystemSound(Self.soundID(for: earcon))
        playHaptic(for: earcon)
    }

    /// #110: `AudioServicesPlaySystemSound` routes through the SYSTEM-SOUND
    /// channel, not the media session the founder turns up to hear feedback over
    /// road noise — so the command ack can be inaudible in a moving car, and the
    /// 2.5 s skip undo-window is only real protection if he can perceive that a
    /// skip fired at all. Haptics survive ringer volume, silent mode and road
    /// noise, so the two COMMAND cues get one alongside the tone. The recording
    /// pair stays tone-only: it fires on every question and a buzz that often
    /// would train him to ignore it.
    private func playHaptic(for earcon: Earcon) {
        guard Self.supportsHaptics else { return }
        switch earcon {
        case .commandAck:
            impact.impactOccurred() // light tap — "heard you"
        case .skipConfirm:
            notification.notificationOccurred(.warning) // destructive, undoable for 2.5 s
        case .micLive, .gotIt:
            break
        }
    }

    private static func soundID(for earcon: Earcon) -> SystemSoundID {
        switch earcon {
        case .micLive:     return 1113 // begin_record.caf
        case .gotIt:       return 1114 // end_record.caf
        case .skipConfirm: return 1104 // Tock — distinct, cautionary
        case .commandAck:  return 1057 // Tink — light acknowledgement
        }
    }
}
