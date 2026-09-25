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
    var body: some View {
        Text("I didn't catch your answer, please try again.")
            .font(.hangsBody(15, weight: .semibold))
            .foregroundColor(Theme.Hangs.Colors.ink)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("question.retryHint")
    }
}
