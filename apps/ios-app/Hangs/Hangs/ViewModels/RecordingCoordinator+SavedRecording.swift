//
//  RecordingCoordinator+SavedRecording.swift
//  Hangs
//
//  #197 track 197.1/197.2: closing a saved car recording — write what the app
//  decided into its sidecar, then kick the uploader without waiting for it.
//

import Foundation

extension RecordingCoordinator {
    func finishSavedRecording(_ stamp: String?, outcome: AnswerRecordingStore.Outcome) {
        guard let stamp else { return }
        AnswerRecordingStore.recordOutcome(outcome, to: stamp)
        answerRecordingDecided()
    }
}

extension AnswerRecordingStore.Outcome {
    /// The decision a submit response carries: the verdict, or `empty` when
    /// the server heard nothing usable (the sheet's "didn't catch that").
    init(response: QuizResponse) {
        guard let evaluation = response.evaluation,
              !evaluation.userAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            self = .notCaptured("empty")
            return
        }
        self.init(
            decision: evaluation.result.rawValue,
            transcript: evaluation.userAnswer,
            correctAnswer: evaluation.correctAnswer,
            headlineAnswer: evaluation.headlineAnswer
        )
    }
}
