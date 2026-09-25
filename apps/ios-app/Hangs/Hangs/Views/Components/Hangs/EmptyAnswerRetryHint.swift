//
//  EmptyAnswerRetryHint.swift
//  Hangs
//
//  #185 track B (founder 2026-09-24): during the one automatic retry after an
//  empty answer, the line the app speaks is ALSO shown right above the mic's
//  bar — with sound and when muted alike, so a muted driver still learns why the
//  mic opened again. Ordinary UI text: it follows the app language, while the
//  spoken line (`SpokenPrompt`) follows the quiz language.
//

import SwiftUI

struct EmptyAnswerRetryHint: View {
    /// Which line is being spoken (#185 track G: an MCQ answer that named no
    /// option has its own).
    var prompt: SpokenPrompt = .didNotCatch

    var body: some View {
        line
            .font(.hangsBody(15, weight: .semibold))
            .foregroundColor(Theme.Hangs.Colors.ink)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("question.retryHint")
    }

    private var line: Text {
        switch prompt {
        case .didNotCatch: Text("I didn't catch your answer, please try again.")
        case .mcqUnmatchedNumber: Text("I didn't catch which option you meant. Please say its number.")
        case .mcqUnmatchedLetter: Text("I didn't catch which option you meant. Please say its letter.")
        }
    }
}
