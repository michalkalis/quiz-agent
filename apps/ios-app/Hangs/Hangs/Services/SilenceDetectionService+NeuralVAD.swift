//
//  SilenceDetectionService+NeuralVAD.swift
//  Hangs
//
//  #204 track 204.3: the Silero detector (`SileroVAD`) as the answer's speech
//  signal behind `VoicePipelineFlags.neuralVADEnabled`. The model scores the
//  tap's audio on the tap thread; the main actor only reads the probability
//  each level buffer carries. The hangover, the blip bar, the 5 s window and
//  the 8 s cap are unchanged — only "is someone talking" changes hands.
//
//  Scope: answer recordings only. Command windows keep the energy detector
//  (the model still runs there, so its state is warm when an answer starts).
//  Fallback: a model that fails to load, or stops scoring mid-recording,
//  hands the decision back to the energy detector and says so in Sentry.
//

@preconcurrency import AVFoundation
import Foundation
import os

/// Which detector decided an answer recording — the A/B field on
/// "answer recording stopped".
nonisolated enum AnswerSpeechDetector: String, Sendable, Equatable {
    case energy
    case neural
    /// Neural was switched on but the model did not load or stopped scoring.
    case energyFallback
}

extension SilenceDetectionService {
    /// The model for a window that starts now, or `nil` (flag off, model
    /// broken). Loaded once; Core ML does the loading off the main thread.
    func neuralVADForWindow() async -> SileroVAD? {
        neuralVADRequested = VoicePipelineFlags.neuralVADEnabled
        guard neuralVADRequested else { return nil }
        if let sileroVAD { return sileroVAD }
        guard !neuralVADLoadFailed else { return nil }
        do {
            let vad = try await SileroVAD.loadBundled()
            sileroVAD = vad
            return vad
        } catch {
            neuralVADLoadFailed = true
            SentryLog.warn("neural vad unavailable", category: .voice, attributes: [
                "error": String(describing: error),
            ])
            return nil
        }
    }

    /// The neural detector decides the recording in progress.
    var usesNeuralDetector: Bool {
        guard neuralVADActive, let answerSession else { return false }
        return !answerSession.neuralFellBack
    }

    /// The speech opinion the state machine acts on.
    var primarySpeaking: Bool {
        usesNeuralDetector ? neuralSpeaking : energySpeaking
    }

    var answerSpeechDetector: AnswerSpeechDetector {
        if usesNeuralDetector { return .neural }
        return neuralVADRequested ? .energyFallback : .energy
    }

    /// A model that has scored nothing after the stale bar of audio is not
    /// listening — the energy detector takes the rest of the recording.
    func fallBackIfNeuralSilent(_ session: inout AnswerDetectionSession) {
        guard usesNeuralDetector, neuralGate.peakProbability == nil,
              session.audioSecs >= VADTuning.levelStaleAfterSecs
        else { return }
        session.neuralFellBack = true
        SentryLog.warn("neural vad silent, energy fallback", category: .voice, attributes: [
            "atMs": Int((session.audioSecs * 1000).rounded()),
        ])
    }

    /// Tap thread: the buffer's speech probability, the analyzer-format audio
    /// brought to the model's 16 kHz mono Float32 first (`resampler` is only
    /// set when the analyzer runs at another rate, e.g. 8 kHz narrowband).
    nonisolated static func speechProbability(
        of buffer: AVAudioPCMBuffer,
        vad: SileroVAD,
        resampler: AVAudioConverter?
    ) -> Float? {
        guard let samples = modelSamples(of: buffer, resampler: resampler) else { return nil }
        return vad.process(samples)
    }

    /// 16 kHz mono Float32 — the format the bundled model is exported for.
    nonisolated static let neuralVADFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: SileroVAD.sampleRate, channels: 1, interleaved: false
    )

    private nonisolated static func modelSamples(
        of buffer: AVAudioPCMBuffer, resampler: AVAudioConverter?
    ) -> [Float]? {
        guard let resampler else { return floatSamples(of: buffer) }
        guard let neuralVADFormat, buffer.format.sampleRate > 0 else { return nil }
        let capacity = AVAudioFrameCount(
            (Double(buffer.frameLength) * SileroVAD.sampleRate / buffer.format.sampleRate).rounded(.up)
        )
        guard let converted = AVAudioPCMBuffer(pcmFormat: neuralVADFormat, frameCapacity: capacity) else { return nil }
        var error: NSError?
        var supplied = false
        resampler.convert(to: converted, error: &error) { _, status in
            guard !supplied else {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil else { return nil }
        return floatSamples(of: converted)
    }

    private nonisolated static func floatSamples(of buffer: AVAudioPCMBuffer) -> [Float]? {
        let frames = Int(buffer.frameLength)
        if let float = buffer.floatChannelData {
            return Array(UnsafeBufferPointer(start: float[0], count: frames))
        }
        if let int16 = buffer.int16ChannelData {
            return UnsafeBufferPointer(start: int16[0], count: frames).map { Float($0) / 32768 }
        }
        return nil
    }
}
