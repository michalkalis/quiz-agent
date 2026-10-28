//
//  RecordingCoordinator+Analytics.swift
//  Hangs
//
//  #51: the recording side's product analytics — a voice answer leaving the
//  device, or an on-device capture that produced nothing to send. A failed
//  capture counts as an attempt, so the answer after it reports `is_retry`.
//  #204.9: every recorded answer also reports how it was captured
//  (`answer_captured`), the data the voice-settings experiment decides on.
//

import Foundation

extension RecordingCoordinator {
    func trackVoiceAnswerSubmitted(questionId: String?) {
        let isRetry = attemptLedger.noteAnswerAttempt(questionId: questionId)
        let latencyMs = attemptLedger.latency.consumeLatencyMs(questionId: questionId, isRetry: isRetry, voice: true)
        trackAnalytics(.answerSubmitted(inputMode: .voice, questionId: questionId, isRetry: isRetry, latencyMs: latencyMs))
    }

    func trackCaptureFailure(_ reason: VoiceCaptureFailure) {
        let questionId = currentQuestion()?.id
        _ = attemptLedger.noteAnswerAttempt(questionId: questionId)
        trackAnalytics(.voiceCaptureFailed(reason: reason, questionId: questionId))
    }

    /// One batch recording just stopped. Takes the route and mic state read
    /// before the engine was released, like "answer recording stopped"; must
    /// run before the attempt is counted (submit or capture failure), which
    /// would turn `is_retry` on.
    func trackAnswerCaptured(
        reason: RecordingStopReason,
        heardSpeech: Bool,
        detection: AnswerDetectionReport,
        durationMs: Int,
        voiceProcessing: Bool,
        outputPort: String,
        mic: MicCaptureSnapshot,
        experiment: VoiceExperimentStore = .shared
    ) {
        let questionId = currentQuestion()?.id
        attemptLedger.latency.noteSpeechOnset(durationMs: durationMs, firstSpeechMs: detection.firstSpeechMs)
        let flags = Dictionary(uniqueKeysWithValues: VoiceExperimentFlag.allCases.map { ($0, experiment.flag($0)) })
        let report = AnswerCapturedReport(
            questionId: questionId,
            isRetry: attemptLedger.isRetryAttempt(questionId: questionId),
            autoTest: experiment.autoTesting,
            flags: flags,
            routeGroup: experiment.routeGroup,
            outputRoute: outputPort,
            inputRoute: mic.inputRoute,
            stopReason: reason,
            detector: detection.detector.rawValue,
            heardSpeech: heardSpeech,
            speechMs: detection.speechMs,
            endDelayMs: AnswerCapturedReport.endDelayMs(durationMs: durationMs, lastSpeechEndMs: detection.lastSpeechEndMs),
            durationMs: durationMs,
            voiceProcessing: voiceProcessing,
            ecEnabled: mic.ecEnabled,
            aecApplicable: experiment.aecApplicable(outputPort: outputPort),
            frontMicApplicable: mic.builtInMicOnly && !voiceProcessing,
            micDataSource: mic.micDataSource,
            micPolarPattern: mic.micPolarPattern,
            rejectedCount: rejectedTranscriptCount()
        )
        trackAnalytics(.answerCaptured(report))
    }
}
