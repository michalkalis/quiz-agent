//
//  SilenceDetectionService+InputTap.swift
//  Hangs
//
//  The mic side of the command listener: installing the tap that pumps the
//  input node into the SpeechAnalyzer and measures each buffer's level for
//  the energy VAD (#185 track A). Split out of
//  SilenceDetectionService+Engine.swift (past the ~300-line cap); the analyzer
//  lifecycle stays there.
//
//  #173 (founder 2026-09-07): voice processing (VPIO) is deliberately NOT armed
//  here any more. It ducked other audio on the listener engine while the
//  answer-recording engine in AudioService has never had it, so every
//  think→record hand-off jumped the music volume in the car. The self-hearing
//  it once guarded against (build-33: the app transcribing its own TTS) is now
//  handled structurally — #119/#149 tear the listener down for the whole
//  duration of any app TTS.
//

// @preconcurrency: see SilenceDetectionService+Engine.swift — AVAudio tap and
// converter closures are not @Sendable.
@preconcurrency import AVFoundation
import Foundation
import os
import Speech

extension SilenceDetectionService {
    /// Install the tap that feeds the analyzer, converting to `analyzerFormat`
    /// when the hardware format differs.
    ///
    /// The explicit format must be the one the bus actually reports: a tap whose
    /// format no longer matches the input bus makes AVAudioEngine trap on start.
    func installInputTap(
        on inputNode: AVAudioInputNode,
        format: AVAudioFormat,
        analyzerFormat: AVAudioFormat,
        continuation: AsyncStream<AnalyzerInput>.Continuation,
        levels: AsyncStream<InputLevelSample>.Continuation,
        answerSink: OSAllocatedUnfairLock<(@Sendable (Data) -> Void)?>
    ) {
        let tapFormat = format
        let tapAnalyzerFormat = analyzerFormat
        let tapConverter = format == analyzerFormat ? nil : AVAudioConverter(from: format, to: analyzerFormat)
        // Filter state carries across buffers; the tap is its only user.
        let meter = OSAllocatedUnfairLock(initialState: InputLevelMeter(sampleRate: analyzerFormat.sampleRate))

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { @Sendable buffer, _ in
            if let tapConverter {
                guard tapFormat.sampleRate > 0 else { return }
                let frameCount = AVAudioFrameCount(
                    Double(buffer.frameLength) * tapAnalyzerFormat.sampleRate / tapFormat.sampleRate
                )
                guard let convertedBuffer = AVAudioPCMBuffer(
                    pcmFormat: tapAnalyzerFormat,
                    frameCapacity: frameCount
                ) else { return }

                var error: NSError?
                // The converter re-invokes this block while it primes its internal
                // buffers. Returning the SAME tap buffer with `.haveData` on every
                // invocation (the original code) fed the analyzer duplicated ~21 ms
                // of audio. Hand the buffer over exactly once, then report that this
                // call has no further input.
                var bufferSupplied = false
                tapConverter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                    guard !bufferSupplied else {
                        outStatus.pointee = .noDataNow
                        return nil
                    }
                    bufferSupplied = true
                    outStatus.pointee = .haveData
                    return buffer
                }

                if error == nil {
                    continuation.yield(AnalyzerInput(buffer: convertedBuffer))
                    Self.tee(convertedBuffer, into: answerSink)
                    Self.measure(convertedBuffer, with: meter, into: levels)
                }
            } else {
                continuation.yield(AnalyzerInput(buffer: buffer))
                Self.tee(buffer, into: answerSink)
                Self.measure(buffer, with: meter, into: levels)
            }
        }
    }

    /// #185 track A: the buffer's band-limited level for the energy VAD — on
    /// the analyzer-format audio, the same samples the answer capture keeps.
    /// Audio-thread code: one uncontended lock, one pass over the samples.
    nonisolated static func measure(
        _ buffer: AVAudioPCMBuffer,
        with meter: OSAllocatedUnfairLock<InputLevelMeter>,
        into levels: AsyncStream<InputLevelSample>.Continuation
    ) {
        guard let sample = meter.withLockUnchecked({ $0.measure(buffer) }) else { return }
        levels.yield(sample)
    }

    /// #184 track B: hand the analyzer-format buffer to the answer capture as
    /// 16-bit PCM when a recording is in progress. Audio-thread code — one lock
    /// read, one conversion, no allocation beyond the chunk itself.
    nonisolated static func tee(
        _ buffer: AVAudioPCMBuffer,
        into answerSink: OSAllocatedUnfairLock<(@Sendable (Data) -> Void)?>
    ) {
        guard let sink = answerSink.withLock({ $0 }) else { return }
        guard let bytes = PCM16.bytes(from: buffer) else { return }
        sink(bytes)
    }
}
