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
//  #184 (car-noise field test): the cues moved off `AudioServicesPlaySystemSound`
//  and onto `AVAudioPlayer` over the app's shared session. System sounds play on
//  the SYSTEM-SOUND channel — ringer volume, and on a phone routed to the car
//  over A2DP/CarPlay they can be swallowed entirely — so the founder heard no
//  ack at all while driving. TTS already reaches the car speakers; these tones
//  now take the same route, at the same volume the driver set for it. The tones
//  are synthesized in memory (`EarconTone`) rather than bundled: four short
//  sine cues, no assets, and the shapes stay editable in one place.
//

import AudioToolbox
import AVFoundation
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

    /// One prepared player per cue, built on first use and kept — decoding and
    /// `prepareToPlay()` cost is paid once, off the moment the driver needs the
    /// ack. `nil` for a cue whose player could not be built (see `player(for:)`).
    private var players: [Earcon: AVAudioPlayer] = [:]

    func play(_ earcon: Earcon) {
        if let player = player(for: earcon) {
            player.currentTime = 0 // re-trigger rather than stack overlapping cues
            player.play()
        } else {
            // Fail audible, not silent: the system-sound channel is the wrong
            // route (that is the whole point of #184) but it is better than no
            // cue at all if AVAudioPlayer construction ever fails.
            AudioServicesPlaySystemSound(Self.soundID(for: earcon))
        }
        playHaptic(for: earcon)
    }

    /// The cached player for `earcon`, synthesized on first request. Does NOT
    /// touch the audio session category/mode — the cue rides whatever session
    /// the quiz already configured for TTS, which is exactly the route the
    /// driver can hear.
    private func player(for earcon: Earcon) -> AVAudioPlayer? {
        if let cached = players[earcon] { return cached }
        guard let player = try? AVAudioPlayer(data: EarconTone.wavData(for: earcon)) else {
            return nil
        }
        player.prepareToPlay()
        players[earcon] = player
        return player
    }

    /// #119: `AudioServicesPlaySystemSound` routes through the SYSTEM-SOUND
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

    /// Fallback only (see `play`) — the pre-#184 system sounds.
    private static func soundID(for earcon: Earcon) -> SystemSoundID {
        switch earcon {
        case .micLive:     return 1113 // begin_record.caf
        case .gotIt:       return 1114 // end_record.caf
        case .skipConfirm: return 1104 // Tock — distinct, cautionary
        case .commandAck:  return 1057 // Tink — light acknowledgement
        }
    }
}


// MARK: - Tone synthesis (#184)

/// The in-memory tone generator behind `SystemEarconPlayer`. Pure and
/// value-only so the waveform can be tested without an audio device: it turns a
/// cue into a 16-bit mono 44.1 kHz WAV, which `AVAudioPlayer(data:)` accepts
/// directly.
///
/// Each cue's SHAPE carries its meaning, since the driver cannot look:
/// rising = something opened, falling = something closed, low repeated = a
/// destructive action you may still undo, one high blip = "heard you".
enum EarconTone {
    /// One tone step, or — with a `nil` frequency — a silent gap.
    struct Segment: Sendable, Equatable {
        let frequency: Double?
        let duration: TimeInterval
    }

    static let sampleRate: Double = 44100
    /// Peak amplitude. Half scale: the cue must cut through road noise without
    /// clipping when it mixes over TTS on the same session.
    static let peak: Double = 0.5
    /// Linear fade at each end of every TONE segment. Without it the waveform
    /// starts mid-air and the discontinuity is audible as a click — which on a
    /// car speaker is louder than the tone itself.
    static let fadeDuration: TimeInterval = 0.010

    /// The tone sequence for a cue.
    static func segments(for earcon: Earcon) -> [Segment] {
        switch earcon {
        // Rising two-step — the mic OPENED.
        case .micLive:
            return [Segment(frequency: 880, duration: 0.070), Segment(frequency: 1175, duration: 0.070)]
        // The same two steps falling — the mic CLOSED. Deliberately the mirror
        // of micLive so the pair is learnable as one gesture.
        case .gotIt:
            return [Segment(frequency: 1175, duration: 0.070), Segment(frequency: 880, duration: 0.070)]
        // Low, repeated, with a gap — a warning shape, matching the 2.5 s undo
        // window it announces.
        case .skipConfirm:
            return [
                Segment(frequency: 440, duration: 0.090),
                Segment(frequency: nil, duration: 0.040),
                Segment(frequency: 440, duration: 0.090),
            ]
        // One short high blip — the cheapest possible "heard you"; it fires on
        // every recognized command, so it must never feel heavy.
        case .commandAck:
            return [Segment(frequency: 1320, duration: 0.060)]
        }
    }

    /// The WAV bytes for a cue.
    static func wavData(for earcon: Earcon) -> Data {
        wavData(for: segments(for: earcon))
    }

    /// Render segments to a 16-bit mono PCM WAV (44-byte canonical RIFF header
    /// + samples).
    static func wavData(for segments: [Segment], sampleRate: Double = EarconTone.sampleRate) -> Data {
        var samples: [Int16] = []
        for segment in segments {
            let count = Int((segment.duration * sampleRate).rounded())
            guard count > 0 else { continue }
            guard let frequency = segment.frequency else {
                samples.append(contentsOf: repeatElement(0, count: count))
                continue
            }
            let fadeSamples = min(Int((fadeDuration * sampleRate).rounded()), count / 2)
            for index in 0 ..< count {
                let value = sin(2 * .pi * frequency * Double(index) / sampleRate)
                var envelope = 1.0
                if fadeSamples > 0 {
                    if index < fadeSamples {
                        envelope = Double(index) / Double(fadeSamples)
                    } else if index >= count - fadeSamples {
                        envelope = Double(count - 1 - index) / Double(fadeSamples)
                    }
                }
                let scaled = value * envelope * peak * Double(Int16.max)
                samples.append(Int16(scaled.rounded()))
            }
        }
        var pcm = Data(capacity: samples.count * 2)
        for sample in samples {
            var little = sample.littleEndian
            withUnsafeBytes(of: &little) { pcm.append(contentsOf: $0) }
        }
        // The RIFF container is #184 track B's `WAVEncoder` — one WAV writer in
        // the app, not two.
        return WAVEncoder.wav(pcm16: pcm, sampleRate: Int(sampleRate))
    }
}
