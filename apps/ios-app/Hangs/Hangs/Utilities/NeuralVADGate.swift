//
//  NeuralVADGate.swift
//  Hangs
//
//  #204 track 204.3: speech / non-speech from the Silero probabilities the
//  mic tap attaches to each level buffer — the neural twin of `EnergyVAD`,
//  pure so tests can replay recorded probabilities. The hangover, the blip
//  bar, the 5 s window and the 8 s cap stay with the service state machine;
//  this only replaces the "is someone talking right now" opinion.
//

import Foundation

nonisolated struct NeuralVADGate: Sendable {
    private(set) var isSpeech = false
    /// Highest probability since the last reset; `nil` = no window scored yet
    /// (the model is still filling its first 32 ms, or it failed).
    private(set) var peakProbability: Float?
    /// Audio time between the release and the onset threshold that did NOT
    /// become speech — the "maybe someone is talking" the 5 s window respects.
    private(set) var ambiguousSecs: TimeInterval = 0

    @discardableResult
    mutating func process(probability: Float?, duration: TimeInterval) -> Bool {
        guard let probability else { return isSpeech }
        peakProbability = max(peakProbability ?? probability, probability)
        if isSpeech {
            if probability < VADTuning.neuralSpeechReleaseProbability { isSpeech = false }
            return isSpeech
        }
        if probability >= VADTuning.neuralSpeechOnsetProbability {
            isSpeech = true
        } else if probability >= VADTuning.neuralSpeechReleaseProbability {
            ambiguousSecs += duration
        }
        return isSpeech
    }
}
