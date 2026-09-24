//
//  EnergyVAD.swift
//  Hangs
//
//  #185 track A (car test 2026-09-23): the on-device speech signal. 16 of 16
//  answer recordings ran into the 5 s "start speaking" window because Apple's
//  SpeechDetector never reports speech (its result stream carries VAD-model
//  errors only — see `VADTuning.commandGateSensitivity`). This is the
//  replacement: a level detector that measures each tap buffer above an
//  engine-rumble high-pass and calls it speech when the level stays clearly
//  above the noise floor measured at the start of the recording.
//
//  Two value types, both pure so they run on synthetic PCM in tests:
//  • `InputLevelMeter` — audio-thread side: band-limited RMS of one buffer.
//  • `EnergyVAD`       — main-actor side: noise floor + speech/non-speech.
//

@preconcurrency import AVFoundation
import Foundation

/// One tap buffer, measured: band-limited RMS level and how much audio it held.
nonisolated struct InputLevelSample: Sendable, Equatable {
    let db: Float
    let duration: TimeInterval
}

/// Band-limited RMS level of each buffer the mic tap delivers. Filter state
/// carries across buffers (one meter per listening engine), so it lives with
/// the tap, behind a lock, on the audio thread.
nonisolated struct InputLevelMeter: Sendable {
    let sampleRate: Double
    private var first: HighPassBiquad
    private var second: HighPassBiquad

    init(sampleRate: Double, highPassHz: Double = VADTuning.energyHighPassHz) {
        self.sampleRate = sampleRate
        first = HighPassBiquad(cutoffHz: highPassHz, sampleRate: sampleRate)
        second = first
    }

    /// Level of one analyzer-format buffer (Float32 or Int16 mono — the two
    /// formats `SpeechAnalyzer` negotiates). `nil` for an empty buffer.
    mutating func measure(_ buffer: AVAudioPCMBuffer) -> InputLevelSample? {
        let frames = Int(buffer.frameLength)
        guard frames > 0, sampleRate > 0 else { return nil }
        var sumOfSquares = 0.0
        if let float = buffer.floatChannelData {
            let channel = float[0]
            for index in 0 ..< frames {
                sumOfSquares += filteredSquare(Double(channel[index]))
            }
        } else if let int16 = buffer.int16ChannelData {
            let channel = int16[0]
            for index in 0 ..< frames {
                sumOfSquares += filteredSquare(Double(channel[index]) / 32768)
            }
        } else {
            return nil
        }
        return sample(sumOfSquares: sumOfSquares, frames: frames)
    }

    /// The same measurement over plain samples (full scale ±1) — the test seam.
    mutating func measure(_ samples: [Float]) -> InputLevelSample? {
        guard !samples.isEmpty, sampleRate > 0 else { return nil }
        var sumOfSquares = 0.0
        for value in samples {
            sumOfSquares += filteredSquare(Double(value))
        }
        return sample(sumOfSquares: sumOfSquares, frames: samples.count)
    }

    private mutating func filteredSquare(_ value: Double) -> Double {
        let filtered = second.process(first.process(value))
        return filtered * filtered
    }

    private func sample(sumOfSquares: Double, frames: Int) -> InputLevelSample {
        let meanSquare = sumOfSquares / Double(frames)
        let db = meanSquare > 1e-16 ? Float(10 * log10(meanSquare)) : -160
        return InputLevelSample(db: db, duration: Double(frames) / sampleRate)
    }
}

/// 2nd-order Butterworth high-pass (RBJ cookbook), transposed direct form II.
nonisolated struct HighPassBiquad: Sendable {
    private let b0: Double
    private let b1: Double
    private let b2: Double
    private let a1: Double
    private let a2: Double
    private var z1 = 0.0
    private var z2 = 0.0

    init(cutoffHz: Double, sampleRate: Double) {
        // Keep the corner below Nyquist so an 8 kHz narrowband route stays stable.
        let cutoff = min(cutoffHz, sampleRate * 0.45)
        let omega = 2 * Double.pi * cutoff / sampleRate
        let alpha = sin(omega) / (2 * 0.5.squareRoot()) // Q = 1/√2
        let cosine = cos(omega)
        let a0 = 1 + alpha
        b0 = (1 + cosine) / 2 / a0
        b1 = -(1 + cosine) / a0
        b2 = (1 + cosine) / 2 / a0
        a1 = -2 * cosine / a0
        a2 = (1 - alpha) / a0
    }

    mutating func process(_ input: Double) -> Double {
        let output = b0 * input + z1
        z1 = b1 * input - a1 * output + z2
        z2 = b2 * input - a2 * output
        return output
    }
}

