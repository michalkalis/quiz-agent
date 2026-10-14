//
//  SileroVAD.swift
//  Hangs
//
//  #204 track 204.3 — the neural speech detector behind `neuralVADEnabled`.
//  Sentry 2026-10-10: 7 of 40 car answers ran into the 8 s cap, and in four of
//  them the energy detector called 9.5–14.7 s of road noise "speech". A level
//  detector cannot tell a louder stretch of asphalt from a voice; a model
//  trained on speech vs. noise can.
//
//  Model: Silero VAD v6.2.1 (MIT, github.com/snakers4/silero-vad), the 32 ms
//  CoreML export from huggingface.co/aufklarer/Silero-VAD-v6.2.1-CoreML (MIT),
//  bundled as `MLModels/silero_vad.mlmodelc` (~640 kB). Never downloaded: a
//  model fetched mid-drive was why a neural VAD was turned down on 09-21.
//
//  It only DECIDES speech vs. silence. The uploaded answer stays raw audio —
//  denoising before STT raised the error rate in every published comparison
//  (docs/research/answer-recognition-vs-wispr-2026-10-14.md).
//

import CoreML
import Foundation
import Synchronization

/// Streaming Silero VAD: feed 16 kHz mono samples in any buffer size, get the
/// speech probability of the latest 32 ms windows. Runs on the mic tap's
/// thread (never the main actor); the LSTM state lives behind a mutex so the
/// main actor can reset it between recordings.
nonisolated final class SileroVAD: Sendable {
    static let sampleRate = 16000.0
    /// New audio per model call (32 ms) and the left context the v5+/v6
    /// models expect in front of it.
    static let chunkSamples = 512
    static let contextSamples = 64
    static let stateSize = 128

    enum LoadError: Error {
        case modelMissing
    }

    private let stream: Mutex<Stream>

    init(model: sending MLModel) throws {
        stream = try Mutex(Stream(model: model))
    }

    /// The bundled model, loaded off the caller's thread by Core ML. CPU only:
    /// at ~0.3 MFLOP per window the ANE/GPU hand-off costs more than it saves.
    static func loadBundled(from bundle: Bundle = .main) async throws -> SileroVAD {
        guard let url = bundle.url(forResource: "silero_vad", withExtension: "mlmodelc") else {
            throw LoadError.modelMissing
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuOnly
        let model = try await MLModel.load(contentsOf: url, configuration: configuration)
        return try SileroVAD(model: model)
    }

    /// Feed 16 kHz mono samples (full scale ±1). Returns the highest
    /// probability among the windows this call completed — the speech-leaning
    /// choice, so an answer is never cut on one low window — or the previous
    /// value when none completed. `nil` before the first window and after a
    /// model failure (the caller then falls back to the energy detector).
    func process(_ samples: [Float]) -> Float? {
        stream.withLock { $0.process(samples) }
    }

    /// Forget everything heard so far (a new recording starts clean, #185 H3).
    func reset() {
        stream.withLock { $0.reset() }
    }
}

nonisolated private extension SileroVAD {
    struct Stream {
        let model: MLModel
        let audio: MLMultiArray
        var hidden: MLMultiArray
        var cell: MLMultiArray
        var context: [Float]
        var pending: [Float] = []
        var lastProbability: Float?
        var failed = false

        init(model: MLModel) throws {
            self.model = model
            audio = try MLMultiArray(shape: [1, 1, NSNumber(value: chunkSamples + contextSamples)], dataType: .float16)
            hidden = try Self.zeroState()
            cell = try Self.zeroState()
            context = [Float](repeating: 0, count: contextSamples)
        }

        mutating func process(_ samples: [Float]) -> Float? {
            guard !failed else { return nil }
            pending.append(contentsOf: samples)
            var best: Float?
            var consumed = 0
            while pending.count - consumed >= chunkSamples {
                let chunk = pending[consumed ..< consumed + chunkSamples]
                consumed += chunkSamples
                guard let probability = predict(chunk) else {
                    failed = true
                    lastProbability = nil
                    pending = []
                    return nil
                }
                best = max(best ?? probability, probability)
            }
            if consumed > 0 { pending.removeFirst(consumed) }
            if let best { lastProbability = best }
            return lastProbability
        }

        mutating func reset() {
            guard !failed else { return }
            if let hidden = try? Self.zeroState(), let cell = try? Self.zeroState() {
                self.hidden = hidden
                self.cell = cell
            }
            context = [Float](repeating: 0, count: contextSamples)
            pending = []
            lastProbability = nil
        }

        private mutating func predict(_ chunk: ArraySlice<Float>) -> Float? {
            audio.withUnsafeMutableBufferPointer(ofType: Float16.self) { pointer, _ in
                for (index, value) in context.enumerated() {
                    pointer[index] = Float16(value)
                }
                for (offset, value) in chunk.enumerated() {
                    pointer[contextSamples + offset] = Float16(value)
                }
            }
            do {
                let input = try MLDictionaryFeatureProvider(dictionary: [
                    "audio": MLFeatureValue(multiArray: audio),
                    "h": MLFeatureValue(multiArray: hidden),
                    "c": MLFeatureValue(multiArray: cell),
                ])
                let output = try model.prediction(from: input)
                guard let probability = output.featureValue(for: "probability")?.multiArrayValue,
                      let nextHidden = output.featureValue(for: "h_out")?.multiArrayValue,
                      let nextCell = output.featureValue(for: "c_out")?.multiArrayValue
                else { return nil }
                hidden = nextHidden
                cell = nextCell
                context = Array(chunk.suffix(contextSamples))
                return probability[0].floatValue
            } catch {
                return nil
            }
        }

        private static func zeroState() throws -> MLMultiArray {
            let state = try MLMultiArray(shape: [1, 1, NSNumber(value: stateSize)], dataType: .float16)
            state.withUnsafeMutableBufferPointer(ofType: Float16.self) { pointer, _ in
                pointer.initialize(repeating: 0)
            }
            return state
        }
    }
}
