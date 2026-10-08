//
//  QuizViewModel+QuestionScreen.swift
//  Hangs
//
//  What the question screen derives from the quiz state: sheet presentation,
//  the busy predicate, the progress counter, the matched-option label and the
//  listen-bar phase. Moved out of QuestionView in #194 A1 so the redesign only
//  restyles layout and cannot change these rules.
//

import Foundation

extension QuizViewModel {
    /// The confirmation sheet is on screen. #173 C2: `confirmAnswer()` clears
    /// `showAnswerConfirmation` synchronously (its single-flight token), so the
    /// sheet's presentation outlives it by `isEvaluatingAnswer` — the driver keeps
    /// looking at the button they pressed while the answer is graded. One
    /// predicate for both the sheet and the #174 A1 dim, so the quiz can never be
    /// dimmed without the sheet or vice versa.
    var isAnswerSheetPresented: Bool {
        showAnswerConfirmation || isEvaluatingAnswer
    }

    /// The sheet shows its Transcribing spinner. `!isEditingTranscript`: deleting
    /// the whole prefill while editing must not flip the sheet into the spinner
    /// (TF build 53 "dialog vanished" bug). `!noAnswerCaptured` (#171 Track B):
    /// the no-answer sheet is also `.processing` with an empty field, but nothing
    /// is in flight — the spinner there would hide the Confirm CTA.
    var isAnswerSheetTranscribing: Bool {
        quizState == .processing && transcribedAnswer.isEmpty
            && !isEditingTranscript && !noAnswerCaptured
    }

    /// "Something is in flight and no sheet is covering the question screen."
    /// The confirmation sheet also lives in `.processing` (every voice answer
    /// passes through it, and since #173 C2 it stays up until the result lands),
    /// so the controls underneath must not read as busy while the driver is
    /// still being asked to confirm.
    var isQuestionScreenBusy: Bool {
        guard !showAnswerConfirmation, !isEvaluatingAnswer else { return false }
        return quizState == .processing || quizState == .skipping
    }

    var questionScreenTotal: Int {
        currentSession?.maxQuestions ?? settings.numberOfQuestions
    }

    /// 1-based, clamped to the set so the progress header never reads 0/10 or 11/10.
    var questionScreenNumber: Int {
        let total = questionScreenTotal
        let number = askedQuestionNumber ?? questionsAnswered + 1
        return min(max(number, 1), max(total, 1))
    }

    /// #171 Track I: "A · Kocka" for the confirmation sheet when a spoken answer
    /// resolved to an MCQ option. Derived from the same `mcqVoiceMatchedKey` the
    /// option grid highlights, so the sheet can never disagree with the grid.
    var matchedVoiceOptionLabel: String? {
        guard let key = mcqVoiceMatchedKey,
              let question = currentQuestion,
              let value = question.possibleAnswers?[key]
        else { return nil }
        return "\(question.optionLabel(for: key)) · \(value)"
    }

    /// A chip is a promise the word will be heard: it needs the Settings toggle
    /// AND an armed listener (`commandListenerHint`), which is what the bar was
    /// gated on wholesale before #179 D1 — the bar stays either way now.
    var showsCommandWords: Bool {
        showsVoiceHints && commandListenerHint != nil
    }

    /// #179 D1: the one state model, asked the same way by both question types.
    func listenPhase(for question: Question) -> QuestionListenPhase? {
        QuestionListenPhase.current(
            quizState: quizState,
            answerWindowRemaining: answerWindowRemaining,
            answerWindowTotal: answerWindowTotal,
            answerKind: question.sortedAnswerOptions.count == 2
                ? .trueFalse
                : (question.usesLetterLabels ? .mcqLetters : .mcq)
        )
    }
}
