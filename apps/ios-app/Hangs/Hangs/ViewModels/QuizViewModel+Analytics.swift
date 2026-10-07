//
//  QuizViewModel+Analytics.swift
//  Hangs
//
//  #51: the quiz's product analytics. Every event rides on an existing
//  transition; the session id is attached here so the app's events join the
//  server's own quiz events (`quiz_started`, `answer_evaluated`, …).
//

extension QuizViewModel {
    /// The child coordinators reach this through their injected closure.
    func trackAnalytics(_ event: AnalyticsEvent) {
        analytics.track(event, sessionId: currentSession?.id)
    }

    /// Right after a quiz starts: where it came from and where its sound goes.
    func trackQuizContext(entryPoint: QuizEntryPoint) {
        trackAnalytics(.quizContext(
            audioRoute: .current,
            voiceCommandsEnabled: settings.voiceCommandsEnabled,
            entryPoint: entryPoint
        ))
    }

    func trackAnswerSubmitted(_ inputMode: AnswerInputMode, questionId: String?) {
        let isRetry = attemptLedger.noteAnswerAttempt(questionId: questionId)
        trackAnalytics(.answerSubmitted(inputMode: inputMode, questionId: questionId, isRetry: isRetry))
    }
}
