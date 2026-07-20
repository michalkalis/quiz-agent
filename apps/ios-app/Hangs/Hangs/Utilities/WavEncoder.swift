//
//  WavEncoder.swift
//  Hangs
//
//  Wraps raw PCM samples in a minimal RIFF/WAVE container (#109). The feedback
//  dictation path tees the same 16 kHz 16-bit mono PCM chunks it streams to
//  ElevenLabs into an in-memory buffer; this turns that buffer into a playable
//  `.wav` for the feedback report's audio attachment (the transcript's fallback).
//
//  Pure + nonisolated so the header layout is unit-testable without any audio
//  hardware.
//

import Foundation

enum WavEncoder {
    /// Prepend a 44-byte canonical PCM WAV header to `pcm` (little-endian,
    /// integer 16-bit samples). `pcm` must already be interleaved 16-bit mono/stereo
    /// samples in the given sample rate — exactly what `AudioService`'s streaming
    /// tap emits (16 kHz, 16-bit, mono).
    static func wrapPCM16(_ pcm: Data, sampleRate: Int = 16000, channels: Int = 1) -> Data {
        let bitsPerSample = 16
        let blockAlign = channels * bitsPerSample / 8
        let byteRate = sampleRate * blockAlign
        let dataSize = pcm.count
        let riffChunkSize = 36 + dataSize

        var header = Data()
        header.append(contentsOf: Array("RIFF".utf8))
        header.append(uint32LE(UInt32(riffChunkSize)))
        header.append(contentsOf: Array("WAVE".utf8))

        // fmt subchunk
        header.append(contentsOf: Array("fmt ".utf8))
        header.append(uint32LE(16)) // PCM fmt subchunk size
        header.append(uint16LE(1)) // audio format = PCM
        header.append(uint16LE(UInt16(channels)))
        header.append(uint32LE(UInt32(sampleRate)))
        header.append(uint32LE(UInt32(byteRate)))
        header.append(uint16LE(UInt16(blockAlign)))
        header.append(uint16LE(UInt16(bitsPerSample)))

        // data subchunk
        header.append(contentsOf: Array("data".utf8))
        header.append(uint32LE(UInt32(dataSize)))

        var out = header
        out.append(pcm)
        return out
    }

    private static func uint32LE(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    private static func uint16LE(_ value: UInt16) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }
}
