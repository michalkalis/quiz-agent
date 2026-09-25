//
//  AnswerAudioConditioningTests.swift
//  HangsTests
//
//  #185 track C — what an answer sample uploads and records once voice
//  processing is off in the car. Why these tests matter:
//  - The founder wants Scribe's input unchanged by default: with the switch
//    off the upload must be the captured WAV byte for byte.
//  - With the switch on, the high-pass must actually strip the engine/road
//    rumble voice processing used to suppress, and the normalization must
//    lift a quiet answer without boosting near-silence into loud noise.
//  - The sidecar is how the offline comparison splits the car cells (route,
//    policy mode, what was uploaded); #184 samples on the founder's phone
//    must still decode.
//

import Foundation
@testable import Hangs
import Testing

private let rate = 16000

private func pcm16(_ samples: [Double]) -> Data {
    var data = Data(capacity: samples.count * 2)
    for value in samples {
        let sample = Int16(max(-32768, min(32767, (value * 32768).rounded())))
        withUnsafeBytes(of: sample.littleEndian) { data.append(contentsOf: $0) }
    }
    return data
}

private func samples(_ pcm: Data) -> [Double] {
    pcm.withUnsafeBytes { raw in
        (0 ..< pcm.count / 2).map {
            Double(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self))) / 32768
        }
    }
}

private func sine(_ hz: Double, amplitude: Double, seconds: Double = 1) -> [Double] {
    (0 ..< Int(Double(rate) * seconds)).map { amplitude * sin(2 * .pi * hz * Double($0) / Double(rate)) }
}

/// Amplitude of the `hz` component (one DFT bin), past the filter's settling.
private func amplitude(of hz: Double, in signal: [Double]) -> Double {
    let steady = signal.dropFirst(rate / 4)
    var re = 0.0, im = 0.0
    for (offset, value) in steady.enumerated() {
        let phase = 2 * .pi * hz * Double(offset) / Double(rate)
        re += value * cos(phase)
        im += value * sin(phase)
    }
    return 2 * (re * re + im * im).squareRoot() / Double(steady.count)
}

@Suite("Answer upload conditioning (#185 C)")
struct AnswerAudioConditioningTests {
    @Test("switch off: Scribe gets the captured WAV byte for byte")
    func offIsUntouched() {
        let wav = WAVEncoder.wav(pcm16: pcm16(sine(300, amplitude: 0.1)), sampleRate: rate)

        let upload = AnswerAudioConditioning.uploadWAV(raw: wav, sampleRate: rate, enabled: false)

        #expect(upload.wav == wav)
        #expect(upload.label == "raw")
    }

    @Test("switch on: engine rumble loses to the voice band by more than 10 dB")
    func highPassStripsRumble() {
        // A car cabin: loud 50 Hz drone under a quiet voice-band tone.
        let rumble = sine(50, amplitude: 0.3)
        let voice = sine(1000, amplitude: 0.05)
        let mixed = zip(rumble, voice).map(+)
        let wav = WAVEncoder.wav(pcm16: pcm16(mixed), sampleRate: rate)

        let upload = AnswerAudioConditioning.uploadWAV(raw: wav, sampleRate: rate, enabled: true)
        let out = samples(upload.wav.dropFirst(WAVEncoder.headerSize))

        let before = amplitude(of: 1000, in: mixed) / amplitude(of: 50, in: mixed)
        let after = amplitude(of: 1000, in: out) / amplitude(of: 50, in: out)
        let gainDb = 20 * log10(after / before)
        #expect(gainDb > 10, "voice-to-rumble ratio improved by only \(gainDb) dB")
        #expect(upload.label == "hpf_norm")
        #expect(upload.wav.count == wav.count, "same length, same header: the backend parses it the same way")
    }

    @Test("switch on: a quiet answer is lifted to the target peak")
    func quietAnswerIsLifted() {
        let quiet = pcm16(sine(1000, amplitude: 0.2))

        let out = samples(AnswerAudioConditioning.condition(pcm16: quiet, sampleRate: rate))

        let peak = out.map(abs).max() ?? 0
        #expect(abs(peak - AnswerAudioConditioning.targetPeak) < 0.03)
    }

    @Test("switch on: near-silence is never boosted past the gain cap")
    func nearSilenceStaysQuiet() {
        // A clip with nothing in it is noise; turning it up to full scale would
        // hand Scribe loud hiss to hallucinate words from.
        let hiss = pcm16(sine(1000, amplitude: 0.002))

        let out = samples(AnswerAudioConditioning.condition(pcm16: hiss, sampleRate: rate))

        // Capped at +18 dB it stays around −35 dBFS; uncapped it would hit the
        // −3 dBFS target like a real answer.
        let peak = out.map(abs).max() ?? 0
        #expect(peak < 0.03)
    }

    @Test("an empty capture is uploaded as it is")
    func emptyCaptureStaysRaw() {
        let wav = WAVEncoder.wav(pcm16: Data(), sampleRate: rate)

        let upload = AnswerAudioConditioning.uploadWAV(raw: wav, sampleRate: rate, enabled: true)

        #expect(upload.wav == wav)
        #expect(upload.label == "raw", "the label must say what was actually sent")
    }
}

@Suite("Answer sample sidecar carries the route (#185 C)")
struct AnswerSidecarRouteTests {
    @Test("route, policy mode and upload round-trip; a sidecar from before them still decodes")
    func routeFieldsRoundTrip() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let sidecar = AnswerRecordingStore.Sidecar(
            recordedAt: Date(timeIntervalSince1970: 1_700_000_000),
            language: "sk", inputPort: "MicrophoneBuiltIn", voiceProcessing: false,
            outputPort: "BluetoothA2DPOutput", voiceProcessingMode: VoiceProcessingMode.offOutput.rawValue,
            uploadConditioning: AnswerAudioConditioning.conditionedLabel,
            sampleRate: 16000, durationMs: 1200, questionId: "q_001"
        )
        let decoded = try decoder.decode(AnswerRecordingStore.Sidecar.self, from: encoder.encode(sidecar))
        #expect(decoded.outputPort == "BluetoothA2DPOutput")
        #expect(decoded.voiceProcessingMode == "off_output")
        #expect(decoded.uploadConditioning == "hpf_norm")

        // The founder's device already holds #184 samples without the fields.
        let legacy = Data("""
        {"recordedAt":"2026-09-23T17:12:43Z","language":"sk","inputPort":"MicrophoneBuiltIn",
         "voiceProcessing":true,"sampleRate":16000,"durationMs":5000}
        """.utf8)
        let old = try decoder.decode(AnswerRecordingStore.Sidecar.self, from: legacy)
        #expect(old.outputPort == nil)
        #expect(old.voiceProcessingMode == nil)
        #expect(old.uploadConditioning == nil)
    }
}
