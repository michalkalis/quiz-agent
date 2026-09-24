//
//  EnergyVADTests.swift
//  HangsTests
//
//  #185 track A (car test 2026-09-23): the energy detector that replaced the
//  SpeechDetector as the speech signal. Driven with seeded synthetic cabin
//  audio (SyntheticCabinAudio.swift) through the SAME meter the mic tap uses,
//  so each test exercises high-pass → level → noise floor → decision.
//
//  The scenario that matters: a loud engine tone, road hiss, and a driver
//  answering at normal voice — 20 dB below the engine in raw level. Without
//  the high-pass the voice vanishes in the rumble; without the onset hold a
//  click is an answer; without the calibration quartile an answer spoken
//  straight away blinds the detector.
//

import AVFoundation
import Foundation
@testable import Hangs
import Testing

@Suite("#185 EnergyVAD on synthetic cabin audio")
struct EnergyVADTests {
    /// WHY: the car failure mode. Engine and road rumble are the loudest thing
    /// the mic hears; if they counted, every rev would be "speech" and the
    /// no-speech window could never close on a silent driver.
    @Test("engine rumble — even revving 10 dB — never counts as speech")
    func rumbleIsNotSpeech() {
        var cabin = SyntheticCabin()
        var run = DetectorRun()
        run.feed(cabin.segment(seconds: 1))
        run.feed(cabin.segment(seconds: 2, rumbleBoostDb: 10))

        #expect(run.speechTimes.isEmpty, "rumble triggered speech at \(run.speechTimes.prefix(3))")
        #expect(
            run.vad.ambiguousSecs < VADTuning.ambiguousActivityMaxSecs,
            "a rev must not read as 'maybe speech' either — the silent driver's window must still close"
        )
    }

    /// WHY: the answer itself. The voice sits 30 dB under the raw engine level
    /// and 12 dB over the hiss; the high-pass is what makes it visible.
    @Test("a normal-voice answer over loud rumble is heard within ~150 ms and released after it")
    func speechOverRumbleIsDetected() throws {
        var cabin = SyntheticCabin()
        var run = DetectorRun()
        run.feed(cabin.segment(seconds: 1))
        run.feed(cabin.segment(seconds: 1.2, speechDb: -38))
        run.feed(cabin.segment(seconds: 1))

        let onset = try #require(run.speechTimes.first, "the answer was never detected")
        // The synthetic syllable rises from a trough at 1.0 s; the onset hold
        // adds 60 ms on top.
        #expect(onset >= 1.0 && onset < 1.15, "onset at \(onset) s — expected within ~150 ms of 1.0 s")
        #expect(!run.heardSpeech(between: 2.4, and: 3.2), "speech must end once the voice stops")
        let floor = try #require(run.vad.noiseFloorDb)
        #expect(abs(floor - cabin.hissDb) < 3, "floor \(floor) dB should sit at the hiss (\(cabin.hissDb) dB), not the rumble")
    }

    /// WHY: the MCQ answer is one syllable ("c", "dva") — ~150 ms of voice.
    @Test("a single 150 ms syllable is heard")
    func shortSyllableIsDetected() {
        var cabin = SyntheticCabin()
        var run = DetectorRun()
        run.feed(cabin.segment(seconds: 1))
        run.feed(cabin.segment(seconds: 0.15, speechDb: -38))
        run.feed(cabin.segment(seconds: 0.5))

        #expect(run.heardSpeech(between: 1.0, and: 1.2), "the syllable was missed")
    }

    /// WHY: a click, a door, a pothole is loud but short — it must not become
    /// an answer (the onset hold).
    @Test("a loud 30 ms click is not speech")
    func clickIsNotSpeech() {
        var cabin = SyntheticCabin()
        var run = DetectorRun()
        run.feed(cabin.segment(seconds: 1))
        var click = cabin.segment(seconds: 0.03)
        var noise = SeededNoise(seed: 7)
        for index in click.indices { click[index] += 0.3 * noise.next() }
        run.feed(click)
        run.feed(cabin.segment(seconds: 1))

        #expect(run.speechTimes.isEmpty, "a click read as speech at \(run.speechTimes)")
    }

    /// WHY: the floor is measured at the start of every recording, and a driver
    /// may already be talking. One early word must not blind the detector for
    /// the rest of the answer — the floor falls back to the noise between words.
    @Test("an answer spoken straight away does not blind the detector for the next words")
    func earlySpeechDoesNotBlind() {
        var cabin = SyntheticCabin()
        var run = DetectorRun()
        run.feed(cabin.segment(seconds: 1.0, speechDb: -38))
        run.feed(cabin.segment(seconds: 1.0))
        run.feed(cabin.segment(seconds: 0.8, speechDb: -38))

        #expect(run.heardSpeech(between: 2.0, and: 2.8), "the second word was missed — floor stuck on the first")
    }

    /// WHY: the tap hands over whichever format the analyzer negotiated
    /// (Float32 or Int16). Both must measure the same level, or the detector's
    /// margins mean different things per device.
    @Test("Int16 and Float32 buffers measure the same level")
    func int16AndFloatAgree() throws {
        var cabin = SyntheticCabin()
        let samples = cabin.segment(seconds: 0.02, speechDb: -30)
        let floatBuffer = try #require(Self.buffer(samples, format: .pcmFormatFloat32))
        let intBuffer = try #require(Self.buffer(samples, format: .pcmFormatInt16))
        var floatMeter = InputLevelMeter(sampleRate: SyntheticCabin.sampleRate)
        var intMeter = InputLevelMeter(sampleRate: SyntheticCabin.sampleRate)

        let floatMeasured = floatMeter.measure(floatBuffer)
        let intMeasured = intMeter.measure(intBuffer)
        let floatLevel = try #require(floatMeasured)
        let intLevel = try #require(intMeasured)

        #expect(abs(floatLevel.db - intLevel.db) < 0.2, "Float32 \(floatLevel.db) vs Int16 \(intLevel.db)")
        #expect(abs(floatLevel.duration - 0.02) < 1e-9)
    }

    private static func buffer(_ samples: [Float], format commonFormat: AVAudioCommonFormat) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(
            commonFormat: commonFormat, sampleRate: SyntheticCabin.sampleRate, channels: 1, interleaved: false
        ), let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for (index, value) in samples.enumerated() {
            if let float = buffer.floatChannelData {
                float[0][index] = value
            } else if let int16 = buffer.int16ChannelData {
                int16[0][index] = Int16(max(-1, min(1, value)) * Float(Int16.max))
            }
        }
        return buffer
    }
}
