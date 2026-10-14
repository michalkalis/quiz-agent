//
//  RoadNoiseReplay.swift
//  HangsTests
//
//  #204 track 204.3: replays a spoken answer over synthetic road noise through
//  the REAL answer detector — `SilenceDetectionService.handleInputLevel` on a
//  `TestClock`, fed exactly what the mic tap would feed it (the level meter,
//  and with the neural detector on, the bundled Silero model's probability).
//
//  Speech: `say` clips (Laura sk-SK, Daniel en-GB) resampled to 16 kHz, in
//  HangsTests/Resources. Noise: seeded pink + brown noise (tyre roar and
//  rumble) whose level can swell after the answer — the passing truck / rough
//  asphalt stretch that kept the energy detector "hearing speech" until the
//  cap in 4 of the 7 capped car answers (Sentry 2026-10-10).
//

import AVFoundation
import Clocks
import Foundation
@testable import Hangs

private final class ReplayBundleToken {}

enum ReplayFixture {
    static func speech(_ name: String) throws -> [Float] {
        guard let url = Bundle(for: ReplayBundleToken.self).url(forResource: name, withExtension: "wav") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard file.processingFormat.sampleRate == SileroVAD.sampleRate,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
        else { throw CocoaError(.fileReadCorruptFile) }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else { throw CocoaError(.fileReadCorruptFile) }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    /// RMS of the samples above -60 dBFS — for speech, the level while talking.
    static func rms(_ samples: [Float]) -> Float {
        let active = samples.filter { abs($0) > 1e-3 }
        guard !active.isEmpty else { return 0 }
        return (active.reduce(0) { $0 + $1 * $1 } / Float(active.count)).squareRoot()
    }

    static func amplitude(_ db: Float) -> Float {
        pow(10, db / 20)
    }
}

/// Seeded road noise: pink (Kellet filter) for tyre roar plus brown for
/// rumble, RMS-calibrated so `levelDb` is the RMS dBFS of the mix.
struct RoadNoise {
    private var source = SeededNoise(seed: 0x204_3)
    private var pink = [Float](repeating: 0, count: 7)
    private var brown: Float = 0

    mutating func samples(count: Int, levelDb: (Int) -> Float) -> [Float] {
        let raw = (0 ..< count).map { _ in
            let white = source.next() * 0.5
            pink[0] = 0.99886 * pink[0] + white * 0.0555179
            pink[1] = 0.99332 * pink[1] + white * 0.0750759
            pink[2] = 0.96900 * pink[2] + white * 0.1538520
            pink[3] = 0.86650 * pink[3] + white * 0.3104856
            pink[4] = 0.55000 * pink[4] + white * 0.5329522
            pink[5] = -0.7616 * pink[5] - white * 0.0168980
            let pinkValue = (pink[0] + pink[1] + pink[2] + pink[3] + pink[4] + pink[5] + pink[6] + white * 0.5362) * 0.11
            pink[6] = white * 0.115926
            brown = (brown + white * 0.02) * 0.995
            return pinkValue + brown * 3
        }
        let unitRMS = max(ReplayFixture.rms(raw), 1e-6)
        return raw.enumerated().map { index, value in
            value / unitRMS * ReplayFixture.amplitude(levelDb(index))
        }
    }
}

/// One answer recording: lead-in noise, the answer, then noise that may swell.
struct CabinAnswer {
    var speech: [Float]
    var speechDb: Float = -26
    var leadInSecs = 1.0
    var totalSecs = 8.0
    var noiseDb: Float = -42
    /// How far the noise rises after the answer (0 = steady road).
    var swellDb: Float = 0

    var speechEndSecs: Double {
        leadInSecs + Double(speech.count) / SileroVAD.sampleRate
    }

    func mix() -> [Float] {
        let rate = SileroVAD.sampleRate
        let total = Int(totalSecs * rate)
        let start = Int(leadInSecs * rate)
        let swellFrom = start + speech.count
        let rampFrames = Int(0.5 * rate)
        var noise = RoadNoise()
        var out = noise.samples(count: total) { index in
            guard index > swellFrom else { return noiseDb }
            return noiseDb + swellDb * min(1, Float(index - swellFrom) / Float(rampFrames))
        }
        let gain = ReplayFixture.amplitude(speechDb) / max(ReplayFixture.rms(speech), 1e-6)
        for (offset, value) in speech.enumerated() where start + offset < total {
            out[start + offset] += value * gain
        }
        return out
    }
}

/// What the detector did with one recording.
struct ReplayOutcome {
    /// Audio time of the auto-stop (`silenceAfterSpeech`), `nil` = it would
    /// have run to the cap.
    var stopSecs: Double?
    var firstSpeechSecs: Double?
    var report: AnswerDetectionReport
    var noSpeechVerdictAt5s: NoSpeechWindowVerdict?
}

@MainActor
enum DetectorReplay {
    static let bufferFrames = 320 // 20 ms — whole milliseconds for the TestClock

    /// Feed `samples` buffer by buffer as the tap does; stop at the first
    /// auto-stop, like the recording coordinator.
    /// `scoreUntilSecs` keeps the model switched on for the window but stops
    /// it scoring from that audio time on — a model that broke (0 = before
    /// its first window).
    static func run(_ samples: [Float], neural vad: SileroVAD?, scoreUntilSecs: Double = .infinity) async -> ReplayOutcome {
        let clock = TestClock()
        let service = SilenceDetectionService(clock: AnyClock(clock))
        if let vad {
            vad.reset()
            service.sileroVAD = vad
            service.neuralVADRequested = true
            service.neuralVADActive = true
        }
        let events = service.makeSilenceEventStream()
        let stopped = StopFlag()
        let collector = Task { @MainActor in
            for await event in events {
                if case .silenceAfterSpeech = event { stopped.value = true }
            }
        }
        service.beginAnswerDetection(minSpeechDuration: VADTuning.minSpeechDurationSecs)

        var meter = InputLevelMeter(sampleRate: SileroVAD.sampleRate)
        var outcome = ReplayOutcome(report: .empty)
        var audioSecs = 0.0
        for start in stride(from: 0, to: samples.count, by: bufferFrames) {
            let buffer = Array(samples[start ..< min(start + bufferFrames, samples.count)])
            guard var sample = meter.measure(buffer) else { continue }
            if let vad, audioSecs < scoreUntilSecs { sample.speechScore = vad.process(buffer) }
            service.handleInputLevel(sample)
            await clock.advance(by: .milliseconds(20))
            await Task.yield()
            audioSecs += sample.duration
            if outcome.noSpeechVerdictAt5s == nil, audioSecs >= 5 {
                outcome.noSpeechVerdictAt5s = service.noSpeechWindowVerdict
            }
            if stopped.value {
                outcome.stopSecs = audioSecs
                break
            }
        }
        outcome.report = service.endAnswerDetection()
        outcome.firstSpeechSecs = outcome.report.firstSpeechMs.map { Double($0) / 1000 }
        collector.cancel()
        return outcome
    }

    @MainActor
    private final class StopFlag {
        var value = false
    }
}
