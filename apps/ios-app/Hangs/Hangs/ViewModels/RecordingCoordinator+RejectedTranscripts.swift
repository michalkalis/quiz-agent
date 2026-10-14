//
//  RecordingCoordinator+RejectedTranscripts.swift
//  Hangs
//
//  #204.2 — a retry must not return the rejected transcript. Every way the
//  player throws the shown transcript away on the confirmation sheet (the
//  Re-record tap, a spoken "nie" / "znova", Cancel, or simply speaking a new
//  answer over it) remembers it for the current question; the next upload for
//  that question sends the list (see `RejectedTranscripts`).
//

import Foundation

extension RecordingCoordinator {
    /// The question a rejection or an upload belongs to (`questionId ?? ""`).
    private var rejectionQuestionKey: String {
        currentQuestion()?.id ?? ""
    }

    /// The player threw `transcript` away on the current question.
    func rememberRejectedTranscript(_ transcript: String) {
        rejectedTranscripts.add(transcript, questionKey: rejectionQuestionKey)
    }

    /// The player kept `transcript` after all (a spoken new answer turned out
    /// to be "potvrď" or "stop", and the old answer came back).
    func forgetRejectedTranscript(_ transcript: String) {
        rejectedTranscripts.remove(transcript, questionKey: rejectionQuestionKey)
    }

    /// What the next upload sends as `rejected_transcripts`: nothing when the
    /// diagnostics switch is off, so the upload is exactly today's.
    func rejectedTranscriptsForUpload() -> [String] {
        guard VoicePipelineFlags.avoidRejectedTranscriptOnRetry else { return [] }
        return rejectedTranscripts.transcripts(for: rejectionQuestionKey)
    }

    /// Rejections on the current question so far, whatever the switch says
    /// (#204.9 `answer_captured`).
    func rejectedTranscriptCount() -> Int {
        rejectedTranscripts.rejectionCount(for: rejectionQuestionKey)
    }

    /// Telemetry for the A/B: whether the switch is on and how many rejected
    /// transcripts the upload carries — never the words themselves.
    func rejectedTranscriptAttributes() -> [String: Any] {
        [
            "avoidRejected": VoicePipelineFlags.avoidRejectedTranscriptOnRetry,
            "rejectedCount": rejectedTranscriptsForUpload().count,
        ]
    }
}
