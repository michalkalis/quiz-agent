//
//  AnswerSpellingHint.swift
//  Hangs
//
//  #208.6 (founder 2026-10-16): after the player threw a transcript of the
//  question away once, the question screen and the answer sheet say the answer
//  can be spelled letter by letter. The backend joins spelled letters into a
//  word, so the app only shows the line. Ordinary UI text in the app language,
//  like `EmptyAnswerRetryHint`, but muted: a tip, not a miss.
//

import SwiftUI

struct AnswerSpellingHint: View {
    private enum Metrics {
        static let textSize: CGFloat = 15
    }

    var body: some View {
        Text(
            "You can also spell your answer: P, A, R, I, S.",
            comment: "Hint after the player rejected a transcript: the answer can be spoken letter by letter. The example spells Paris as it is written in this language."
        )
        .font(.hangsBody(Metrics.textSize, weight: .medium))
        .foregroundColor(Theme.Hangs.Colors.muted)
        .multilineTextAlignment(.center)
        .lineLimit(2)
        .minimumScaleFactor(0.8)
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("answer.spellingHint")
    }
}
