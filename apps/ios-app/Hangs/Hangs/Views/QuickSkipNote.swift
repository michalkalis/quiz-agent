//
//  QuickSkipNote.swift
//  Hangs
//
//  #224.8 (canvas D4): the note a quick game shows on the next question after
//  a skip, "Skipped, correct: 1989". Brief and non-blocking: it sits over the
//  top of the question, takes no touches and leaves by itself
//  (`QuizViewModel.quickSkipNote`).
//

import SwiftUI

struct QuickSkipNote: View {
    let correctAnswer: String

    var body: some View {
        Text("Skipped, correct: \(correctAnswer)")
            .font(.hangsLabel)
            .foregroundStyle(Theme.Hangs.Colors.ink)
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .padding(.horizontal, Theme.Hangs.Spacing.md)
            .padding(.vertical, Theme.Hangs.Spacing.xs)
            .background(
                Capsule().fill(Theme.Hangs.Colors.bgCard)
                    .strokeBorder(Theme.Hangs.Colors.hairline)
            )
            .hangsShadow(Theme.Hangs.Shadow.raised)
            .padding(.horizontal, Theme.Hangs.Spacing.md)
            .allowsHitTesting(false)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("question.quickSkipNote")
    }
}

#if DEBUG
    #Preview {
        QuickSkipNote(correctAnswer: "1989")
            .padding()
            .background(Theme.Hangs.Colors.bg)
    }
#endif
