//
//  SyntheticCabinAudio.swift
//  HangsTests
//
//  #185 track A: deterministic car-cabin PCM for the speech-detector tests —
//  a loud low engine tone, broadband road hiss and a voiced, syllable-shaped
//  "speech" signal, all from a seeded generator so every run is identical.
//  Levels are RMS dBFS of each component on its own (full scale = ±1).
//

import Foundation
@testable import Hangs

/// xorshift64* — a tiny seeded PRNG so the noise is the same on every run.
struct SeededNoise {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    }

    /// Uniform in [-1, 1] (RMS 1/√3).
    mutating func next() -> Float {
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        let value = state &* 2_685_821_657_736_338_717
        return Float(Double(value >> 11) / Double(UInt64(1) << 53)) * 2 - 1
    }
}

struct SyntheticCabin {
    static let sampleRate = 16000.0
    /// 20 ms buffers — whole milliseconds, so a test clock can follow audio time.
    static let bufferFrames = 320
    static var bufferDuration: Duration { .milliseconds(20) }

    /// Engine tone (45 Hz — well below the detector's high-pass).
    var rumbleDb: Float = -20
    /// Broadband road/wind hiss — the noise that survives the high-pass.
    var hissDb: Float = -50

    private var noise = SeededNoise(seed: 0x185A)
    private var sampleIndex = 0

    /// `seconds` of cabin audio with `speechDb` of voice on top (`nil` = no
    /// voice) and the engine revved by `rumbleBoostDb`. Consecutive calls
    /// continue the same waveform.
    mutating func segment(
        seconds: Double,
        speechDb: Float? = nil,
        rumbleBoostDb: Float = 0
    ) -> [Float] {
        let count = Int((seconds * Self.sampleRate).rounded())
        let rumbleAmplitude = Self.amplitude(rumbleDb + rumbleBoostDb) * 2.0.squareRoot()
        let hissScale = Self.amplitude(hissDb) * 3.0.squareRoot()
        let speechScale = speechDb.map { Self.amplitude($0) / Self.unitSpeechRMS } ?? 0
        var out = [Float](repeating: 0, count: count)
        for index in 0 ..< count {
            let time = Double(sampleIndex) / Self.sampleRate
            var value = rumbleAmplitude * sin(2 * .pi * 45 * time)
            value += hissScale * Double(noise.next())
            if speechScale > 0 { value += speechScale * Self.unitSpeech(at: time) }
            out[index] = Float(value)
            sampleIndex += 1
        }
        return out
    }

    /// Split into the tap's buffers.
    static func buffers(_ samples: [Float]) -> [[Float]] {
        stride(from: 0, to: samples.count, by: bufferFrames).map {
            Array(samples[$0 ..< min($0 + bufferFrames, samples.count)])
        }
    }

    /// Voiced speech stand-in: 140 Hz fundamental plus harmonics to ~2.8 kHz
    /// (amplitude 1/√k), shaped by a 4 Hz syllable envelope that dips to 30 %.
    private static func unitSpeech(at time: Double) -> Double {
        let envelope = 0.65 - 0.35 * cos(2 * .pi * 4 * time)
        var sum = 0.0
        for harmonic in 1 ... 20 {
            sum += sin(2 * .pi * 140 * Double(harmonic) * time) / Double(harmonic).squareRoot()
        }
        return envelope * sum
    }

    /// RMS of `unitSpeech`: harmonic powers Σ(1/k)/2 times the envelope's mean
    /// square (0.65² + 0.35²/2).
    private static let unitSpeechRMS: Double = {
        let harmonicPower = (1 ... 20).reduce(0.0) { $0 + 1 / Double($1) } / 2
        return (harmonicPower * (0.65 * 0.65 + 0.35 * 0.35 / 2)).squareRoot()
    }()

    private static func amplitude(_ db: Float) -> Double {
        pow(10, Double(db) / 20)
    }
}

/// Run PCM through the tap's meter and the detector the way production does.
struct DetectorRun {
    var meter = InputLevelMeter(sampleRate: SyntheticCabin.sampleRate)
    var vad = EnergyVAD()
    private(set) var elapsed: TimeInterval = 0
    /// Audio times (start of buffer) at which the detector said speech.
    private(set) var speechTimes: [TimeInterval] = []

    mutating func feed(_ samples: [Float]) {
        for buffer in SyntheticCabin.buffers(samples) {
            guard let level = meter.measure(buffer) else { continue }
            if vad.process(level) { speechTimes.append(elapsed) }
            elapsed += level.duration
        }
    }

    func heardSpeech(between start: TimeInterval, and end: TimeInterval) -> Bool {
        speechTimes.contains { $0 >= start && $0 < end }
    }
}
