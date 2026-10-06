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
//  Five cues, one per meaningful transition:
//    • micLive    — the mic just opened (start recording)
//    • speechStart — the driver was first heard in this recording
//    • gotIt      — STOP: recording ended / was auto-submitted
//    • skipConfirm — the skip undo-window opened (destructive, tap/say to abort)
//    • commandAck — a spoken command was recognized
//
//  #188 G6 (founder 2026-10-06, after the car test: earcons were "really
//  annoying and frequent"): ONLY `micLive` still plays a tone. The other four
//  are haptic-only; every cue keeps its haptic. No new sound was added for the
//  silent stretches (thinking time, before the next question) — the next
//  question's voice and the "start" command already cover them. See
//  `Earcon.hasTone`. (#185 track F earlier made every cue quieter and gave each
//  a haptic, useful outside the car too.)
//
//  This ALSO delivers #68's record-start earcon item (micLive).
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
//  is synthesized in memory (`EarconTone`) rather than bundled: a short
//  sine cue, no assets, and the shape stays editable in one place.
//

import AudioToolbox
import AVFoundation
import CoreHaptics
import Foundation
import UIKit

/// The hands-free audio cues (77.10, #185 track F). Language-neutral tones — no words.
enum Earcon: String, CaseIterable, Sendable, Equatable {
    case micLive       // mic opened
    case speechStart   // #185 track F: the driver's answer was first heard
    case gotIt         // STOP: recording ended / auto-submitted
    case skipConfirm   // skip undo-window opened
    case commandAck    // a spoken command was recognized

    /// #188 G6 (founder 2026-10-06: earcons in the car were "really annoying and
    /// frequent"): the single policy for which cues make a sound. Only the
    /// mic-live tone ("the mic is open, talk now") earns one; every other cue is
    /// haptic-only. At most one tone per answer, never a tone for a state.
    var hasTone: Bool { self == .micLive }
}

/// The haptic that accompanies a cue (#185 track F: every cue has one). Pure so
/// "no cue without a haptic" is assertable without a Taptic Engine.
enum EarconHaptic: Equatable {
    /// `UIImpactFeedbackGenerator(style: .soft)` at this intensity.
    case soft(intensity: Double)
    /// `UIImpactFeedbackGenerator(style: .light)` — "heard you".
    case light

    static func haptic(for earcon: Earcon) -> EarconHaptic {
        switch earcon {
        // The recording cues fire on every question, so they are the softest
        // taps the engine makes — present, never a buzz to learn to ignore.
        case .micLive: return .soft(intensity: 0.7)
        case .speechStart: return .soft(intensity: 0.4)
        case .gotIt: return .soft(intensity: 0.6)
        case .commandAck: return .light
        // #188 G5 (founder 2026-10-06): a skip is not an error — a soft tap,
        // not the warning buzz. The two-tone cue still marks the undo window.
        case .skipConfirm: return .soft(intensity: 0.7)
        }
    }
}

/// Seam so the earcon player can be mocked in tests (assert exactly-one cue per
/// event, and none during TTS).
@MainActor
protocol EarconPlaying: AnyObject {
    /// The tone and its haptic.
    func play(_ earcon: Earcon)
    /// #185 track F (founder 2026-09-25): the haptic alone — "Recording
    /// sounds" off silences the tone, the tap still confirms the event.
    func playHaptic(_ earcon: Earcon)
}

/// Production earcon player: distinct built-in iOS system sounds per cue. System
/// sounds are language-neutral, need no bundled assets, and mix over the active
/// audio session without tearing down TTS/recording. IDs are stable Apple system
/// sounds; the exact tones are a starting point and can be swapped for bespoke
/// generated tones without touching any call site.
@MainActor
final class SystemEarconPlayer: EarconPlaying {
    /// The one player of the process. Its cached `AVAudioPlayer`s must outlive
    /// every cue they play: AVFoundation delivers `finishedPlaying:` to the
    /// player on the main run loop after the tone ends, and a player released
    /// mid-cue (its owner — a view model — went away within the 60–220 ms of a
    /// tone) crashes there with EXC_BAD_ACCESS → abort. Seen as intermittent
    /// "signal abrt" test crashes on CI (#186 step 2); a shared instance is
    /// never released, so no cue can outlive its player.
    static let shared = SystemEarconPlayer()

    private init() {}

    /// Whether this device has a Taptic Engine. Cached — the capability query is
    /// not free and the answer cannot change at runtime.
    private static let supportsHaptics = CHHapticEngine.capabilitiesForHardware().supportsHaptics

    private let impact = UIImpactFeedbackGenerator(style: .light)
    private let softImpact = UIImpactFeedbackGenerator(style: .soft)