/// Speech / non-speech from per-buffer levels, relative to a noise floor.
///
/// The floor is the lower quartile of the first `calibrationSecs` of levels
/// (a word spoken straight away sits in the upper quartiles), then follows the
/// noise between words — down fast, up slowly, frozen during speech. Speech
/// starts after the level held `onsetMarginDb` above the floor for
/// `onsetHoldSecs` (a click or a bump is shorter) and ends when it falls below
/// `releaseMarginDb`. Time is AUDIO time (buffer durations), so the same
/// samples always give the same answer.
nonisolated struct EnergyVAD: Sendable {
    struct Tuning: Sendable, Equatable {
        var calibrationSecs = VADTuning.noiseCalibrationSecs
        var onsetMarginDb = VADTuning.speechOnsetMarginDb
        var releaseMarginDb = VADTuning.speechReleaseMarginDb
        var onsetHoldSecs = VADTuning.speechOnsetHoldSecs
        var absoluteSpeechFloorDbfs = VADTuning.absoluteSpeechFloorDbfs
        var floorFallSecs = VADTuning.noiseFloorFallSecs
        var floorRiseSecs = VADTuning.noiseFloorRiseSecs
    }

    let tuning: Tuning

    /// `nil` until the first `calibrationSecs` of audio have been measured.
    private(set) var noiseFloorDb: Float?
    private(set) var isSpeech = false
    /// Loudest buffer since the last reset (telemetry: did audio get through?).
    private(set) var peakDb: Float?
    /// Audio time above the release margin that did NOT become speech — the
    /// "maybe someone is talking" the no-speech window must respect.
    private(set) var ambiguousSecs: TimeInterval = 0

    private var calibrationLevels: [Float] = []
    private var calibrationSecs: TimeInterval = 0
    private var aboveOnsetSecs: TimeInterval = 0

    init(tuning: Tuning = Tuning()) {
        self.tuning = tuning
    }

    /// Feed one buffer's level; returns whether speech is active after it.
    @discardableResult
    mutating func process(_ sample: InputLevelSample) -> Bool {
        peakDb = max(peakDb ?? sample.db, sample.db)
        guard let floor = noiseFloorDb else {
            calibrate(with: sample)
            return false
        }

        let onset = max(floor + tuning.onsetMarginDb, tuning.absoluteSpeechFloorDbfs)
        let release = onset - (tuning.onsetMarginDb - tuning.releaseMarginDb)

        if isSpeech {
            if sample.db < release { isSpeech = false }
            return isSpeech
        }

        if sample.db >= release { ambiguousSecs += sample.duration }
        if sample.db >= onset {
            aboveOnsetSecs += sample.duration
            // 1 µs of slack: buffer durations are fractional, the hold is not.
            if aboveOnsetSecs + 1e-6 >= tuning.onsetHoldSecs {
                isSpeech = true
                aboveOnsetSecs = 0
            }
            return isSpeech
        }

        aboveOnsetSecs = 0
        let timeConstant = sample.db < floor ? tuning.floorFallSecs : tuning.floorRiseSecs
        let weight = Float(1 - exp(-sample.duration / timeConstant))
        noiseFloorDb = floor + (sample.db - floor) * weight
        return false
    }

    private mutating func calibrate(with sample: InputLevelSample) {
        calibrationLevels.append(sample.db)
        calibrationSecs += sample.duration
        guard calibrationSecs + 1e-6 >= tuning.calibrationSecs else { return }
        let sorted = calibrationLevels.sorted()
        noiseFloorDb = sorted[sorted.count / 4]
        calibrationLevels = []
    }
}
