//
//  PCMAudio.swift
//  Hangs
//
//  #184 track B — the answer recording as PCM. The batch answer path no longer
//  runs an `AVAudioRecorder` next to the command-listener engine (two mic
//  clients, and the recorder never saw the voice processing the engine had).
//  Instead the listener engine's tap tees the SAME 16-bit mono samples the VAD
//  sees into `AnswerCapture`, and `WAVEncoder` wraps them for the upload.
//  Pure value code, unit-tested without an audio device.
//

@preconcurrency import AVFoundation
import Foundation
import os

/// Canonical 44-byte RIFF/WAVE header + 16-bit PCM body.
nonisolated enum WAVEncoder {
    static let headerSize = 44

    /// Wrap little-endian 16-bit mono PCM in a WAV container.
    static func wav(pcm16 samples: Data, sampleRate: Int, channels: Int = 1) -> Data {
        let bitsPerSample = 16
        let blockAlign = channels * bitsPerSample / 8
        let byteRate = sampleRate * blockAlign

        var data = Data(capacity: headerSize + samples.count)
        data.append(contentsOf: Array("RIFF".utf8))
        data.appendUInt32LE(UInt32(36 + samples.count))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        data.appendUInt32LE(16) // PCM fmt chunk size
        data.appendUInt16LE(1) // PCM
        data.appendUInt16LE(UInt16(channels))
        data.appendUInt32LE(UInt32(sampleRate))
        data.appendUInt32LE(UInt32(byteRate))
        data.appendUInt16LE(UInt16(blockAlign))
        data.appendUInt16LE(UInt16(bitsPerSample))
        data.append(contentsOf: Array("data".utf8))
        data.appendUInt32LE(UInt32(samples.count))
        data.append(samples)
        return data
    }
}

// `nonisolated`: `WAVEncoder` is nonisolated, so under the module's MainActor
// default isolation these helpers must be too or it cannot call them.
private nonisolated extension Data {
    mutating func appendUInt32LE(_ value: UInt32) {
        var little = value.littleEndian
        append(Data(bytes: &little, count: 4))
    }

    mutating func appendUInt16LE(_ value: UInt16) {
        var little = value.littleEndian
        append(Data(bytes: &little, count: 2))
    }
}

/// 16-bit little-endian sample extraction from an `AVAudioPCMBuffer` in either
/// of the two formats the analyzer negotiates (Float32 or Int16, mono).
nonisolated enum PCM16 {
    static func bytes(from buffer: AVAudioPCMBuffer) -> Data? {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return nil }
        if let int16 = buffer.int16ChannelData {
            return Data(bytes: int16[0], count: frames * MemoryLayout<Int16>.size)
        }
        if let float = buffer.floatChannelData {
            var out = [Int16](repeating: 0, count: frames)
            let channel = float[0]
            for i in 0 ..< frames {
                let clamped = max(-1.0, min(1.0, channel[i]))
                out[i] = Int16(clamped * Float(Int16.max))
            }
            return out.withUnsafeBufferPointer { Data(buffer: $0) }
        }
        return nil
    }
}

/// Lock-protected accumulator for one answer recording. Appended from the audio
/// thread (via the listener tap's sink), drained on the main actor. Capped so a
/// stuck recording can never grow without bound — `maxBytes` mirrors the hidden
/// dead-air cap (`Config.autoRecordingDuration`) at 16 kHz mono.
nonisolated final class AnswerCapture: Sendable {
    struct State: Sendable {
        var active = false
        var sampleRate = 16000
        var samples = Data()
        var dropped = 0
        /// #185 5.1: keep the NEWEST audio instead of refusing it once full —
        /// the answer sheet listens for as long as the driver leaves it open.
        var rolling = false
    }

    private let state: OSAllocatedUnfairLock<State>
    let maxBytes: Int

    init(maxSeconds: TimeInterval = Config.autoRecordingDuration + 5, sampleRate: Int = 16000) {
        maxBytes = Int(maxSeconds) * sampleRate * MemoryLayout<Int16>.size
        state = OSAllocatedUnfairLock(initialState: State(sampleRate: sampleRate))
    }

    var isActive: Bool { state.withLock { $0.active } }

    /// Start a fresh capture at `sampleRate` Hz, discarding anything buffered.
    /// `rolling` (#185 5.1): once full, drop the OLDEST half instead of the
    /// newest audio.
    func begin(sampleRate: Int, rolling: Bool = false) {
        state.withLock { current in
            current = State(active: true, sampleRate: sampleRate, rolling: rolling)
        }
    }

    /// The tap's sink. Silently drops once the cap is hit (counted for telemetry).
    func append(_ chunk: Data) {
        state.withLock { current in
            guard current.active else { return }
            if current.samples.count + chunk.count > maxBytes {
                guard current.rolling else {
                    current.dropped += chunk.count
                    return
                }
                // Halving (sample-aligned) keeps the copy cost amortized;
                // `subdata` copies, so the dropped half's memory is released.
                let half = (current.samples.count / 2) & ~1
                let start = current.samples.startIndex + half
                current.samples = current.samples.subdata(in: start ..< current.samples.endIndex)
                current.dropped += half
            }
            current.samples.append(chunk)
        }
    }

    /// Stop capturing and hand back the WAV plus the raw stats the recording
    /// telemetry logs. Returns `nil` samples-empty capture as an empty WAV body.
    func finish() -> (wav: Data, sampleRate: Int, bytes: Int, durationMs: Int, droppedBytes: Int) {
        let snapshot: State = state.withLock { current in
            let taken = current
            current = State(active: false, sampleRate: current.sampleRate)
            return taken
        }
        let bytes = snapshot.samples.count
        let durationMs = snapshot.sampleRate > 0
            ? bytes * 1000 / (snapshot.sampleRate * MemoryLayout<Int16>.size)
            : 0
        return (
            WAVEncoder.wav(pcm16: snapshot.samples, sampleRate: snapshot.sampleRate),
            snapshot.sampleRate,
            bytes,
            durationMs,
            snapshot.dropped
        )
    }

    /// Discard without producing a WAV (teardown paths).
    func cancel() {
        state.withLock { current in
            current = State(active: false, sampleRate: current.sampleRate)
        }
    }
}
