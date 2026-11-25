//
//  EarconLoudnessTests.swift
//  HangsTests
//
//  TestFlight build 90 feedback (founder 2026-11-21): the volume jumped, the
//  mic-live tone sounded louder than the spoken questions. Measured offline:
//  at quarter scale the tone sat at about -17 LUFS while it sounds, as loud as
//  the questions (-16 to -17 LUFS integrated, all languages). The guard here
//  is the relationship the founder asked for, a subtle cue clearly under the
//  voice, measured against real question audio as the app receives it, not a
//  number on its own.
//
//  Fixtures: one question clip per voice from production (en and sk George,
//  cs Josef), the backend's mastered MP3s unchanged (`Resources/speech_*.mp3`).
//

import Foundation
@testable import Hangs
import Testing

private final class LoudnessBundleToken {}

@Suite("Earcon loudness against speech")
struct EarconLoudnessTests {
    /// How far under the quietest voice the tone must stay: about the gap at
    /// which a cue reads as "in the background" next to speech.
    static let minimumGapLU = 10.0

    nonisolated static let speechFixtures = ["speech_en_george", "speech_sk_george", "speech_cs_josef"]

    private func toneLoudness(_ earcon: Earcon = .micLive) -> Double {
        let data = EarconTone.wavData(for: earcon)
        let samples: [Float] = stride(from: 44, to: data.count, by: 2).map { offset in
            Float(Int16(bitPattern: UInt16(data[offset]) | UInt16(data[offset + 1]) << 8)) / Float(Int16.max)
        }
        return LoudnessMeter.whileSounding(samples, sampleRate: EarconTone.sampleRate)
    }

    private func speechLoudness(_ name: String) throws -> Double {
        let url = try #require(Bundle(for: LoudnessBundleToken.self).url(forResource: name, withExtension: "mp3"))
        let audio = try LoudnessMeter.read(url)
        return LoudnessMeter.integrated(audio.samples, sampleRate: audio.sampleRate)
    }

    /// WHY: a tone as loud as the question is the jump the founder heard; it
    /// is a cue, so it must sit clearly under every voice the app plays.
    @Test("The mic-live tone sits at least 10 LU under every voice", arguments: speechFixtures)
    func toneSitsUnderSpeech(_ fixture: String) throws {
        let speech = try speechLoudness(fixture)
        // A clip that failed to decode would read as silence and pass
        // nothing; mastered speech lands near -16 LUFS.
        #expect((-24.0 ... -10.0).contains(speech), "\(fixture) measured \(speech) LUFS, not mastered speech")
        let tone = toneLoudness()
        #expect(tone <= speech - Self.minimumGapLU, "tone \(tone) LUFS vs \(fixture) \(speech) LUFS")
    }

    /// WHY: quiet must not mean gone. A tone 30 LU or more under the voice
    /// is lost in road noise, and the driver no longer hears the mic open.
    @Test("The mic-live tone stays audible next to speech", arguments: speechFixtures)
    func toneStaysAudible(_ fixture: String) throws {
        let speech = try speechLoudness(fixture)
        #expect(toneLoudness() > speech - 20, "the tone would vanish under road noise")
    }

    /// WHY (founder 2026-11-22, decision 4): a recognised command answers with
    /// one quiet, very short tick. It confirms a word the player just said, so
    /// it must sit under the mic tone (which asks them to start talking) and
    /// be over before the action it confirms is heard.
    @Test("The command tick is quieter and much shorter than the mic-live tone")
    func tickSitsUnderMicTone() {
        #expect(Earcon.commandAck.hasTone)
        #expect(toneLoudness(.commandAck) <= toneLoudness(.micLive) - 3, "the tick must be quieter than the mic tone")
        let tickSecs = EarconTone.segments(for: .commandAck).map(\.duration).reduce(0, +)
        let micSecs = EarconTone.segments(for: .micLive).map(\.duration).reduce(0, +)
        #expect(tickSecs > 0 && tickSecs <= 0.05, "a tick, not a beep: \(tickSecs) s")
        #expect(tickSecs < micSecs / 2)
    }
}
