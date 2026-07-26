//
//  SilenceDetectionService+InputTap.swift
//  Hangs
//
//  The mic side of the command listener: arming voice processing (echo
//  cancellation / AGC / noise suppression), installing the tap that pumps the
//  input node into the SpeechAnalyzer, and the one-shot retry that decides
//  whether voice processing is what an engine start actually failed on. Split
//  out of SilenceDetectionService+Engine.swift (past the ~300-line cap); the
//  analyzer lifecycle stays there.
//

// @preconcurrency: see SilenceDetectionService+Engine.swift — AVAudio tap and
// converter closures are not @Sendable.
@preconcurrency import AVFoundation
import Foundation
import Speech

extension SilenceDetectionService {
    /// Arm echo cancellation / AGC / noise suppression on the command mic.
    ///
    /// WHY (build-33 field fix): grep-confirmed `setVoiceProcessingEnabled`
    /// appeared nowhere in the target, so the listener ran with a raw mic in a
    /// moving car and the app's own feedback TTS was re-ingested and transcribed
    /// back ("you said proud answer proud" on the result screen). Apple pins two
    /// constraints (AVAudioIONode.h): the engine must be STOPPED when toggling
    /// this, and it must happen before the tap is installed — hence the call site
    /// right after `AVAudioEngine()`. A failure only means degraded audio, so we
    /// log and continue rather than aborting the listener.
    ///
    /// This is orthogonal to the AVAudioSession category/mode, so the deliberate
    /// #104 Media-Mode routing decision is untouched — switching the session to
    /// `.voiceChat` would force 8 kHz Bluetooth HFP and re-break #104.
    func configureVoiceProcessing(on inputNode: AVAudioInputNode) {
        do {
            try inputNode.setVoiceProcessingEnabled(true)
            // iOS 17+ VPIO ducks other audio by default. The founder drives with
            // music on, so pick the least aggressive configuration the SDK exposes
            // (advanced ducking off, `.min` level) rather than ducking the car
            // stereo for the whole quiz.
            inputNode.voiceProcessingOtherAudioDuckingConfiguration =
                AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
                    enableAdvancedDucking: false,
                    duckingLevel: .min
                )
        } catch {
            SentryLog.warn(
                "voice processing enable failed",
                category: .voice,
                attributes: ["error": error.localizedDescription]
            )
        }
    }

    /// Install the tap that feeds the analyzer, converting to `analyzerFormat`
    /// when the hardware format differs.
    ///
    /// Extracted from `startListening()` because the engine-start failure path
    /// must re-install it: toggling voice processing CHANGES the input node's
    /// format, and a tap whose explicit format no longer matches the bus makes
    /// AVAudioEngine trap on the next start.
    func installInputTap(
        on inputNode: AVAudioInputNode,
        format: AVAudioFormat,
        analyzerFormat: AVAudioFormat,
        continuation: AsyncStream<AnalyzerInput>.Continuation
    ) {
        let tapFormat = format
        let tapAnalyzerFormat = analyzerFormat
        let tapConverter = format == analyzerFormat ? nil : AVAudioConverter(from: format, to: analyzerFormat)

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
                }
            } else {
                continuation.yield(AnalyzerInput(buffer: buffer))
            }
        }
    }

    /// One-shot second attempt at `engine.start()` with voice processing
    /// disarmed. Returns whether the engine is now running.
    ///
    /// WHY this exists instead of reading `inputNode.isVoiceProcessingEnabled`:
    /// that flag cannot ATTRIBUTE a start failure. `configureVoiceProcessing`
    /// runs on essentially every attempt and swallows its own throw, so the flag
    /// is true almost always — treating it as proof would latch echo cancellation
    /// off for the WHOLE PROCESS on any unrelated failure (a route change, a
    /// session not yet active after AVPlayer teardown, the #64/#100.4 mic
    /// contention), silently re-opening the dirty-mic root cause with nothing in
    /// telemetry to tell the two apart. Only a retry that SUCCEEDS proves VPIO was
    /// the cause.
    func retryStartWithoutVoiceProcessing(
        _ engine: AVAudioEngine,
        inputNode: AVAudioInputNode,
        analyzerFormat: AVAudioFormat,
        continuation: AsyncStream<AnalyzerInput>.Continuation
    ) -> Bool {
        guard inputNode.isVoiceProcessingEnabled else { return false }

        // The tap's format is about to stop matching the bus — remove before the
        // toggle, re-install against the format we actually end up with.
        inputNode.removeTap(onBus: 0)
        do {
            try inputNode.setVoiceProcessingEnabled(false)
        } catch {
            return false
        }

        let retryFormat = inputNode.outputFormat(forBus: 0)
        guard retryFormat.sampleRate > 0, retryFormat.channelCount > 0 else { return false }
        installInputTap(
            on: inputNode, format: retryFormat, analyzerFormat: analyzerFormat, continuation: continuation
        )

        do {
            try engine.start()
            return true
        } catch {
            return false
        }
    }
}
