//
//  AnswerAudioConditioning.swift
//  Hangs
//
//  #185 track C — the software stand-in for voice processing on the car route.
//  There voice processing stays off (it would move the sound to the iPhone),
//  which loses its noise suppression and gain control. The cheap half of that
//  is a high-pass below the voice band (engine and road rumble) plus a peak
//  normalization (the level gain control used to restore). Research:
//  docs/research/bt-route-noise-suppression-2026-09-24.md §2, recommendation 2.
//
//  Founder 2026-09-24: Scribe transcribes the answers well and its input must
//  not change by default (and a 2025 study found enhancement raised WER for
//  every modern ASR model it tried). So this touches ONLY the uploaded answer,
//  ONLY behind the diagnostics switch `VoicePipelineFlags.conditionAnswerUpload`
//  (off), and the saved sample stays raw: with the switch on, each saved clip
//  carries the transcript of the cleaned upload while `scripts/stt_compare.py`
//  re-transcribes the raw WAV, so the offline comparison decides.
//

import Foundation

nonisolated enum AnswerAudioConditioning {
    /// What was uploaded — the sidecar / log label.
    static let rawLabel = "raw"
    static let conditionedLabel = "hpf_norm"

    /// Corner of the high-pass (research: ~100–150 Hz). Voice fundamentals
    /// start around 85 Hz, but their harmonics carry the words; the rumble of
    /// engine, road and wind sits below this.
    static let highPassHz: Double = 120
    /// Peak target ≈ −3 dBFS: level for a quiet answer, headroom for the codec.
    static let targetPeak: Double = 0.7
    /// Gain cap (+18 dB): a near-silent clip is noise, not a whisper to boost.
    static let maxGain: Double = 8

    /// The WAV to upload and its label. Switch off → the captured WAV, byte
    /// for byte (the Scribe path the founder wants unchanged).
    static func uploadWAV(raw wav: Data, sampleRate: Int, enabled: Bool) -> (wav: Data, label: String) {
        guard enabled, sampleRate > 0, wav.count > WAVEncoder.headerSize else { return (wav, rawLabel) }
        let pcm = Data(wav.dropFirst(WAVEncoder.headerSize))
        let conditioned = condition(pcm16: pcm, sampleRate: sampleRate)
        return (WAVEncoder.wav(pcm16: conditioned, sampleRate: sampleRate), conditionedLabel)
    }

    /// High-pass the 16-bit mono PCM, then scale its peak to `targetPeak`
    /// (down as well as up, never more than `maxGain`).
    static func condition(pcm16: Data, sampleRate: Int) -> Data {
        let count = pcm16.count / MemoryLayout<Int16>.size
        guard count > 0, sampleRate > 0 else { return pcm16 }

        var filter = HighPassBiquad(cutoffHz: highPassHz, sampleRate: Double(sampleRate))
        var filtered = [Double](repeating: 0, count: count)
        var peak = 0.0
        pcm16.withUnsafeBytes { raw in
            for index in 0 ..< count {
                let sample = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: index * 2, as: Int16.self))
                let value = filter.process(Double(sample) / 32768)
                filtered[index] = value
                peak = max(peak, abs(value))
            }
        }

        let gain = peak > 0 ? min(maxGain, targetPeak / peak) : 1
        var out = Data(count: count * MemoryLayout<Int16>.size)
        out.withUnsafeMutableBytes { raw in
            for index in 0 ..< count {
                let scaled = (filtered[index] * gain * 32768).rounded()
                let sample = Int16(max(-32768, min(32767, scaled)))
                raw.storeBytes(of: sample.littleEndian, toByteOffset: index * 2, as: Int16.self)
            }
        }
        return out
    }
}
