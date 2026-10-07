//
//  RecordingCoordinator+Analytics.swift
//  Hangs
//
//  #51: the recording side's product analytics — a voice answer leaving the
//  device, or an on-device capture that produced nothing to send. A failed
//  capture counts as an attempt, so the answer after it reports `is_retry`.
//

extension RecordingCoordinator {
    func trackVoiceAnswerSubmitted(questionId: String?) {
        let isRetry = attemptLedger.noteAnswerAttempt(questionId: questionId)
        trackAnalytics(.answerSubmitted(inputMode: .voice, questionId: questionId, isRetry: isRetry))
    }

    func trackCaptureFailure(_ reason: VoiceCaptureFailure) {
        let questionId = currentQuestion()?.id
        _ = attemptLedger.noteAnswerAttempt(questionId: questionId)
        trackAnalytics(.voiceCaptureFailed(reason: reason, questionId: questionId))
    }
}
