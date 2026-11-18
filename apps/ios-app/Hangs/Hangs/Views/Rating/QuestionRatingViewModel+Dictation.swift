//
//  QuestionRatingViewModel+Dictation.swift
//  Hangs
//
//  Spoken justification for the #155 rating panel, on the shared
//  `TextDictation` engine (#208.8: record, then transcribe on the server).
//  Unlike the feedback sheet a rating stores text only — no WAV attachment.
//

import Foundation

@MainActor
extension QuestionRatingViewModel {
    /// Toggle dictation: start if idle/denied-retry, stop if recording.
    func toggleDictation() async {
        switch micState {
        case .dictating:
            await stopDictation()
        case .idle, .denied:
            await startDictation()
        }
    }

    /// Record on the SHARED audio service; the text lands in `justification`
    /// when the recording stops.
    func startDictation() async {
        guard let voice else { return }
        await dictation.start(languageCode: voice.languageCode) { [weak self] text in
            guard let self else { return }
            justification = TextDictation.appending(text, to: justification)
        }
    }

    /// Stop dictation and wait for its text to land in `justification`.
    func stopDictation() async {
        await dictation.stop()
    }
}
