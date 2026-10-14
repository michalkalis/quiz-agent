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

@preconcurrency import AVFoundation

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

    /// One batch recording just stopped. Reads the same live state as
    /// "answer recording stopped"; must run before the attempt is counted
    /// (submit or capture failure), which would turn `is_retry` on.
    func trackAnswerCaptured(
        reason: RecordingStopReason,
        heardSpeech: Bool,
        detection: AnswerDetectionReport,
        durationMs: Int,
        voiceProcessing: Bool,
        outputPort: String,
        experiment: VoiceExperimentStore = .shared
    ) {
        let session = AVAudioSession.sharedInstance()
        let questionId = currentQuestion()?.id
        let flags = Dictionary(uniqueKeysWithValues: VoiceExperimentFlag.allCases.map { ($0, experiment.flag($0)) })
        let report = AnswerCapturedReport(
            questionId: questionId,
            isRetry: attemptLedger.isRetryAttempt(questionId: questionId),
            autoTest: experiment.autoTesting,
            flags: flags,
            routeGroup: experiment.routeGroup,
            outputRoute: outputPort,
            inputRoute: VoiceProcessingPolicy.currentInputPort(),
            stopReason: reason,
            detector: detection.detector.rawValue,
            heardSpeech: heardSpeech,
            speechMs: detection.speechMs,
            endDelayMs: AnswerCapturedReport.endDelayMs(durationMs: durationMs, lastSpeechEndMs: detection.lastSpeechEndMs),
            durationMs: durationMs,
            voiceProcessing: voiceProcessing,
            ecEnabled: session.isEchoCancelledInputEnabled,
            aecApplicable: VoiceRouteGroup(outputPortName: outputPort) == .btCar && session.isEchoCancelledInputAvailable,
            frontMicApplicable: session.currentRoute.inputs.map(\.portType) == [.builtInMic] && !voiceProcessing,
            micDataSource: MicCapturePolicy.micDataSource(session),
            micPolarPattern: MicCapturePolicy.micPolarPattern(session),
            rejectedCount: rejectedTranscriptCount()
        )
        trackAnalytics(.answerCaptured(report))
    }
}
