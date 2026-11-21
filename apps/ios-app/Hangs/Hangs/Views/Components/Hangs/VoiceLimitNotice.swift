//
//  VoiceLimitNotice.swift
//  Hangs
//
//  Free tier split (founder 2026-11-21, D1): this month's free voice answers
//  are used up. Shown once a month on the question where it happened, next
//  to the controls it explains, like the retry line (`EmptyAnswerRetryHint`).
//  It never blocks the question: the Plus link is a quiet text link, the
//  question stays answerable by typing or tapping. The spoken twin is
//  `SpokenPrompt.voiceLimitLine` (quiz language); this follows the app one.
//

import SwiftUI

struct VoiceLimitNotice: View {
    let onPlus: () -> Void

    private enum Metrics {
        /// The retry line's size (`EmptyAnswerRetryHint`): both sit above the controls.
        static let lineSize: CGFloat = 15
    }

    var body: some View {
        VStack(spacing: Theme.Hangs.Spacing.xxs) {
            Text("This month's free voice answers are used up. Keep playing by typing or tapping.")
                .font(.hangsBody(Metrics.lineSize, weight: .semibold))
                .foregroundStyle(Theme.Hangs.Colors.ink)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("question.voiceLimitNotice")
            HangsGhostButton(title: "Unlimited voice with Trubbo Plus", action: onPlus)
                .accessibilityIdentifier("question.voiceLimitPlus")
        }
        .frame(maxWidth: .infinity)
    }
}
