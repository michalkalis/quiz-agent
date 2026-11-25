//
//  LoudnessMeter.swift
//  HangsTests
//
//  ITU-R BS.1770-4 loudness for tests: K-weighting (the head's high-shelf plus
//  the low cut, coefficients derived for any sample rate as in pyloudnorm) and
//  the gated integrated loudness (400 ms blocks, 75 % overlap, absolute gate
//  -70 LUFS, relative gate -10 LU). Lets a test compare two sounds the way the
//  ear and every loudness meter compare them, instead of comparing peaks.
//

import AVFAudio
import Foundation

enum LoudnessMeter {
    /// Integrated loudness in LUFS of a whole programme (speech).
    static func integrated(_ samples: [Float], sampleRate: Double) -> Double {
        let weighted = kWeighted(samples, sampleRate: sampleRate)
        let block = Int(0.4 * sampleRate)
        let hop = block / 4
        guard weighted.count >= block else { return loudness(meanSquare(weighted[...])) }
        let blocks = stride(from: 0, through: weighted.count - block, by: hop).map {
            meanSquare(weighted[$0 ..< $0 + block])
        }
        let aboveAbsolute = blocks.filter { loudness($0) > -70 }
        guard !aboveAbsolute.isEmpty else { return -.infinity }
        let relativeGate = loudness(aboveAbsolute.reduce(0, +) / Double(aboveAbsolute.count)) - 10
        let gated = aboveAbsolute.filter { loudness($0) > relativeGate }
        return loudness(gated.reduce(0, +) / Double(gated.count))
    }

    /// K-weighted loudness over the whole buffer, ungated: the level of a cue
    /// shorter than one 400 ms block while it sounds.
    static func whileSounding(_ samples: [Float], sampleRate: Double) -> Double {
        loudness(meanSquare(kWeighted(samples, sampleRate: sampleRate)[...]))
    }

    /// Mono float samples of an audio file (MP3, WAV) and its sample rate.
    static func read(_ url: URL) throws -> (samples: [Float], sampleRate: Double) {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else { throw CocoaError(.fileReadCorruptFile) }
        return (Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))), file.processingFormat.sampleRate)
    }

    // MARK: - BS.1770 pieces

    private static func loudness(_ meanSquare: Double) -> Double {
        -0.691 + 10 * log10(meanSquare)
    }

    private static func meanSquare(_ samples: ArraySlice<Double>) -> Double {
        samples.reduce(0) { $0 + $1 * $1 } / Double(max(samples.count, 1))
    }

    private static func kWeighted(_ samples: [Float], sampleRate: Double) -> [Double] {
        let input = samples.map(Double.init)
        let shelf = Biquad.highShelf(gainDB: 4, q: 1 / 2.0.squareRoot(), frequency: 1500, sampleRate: sampleRate)
        let lowCut = Biquad.highPass(q: 0.5, frequency: 38, sampleRate: sampleRate)
        return lowCut.filter(shelf.filter(input))
    }

    private struct Biquad {
        let b: (Double, Double, Double)
        let a: (Double, Double)

        static func highShelf(gainDB: Double, q: Double, frequency: Double, sampleRate: Double) -> Biquad {
            let amp = pow(10, gainDB / 40)
            let w0 = 2 * Double.pi * frequency / sampleRate
            let alpha = sin(w0) / (2 * q)
            let cosw = cos(w0)
            let root = 2 * amp.squareRoot() * alpha
            let a0 = (amp + 1) - (amp - 1) * cosw + root
            return Biquad(
                b: (
                    amp * ((amp + 1) + (amp - 1) * cosw + root) / a0,
                    -2 * amp * ((amp - 1) + (amp + 1) * cosw) / a0,
                    amp * ((amp + 1) + (amp - 1) * cosw - root) / a0
                ),
                a: (2 * ((amp - 1) - (amp + 1) * cosw) / a0, ((amp + 1) - (amp - 1) * cosw - root) / a0)
            )
        }

        static func highPass(q: Double, frequency: Double, sampleRate: Double) -> Biquad {
            let w0 = 2 * Double.pi * frequency / sampleRate
            let alpha = sin(w0) / (2 * q)
            let cosw = cos(w0)
            let a0 = 1 + alpha
            return Biquad(
                b: ((1 + cosw) / 2 / a0, -(1 + cosw) / a0, (1 + cosw) / 2 / a0),
                a: (-2 * cosw / a0, (1 - alpha) / a0)
            )
        }

        func filter(_ x: [Double]) -> [Double] {
            var y = [Double](repeating: 0, count: x.count)
            var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
            for index in x.indices {
                let out = b.0 * x[index] + b.1 * x1 + b.2 * x2 - a.0 * y1 - a.1 * y2
                x2 = x1
                x1 = x[index]
                y2 = y1
                y1 = out
                y[index] = out
            }
            return y
        }
    }
}