    /// One prepared player per cue, built on first use and kept — decoding and
    /// `prepareToPlay()` cost is paid once, off the moment the driver needs the
    /// ack. `nil` for a cue whose player could not be built (see `player(for:)`).
    private var players: [Earcon: AVAudioPlayer] = [:]

    func play(_ earcon: Earcon) {
        guard earcon.hasTone else { // #188 G6: haptic-only cue
            playHaptic(earcon)
            return
        }
        if let player = player(for: earcon) {
            player.currentTime = 0 // re-trigger rather than stack overlapping cues
            player.play()
        } else {
            // Fail audible, not silent: the system-sound channel is the wrong
            // route (that is the whole point of #184) but it is better than no
            // cue at all if AVAudioPlayer construction ever fails.
            AudioServicesPlaySystemSound(Self.soundID(for: earcon))
        }
        playHaptic(earcon)
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

    /// #119: haptics survive ringer volume, silent mode and road noise, so the
    /// command cues got one alongside the tone. #185 track F (founder
    /// 2026-09-24): EVERY cue gets one now — outside the car (a party, a
    /// cottage) the phone is in a hand and the tap carries the cue when the
    /// quieter tone does not. The recording cues use the soft generator so
    /// a tap on every question never becomes a buzz. This is the only place
    /// the recording haptics fire (QuestionView's own `.sensoryFeedback` on
    /// entering recording is gone — two taps per cue would be noise).
    func playHaptic(_ earcon: Earcon) {
        guard Self.supportsHaptics else { return }
        switch EarconHaptic.haptic(for: earcon) {
        case let .soft(intensity):
            softImpact.impactOccurred(intensity: intensity)
        case .light:
            impact.impactOccurred()
        }
    }

    /// Fallback only (see `play`) — the pre-#184 system sounds.
    private static func soundID(for _: Earcon) -> SystemSoundID {
        1113 // begin_record.caf — only micLive has a tone (#188 G6)
    }
}


// MARK: - Tone synthesis (#184)

/// The in-memory tone generator behind `SystemEarconPlayer`. Pure and
/// value-only so the waveform can be tested without an audio device: it turns a
/// cue into a 16-bit mono 44.1 kHz WAV, which `AVAudioPlayer(data:)` accepts
/// directly.
///
/// The one tone left (#188 G6): rising two-step = "the mic OPENED". The shape
/// carries the meaning because the driver cannot look.
///
/// #185 track F (founder 2026-09-24: the tones were loud and grew tiresome):
/// 6 dB quieter (peak 0.5 → 0.25), lower (660 → 880 Hz) and a 20 ms
/// raised-cosine swell in and out instead of a 10 ms linear ramp — the hard
/// edges were what made it read as a beep.
enum EarconTone {
    /// One tone step, or — with a `nil` frequency — a silent gap.
    struct Segment: Sendable, Equatable {
        let frequency: Double?
        let duration: TimeInterval
    }

    static let sampleRate: Double = 44100
    /// Peak amplitude. Quarter scale (#185 track F; was half): the cue rides
    /// the same session and volume as the TTS, which the driver already set to
    /// be heard over the road, so it needs no headroom of its own.
    static let peak: Double = 0.25
    /// Raised-cosine fade at each end of every TONE segment. Without it the
    /// waveform starts mid-air and the discontinuity is audible as a click —
    /// which on a car speaker is louder than the tone itself; the cosine shape
    /// (#185 track F) also takes the edge off the attack.
    static let fadeDuration: TimeInterval = 0.020

    /// The tone sequence for a cue; empty for the haptic-only cues (#188 G6,
    /// see `Earcon.hasTone`).
    static func segments(for earcon: Earcon) -> [Segment] {
        guard earcon.hasTone else { return [] }
        return [Segment(frequency: 660, duration: 0.070), Segment(frequency: 880, duration: 0.070)]
    }

    /// The WAV bytes for a cue.
    static func wavData(for earcon: Earcon) -> Data {
        wavData(for: segments(for: earcon))
    }

    /// Render segments to a 16-bit mono PCM WAV (44-byte canonical RIFF header
    /// + samples).
    static func wavData(
        for segments: [Segment],
        sampleRate: Double = EarconTone.sampleRate
    ) -> Data {
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
                var ramp = 1.0
                if fadeSamples > 0 {
                    if index < fadeSamples {
                        ramp = Double(index) / Double(fadeSamples)
                    } else if index >= count - fadeSamples {
                        ramp = Double(count - 1 - index) / Double(fadeSamples)
                    }
                }
                // Raised cosine: 0 → 1 with a zero slope at both ends.
                let envelope = 0.5 - 0.5 * cos(.pi * ramp)
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
